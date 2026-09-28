--!strict

--[[
	TestFSM
	Ronin — The Last Blade · Day 2 transition invariant suite

	Drives the combat state machine through its five core invariants at server start
	and reports one greppable line per suite run:
	  * any violation   ->  [FSM TEST] FAILED: <reason>
	  * all invariants  ->  [FSM TEST] SUCCESS: All 5 transition invariants verified.

	Invariants under test (docs/COMBAT_SPEC.md §2):
	  a) Legal chain          : Idle -> Windup -> Active -> Recovery -> Idle
	  b) Priority override    : Windup -> Parrying (a parry cancels the startup)
	  c) Action lock          : Active -> Windup is rejected (the strike is committed)
	  d) Input lock           : Stunned -> Windup is rejected (a stagger locks inputs)
	  e) Interruption by stun : Active -> Stunned (a stun overrides every state)

	Invariants (c) and (d) deliberately attempt illegal transitions, so the state
	machine's own "[FSM] Rejected transition: ..." warnings are expected output on a
	fully passing run.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Test harness only: never run transition checks (or their intentional rejection
-- warnings) on a live production server.
if not RunService:IsStudio() then
	return
end

local StateMachine = require(ReplicatedStorage:WaitForChild("StateMachine") :: ModuleScript)

local failures: { string } = {}

local function check(condition: boolean, reason: string)
	if not condition then
		table.insert(failures, reason)
	end
end

-- a) Legal chain: a full swing resolves back to Idle --------------------------
do
	local fsm = StateMachine.new("Idle")

	check(fsm:SetState("Windup") == true, "a) Idle -> Windup must be allowed")
	check(fsm:SetState("Active") == true, "a) Windup -> Active must be allowed")
	check(fsm:SetState("Recovery") == true, "a) Active -> Recovery must be allowed")
	check(fsm:SetState("Idle") == true, "a) Recovery -> Idle must be allowed")
	check(fsm.CurrentState == "Idle", "a) the full chain must land back on Idle")
	check(fsm.PreviousState == "Recovery", "a) PreviousState must track the prior state")
end

-- b) Priority override: a parry cancels the Windup startup --------------------
do
	local fsm = StateMachine.new("Idle")

	check(fsm:SetState("Windup") == true, "b) Idle -> Windup must be allowed")
	check(fsm:SetState("Parrying") == true, "b) Windup -> Parrying must be allowed")
	check(fsm.CurrentState == "Parrying", "b) the parry override must apply immediately")
end

-- c) Action lock: Active cannot be cancelled back into Windup -----------------
do
	local fsm = StateMachine.new("Idle")

	check(fsm:SetState("Windup") == true, "c) Idle -> Windup must be allowed")
	check(fsm:SetState("Active") == true, "c) Windup -> Active must be allowed")
	check(fsm:SetState("Windup") == false, "c) Active -> Windup must be rejected")
	check(fsm.CurrentState == "Active", "c) a rejected transition must not change state")
end

-- d) Input lock: Stunned can only recover to Idle -----------------------------
do
	local fsm = StateMachine.new("Idle")

	check(fsm:SetState("Stunned") == true, "d) Idle -> Stunned must be allowed")
	check(fsm:SetState("Windup") == false, "d) Stunned -> Windup must be rejected")
	check(fsm.CurrentState == "Stunned", "d) a rejected transition must not change state")
end

-- e) Interruption: a stun overrides an Active swing ---------------------------
do
	local fsm = StateMachine.new("Idle")

	check(fsm:SetState("Windup") == true, "e) Idle -> Windup must be allowed")
	check(fsm:SetState("Active") == true, "e) Windup -> Active must be allowed")
	check(fsm:SetState("Stunned") == true, "e) Active -> Stunned must be allowed")
	check(fsm.CurrentState == "Stunned", "e) the stun must land the machine on Stunned")
end

-- Report ----------------------------------------------------------------------
if #failures == 0 then
	print("[FSM TEST] SUCCESS: All 5 transition invariants verified.")
	return
end

for _, reason in ipairs(failures) do
	print(string.format("[FSM TEST] FAILED: %s", reason))
end
