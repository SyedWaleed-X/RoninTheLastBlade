--!strict

--[[
	CombatController
	Ronin — The Last Blade · local character lifecycle binder

	Keeps exactly one combat state machine alive per character:
	  * CharacterAdded           -> build a fresh StateMachine("Idle"), publish it to
	                                CombatStateBus and log every transition it makes.
	  * Humanoid.Died / CharacterRemoving -> detach the listener, neutralise the
	                                machine and release the reference so nothing
	                                outlives the character.

	Per docs/ARCHITECTURE.md #3 this controller is local prediction and presentation
	only: the server remains the sole authority for damage and state transitions.

	This file is a LocalScript (Script Sync suffix `.local.luau`). StarterPlayerScripts
	is already a per-player container, so a Script carrying a non-legacy RunContext in it
	starts twice per client (Studio warns about exactly that combination); a local script
	runs once, which is what a single-machine-per-character contract needs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[[
	Day 8 · Part 2/2: required for the heartbeat that holds the stun freeze. The
	only service this file added across the whole project until now, and added
	deliberately — see `holdStunFreeze` for why a one-shot write was not enough.
]]
local RunService = game:GetService("RunService")

local StateMachine = require(ReplicatedStorage:WaitForChild("StateMachine") :: ModuleScript)
local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

-- Client-local bridge: publishes the bound machine to observers (the debug HUD) and to
-- the keyboard/chaos harness. Every client script shares the one bus in PlayerScripts.
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)

--[[
	Day 6 · Part 2/2: required here purely for its side effect of subscribing to
	`GuardClashEvent`.

	A ModuleScript in StarterPlayerScripts does not run until something requires it -
	it is not a LocalScript, so there is no automatic execution - and a spark emitter
	nobody required is a spark emitter that silently never draws anything. The
	alternative, having WeaponVisuals require it, would tie the *visual* effect to the
	*rig* module; requiring it from the guard's own controller keeps the pair - break
	and clash, the two halves of the server's guard wire - described in one place.

	The result is deliberately discarded: the module exports nothing, and the require
	is for the connection it opens at load time.
]]
require(script.Parent:WaitForChild("GuardSparks") :: ModuleScript)

--[[
	Day 7 · Part 1/2: required for the parry window itself.

	`InputBinder` calls `OnBlockPressed` on the block press, but the *reading* of
	whether a window is still open is needed here — a state transition into Blocking
	has to publish the claim with the window's live state, and a stale answer would
	tell the server a parry that has already closed. Same reasoning as the `GuardSparks`
	require above: a ModuleScript in PlayerScripts does not run until something
	requires it, and the require is for the shared instance both scripts then read.
]]
local ParryWindow = require(script.Parent:WaitForChild("ParryWindow") :: ModuleScript)

--[[
	Day 7 · Part 1/2: the deflect micro-pause, required for its `Apply` side effect.

	Same reasoning as the two requires above — a ModuleScript in PlayerScripts runs
	only once something requires it, and this is the one place in the client that
	decides a deflect happened *and* owns the local character it happened to.
]]
local Hitstop = require(script.Parent:WaitForChild("Hitstop") :: ModuleScript)

--[[
	Day 7 · Part 2/2: the deflect's clang and camera punch.

	Required here because this is the one client-side place that knows a deflect
	happened *to this player* — both deflect remotes land in this file, and they are
	the only two events in the project that can say so. Sound and camera are per
	viewer, so they have to be driven from the viewer's own client, and the
	punctuation of the parry is not `Hitstop`'s job: see that module's header.
]]
local DeflectFeedback = require(script.Parent:WaitForChild("DeflectFeedback") :: ModuleScript)

local localPlayer = Players.LocalPlayer

type CombatAction = InputBuffer.CombatAction

--[[
	Action -> effect. The single mapping from a spent intent to the transition it
	causes, shared by the two paths that can spend one: the Idle branch of the
	transition handler below, and the direct intake further down.

	There is exactly one copy of this mapping on purpose. A LightAttack pressed while
	the character is already Idle has to behave identically to the same press spent a
	frame later by the Idle handler; two copies of "what does Guard do" is precisely
	how those two paths would drift apart.
]]
local function dispatchAction(action: CombatAction): boolean
	if action == "LightAttack" then
		-- The swing is not a single Idle -> Windup edge any more. AttackController
		-- requests the Windup itself and then drives Active, Recovery and Idle on its
		-- own frame-data timers, so this only spends the input and hands over. It is
		-- reached through the bus because `require` cannot load a LocalScript.
		return CombatStateBus.RunLightAttack()
	elseif action == "Guard" then
		return CombatStateBus.RequestState("Blocking")
	end

	-- Dodge and Execute are bound and queued but have no transition wired up yet.
	return false
end

--[[
	Day 4 · Part 2/2 — direct intake, registered on the bus for InputBinder.

	A press made while the character is already Idle is spent immediately, in the same
	callback that observed it, instead of waiting for a transition into Idle that may
	never come. Before this the only read of the queue was the Idle branch below, so a
	click made while the character was standing still sat unspent until something else
	had to move the machine first.

	Two details make the direct path safe to add:

	  * The press evicts whatever an earlier press left in the queue before it is
	    spent. InputBuffer is a single slot with a "latest press wins" rule, and this
	    path bypasses Push, so without the eviction a guard tapped 150ms earlier
	    would still be sitting there and would be spent *instead* of the attack the
	    player just made - the newest intent silently lost.
	  * Latency is reported as 0 because that is the truth here: the intent is
	    dispatched inside the input event itself, so the telemetry panel's "spend
	    latency" for a direct press really is zero.
]]
local function offerIntent(action: CombatAction): boolean
	InputBuffer.Clear()

	local machine = CombatStateBus.GetActiveMachine()
	if machine == nil or machine.CurrentState ~= "Idle" then
		-- Busy: the intent goes into the queue and the Idle branch of
		-- onStateChanged spends it the instant the character becomes actionable.
		-- This is the COMBAT_SPEC §2.4 chaining path, unchanged.
		InputBuffer.Push(action)
		return false
	end

	CombatStateBus.RecordConsumed(action, 0)

	return dispatchAction(action)
end

CombatStateBus.SetActionIntake(offerIntent)

--[[
	Day 6 · Part 1/2 — publishing the guard to the server.

	The client owns when the player is *holding* the button; the server owns whether
	that actually blocks anything. This is the seam between them: one boolean, sent
	only on a change, and the server writes the authoritative attribute that
	`HitValidator` reads when a hit lands.

	It lives here rather than in `InputBinder` for one specific reason: this module
	already observes every transition the machine makes, from every source - the
	direct intake, the buffered action spent on the next Idle, the Day 6 hold path,
	and the debug harness. Firing the event from the transition means the server
	can never be told "I am Blocking" by a path that forgot to tell it, which is the
	failure that would leave a guard visibly up on the client and doing nothing on
	the server. One observer, one place that publishes, no drift.

	Only changes are sent. A player who holds guard for a minute produces exactly
	one message, not one per frame - the alternative would be a remote firing on
	every Heartbeat, which is a bandwidth cost for information that never changes.
]]
local guardEvent = ReplicatedStorage:WaitForChild(AttackConfig.REMOTE_GUARD_EVENT, 10) :: RemoteEvent?

--[[
	The last pair published to the server, tracked as two separate optionals rather
	than one record.

	A single `lastPublished: {blocking, parry}?` table would be the tidier shape and
	would allocate one table on each publish; two scalars cost nothing and cannot go
	stale relative to each other, because they are only ever written in the same
	statement. Both start nil, which is what makes the very first publish go out.
]]
local lastPublishedGuard: boolean? = nil
local lastPublishedParry: boolean? = nil

--[[
	Publishes the guard state, skipping the send when it already matches what the
	server was last told. `lastPublishedGuard` starts nil rather than false so the
	very first publish always goes out - a player who spawns already holding the
	button (impossible today, possible the moment guard is buffered) must not be
	silently skipped by an optimistic default.

	nil is also written on teardown, so a respawn re-publishes rather than assuming
	the server still believes the old character is guarding.

	Day 7 · Part 1/2: this is also where the parry claim goes out, as a third
	argument, and the deduplication had to widen to match.

	The old check was `lastPublishedGuard == isBlocking`, which is correct for a
	boolean and silently wrong for a pair. A press that opens a parry while the guard
	is already published `true` produces the *same* boolean as the publish that
	preceded it, so the old comparison would drop it and the server would never learn
	a window had opened - the player would parry perfectly and be told nothing
	happened. Tracking the two halves separately is the smallest change that makes
	the guard publish and the parry publish independent, which they now are: a window
	can open without the guard changing state, and the guard can drop without a window
	ever having existed.
]]
local function publishGuardState(isBlocking: boolean, isParrying: boolean)
	if guardEvent == nil then
		return
	end

	if lastPublishedGuard == isBlocking and lastPublishedParry == isParrying then
		return
	end

	lastPublishedGuard = isBlocking
	lastPublishedParry = isParrying
	guardEvent:FireServer(isBlocking, isParrying)
end

--[[
	Day 7 · Part 1/2: the inbound half of the parry seam.

	`InputBinder` is a LocalScript, so it cannot be required here; it announces the
	press through the bus and this is the one place that answers. Registering rather
	than subscribing keeps the "one observer publishes the guard" invariant intact -
	there is exactly one publisher of `GUARD_STATE_ATTRIBUTE` on the client, and this
	is it.

	`isParrying` is forwarded as the client's *claim*; the server re-derives the
	window width from its own ladder (see `openParryWindow`), so nothing here decides
	how long the window is.
]]
CombatStateBus.SetParryPressListener(function(windowSeconds: number)
	print(string.format(
		"[GUARD] Publishing parry claim: %dms window at %.3f",
		math.floor(windowSeconds * 1000),
		os.clock()
	))

	-- A press is only published as a parry while the guard is actually up. The
	-- binder calls this before the state request, so the machine may not have moved
	-- yet; reading it here means a press made while mid-swing is still recorded by
	-- the client's own ladder (which is where the spam penalty belongs) but is not
	-- announced to the server as a live parry.
	publishGuardState(CombatStateBus.GetCurrentState() == "Blocking", true)
end)

--[[
	Resets the published state on respawn. The new character has no guard attribute
	and the server has a fresh `player.Character`, so the next transition out of
	Blocking has to be able to send `false` again - which it cannot if the last
	published value was already `false`.
]]
local function resetPublishedGuard()
	lastPublishedGuard = nil
	lastPublishedParry = nil
end

--[[
	Day 6 · Part 2/2 — the server's guard break, applied locally.

	`HitValidator` decides that a defender's posture has shattered and *tells* this
	client, because the state machine it needs to move is the one living in this
	process (ARCHITECTURE.md #3: the client predicts, the server decides). This is that
	decision landing, and it is the first thing in the project where a state
	transition originates on the server rather than on input.

	Two things are checked before the machine is touched, and both matter:

	  * The payload must name *this player's own character*. The remote is targeted,
	    so in practice it always does - but a `Stunned` that lands on the wrong
	    character is a permanent input lock, and the cost of refusing a misrouted
	    event is one frame of blocking.
	  * The duration is clamped to the spec's 0.5-3.0s Stunned band rather than
	    trusted. A negative duration would leave the machine in `Stunned` with a timer
	    already in the past, and a huge one would be a soft ban delivered by accident.

	The release is scheduled on the *machine*, not the character: if the player dies or
	respawns during the stun, teardown drops the reference and the machine is replaced,
	so a timer that fired against a retired machine would be writing to a dead object.
	Re-reading the active machine and confirming it is still `Stunned` before
	releasing covers the case where something else (a parry, a debug reset) already
	moved it on - without that check the timer would yank the character out of whatever
	state it had legitimately reached.
]]
local guardBreakEvent = ReplicatedStorage:WaitForChild(AttackConfig.REMOTE_GUARD_BREAK_EVENT, 10) :: RemoteEvent?
local MIN_STUN_DURATION = 0.1
local MAX_STUN_DURATION = 3.0

--[[
	Day 8 · Part 2/2: the values the freeze restores to, read once from the shared
	config so the client and the server cannot disagree about what "a character at
	rest" means.

	These are **fallbacks**, and the distinction is load-bearing. Day 8 · Part 1/2
	invariant 4 is that WalkSpeed is *captured*, never assumed: `WeaponVisuals` writes
	`GUARD_WALK_SPEED` (9) on guard and restores its own captured rest value on
	release, so a client that woke a stunned character up at a hardcoded 16 would
	leave `WeaponVisuals` permanently restoring 16 as *its* rest speed afterwards.
	The capture below is what actually gets restored; these are only what a
	character with nothing captured falls back to.
]]
local REST_WALK_SPEED = AttackConfig.DEFAULT_WALK_SPEED
local REST_JUMP_POWER = AttackConfig.DEFAULT_JUMP_POWER

--[[
	Day 8 · Part 2/2: the captured pre-stun movement state.

	Scoped to this file rather than to `bindCharacter` on purpose. `onStateChanged`
	runs on a `task.spawn`ed thread, so a per-character local could be captured by a
	stun entry whose release is still pending when the next character binds. There is
	exactly one bound character at a time — `bindCharacter` returns the teardown that
	retires the previous one — so a second capture can only ever overwrite a value
	belonging to a body that is already gone.

	`nil` means "nothing captured": the release then falls back to the config values
	rather than writing a number read off a destroyed Humanoid.
]]
local capturedWalkSpeed: number? = nil
local capturedJumpPower: number? = nil

--[[
	Day 8 · Part 2/2: a generation stamp, so a release belonging to an *earlier*
	stun cannot undo the current one.

	`StateMachine` dispatches listeners through `task.spawn`, so the release thread
	and the freeze thread are independent and can interleave. The sequence this
	guards against was observed on the first live playtest as a single burst of
	property writes on the client Humanoid:

	    JUMP->0  ROT->false   WALK->16  WALK->0  JUMP->50  ROT->true

	Read left to right: the new stun froze the body, and then the release belonging
	to the *previous* rupture - whose 3.0s server timer expired inside the same
	interval - restored it. The character spent the whole stagger jumpable and
	turning, with `WalkSpeed` at 0 only because the server had independently
	written that a frame later, which is why the freeze looked half-applied.

	Stamping each freeze and carrying the stamp into the release means a release
	only restores movement when it is releasing the stun that is actually current.
	A stale one is dropped, and because the server owns `WalkSpeed` and re-asserts
	it for the whole rupture, a dropped release costs one redundant write and
	nothing else.
]]
local stunGeneration = 0
local activeStunGeneration = 0

--[[
	The Humanoid the freeze is currently being asserted against, or nil when the
	character is not frozen.

	Held as a reference rather than re-resolved from `localPlayer.Character` on every
	re-assert, because a re-resolve would silently start writing to a *new* body if
	the character respawned between the stun and the re-assert. Pinning the instance
	means the freeze can only ever affect the body it was applied to, and the liveness
	test in `holdStunFreeze` retires it.
]]
local frozenHumanoid: Humanoid? = nil

--[[
	Day 8 · Part 2/2: the client-side stun freeze.

	`Stunned` in COMBAT_SPEC §1 is "complete input lock", and until this day the client
	only locked *state* — the machine refused transitions, so no action could be
	dispatched — while the body itself was still free to walk and jump. A rooted
	character that keeps running is the most visible way a hitstun fails to read as a
	hitstun, and it undercuts the posture economy too: a player who is supposed to be
	kneeling and helpless could walk out of the attacker's reach during the 3.0s.

	Both properties are written **synchronously**, and everything that cancels runs
	before the first yield. `StateMachine.SetState` dispatches listeners through
	`task.spawn`, so this body does not run on the frame the transition happened —
	anything deferred past a yield here would be a visible frame of walking through
	the stagger, and the point of the change is that there are none.

	`ResetComboChain` stops an in-flight swing (it is the only seam that reaches
	`AttackController`) and `InputBuffer.Clear` drops anything queued in the last
	200ms. Neither is optional: a swing that kept its arm animation would visibly
	continue through the stagger, and a queued press would be spent by the `Idle`
	handler on the very frame the stun expires.
]]
local function applyStunFreeze()
	local character = localPlayer.Character
	if character == nil then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	-- Capture only on the way in, and only once. A second entry inside the same stun
	-- (which ALLOWED_TRANSITIONS refuses, but which a guard-break event racing a
	-- stagger would attempt) must not overwrite the original capture with the frozen
	-- 0, or the release would restore 0 and leave the character rooted permanently.
	if capturedWalkSpeed == nil then
		capturedWalkSpeed = humanoid.WalkSpeed
		capturedJumpPower = humanoid.JumpPower
	end

	stunGeneration = stunGeneration + 1
	activeStunGeneration = stunGeneration
	frozenHumanoid = humanoid

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false

	CombatStateBus.ResetComboChain()
	CombatStateBus.SetStunInputLock(true)
	InputBuffer.Clear()
end

--[[
	Day 8 · Part 2/2: re-assert the freeze while it is held.

	`PostureEngine` owns `WalkSpeed` during a rupture and writes it to 0 on the way in
	and back to the captured value on the way out, from a `task.delay` that resolves
	3.0s later. Those are server writes to a *client-owned* Humanoid, and on the
	client they land as property changes like any other.

	That produces a race the client cannot win by writing once. Observed on the first
	live playtest, the full write sequence across one rupture was:

	    WALK->0  JUMP->0  ROT->false  WALK->16  WALK->0  JUMP->50  ROT->true

	`JUMP->0` and `ROT->false` are this freeze. The release belonging to the
	*previous* rupture then restored all three, and the character spent the entire
	3.0s stagger jumpable and free to turn - a stun that had visibly stopped working
	the moment it started.

	Re-asserting every frame while frozen is the standard answer and it is cheap:
	two property writes that are almost always the same value, on a transition that
	happens a handful of times per fight. Once the machine leaves `Stunned` the
	release path clears `frozenHumanoid` and this stops writing, so it cannot fight
	the wakeup it is meant to precede.
]]
local FROZEN_REASSERT_PERIOD = 0.1
local lastFreezeReassert = 0.0

local function holdStunFreeze()
	if frozenHumanoid == nil then
		return
	end

	-- The character may have died or respawned under us; a stale Humanoid must not
	-- keep being written to, and its `Parent` is the cheapest liveness test.
	if frozenHumanoid.Parent == nil then
		frozenHumanoid = nil
		return
	end

	local now = os.clock()
	if now - lastFreezeReassert < FROZEN_REASSERT_PERIOD then
		return
	end
	lastFreezeReassert = now

	-- Written unconditionally rather than only-on-change: a server write is
	-- invisible to the client until the next frame anyway, so comparing against a
	-- cached local value would only ever add state to keep in sync.
	frozenHumanoid.WalkSpeed = 0
	frozenHumanoid.JumpPower = 0
	frozenHumanoid.AutoRotate = false
end

--[[
	Day 8 · Part 2/2: the wakeup, and the deliberate asymmetry in it.

	Movement comes back; the guard does not. `SetGuardReleaseRequired(true)` is what
	enforces "release and re-press Mouse2" — a player who walked into a rupture with
	the button down would otherwise find their guard silently re-raised the instant
	the 3.0s ran out, which is the exact opposite of what being knocked out of a guard
	should feel like. See `CombatStateBus` for why the flag is needed at all when
	`ContextActionService` already produces no fresh press in the common case.

	`AutoRotate` is restored to `true` unconditionally rather than captured, because
	`Hitstop` writes `false` onto it during a deflect micro-pause and releases it
	itself; capturing here would race that release and leave a character that cannot
	turn. A character being frozen is not a character being deflected, so during a
	stun this function is the only writer of the property.
]]
local function releaseStunFreeze(releasedGeneration: number)
	-- Stale release: this belongs to a stun a later one has already superseded.
	-- Returning here is the whole point of the stamp.
	if releasedGeneration ~= activeStunGeneration then
		return
	end

	local character = localPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil

	local walkSpeed = capturedWalkSpeed or REST_WALK_SPEED
	local jumpPower = capturedJumpPower or REST_JUMP_POWER

	-- Clear the capture *before* writing, so a humanoid that turns out to be gone
	-- (died during the stun) cannot leave a stale pair behind for the next body.
	capturedWalkSpeed = nil
	capturedJumpPower = nil

	-- Retired before the restore writes, so the per-frame re-assert stops in the
	-- same pass rather than on the next one. Writing the restore first would leave
	-- a window where the freeze re-asserts on top of it.
	frozenHumanoid = nil

	if humanoid ~= nil then
		humanoid.WalkSpeed = walkSpeed
		humanoid.JumpPower = jumpPower
		humanoid.AutoRotate = true
	end

	CombatStateBus.SetStunInputLock(false)
	CombatStateBus.SetGuardReleaseRequired(true)
end

local function applyGuardBreakStun(character: Model, duration: number)
	if character ~= localPlayer.Character then
		return
	end

	local machine = CombatStateBus.GetActiveMachine()
	if machine == nil then
		return
	end

	--[[
		Day 8 · Part 2/2: the rupture floor.

		A posture rupture arrives over the *same* remote as a shattered guard, and
		`PostureEngine` sends `POSTURE_RUPTURE_DURATION` (3.0s) on it, so the two are
		indistinguishable on this wire — as they are visually, and as they are in
		COMBAT_SPEC, which calls `Stunned` one state from 0.5s to 3.0s. The client
		therefore cannot pick the duration off the payload alone; it asks the
		character's server-written `RoninPostureBroken` flag, which is the same
		attribute `PostureEngine` sets at the moment it decides to kneel.

		Reading the *flag* rather than the duration is what makes this robust rather
		than a second copy of the server's number. A number arriving on the wire is a
		claim; a flag the server wrote on the model is a fact about the same
		authority, and it survives a payload that is late, short, or from a build that
		still sends the old 1.5s guard break for a genuine break. The result is
		`math.max` of the clamped wire value and the rupture duration, so this can
		only ever lengthen a stun the server asked for — it can never shorten one, and
		never resurrect a `Stunned` that is already over.
	]]
	local isRupture = character:GetAttribute(AttackConfig.POSTURE_BROKEN_ATTRIBUTE) == true
	local stunDuration = math.clamp(duration, MIN_STUN_DURATION, MAX_STUN_DURATION)
	if isRupture then
		stunDuration = math.max(stunDuration, AttackConfig.POSTURE_RUPTURE_DURATION)
	end

	-- COMBAT_SPEC §2.1: Stunned overrides ALL states, and `ALLOWED_TRANSITIONS`
	-- already grants an edge into it from Idle, Windup, Active, Recovery, Blocking
	-- and Parrying. The one origin it refuses is `Stunned` itself, so a second break
	-- landing during the first stun is correctly ignored rather than restarting the
	-- clock on an already-locked character.
	if not machine:SetState("Stunned") then
		return
	end

	task.delay(stunDuration, function()
		local active = CombatStateBus.GetActiveMachine()

		-- A machine that is gone, is no longer this stun, or has already been moved
		-- somewhere legitimate (parried out, debug-reset) is left exactly as it is.
		if active == nil or active.CurrentState ~= "Stunned" then
			return
		end

		active:SetState("Idle")
	end)
end

if guardBreakEvent == nil then
	warn("[GUARD] GuardBreakEvent not found; guard breaks will not stun.")
else
	guardBreakEvent.OnClientEvent:Connect(function(character: any, duration: any)
		if typeof(character) ~= "Instance" or not character:IsA("Model") then
			return
		end

		if typeof(duration) ~= "number" then
			return
		end

		applyGuardBreakStun(character, duration)
	end)
end

--[[
	Day 7 · Part 1/2 — the server's deflect, applied locally.

	Two remotes, two audiences, and the split is the server's decision rather than a
	convenience:

	  * `ParryResultEvent` goes to the *defender*. The server has resolved a perfect
	    parry on this character, and this client is told so it can freeze the local
	    animation and render the HUD line. The window it carries is the one the
	    *server* measured, not the one the client predicted, so the number shown to
	    the player is the number the deflect was actually judged on.

	  * `ComboBreakEvent` goes to the *attacker*. The server has thrown away this
	    attacker's Active window, but the chain index their HUD shows lives in this
	    process, so the break has to be carried across. This client also freezes
	    itself here, which is what makes the 50ms read as *both* blades stopping
	    rather than only the defender's.

	Both payloads are fully schema-checked before anything is read (ARCHITECTURE #2),
	and both refuse an event naming a character other than the one this player is
	wearing. A targeted remote that landed on the wrong body would either stun the
	wrong machine or reset a chain index belonging to a character that is not on
	screen — and for the hitstop, freeze somebody else's body, which is the one
	outcome with no correct interpretation.
]]
local parryResultEvent = ReplicatedStorage:WaitForChild(AttackConfig.REMOTE_PARRY_RESULT_EVENT, 10) :: RemoteEvent?
local comboBreakEvent = ReplicatedStorage:WaitForChild(AttackConfig.REMOTE_COMBO_BREAK_EVENT, 10) :: RemoteEvent?

--[[
	Confines a deflect payload to this player's own character. Returns the character
	only if it is the one being worn, or nil.

	Split find-and-test from the cast for the same reason as everywhere else in this
	file: the nil test has to run before the cast narrows a value the checker already
	knows is present.
]]
local function ownCharacter(value: any): Model?
	if typeof(value) ~= "Instance" or not value:IsA("Model") then
		return nil
	end

	local model = value :: Model
	if model ~= localPlayer.Character then
		return nil
	end

	return model
end

if parryResultEvent == nil then
	warn("[PARRY] ParryResultEvent not found; deflect HUD feedback is disabled.")
else
	parryResultEvent.OnClientEvent:Connect(function(
		character: any,
		windowSeconds: any,
		reflectedPosture: any,
		attackerName: any
	)
		local model = ownCharacter(character)
		if model == nil then
			return
		end

		if typeof(windowSeconds) ~= "number" or typeof(reflectedPosture) ~= "number" then
			return
		end

		--[[
			The window is clamped to the shared ladder's best case for the same reason
			the server clamps it when reading the attribute: this value decides what
			the HUD claims about a timing the player achieved, and a number that could
			exceed the real best case would be a lie the UI tells.
		]]
		local reported = math.clamp(windowSeconds, 0, AttackConfig.PARRY_BASE_WINDOW)

		Hitstop.Apply(AttackConfig.PARRY_HITSTOP_DURATION)

		--[[
			Day 7 · Part 2/2: the two senses the hitstop does not cover.

			The clang and the punch go out *after* the freeze is scheduled, so the
			50ms of held time and the flash of sound land together rather than the
			sound arriving on a body that has not stopped yet. The punch is applied
			only on this path — the defender's own event — because a zoom is a reward
			and the player who was parried did not earn one (their side gets the
			clang, below).
		]]
		DeflectFeedback.Clang()
		DeflectFeedback.Punch()

		CombatStateBus.FireParryResult({
			WindowSeconds = reported,
			ReflectedPosture = math.max(reflectedPosture, 0),
			DeflectorName = model.Name,
			-- Type-checked rather than cast: the attacker's name is the one field
			-- here that came off the wire purely for display, and a non-string must
			-- not reach the HUD's string.format.
			AttackerName = if typeof(attackerName) == "string" then attackerName else "?",
		})

		print(string.format(
			"[PARRY] PERFECT DEFLECT! Reflected %d posture. Window was %dms. Hitstop %.0fms.",
			math.max(reflectedPosture, 0),
			math.floor(reported * 1000),
			AttackConfig.PARRY_HITSTOP_DURATION * 1000
		))
	end)
end

if comboBreakEvent == nil then
	warn("[PARRY] ComboBreakEvent not found; interrupted chains will not reset.")
else
	comboBreakEvent.OnClientEvent:Connect(function(character: any, reflectedPosture: any, hitstopDuration: any)
		local model = ownCharacter(character)
		if model == nil then
			return
		end

		if typeof(reflectedPosture) ~= "number" or typeof(hitstopDuration) ~= "number" then
			return
		end

		--[[
			The chain is reset through the bus rather than by poking `AttackController`,
			for the same reason every other cross-LocalScript call in the project goes
			through it: AttackController is a LocalScript and cannot be required, so
			the bus is the only place that can reach it. Resetting to Hit 1 is the
			whole penalty — the next press starts the chain over rather than continuing
			a three-hit combination that this strike was supposed to be part of.
		]]
		CombatStateBus.ResetComboChain()

		Hitstop.Apply(hitstopDuration)

		--[[
			Day 7 · Part 2/2: the attacker hears the clash too.

			Both blades were in the attacker's hands (one of them, at least) and both
			are a foot from their camera, so a deflect that only the defender could
			hear would make the single most punishing moment in the game silent for
			the player it punished. No FOV punch here: the zoom belongs to the player
			who won the exchange.
		]]
		DeflectFeedback.Clang()

		print(string.format(
			"[PARRY] %s had their chain broken by a deflect (+%d posture reflected).",
			model.Name,
			math.max(reflectedPosture, 0)
		))
	end)
end

-- Teardown of the character that is currently bound; nil while no character is bound.
local activeTeardown: (() -> ())? = nil

--[[
	Binds a single character lifetime to a single state machine. The teardown it
	returns is idempotent so that Died and CharacterRemoving can both drive it
	without double cleanup.
]]
local function bindCharacter(character: Model): () -> ()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	local machine = StateMachine.new("Idle")

	-- Publish immediately so client observers mirror the machine from its first
	-- transition onwards.
	CombatStateBus.Bind(machine)

	local lastTransitionClock = machine.LastTransitionTime
	local disconnectStateChanged: (() -> ())? = nil
	local diedConnection: RBXScriptConnection? = nil
	local isBound = true

	--[[
		Logs `[COMBAT] State changed: <from> -> <to> (dt: <time>)`. `dt` is the
		interval in seconds since the previous transition, read from the machine's own
		LastTransitionTime so the value is not skewed by the machine's deferred
		(task.spawn) listener dispatch.

		Also drives the action consumption loop (Day 3):
		  - Idle: consumes buffered action and dispatches it (Day 4: LightAttack ->
		            AttackController, which owns the whole swing; Guard -> Blocking).
		  - Stunned: clears input buffer to prevent actions queued during/before hitstun.
		  - Recovery: keeps listening, allowing new inputs to fill the buffer.
	]]
	local function onStateChanged(fromState: string, toState: string)
		local transitionClock = machine.LastTransitionTime
		local dt = transitionClock - lastTransitionClock
		lastTransitionClock = transitionClock

		print(string.format("[COMBAT] State changed: %s -> %s (dt: %.3f)", fromState, toState, dt))

		--[[
			Day 6 · Part 1/2: mirror the guard to the server on every transition, not
			just the ones input caused. A guard is also lost by being hit into `Stunned`
			or by a debug reset, and both of those are transitions this handler already
			sees - so this catches the guard dropping for *any* reason, which is the
			only way to guarantee the server never keeps blocking a character that has
			already stopped guarding.

			`toState == "Blocking"` is the whole test. There is deliberately no
			`fromState == "Blocking"` branch: every legal exit from Blocking lands in a
			state that is not Blocking, so the single condition covers both edges and
			there is no way for the two to disagree.
		]]
		--[[
			Day 7 · Part 1/2: the parry half of the same publish.

			Any transition that is *not* `Blocking` also withdraws the parry claim. A
			guard that has dropped must not leave a window behind on the server, and
			`ALLOWED_TRANSITIONS` routes every exit from Blocking (to Idle, to
			Stunned, and back through a parry) through a non-Blocking state, so the
			same single test covers both edges exactly as it did for the guard flag.
		]]
		local enteringBlocking = toState == "Blocking"
		publishGuardState(enteringBlocking, enteringBlocking and ParryWindow.IsParryActive())

		--[[
			Day 6 · Part 2/2: drive the guard *pose* from the same single observer.

			Sitting beside `publishGuardState` on purpose, and reading the same
			`toState == "Blocking"` test, is what makes it structurally impossible for
			the character to be visibly guarding while the server thinks it is not (or
			the reverse). One transition, two consequences, one place that knows about
			both.

			The release is *not* instant. This is the guard dropping - a button release,
			an attack-out-of-guard, a parry falling back - and every one of those should
			look like the arms coming down. The instant path belongs to AttackController,
			which needs the shoulder at rest at a moment that is not a transition at all.
		]]
		local guardPose = CombatStateBus.GetGuardPose()
		if guardPose ~= nil then
			if toState == "Blocking" then
				guardPose.Raise()
			else
				guardPose.Release(false)
			end
		end

		if toState == "Idle" then
			--[[
				Day 8 · Part 2/2: the stun release, and why it is here rather than at
				the end of the handler.

				Everything below this branch begins with a `return` guard
				(`machine.CurrentState ~= "Idle"`), and a `Stunned -> Idle` release is
				exactly the case where a queued action is most likely to be spent on
				the same frame. Restoring movement has to be unconditional, or a wakeup
				that is immediately interrupted by the player's own buffered press
				would leave the character rooted at 0 speed with no stun left to
				explain it.

				`fromState == "Stunned"` is the condition, not "was frozen": it keys
				off the transition the machine actually made, so a character that was
				frozen and then died (teardown, no `Idle` transition) never runs this,
				and a normal `Idle -> Idle` never pays for it.
			]]
			if fromState == "Stunned" then
				releaseStunFreeze(stunGeneration)
			end

			--[[
				Listeners are dispatched with task.spawn, so the machine can already
				have left Idle by the time this body runs - the direct intake above can
				start a swing in that window. Re-checking here is what stops one press
				being spent twice: the intake has already emptied the queue, and a swing
				it started is not ours to start again.
			]]
			if machine.CurrentState ~= "Idle" then
				return
			end

			local action, latencyDelta = InputBuffer.Consume()
			if action then
				CombatStateBus.RecordConsumed(action, latencyDelta or 0)
				dispatchAction(action)
			end
		elseif toState == "Stunned" then
			--[[
				Day 8 · Part 2/2: the freeze, plus the re-assert that holds it.

				`applyStunFreeze` is called once per transition, but the server writes
				`WalkSpeed` on *both* ends of a rupture, and those writes land on this
				client-owned Humanoid as ordinary property changes. A single write is
				therefore not enough: a release - especially one belonging to the
				previous rupture, whose 3.0s timer can expire inside the same interval
				- will undo it. `holdStunFreeze` re-asserts for as long as the machine
				says `Stunned`, and this transition is where it starts.

				Placed at the very top of the branch and ahead of everything else for
				the reason given on `applyStunFreeze` — `StateMachine` dispatches this
				thread, so the character is still moving on the frame the transition
				happened no matter where in here the write goes. This is the earliest
				line the handler can reach, which is the whole point.
			]]
			applyStunFreeze()
		elseif toState == "Recovery" then
			-- Keep listening, allowing new inputs to fill the buffer
		end
	end

	disconnectStateChanged = machine:OnStateChanged(onStateChanged)

	--[[
		Retires the binding: stop listening, return the machine to Idle and drop every
		reference this closure holds.
	]]
	local function teardown()
		if not isBound then
			return
		end
		isBound = false

		-- 1) Stop receiving transitions from a character that is going away.
		local connection = diedConnection
		diedConnection = nil
		if connection then
			connection:Disconnect()
		end

		local disconnect = disconnectStateChanged
		disconnectStateChanged = nil
		if disconnect then
			disconnect()
		end

		-- Stop feeding client observers before the machine is retired.
		CombatStateBus.Release(machine)

		-- Clear buffered inputs on death/respawn
		InputBuffer.Clear()

		--[[
			Day 6 · Part 1/2: forget what the server was last told about the guard.
			The new character is a different model with no guard attribute, so a stale
			`lastPublishedGuard = true` would suppress the next `true` publish and leave
			the server believing a character that no longer exists is still guarding.
		]]
		resetPublishedGuard()

		--[[
			Day 7 · Part 1/2: clear the two pieces of parry state that belong to *this*
			body rather than to the session.

			`ParryWindow.Reset` first, because a dead character leaving a live window
			would hand the next body a deflect it never earned — the new character
			spawns inside the old one's remaining 133ms and the first strike to land
			in it is a perfect parry with no press behind it. It also drops the ladder
			position, so the new life starts at the top rung rather than inheriting a
			mash penalty.

			`Hitstop.Release` second, and it has to be explicit: the hitstop writes
			`AutoRotate` and `TimeScale` onto instances rather than owning a timer
			that dies with the character, so a character destroyed inside the 50ms
			window leaves a frozen `TimeScale` behind. The new body has its own
			Animator, so nothing downstream would ever restore it — the respawn would
			produce a character that cannot turn and whose animations do not advance.
		]]
		ParryWindow.Reset()
		Hitstop.Release()
		CombatStateBus.ClearParryResult()

		--[[
			Day 8 · Part 2/2: a death mid-stun must not leave a frozen body behind.

			The capture and the input lock are both file-scope (see
			`applyStunFreeze` for why), which is exactly what makes them dangerous
			here: a character killed while kneeling never runs the `Stunned -> Idle`
			release, because teardown retires the machine without a transition. Left
			alone, the next character would bind with `capturedWalkSpeed` still
			holding the dead body's speed and `stunInputLocked` still true — a player
			who respawns unable to walk, unable to attack, with no stun anywhere in
			sight to explain it.

			The guard-release requirement is deliberately *not* cleared here. It is
			cleared by a real Mouse2 `End`, and a player who respawns holding the
			button should indeed have to let it go. Carrying it across a respawn is
			the correct reading of the rule; carrying the freeze across one is not.
		]]
		capturedWalkSpeed = nil
		capturedJumpPower = nil
		frozenHumanoid = nil
		stunGeneration = stunGeneration + 1
		activeStunGeneration = stunGeneration
		CombatStateBus.SetStunInputLock(false)

		-- 2) Neutralise the machine. Disposal is not a combat transition, so a
		--    table-legal move goes through SetState; dying mid-strike (Active -> Idle)
		--    is the one case the table forbids, and there we reset the fields directly
		--    rather than log a rejection for a machine that is about to be discarded.
		if machine.CurrentState ~= "Idle" then
			if not machine:SetState("Idle") then
				machine.PreviousState = machine.CurrentState
				machine.CurrentState = "Idle"
				machine.LastTransitionTime = os.clock()
			end
		end

		-- 3) Release the caller's reference. With the listener disconnected and this
		--    closure dropped, nothing keeps the machine (or the character) alive.
		if activeTeardown == teardown then
			activeTeardown = nil
		end
	end

	diedConnection = humanoid.Died:Connect(teardown)

	--[[
		Day 8 · Part 2/2: the heartbeat that holds the stun freeze.

		Connected per character rather than once at module scope, so it is torn down
		with the binding and cannot outlive the body it was asserting against. The
		`teardown` closure above is what disconnects it, alongside the `Died` signal.

		`Heartbeat` rather than `RenderStepped` because this is not a visual: it is
		re-asserting an authoritative-looking value that the server is concurrently
		writing, and it should keep doing so at simulation rate rather than only when
		the camera happens to be drawing.
	]]
	local heartbeatConnection = RunService.Heartbeat:Connect(holdStunFreeze)

	--[[
		`holdStunFreeze` retires its own `frozenHumanoid` when the body dies, but the
		connection itself has to be released by the teardown, and teardown is already
		assembled above. Assigning the connection into a local the teardown can see
		is done by wrapping: the disconnect is registered below the teardown's own
		disconnect block, so a respawn cannot leave two loops both writing 0.
	]]
	local disconnectHeartbeat: (() -> ())? = nil
	disconnectHeartbeat = function()
		heartbeatConnection:Disconnect()
		disconnectHeartbeat = nil
	end

	--[[
		`teardown` is the function above. Rather than re-enter it, the freeze's own
		disconnect is attached here through the same reference the caller uses, so
		there is exactly one teardown path and the heartbeat cannot be leaked.
	]]
	local originalTeardown = teardown
	teardown = function()
		if disconnectHeartbeat ~= nil then
			disconnectHeartbeat()
		end
		originalTeardown()
	end

	return teardown
end

local function detachActiveBinding()
	local teardown = activeTeardown
	if teardown then
		activeTeardown = nil
		teardown()
	end
end

local function onCharacterAdded(character: Model)
	-- A respawn can arrive while the previous binding is still live.
	detachActiveBinding()
	activeTeardown = bindCharacter(character)
end

local function onCharacterRemoving(_character: Model)
	detachActiveBinding()
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)
localPlayer.CharacterRemoving:Connect(onCharacterRemoving)

-- The local player may already be alive by the time this script starts.
local existingCharacter = localPlayer.Character
if existingCharacter then
	onCharacterAdded(existingCharacter)
end
