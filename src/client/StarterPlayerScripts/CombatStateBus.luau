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

local bus = {}

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
