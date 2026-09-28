--!strict

--[[
	AttackConfig
	Ronin — The Last Blade · 3-hit chain frame data (Day 4 · Part 1/2)

	Frozen frame data for the light-attack chain. Every duration is in seconds and
	describes one phase of one swing, matching the states in docs/COMBAT_SPEC.md §1:
	  Windup    - startup, the window a parry can cancel into.
	  Active    - the lethal strike window, action locked.
	  Recovery  - follow-through, where a new intent is buffered for the next hit.

	The chain is a dictionary keyed by the 1-based hit index so a consumer reads its
	frame data with a plain index (`COMBO_CHAIN[CurrentComboIndex]`) instead of an
	array walk, and so `HitIndex` travels with the data for logging/serialisation.

	The escalating numbers are the design intent of the chain: every hit is faster to
	start but hits harder, and Hit 3 commits the longest (0.77s of total frame time)
	for the biggest damage and the biggest posture damage.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #4 - the table is frozen so neither client prediction nor the
	    server can mutate shared frame data at runtime.
]]

export type AttackData = {
	HitIndex: number,
	WindupDuration: number,
	ActiveDuration: number,
	RecoveryDuration: number,
	Damage: number,
	PoiseDamage: number,
	LungeSpeed: number,
}

--[[
	The literal is built into an annotated local first and frozen second on purpose:
	`table.freeze` returns a readonly sealed table, and a readonly literal cannot
	satisfy a mutable indexer annotation in strict mode. Assigning the plain literal to
	the annotated `chain` first lets the expected type supply the indexer, then
	`table.freeze` locks it down at runtime (same pattern as CombatTypes).
]]
local chain: { [number]: AttackData } = {
	[1] = {
		HitIndex = 1,
		WindupDuration = 0.15,
		ActiveDuration = 0.12,
		RecoveryDuration = 0.20,
		Damage = 10,
		PoiseDamage = 15,
		LungeSpeed = 22,
	},
	[2] = {
		HitIndex = 2,
		WindupDuration = 0.12,
		ActiveDuration = 0.12,
		RecoveryDuration = 0.22,
		Damage = 14,
		PoiseDamage = 20,
		LungeSpeed = 28,
	},
	[3] = {
		HitIndex = 3,
		WindupDuration = 0.24,
		ActiveDuration = 0.18,
		RecoveryDuration = 0.35,
		Damage = 24,
		PoiseDamage = 35,
		LungeSpeed = 38,
	},
}

local COMBO_CHAIN = table.freeze(chain)

--[[
	Chain window in seconds. A new press only continues the chain when it lands within
	COMBO_RESET_TIMEOUT of the *end* of the previous swing; beyond that the next swing
	restarts at Hit 1. 800ms is deliberately longer than the 200ms InputBuffer
	tolerance, because the buffer window is spent while the character is still busy
	(Recovery) whereas the chain window is what the player actually feels.
]]
local COMBO_RESET_TIMEOUT = 0.80

local AttackConfig = table.freeze({
	COMBO_CHAIN = COMBO_CHAIN,
	COMBO_RESET_TIMEOUT = COMBO_RESET_TIMEOUT,
})

return AttackConfig
