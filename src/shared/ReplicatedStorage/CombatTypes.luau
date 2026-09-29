--!strict

--[[
	CombatTypes
	Ronin — The Last Blade

	Shared combat contracts for the deterministic state machine.

	Source of truth: src/shared -> ReplicatedStorage (docs/ARCHITECTURE.md).
	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #4 - the module returns frozen, constant data so client
	    prediction and server authority can read it without runtime allocation.
]]

--[[
	Every legal state of the combat state machine. The server is the only authority
	allowed to move a character between these states; the client predicts locally
	and reconciles against the server.
]]
export type CombatState =
	"Idle"
	| "Windup"
	| "Active"
	| "Recovery"
	| "Blocking"
	| "Parrying"
	| "Stunned"
	| "Executing"
	| "Dodging"

--[[
	Wire format for an attack. `AttackId` is a server-issued monotonic id used for
	duplicate/replay rejection, `Timestamp` is the sender's clock reading at request
	time (never trusted for damage authority) and `Damage` is the raw requested
	value before server-side validation clamps it.
]]
export type AttackPayload = {
	Attacker: Player,
	AttackId: number,
	Timestamp: number,
	Damage: number,
}

--[[
	Result of resolving a deflect against the 133ms parry window. When `Success` is
	true, `PostureDamage` is the reflected posture cost applied to the attacker, and
	`AttackerStunned` reports whether that reflection broke the attacker's action
	lock into `Stunned`.
]]
export type DeflectResult = {
	Success: boolean,
	PostureDamage: number,
	AttackerStunned: boolean,
}

--[[
	Runtime mirror of `CombatState`. Luau types are erased at runtime, so remote
	validation schemas (ARCHITECTURE.md #2) need a concrete table to check untrusted
	client strings against.
]]
-- The literal is built first and frozen second on purpose: `table.freeze` returns
-- a readonly sealed table, and a readonly literal cannot satisfy the `[string]`
-- indexer annotation below (strict mode reports that as a type error). Assigning
-- the plain literal to the annotated `stateMap` first lets the expected type supply
-- the indexer, then `table.freeze` locks it down at runtime.
local stateMap: { [string]: CombatState } = {
	Idle = "Idle",
	Windup = "Windup",
	Active = "Active",
	Recovery = "Recovery",
	Blocking = "Blocking",
	Parrying = "Parrying",
	Stunned = "Stunned",
	Executing = "Executing",
	Dodging = "Dodging",
}

local CombatStates = table.freeze(stateMap)

--[[
	Type guard for inbound remotes: rejects anything that is not one of the nine
	literal states. Allocation free, so it is safe inside validation schemas.
]]
local function isCombatState(value: any): boolean
	return typeof(value) == "string" and CombatStates[value] ~= nil
end

local CombatTypes = table.freeze({
	CombatStates = CombatStates,
	IsCombatState = isCombatState,
})

return CombatTypes
