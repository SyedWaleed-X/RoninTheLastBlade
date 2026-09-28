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

type CombatState = CombatTypes.CombatState
type StateMachineInstance = StateMachine.StateMachine

export type TransitionListener = (fromState: CombatState, toState: CombatState) -> ()

local activeMachine: StateMachineInstance? = nil
local disconnectTransitions: (() -> ())? = nil
local listeners: { TransitionListener } = {}

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

return bus
