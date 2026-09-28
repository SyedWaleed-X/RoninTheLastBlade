--!strict

--[[
	InputBinder
	Ronin — The Last Blade · input sink -> InputBuffer bridge (Day 3 · Part 1/2)

	The single place where combat intent enters the client. ContextActionService owns
	the bindings rather than UserInputService directly, so:
	  * keyboard/mouse and future mobile touch sinks are declared in one table
	    (ACTION_BINDINGS) instead of being plumbed through separate event paths, and
	  * every sink shares one action name, which keeps rebinding idempotent.

	Bound actions (Part 1 scope):
	  MouseButton1 -> LightAttack
	  MouseButton2 -> Guard
	  Q            -> Dodge
	  F            -> Execute

	Handler contract:
	  1) drop input the game already processed,
	  2) queue only the Begin (press) edge,
	  3) hand the intent to InputBuffer and trace it:
	     [INPUT BUFFER] Queued: <action> at <os.clock()>

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - this binder only records local intent. It never fires a
	    remote; the server remains the authority for damage and state transitions.
	  * ARCHITECTURE.md #4 - the handlers run in C-event context (no Heartbeat loop) and
	    only touch the buffer, so they stay allocation-light.

	This file is a LocalScript (Script Sync suffix `.local.luau`). StarterPlayerScripts
	is already a per-player container, so a Script carrying a non-legacy RunContext in it
	starts twice per client - Studio warns about exactly that combination, and both starts
	require their own copy of InputBuffer, so half the pushes would land in a buffer no
	consumer reads. A local script runs once, from PlayerScripts, which is the single
	sink/single-buffer contract this binder needs (same reasoning as
	CombatController.local.luau).
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

-- Client-local neighbour: every client script requiring this module shares the one
-- buffer the binder pushes into.
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)

-- Day 4 · Part 2/2: the press is handed to CombatController, which owns the machine
-- and is the only place that knows whether the action is legal right now.
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

-- Debug-only gate the Day 3 chaos suite flips to keep live keypresses out of the
-- buffer while it asserts. Open by default; this binder only ever reads it.
local InputGate = require(script.Parent:WaitForChild("InputGate") :: ModuleScript)

type CombatAction = InputBuffer.CombatAction

--[[
	Declarative sink table. `InputTypes` is the list ContextActionService binds, so a
	mobile sink is a one-line change here (add `Enum.UserInputType.Touch`, or flip
	`CreateTouchButton` to let CAS build the default on-screen button) rather than a
	new code path.
]]
type ActionBinding = {
	Action: CombatAction,
	ActionName: string,
	CreateTouchButton: boolean,
	InputTypes: { Enum.KeyCode | Enum.UserInputType },
}

local ACTION_BINDINGS: { ActionBinding } = {
	{
		Action = "LightAttack",
		ActionName = "Ronin_LightAttack",
		CreateTouchButton = false,
		InputTypes = { Enum.UserInputType.MouseButton1 },
	},
	{
		Action = "Guard",
		ActionName = "Ronin_Guard",
		CreateTouchButton = false,
		InputTypes = { Enum.UserInputType.MouseButton2 },
	},
	{
		Action = "Dodge",
		ActionName = "Ronin_Dodge",
		CreateTouchButton = false,
		InputTypes = { Enum.KeyCode.Q },
	},
	{
		Action = "Execute",
		ActionName = "Ronin_Execute",
		CreateTouchButton = false,
		InputTypes = { Enum.KeyCode.F },
	},
}

--[[
	ContextActionService handlers do not receive UserInputService's `gameProcessedEvent`
	flag - that flag only exists on the raw UserInputService events - so the equivalent
	test is used here. While a text box owns focus (chat, any UI field) the press already
	belongs to that UI and must not be queued: without this guard, typing "q" in chat
	would queue a Dodge.
]]
local function isGameProcessed(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

--[[
	Queues `action` on the press edge and traces it. Returns `Pass` so the input keeps
	travelling (default camera drag on MouseButton2, GUI clicks on MouseButton1): the
	buffer records intent, it does not claim the input.
]]
local function onActionInput(action: CombatAction, inputState: Enum.UserInputState): Enum.ContextActionResult
	if InputGate.IsGated() or isGameProcessed() then
		return Enum.ContextActionResult.Pass
	end

	if inputState ~= Enum.UserInputState.Begin then
		-- Release/cancel edges are not intents; the consumer owns what happens after
		-- the action resolves.
		return Enum.ContextActionResult.Pass
	end

	--[[
		Day 4 · Part 2/2: the press is offered to the bound machine, which either
		spends it on the spot (the character is already Idle) or queues it for the next
		Idle entry. Before this, every press went straight into the queue and the queue
		was only ever read on a transition *into* Idle, so a click made while the
		character was already actionable sat unspent until something else had to move
		the machine first - to the player, a dropped input.

		The decision is deliberately not made here. CombatController owns the machine
		and the single action -> transition mapping; this binder is a sink, and a
		second copy of the "is it legal yet" rule in the binder is exactly how the two
		paths would drift apart.
	]]
	if CombatStateBus.OfferIntent(action) then
		print(string.format("[INPUT] Spent on the spot: %s at %.3f", action, os.clock()))
	else
		print(string.format("[INPUT BUFFER] Queued: %s at %.3f", action, os.clock()))
	end

	return Enum.ContextActionResult.Pass
end

-- Binding ----------------------------------------------------------------------
for _, binding in ipairs(ACTION_BINDINGS) do
	local action = binding.Action

	ContextActionService:BindAction(
		binding.ActionName,
		function(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
			return onActionInput(action, inputState)
		end,
		binding.CreateTouchButton,
		table.unpack(binding.InputTypes)
	)
end
