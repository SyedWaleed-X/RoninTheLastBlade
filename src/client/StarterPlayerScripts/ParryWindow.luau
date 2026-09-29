--!strict

--[[
	ParryWindow
	Ronin — The Last Blade · the 133ms parry window (Day 7 · Part 1/2)

	COMBAT_SPEC §1 defines `Parrying` as a "precision 133ms reaction window [that]
	cancels incoming damage and reflects heavy posture damage". This module is the
	client half of that: it owns *when the player pressed block* and therefore *how
	long the window is still open*, and it answers three questions for the rest of
	the client.

	    OnBlockPressed()      a press happened - open a window, return its width
	    IsParryActive()       is a hit landing right now inside that window?
	    GetRemainingWindow()  how long is left, in ms, for the HUD countdown

	Why this is a module and not a line inside InputBinder
	--------------------------------------------------------
	Because the timing is not the binder's business. InputBinder's whole contract is
	"record intent, ask the machine if it is legal, hand it over" - it has no state
	of its own, and the parry window is state. Putting it here means the input sink
	stays a sink, the HUD can read the same countdown the hit resolution will, and
	the rule that a second press within the cooldown shortens the window exists in
	exactly one place instead of once per consumer.

	The spam ladder, and why a parry has to decay at all
	------------------------------------------------------
	A parry that costs the attacker 25 posture and the defender nothing is a strictly
	better button than blocking. Held down it would be an unanswerable defence: take
	no damage, win the posture war, never lose a trade. So pressing block *again*
	inside `PARRY_SPAM_RESET_COOLDOWN` walks the player down the shared ladder
	(133ms -> 80ms -> 33ms), and holding the button does nothing at all - a hold
	produces exactly one `Begin` edge and `OnBlockPressed` is only ever called from
	that edge.

	The ladder values are read from `AttackConfig` rather than written here, because
	the server re-derives the same ladder and two copies of a timing number that
	disagree fail in the worst possible way - a parry the player timed correctly
	that the server refuses. See the note on `PARRY_WINDOW_LADDER` in AttackConfig.

	What this module is NOT allowed to decide
	--------------------------------------------
	Whether the parry *succeeded*. It measures a window; `HitValidator` decides what
	happened inside it, and this client tells the server when a window opened so the
	server can open its own. A client that lies about a window gets a window it
	cannot time - the same property the guard flag has had since Day 6.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - the client predicts that it *pressed*; the server decides
	    what that was worth. This module fires no remotes and changes no state.
	  * ARCHITECTURE.md #4 - no per-frame path. Every function is called on an input
	    edge or read by a consumer; nothing here runs on Heartbeat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")



local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
--[[
	Window widths, in seconds, worst case last. Index 1 is a clean press; each
	additional press inside the cooldown steps one rung down the shared ladder, and
	the last rung is a floor rather than a continuing decay - a button that keeps
	losing accuracy forever stops being a timing mechanic and becomes a joke.

	`BASE_WINDOW` is what a clean press opens and is named because the HUD and the
	console both quote it back to the player; `MIN_WINDOW` is the floor the ladder
	cannot fall below. Both are read from the shared config rather than written here,
	so there is no second copy of the number to drift.
]]
local WINDOW_LADDER = AttackConfig.PARRY_WINDOW_LADDER
local BASE_WINDOW = WINDOW_LADDER[1]
local MIN_WINDOW = WINDOW_LADDER[#WINDOW_LADDER]
local RESET_COOLDOWN = AttackConfig.PARRY_SPAM_RESET_COOLDOWN

-- Sentinel for "block has never been pressed this session". -math.huge makes the
-- first press's `now - LastPressTime` a large positive number, so the very first
-- press in a session takes the "cooldown expired" path and opens the full window
-- rather than decaying off the end of the ladder.
local NO_PRESS_YET = -math.huge

--[[
	The only two pieces of state this module has, and both are numbers.

	ActiveParryUntil - os.clock() reading past which the window has closed. Zero
	                    initially, which is safely in the past, so a character that
	                    has never pressed block can never read as parrying.
	LastPressTime    - when the last `OnBlockPressed` landed, used only to decide
	                    whether that press decays the window or restores it.
	CurrentRung      - which rung of the ladder the *next* press will open. This is
	                    the state the ladder actually is; without it persisted, every
	                    press would recompute from the top and the decay would be
	                    unobservable (see the note at the step below).
]]
local ActiveParryUntil = 0
local LastPressTime = NO_PRESS_YET
local currentRung = 1

--[[
	The module's own table.

	Declared here, after the state it closes over, so the methods below can be
	written as `function ParryWindow.X()` rather than as a `table.freeze({...})`
	literal at the bottom of the file. Every other module in `PlayerScripts` that
	exposes methods does the same (`StateMachine`, `BladeHitbox`, `InputGate`), and
	the reason is not style: a module that assigns to a name it never declared
	creates a *global*, and a global is silently shared across every copy of this
	script in the place — so two players' windows would write to the same table.
]]
local ParryWindow = {}


--[[
	Called on the `Begin` edge of the block input.

	Returns the width of the window it just opened, in seconds, because the caller
	wants to say so out loud and reconstructing it from the ladder index would be a
	second copy of the rule that decides it.

	The window is opened *after* the ladder step, not before: a press that decays to
	the floor still gets a floor-width window, so mashing is always weakly worse than
	not mashing rather than being strictly worse than doing nothing at all.
]]
function ParryWindow.OnBlockPressed(): number
	local now = os.clock()

	--[[
		Ladder step. A press inside the cooldown walks *down* one rung and remembers
		that it did; a press after the cooldown (or the first of the session) resets
		to the top.

		`currentRung` is module state rather than a local on purpose, and getting
		this wrong was a real bug caught in playtest: written as a local initialised
		to 1, every press inside the cooldown produced rung 2, so the ladder read
		133 -> 133 -> 133 -> 80 -> 80 -> 80 and the 33ms floor was unreachable. The
		player could mash forever and never be punished past the second rung, which is
		exactly the outcome the ladder exists to prevent. A decay that recomputes from
		scratch on each press is not a decay, it is a comparison.
	]]
	if now - LastPressTime < RESET_COOLDOWN then
		currentRung += 1
		if currentRung > #WINDOW_LADDER then
			currentRung = #WINDOW_LADDER
		end
	else
		currentRung = 1
	end

	local rung = currentRung
	local window = WINDOW_LADDER[rung]
	if window < MIN_WINDOW then
		window = MIN_WINDOW
	end

	LastPressTime = now
	ActiveParryUntil = now + window

	print(string.format(
		"[PARRY] Block pressed: %dms window (rung %d/%d) at %.3f",
		math.floor(window * 1000),
		rung,
		#WINDOW_LADDER,
		now
	))

	return window
end


--[[
	Is a hit landing *right now* inside the open window?

	Deliberately a comparison against the clock rather than a stored boolean: a
	boolean would have to be cleared by something, and the only things that could
	clear it are another press, the guard dropping, or a timer. Any of the three can
	be missed, and a parry flag left stuck on is an invulnerable client. Reading the
	clock cannot be left in a wrong state, because it is derived on every call.

	`<=` rather than `<` so the frame landing exactly on the boundary still counts as
	a parry: at 60Hz the difference is one frame, and a player who pressed on a frame
	boundary should not lose the window they earned.
]]
function ParryWindow.IsParryActive(): boolean
	return os.clock() <= ActiveParryUntil
end

--[[
	Milliseconds left in the open window, floored at zero.

	Milliseconds rather than seconds because the number is only ever rendered - the
	HUD prints it beside the input telemetry's `XXX ms` readout, and a consumer that
	had to multiply by 1000 to match its own label would eventually forget to.
]]
function ParryWindow.GetRemainingWindow(): number
	local remaining = ActiveParryUntil - os.clock()
	if remaining <= 0 then
		return 0
	end

	return remaining * 1000
end


--[[
	The width the currently-open window was set to, in seconds, or 0 when no window
	is open.

	The HUD's success line reports the window that was actually live, which is not
	always the base one: a player who mashed down to the floor rung and then timed
	that 33ms window perfectly deserves to be told "33ms", not "133ms". Reading it
	back as `ActiveParryUntil - LastPressTime` (rather than tracking a separate
	`ActiveWindow` field) is what guarantees the number quoted to the player is the
	same number the hit resolution measured.
]]
function ParryWindow.GetActiveWindow(): number
	if not ParryWindow.IsParryActive() then
		return 0
	end

	local window = ActiveParryUntil - LastPressTime
	if window > BASE_WINDOW then
		return BASE_WINDOW
	end

	return window
end

--[[
	Forgets the window.

	Called when the character is torn down. A dead character leaving a live window
	would otherwise hand the next body a deflect it never earned: the new character
	spawns still inside the old one's sliver, and the first strike to land in it is a
	perfect parry with no press behind it. Clearing the ladder position too means
	the new life starts at the top rung rather than inheriting a mash penalty the
	player has not committed yet.
]]
function ParryWindow.Reset()
	ActiveParryUntil = 0
	LastPressTime = NO_PRESS_YET
	currentRung = 1
end

return ParryWindow

