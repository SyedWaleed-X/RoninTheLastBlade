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
		Dodging = true,     -- Day 9 P1/2: a dodge out of neutral
		Idle = false,
	},
	Windup = {
		Active = true,
		Parrying = true, -- Can cancel startup into a parry
		Stunned = true,  -- Hit by opponent
		Idle = true,     -- Feint cancel
		Dodging = true,  -- Day 9 P1/2: a dodge is the *other* cancel out of startup
	},
	Active = {
		Recovery = true,
		Stunned = true,  -- Staggered by an attack/parry
		-- No Dodging edge on purpose. COMBAT_SPEC §1 calls Active the lethal,
		-- action-locked, cannot-turn window, and §2.3 says it cannot be interrupted
		-- except by taking damage. A dodge that could cancel the strike that is
		-- already live would make Active an optional commitment rather than the
		-- committed one the whole frame-data chain is built around.
	},
	Recovery = {
		Idle = true,
		Stunned = true,
		Dodging = true,  -- Day 9 P1/2: dodge-cancel the follow-through
	},
	Blocking = {
		Idle = true,     -- Releasing block
		Parrying = true, -- Tapping parry
		Stunned = true,  -- Guard broken
		-- No Dodging edge. A guard is a *stance*: the player is holding a button,
		-- paying posture for the privilege, and COMBAT_SPEC §1 gives it its own
		-- state for a reason. Letting a single key escape it for free would make
		-- the posture economy irrelevant, because the correct play against any
		-- attack would be "block, then tap Q" rather than "block, or don't".
		-- The dodge has to be *paid for* by not being in a stance.
	},
	Parrying = {
		Blocking = true, -- Fall back to block after parry window
		Idle = true,     -- Releasing after parry
		Stunned = true,
	},
	Stunned = {
		Idle = true,     -- Stun duration expired
		-- No Dodging edge. COMBAT_SPEC §2.1: Stunned overrides ALL states
		-- immediately, and §1 defines it as a complete input lock. A dodge out of
		-- a stagger would be the one action that beats a stagger.
	},
	Executing = {
		Idle = true,     -- Finisher completed
	},
	Dodging = {
		Idle = true,     -- The 350ms window closed
		Stunned = true,  -- Hit out of the i-frames, or during recovery
		-- No Dodging -> Dodging. The controller also refuses a second dodge
		-- outright, but the table is the authority and this is the edge that
		-- says so: without it, a mashing player could chain i-frames into one
		-- long unbroken invulnerability and the dodge would stop costing
		-- anything at all.
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