--!strict

--[[
	InputBuffer
	Ronin — The Last Blade · client-side action queue (Day 3 · Part 1/2)

	Holds at most one queued combat intent for a short tolerance window, so a press
	made while the character is still busy (docs/COMBAT_SPEC.md §1 Recovery:
	"inputs are buffered") is not swallowed — the state machine can spend it the
	instant the character becomes actionable again.

	Contract:
	  * Push             - records an action stamped with os.clock(); a newer press
	                       replaces the older pending one (the player's latest intent
	                       wins), including one that was already consumed.
	  * Peek             - reads the queued action without spending it. Returns nil as
	                       soon as the entry is consumed or older than BUFFER_WINDOW,
	                       and drops that stale entry on the same read.
	  * Consume          - reads and spends the queued action, so one press can only
	                       ever produce one action.
	  * Clear            - flushes everything immediately: the Stun / Ragdoll input
	                       lock (COMBAT_SPEC §1) and respawn use this.
	  * GetTimeRemaining - milliseconds left in the window, 0 when nothing is queued.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - this is a *local intent* only. Nothing here is sent to the
	    server; the server stays the sole authority for damage and state transitions.
	  * ARCHITECTURE.md #4 - only Push allocates, and only on the input event itself.
	    The polling paths (Peek / Consume / GetTimeRemaining) reuse the live entry and
	    never build a new table, so they are safe for a per-frame consumer.

	Client-local by construction (a ModuleScript in StarterPlayerScripts): `require`
	caches per instance, so every client script that requires it shares the one buffer.
]]

--[[
	Input tolerance in seconds. A press that lands within 200ms of the character
	becoming actionable is still honoured; anything older is discarded as a stale
	intent. Deliberately longer than the 133ms parry reaction window, which is a
	server-timed state transition and not an input queue concern.
]]
local BUFFER_WINDOW = 0.20

--[[
	Every action the player can queue. The binder maps physical inputs onto these, and
	the state machine (Part 2) resolves them into transitions.
]]
export type CombatAction =
	"LightAttack"
	| "Guard"
	| "Dodge"
	| "Execute"

--[[
	One queued intent. `Timestamp` is the `os.clock()` reading taken by Push and
	`Consumed` reports whether the queue has already been spent, so a consumer can
	tell "never queued" apart from "already used".
]]
export type BufferedInput = {
	Action: CombatAction,
	Timestamp: number,
	Consumed: boolean,
}

local InputBuffer = {}

-- The single pending queue slot. At most one entry lives here at a time.
local bufferedInput: BufferedInput? = nil

--[[
	Reads the live entry, or nil when there is nothing to spend. A consumed or expired
	entry is dropped here so a later read can never resurrect it.
]]
local function readPending(): BufferedInput?
	local pending = bufferedInput
	if not pending then
		return nil
	end

	if pending.Consumed or (os.clock() - pending.Timestamp) > BUFFER_WINDOW then
		bufferedInput = nil
		return nil
	end

	return pending
end

--[[
	Records `action` as the newest intent, replacing whatever was pending. Called from
	input handlers, so it is the only path in this module that allocates.
]]
function InputBuffer.Push(action: CombatAction)
	bufferedInput = {
		Action = action,
		Timestamp = os.clock(),
		Consumed = false,
	}
end

--[[
	Returns the queued action without spending it, or nil when the queue is empty,
	already consumed, or has outlived BUFFER_WINDOW.
]]
function InputBuffer.Peek(): CombatAction?
	local pending = readPending()
	if not pending then
		return nil
	end

	return pending.Action
end

--[[
	Returns the queued action and marks it consumed, so a second Consume for the same
	press returns nil. The spent entry is left in place (flagged) until the next Push
	or Clear, which keeps the queue slot single-valued without extra bookkeeping.
]]
function InputBuffer.Consume(): CombatAction?
	local pending = readPending()
	if not pending then
		return nil
	end

	pending.Consumed = true

	return pending.Action
end

--[[
	Flushes all pending inputs immediately. Used on the Stun / Ragdoll input lock
	(COMBAT_SPEC §2.1) and on respawn, where queued intents must not survive.
]]
function InputBuffer.Clear()
	bufferedInput = nil
end

--[[
	Milliseconds remaining before the queued action expires, or 0 when nothing is
	queued (empty, consumed or expired). Floored to whole milliseconds for display.
]]
function InputBuffer.GetTimeRemaining(): number
	local pending = readPending()
	if not pending then
		return 0
	end

	local remaining = BUFFER_WINDOW - (os.clock() - pending.Timestamp)

	return math.max(0, math.floor(remaining * 1000))
end

-- Exposed as a field so observers (debug HUD, Part 2 predictor) can render the
-- tolerance without duplicating the constant.
InputBuffer.BUFFER_WINDOW = BUFFER_WINDOW

return InputBuffer
