--!strict

--[[
	InputGate
	Ronin — The Last Blade · debug-only live-input gate (Day 3 · Part 2/2)

	A one-flag module shared by InputBinder and the CombatDebugUI chaos suite.

	Why it exists: the Day 3 suite asserts against the live InputBuffer, but the player
	is still pressing keys while it runs. A press landing between an assertion and the
	check that follows it reads as a leaked input and fails the suite spuriously - that
	exact race is what made the first Hitstun Flush run fail. The suite therefore
	closes the live-input edge for the duration and reopens it afterwards.

	Deliberately placed at the *input edge* rather than inside InputBuffer: the suite
	pushes straight to InputBuffer, so gating Push itself would block the suite's own
	writes. Gating the binder blocks only real keypresses.

	This is debug scaffolding, not gameplay. The default is open (gated = false), the
	InputBinder never sets it, and the suite pairs every Set with its cleanup so a
	failed assertion cannot leave the game deaf.
]]

local InputGate = {}

local gated = false

--[[
	Opens (true) or closes (false) the live-input edge. Returns the previous value so a
	caller can restore exactly what it found.
]]
function InputGate.Set(value: boolean): boolean
	local previous = gated
	gated = value
	return previous
end

function InputGate.IsGated(): boolean
	return gated
end

return InputGate
