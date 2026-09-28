--!strict
local CombatTypes = require(script.Parent:WaitForChild("CombatTypes"))

type CombatState = CombatTypes.CombatState

export type StateTransitionCallback = (fromState: CombatState, toState: CombatState) -> ()

export type StateMachine = {
	CurrentState: CombatState,
	PreviousState: CombatState,
	LastTransitionTime: number,
	-- Private by convention (underscore prefix), but declared here so a `--!strict`
	-- consumer/implementation can infer the table shape without widening to `any`.
	_listeners: { StateTransitionCallback },
	CanTransitionTo: (self: StateMachine, targetState: CombatState) -> boolean,
	SetState: (self: StateMachine, targetState: CombatState) -> boolean,
	OnStateChanged: (self: StateMachine, callback: StateTransitionCallback) -> () -> (),
}

local StateMachine = {}
StateMachine.__index = StateMachine

-- Define the authoritative interruption rules
local ALLOWED_TRANSITIONS: { [CombatState]: { [CombatState]: boolean } } = {
	Idle = {
		Windup = true,
		Blocking = true,
		Parrying = true,
		Stunned = true,
		Executing = true,
		Idle = false,
	},
	Windup = {
		Active = true,
		Parrying = true, -- Can cancel startup into a parry
		Stunned = true,  -- Hit by opponent
		Idle = true,     -- Feint cancel
	},
	Active = {
		Recovery = true,
		Stunned = true,  -- Staggered by an attack/parry
	},
	Recovery = {
		Idle = true,
		Stunned = true,
	},
	Blocking = {
		Idle = true,     -- Releasing block
		Parrying = true, -- Tapping parry
		Stunned = true,  -- Guard broken
	},
	Parrying = {
		Blocking = true, -- Fall back to block after parry window
		Idle = true,     -- Releasing after parry
		Stunned = true,
	},
	Stunned = {
		Idle = true,     -- Stun duration expired
	},
	Executing = {
		Idle = true,     -- Finisher completed
	},
}

function StateMachine.new(initialState: CombatState?): StateMachine
	local startingState = initialState or "Idle"
	
	local self = setmetatable({}, StateMachine)
	self.CurrentState = startingState
	self.PreviousState = startingState
	self.LastTransitionTime = os.clock()
	self._listeners = {} :: { StateTransitionCallback }
	
	return (self :: any) :: StateMachine
end

-- Methods are declared with an explicitly annotated `self`: the instance is built with
-- `setmetatable({}, StateMachine)` on a table that points back at itself through
-- `__index`, and inferring `self` from that recursion made the strict checker widen the
-- instance fields (generic 'T'/`unknown` leakage). Annotating `self` pins the shape.

function StateMachine.CanTransitionTo(self: StateMachine, targetState: CombatState): boolean
	local current: CombatState = self.CurrentState
	local allowedTargets = ALLOWED_TRANSITIONS[current]
	
	if not allowedTargets then
		return false
	end
	
	return allowedTargets[targetState] == true
end

function StateMachine.SetState(self: StateMachine, targetState: CombatState): boolean
	if not self.CanTransitionTo(self, targetState) then
		warn(string.format("[FSM] Rejected transition: %s -> %s", tostring(self.CurrentState), tostring(targetState)))
		return false
	end

	local fromState = self.CurrentState
	self.PreviousState = fromState
	self.CurrentState = targetState
	self.LastTransitionTime = os.clock()

	for _, callback in ipairs(self._listeners) do
		task.spawn(callback, fromState, targetState)
	end

	return true
end

function StateMachine.OnStateChanged(self: StateMachine, callback: StateTransitionCallback): () -> ()
	table.insert(self._listeners, callback)
	
	-- Return a disconnect function to prevent memory leaks
	return function()
		local index = table.find(self._listeners, callback)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

return StateMachine