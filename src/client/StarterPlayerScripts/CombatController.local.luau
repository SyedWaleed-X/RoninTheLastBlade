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

local function applyGuardBreakStun(character: Model, duration: number)
	if character ~= localPlayer.Character then
		return
	end

	local machine = CombatStateBus.GetActiveMachine()
	if machine == nil then
		return
	end

	local stunDuration = math.clamp(duration, MIN_STUN_DURATION, MAX_STUN_DURATION)

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
			-- Immediately flush queued actions: no attacks after hitstun
			InputBuffer.Clear()
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
