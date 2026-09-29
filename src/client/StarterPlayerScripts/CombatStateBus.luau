--!strict

--[[
	CombatStateBus
	Ronin — The Last Blade · client-side state machine bridge

	`CombatController` owns the lifetime of the local character's state machine, while
	the debug HUD and the keyboard/chaos harness need to observe and drive it. This
	module is that seam: it holds the currently bound machine, re-emits its transitions
	to any number of subscribers, and forwards requested transitions.

	It is deliberately client-local (a ModuleScript cloned into PlayerScripts), so each
	client gets exactly one bus and therefore exactly one machine per character.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatTypes = require(ReplicatedStorage.CombatTypes)
local StateMachine = require(ReplicatedStorage.StateMachine)

-- Required for its `CombatAction` type only: Day 4 · Part 2/2 adds a direct-intake
-- path, so the bus has to name the same action union the queue stores. InputBuffer
-- has no dependency back on the bus, so this cannot cycle.
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)

type CombatState = CombatTypes.CombatState
type StateMachineInstance = StateMachine.StateMachine
type CombatAction = InputBuffer.CombatAction

export type TransitionListener = (fromState: CombatState, toState: CombatState) -> ()

export type ConsumedInputRecord = {
	Action: string,
	LatencyDelta: number,
	Timestamp: number,
}

--[[
	Signature of the light-attack driver registered by AttackController. Returns
	whether a swing actually started.
]]
export type LightAttackExecutor = () -> boolean

--[[
	Signature of the direct-intake path registered by CombatController. Given a press,
	it either spends it on the spot (true) or leaves it queued for the next Idle entry
	(false).
]]
export type ActionIntake = (action: CombatAction) -> boolean

--[[
	Day 5 · Part 1/2: the client-local katana proxy published by WeaponVisuals.

	WeaponVisuals is a LocalScript (Script Sync `.local.luau` suffix) and `require`
	only works on ModuleScripts, so the blade it builds reaches the rest of the client
	through the same seam AttackController registers on. The rig carries the handles a
	consumer needs - the blade part, the two sweep attachments, the trail - plus the
	three methods that drive it, so nothing downstream has to know how the proxy is
	built, what it is called or where in the hand it sits.

	`StartSwing` / `StopSwing` live here rather than in the swing driver because the
	blade's joint is a Motor6D the proxy owns outright: no Animator in the place writes
	to it, so a scripted Transform on it is never blended away by a locomotion track.
	That property is the whole reason the blade is the thing that visibly swings.
]]
export type BladeRig = {
	Character: Model,
	Hand: BasePart,
	Blade: Part,
	Base: Attachment,
	Tip: Attachment,
	Trail: Trail,
	SetTrailEnabled: (enabled: boolean) -> (),
	StartSwing: (
		hitIndex: number,
		windupDuration: number,
		activeDuration: number,
		recoveryDuration: number
	) -> (),
	StopSwing: () -> (),
}

--[[
	Day 6 · Part 2/2: the guard pose, published by WeaponVisuals beside the blade.

	The same shape-of-the-rig reasoning as `BladeRig` applies - the pose is built over
	real Motor6D shoulders, and no consumer should have to know that. It is published
	rather than reached through a subscription because the *driver* is not a
	transition: `AttackController` has to drop the pose synchronously the instant a
	swing begins, at a point where no state transition is involved, and a
	subscriber-only seam would force it to fake one.

	`Release(instant)` is the load-bearing member. `instant = true` parks the arms at
	rest on the spot and is what a swing must call before it reads the shoulder's C0;
	`instant = false` plays the smooth return and is what a guard drop should call.
	Ignoring the difference produces a swing composed on top of a half-raised arm.
]]
export type GuardPoseHandle = {
	Raise: () -> (),
	Release: (instant: boolean) -> (),
	IsRaised: () -> boolean,
}

--[[
	Day 5 · Part 1/2: one confirmed blade contact, published by BladeHitbox.

	This is the local prediction seam. Day 5 · Part 2/2 replaces the `print` with a
	schema-validated RemoteEvent the server owns (ARCHITECTURE.md #2/#3) - nothing in
	the client may apply damage from this record, and the server will re-derive the hit
	from its own trace rather than trusting `Damage` or `Position` as sent.
]]
export type BladeHitEvent = {
	TargetModel: Model,
	TargetHumanoid: Humanoid,
	HitIndex: number,
	Damage: number,
	PoiseDamage: number,
	Position: Vector3,
	Distance: number,
}

export type BladeHitListener = (event: BladeHitEvent) -> ()

local MAX_CONSUMED_HISTORY = 3

local activeMachine: StateMachineInstance? = nil
local disconnectTransitions: (() -> ())? = nil
local listeners: { TransitionListener } = {}
local consumedHistory: { ConsumedInputRecord } = {}

--[[
	Day 4: the light-attack executor and the mirror of the live chain index.

	AttackController is a LocalScript (Script Sync `.local.luau` suffix), and
	`require` only works on ModuleScripts - so CombatController cannot require it and
	CombatDebugUI cannot read its state. This bus is the client-local seam both of
	those scripts already share: AttackController registers here, the controller's
	consumption loop dispatches through here, and the HUD reads the mirrored index
	from here instead of owning a second copy of the chain state.
]]
local lightAttackExecutor: LightAttackExecutor? = nil
local actionIntake: ActionIntake? = nil
local activeComboIndex = 1
-- 0 until AttackController publishes a chain length; the HUD leaves its placeholder
-- text alone for 0 rather than rendering a "HIT 1 / 0" row.
local comboTotalHits = 0

--[[
	Day 5 · Part 1/2 state: the live blade rig (nil until a character spawns and
	nil again on respawn), the hit subscribers, and the most recent contact so the
	debug HUD can render "what did that last swing actually touch" without keeping
	its own copy of the record.
]]
local bladeRig: BladeRig? = nil

-- Day 6 · Part 2/2: the guard pose published beside the blade rig. Cleared with the
-- rig on every unequip, so it can never outlive the character it poses.
local guardPose: GuardPoseHandle? = nil
local hitListeners: { BladeHitListener } = {}
local lastHitEvent: BladeHitEvent? = nil


--[[
	Day 7 · Part 1/2: the parry seam.

	Two halves, and the split is the reason this is a seam at all.

	*Inward* (`NotifyParryPressed`) - `InputBinder` is a LocalScript and cannot be
	required by `CombatController`, so the press has to be announced through the one
	place both of them already share. It carries the window width that
	`ParryWindow.OnBlockPressed()` just resolved, so the server is told how wide the
	window was rather than being asked to guess.

	*Outward* (`SubscribeParryResults`) - the server tells this client a parry landed.
	The HUD renders that as its success line, and nothing else consumes it, but
	publishing it here rather than having the HUD require a module is what keeps the
	"one observer publishes, everyone reads" shape the rest of the bus is built on.

	The result record is a flat table of primitives so a subscriber can be added
	without this module having to know what it does with one.
]]
export type ParryResultRecord = {
	WindowSeconds: number,
	ReflectedPosture: number,
	DeflectorName: string,
	AttackerName: string,
}

export type ParryResultListener = (record: ParryResultRecord) -> ()

local parryResultListeners: { ParryResultListener } = {}
local lastParryResult: ParryResultRecord? = nil
local parryPressListener: ((windowSeconds: number) -> ())? = nil
local bus = {}

--[[
	Records that the block button was pressed and the width of the window it opened.

	Single-slot rather than a list: exactly one thing consumes this (the guard
	publisher in CombatController), and a list would be a second thing that could
	start depending on an ordering nobody had to reason about. Registering nil
	clears it.
]]
function bus.SetParryPressListener(listener: ((windowSeconds: number) -> ())?)
	parryPressListener = listener
end

function bus.NotifyParryPressed(windowSeconds: number)
	local listener = parryPressListener
	if listener ~= nil then
		listener(windowSeconds)
	end
end

function bus.SubscribeParryResults(listener: ParryResultListener): () -> ()
	table.insert(parryResultListeners, listener)

	return function()
		local index = table.find(parryResultListeners, listener)
		if index then
			table.remove(parryResultListeners, index)
		end
	end
end

--[[
	Publishes a resolved parry to the client HUD.

	Dispatch is reverse-indexed for the same reason `emit` is: a subscriber may
	unsubscribe from inside its own callback, and forward iteration over a shrinking
	list would skip an entry when that happens.
]]
function bus.FireParryResult(record: ParryResultRecord)
	lastParryResult = record

	for index = #parryResultListeners, 1, -1 do
		local listener = parryResultListeners[index]
		if listener then
			listener(record)
		end
	end
end

--[[
	The most recent resolved parry, or nil if none has landed this session. Kept as a
	single record for the same reason `GetLastHit` is: it is per-exchange state, and a
	history would be a leak with no reader.
]]
function bus.GetLastParryResult(): ParryResultRecord?
	return lastParryResult
end

--[[
	Clears the parry mirror on teardown, beside `resetPublishedGuard`'s siblings. A
	result carried across a respawn would flash the new character's HUD with the
	previous body's deflect, which is worse than showing nothing.
]]
function bus.ClearParryResult()
	lastParryResult = nil
end

local function emit(fromState: CombatState, toState: CombatState)
	-- Reverse iteration keeps this allocation free and safe if a subscriber drops
	-- itself while the transition is being delivered.
	for index = #listeners, 1, -1 do
		local listener = listeners[index]
		if listener then
			listener(fromState, toState)
		end
	end
end

--[[
	Adopts a machine and starts forwarding its transitions. Any previously bound
	machine is released first, which keeps the binding single-valued across respawns.
]]
function bus.Bind(machine: StateMachineInstance)
	bus.Release()

	activeMachine = machine
	disconnectTransitions = machine:OnStateChanged(function(fromState: CombatState, toState: CombatState)
		emit(fromState, toState)
	end)
end

--[[
	Retires a machine. Passing the machine is optional; when supplied, the release is
	ignored if a newer machine has already replaced it, so a stale teardown cannot
	detach a live binding.
]]
function bus.Release(machine: StateMachineInstance?)
	if machine ~= nil and activeMachine ~= machine then
		return
	end

	local disconnect = disconnectTransitions
	disconnectTransitions = nil
	if disconnect then
		disconnect()
	end

	activeMachine = nil

	-- The mirrored chain belongs to the character that is going away, so a respawn
	-- must not leave the HUD advertising a hit the new character never swung. The
	-- registered executor is deliberately *not* cleared: it is owned by a client
	-- script whose lifetime is the client, not the character, and dropping it would
	-- make every post-respawn attack a no-op until the session reloaded.
	activeComboIndex = 1
end

function bus.GetActiveMachine(): StateMachineInstance?
	return activeMachine
end

function bus.GetCurrentState(): CombatState?
	local machine = activeMachine
	if not machine then
		return nil
	end
	return machine.CurrentState
end

--[[
	Subscribes to transitions of whichever machine is bound. Returns a disconnect
	function, so a consumer that outlives a binding still only gets one call per
	transition (the subscription survives respawns).
]]
function bus.Subscribe(listener: TransitionListener): () -> ()
	table.insert(listeners, listener)

	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

--[[
	Requests a transition through the machine's own rules. Returns false when no
	machine is bound or the state table rejects the move.
]]
function bus.RequestState(targetState: CombatState): boolean
	local machine = activeMachine
	if not machine then
		return false
	end

	return machine:SetState(targetState)
end

--[[
	Day 6 · Part 1/2: asks the machine whether a transition is legal *without*
	performing it.

	`RequestState` is the only way to move the machine, but it logs a warning when
	the table refuses the move - which is the right behaviour for a system that
	asked and was told no, and the wrong behaviour for an input sink that merely
	wants to know whether holding the guard button right now would do anything.

	This is deliberately a pass-through rather than a second copy of
	`ALLOWED_TRANSITIONS`: the rules live in `StateMachine` and the binder asks
	this, so a consumer can pre-check without re-deriving legality and having the
	two copies drift apart.
]]
function bus.CanRequestState(targetState: CombatState): boolean
	local machine = activeMachine
	if not machine then
		return false
	end

	return machine:CanTransitionTo(targetState)
end

--[[
	Debug-only hard reset. Disposal is not a combat transition, so a table-legal move
	goes through SetState; when the table forbids it the fields are reset directly and
	subscribers receive a synthetic transition so the HUD cannot show a stale state.
]]
function bus.ForceResetToIdle(): boolean
	local machine = activeMachine
	if not machine then
		return false
	end

	local currentState = machine.CurrentState
	if currentState == "Idle" then
		return true
	end

	if machine:SetState("Idle") then
		return true
	end

	machine.PreviousState = currentState
	machine.CurrentState = "Idle"
	machine.LastTransitionTime = os.clock()
	emit(currentState, "Idle")

	return true
end

--[[
	Day 4 · Part 1/2: light-attack dispatch.

	Registers the client-local swing driver (AttackController). Registering twice is
	harmless and idempotent: the last registration wins, so a re-run of the script
	does not leave the bus pointing at a dead closure.
]]
function bus.SetLightAttackExecutor(executor: LightAttackExecutor?)
	lightAttackExecutor = executor
end

--[[
	Runs the registered light-attack driver, returning whether a swing started.
	Returns false when nothing is registered, which is a real failure (a press that
	silently does nothing) rather than a normal outcome, so it is reported instead of
	being swallowed: without this the StateMachine's own transition rules would be
	the only clue and a LightAttack would simply never fire.
]]
function bus.RunLightAttack(): boolean
	local executor = lightAttackExecutor
	if executor == nil then
		warn("[COMBAT] RunLightAttack: no executor registered (is AttackController running?).")
		return false
	end

	return executor()
end

--[[
	Day 4 · Part 2/2: direct intake for a press made while the character is already
	actionable. Registers CombatController's intake; registering twice is idempotent
	(last registration wins), matching SetLightAttackExecutor above.
]]
function bus.SetActionIntake(intake: ActionIntake?)
	actionIntake = intake
end

--[[
	Offers a press to the bound machine so it can be spent now rather than on the next
	transition into Idle.

	Returns true when the controller spent it immediately and false when it queued the
	press instead (the character was busy). A false is therefore an ordinary outcome,
	not a failure - InputBinder keys its trace off it. When no controller has
	registered yet the press is pushed into the Day 3 queue as a fallback, so a
	machine that binds before the 200ms window closes still spends it.
]]
function bus.OfferIntent(action: CombatAction): boolean
	local intake = actionIntake
	if intake == nil then
		InputBuffer.Push(action)
		return false
	end

	return intake(action)
end

--[[
	Mirrors the live chain index (and the chain length) for observers that cannot
	require AttackController - today only the debug HUD. `activeIndex` is the hit the
	character is on, or the hit the next press will play while it sits in Idle.
]]
function bus.SetComboState(activeIndex: number, totalHits: number)
	activeComboIndex = activeIndex
	comboTotalHits = totalHits
end

function bus.GetComboState(): (number, number)
	return activeComboIndex, comboTotalHits
end

--[[
	Day 7 · Part 1/2: resets the attacker's chain after a deflect.

	Registered rather than called directly because `AttackController` is a
	LocalScript and `require` does not work on one — the same reason
	`SetLightAttackExecutor` exists a few lines up. The executor is the outbound
	call and this is the inbound one, so the two together are the full seam between
	"something happened" and "the chain driver reacts to it".

	Single-slot rather than a list for the same reason as the parry press listener:
	there is exactly one chain, and a second subscriber could only be a second
	opinion about the same index.
]]
local comboResetHandler: (() -> ())? = nil

function bus.SetComboResetHandler(handler: (() -> ())?)
	comboResetHandler = handler
end

--[[
	Asks the chain driver to drop back to Hit 1.

	Guarded on a registered handler rather than assumed: the bus outlives any single
	character, so it can be asked to reset a chain for a character that is mid-teardown
	with AttackController already unbound. Writing `activeComboIndex = 1` here
	instead would silently make the mirror disagree with a driver that is about to
	re-publish a stale value, and the HUD would show "HIT 1" over a live Hit 3.
]]
function bus.ResetComboChain()
	local handler = comboResetHandler
	if handler == nil then
		return
	end

	handler()
end

--[[
	Day 5 · Part 1/2: publishes (or clears) the blade proxy for the local character.

	Registering nil on respawn is mandatory rather than tidy: a rig left behind by the
	destroyed character would keep handing out a dead Part and two dead Attachments,
	and every consumer of this seam would have to parent-check the rig for itself.
	Clearing it in one place is the only version of that check that cannot be forgotten.
]]
function bus.SetBladeRig(rig: BladeRig?)
	bladeRig = rig
end

function bus.GetBladeRig(): BladeRig?
	return bladeRig
end

--[[
	Day 6 · Part 2/2: publishes (or clears) the guard pose for the local character.

	Clearing it on respawn is mandatory for the same reason clearing the blade rig is:
	a handle left behind after `unequip` would still hold joints from a destroyed
	character, and every caller would have to parent-check before trusting it.

	`GetGuardPose` is also the honest answer to "is this character visually guarding?",
	which the state machine alone cannot answer on a rig that refused to pose.
]]
function bus.SetGuardPose(pose: GuardPoseHandle?)
	guardPose = pose
end

function bus.GetGuardPose(): GuardPoseHandle?
	return guardPose
end

--[[
	Publishes one confirmed blade contact to the hit subscribers. The record itself is
	built by BladeHitbox at the moment of contact (a handful per swing at most), so
	this is not on the per-frame path.

	Dispatch is reverse-indexed for the same reason `emit` is: a subscriber is allowed
	to unsubscribe from inside its own callback, and forward iteration over a shrinking
	list skips an entry when that happens.
]]
function bus.FireHit(event: BladeHitEvent)
	lastHitEvent = event

	for index = #hitListeners, 1, -1 do
		local listener = hitListeners[index]
		if listener then
			listener(event)
		end
	end
end

function bus.SubscribeHits(listener: BladeHitListener): () -> ()
	table.insert(hitListeners, listener)

	return function()
		local index = table.find(hitListeners, listener)
		if index then
			table.remove(hitListeners, index)
		end
	end
end

--[[
	The most recent contact, or nil when this session has not landed a hit yet. Kept
	as a single record rather than a history: Day 5 · Part 2/2 consumes it as the
	damage request it sends to the server, which is per-swing state by definition.
]]
function bus.GetLastHit(): BladeHitEvent?
	return lastHitEvent
end

--[[
	Records a consumed input event and its latency delta into the recent history ring.
]]
function bus.RecordConsumed(action: string, latencyDelta: number)
	table.insert(consumedHistory, 1, {
		Action = action,
		LatencyDelta = latencyDelta,
		Timestamp = os.clock(),
	})
	if #consumedHistory > MAX_CONSUMED_HISTORY then
		table.remove(consumedHistory)
	end
end

--[[
	Returns the recent history of consumed inputs (at most 3 items).
]]
function bus.GetConsumedHistory(): { ConsumedInputRecord }
	return consumedHistory
end

return bus
