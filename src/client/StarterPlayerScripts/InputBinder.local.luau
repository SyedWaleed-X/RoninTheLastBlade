--!strict

--[[
	InputBinder
	Ronin — The Last Blade · input sink -> InputBuffer bridge (Day 6 · Part 1/2)

	The single place where combat intent enters the client. ContextActionService owns
	the bindings rather than UserInputService directly, so:
	  * keyboard/mouse and future mobile touch sinks are declared in one table
	    (ACTION_BINDINGS) instead of being plumbed through separate event paths, and
	  * every sink shares one action name, which keeps rebinding idempotent.

	Bound actions:
	  MouseButton1 -> LightAttack   (tap; attacking out of a guard releases it first)
	  MouseButton2 -> Guard         (HOLD - Blocking on press, Idle on release)
	  Q            -> Dodge
	  F            -> Execute

	Handler contract:
	  1) drop input the game already processed,
	  2) tap actions: queue only the Begin (press) edge,
	  3) hold actions: Begin requests the state, End drops it again,
	  4) hand the intent to the bound machine and trace it.

	Two input shapes, one binding table
	------------------------------------
	Day 3 bound every action as a *tap*, because at that point every action was a
	single transition: press Guard, be Blocking, done. Day 6 makes Guard a *hold*,
	which is a different contract and therefore a different handler, and the two are
	distinguished by a `Hold` flag on the binding rather than by a second table. A
	second table would be one more place to remember to add the next action; a flag
	is one field that is either set or not.

	`Hold` actions are driven from the raw `UserInputState` edges and never reach
	`InputBuffer`, for a reason worth stating: the buffer is a 200ms single-slot
	queue whose entire job is to survive the character being busy, and a guard
	*hold* has nothing to survive - the button's own physical release is the event
	that ends the state, and it arrives whenever the player lets go, potentially
	seconds later. Routing a hold through a 200ms window would mean the guard
	silently timed out while the button was still down, so `End` drives the exit
	straight off the button.

	Legality is still not decided here. `CanRequestState` / `RequestState` go to
	the machine, so the same `ALLOWED_TRANSITIONS` table governs a hold exactly as
	it governs a tap - this file decides *when to ask*, never *whether it is
	allowed*.

	Attacking out of a guard
	------------------------
	A press of LightAttack while the character is Blocking is the one case where
	the input and the machine genuinely disagree: the character is in a state
	`offerIntent` treats as "busy", so the press would be queued and swallowed for
	up to 200ms while the player watches a guard they did not ask for stay up.

	So the binder releases the guard on the spot and offers the attack in the same
	callback. Ordering matters and is not arbitrary: `RequestState("Idle")`
	completes synchronously, so by the time `OfferIntent` runs, `offerIntent`
	observes a genuinely Idle machine and spends the press directly instead of
	queueing it. The alternative - offering first - would queue, and the queued
	intent would then compete with the release for the next Idle.

	`Blocking -> Idle` is a legal edge in `StateMachine` (COMBAT_SPEC: "Releasing
	block"), so this is a table-sanctioned transition, not a forced one.

	The chain index that plays is Hit 1 in every practical case, because holding a
	guard out of combat for any real duration exceeds `COMBO_RESET_TIMEOUT`
	(0.80s) and the chain resets to its opener. A guard tapped and dropped inside
	800ms of a swing resolving continues the chain onto Hit 2/3 - that is the chain
	rule in `AttackConfig` behaving as designed, not a bug, and forcing the index
	here would mean the binder owning chain state that it does not own.

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

--[[
	Day 7 · Part 1/2: the parry timing engine.

	Required here for the `Begin` edge of the Guard binding and nothing else. It is a
	ModuleScript rather than a LocalScript, so this require is also what starts it —
	the same reasoning that has been applied to `GuardSparks` since Day 6: a module
	nobody requires never runs its body.
]]
local ParryWindow = require(script.Parent:WaitForChild("ParryWindow") :: ModuleScript)

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
	-- Day 6 · Part 1/2: true for actions whose *release* is also a combat event.
	-- See the "Two input shapes" note in the header.
	Hold: boolean,
}

local ACTION_BINDINGS: { ActionBinding } = {
	{
		Action = "LightAttack",
		ActionName = "Ronin_LightAttack",
		CreateTouchButton = false,
		InputTypes = { Enum.UserInputType.MouseButton1 },
		Hold = false,
	},
	{
		Action = "Guard",
		ActionName = "Ronin_Guard",
		CreateTouchButton = false,
		InputTypes = { Enum.UserInputType.MouseButton2 },
		Hold = true,
	},
	{
		Action = "Dodge",
		ActionName = "Ronin_Dodge",
		CreateTouchButton = false,
		InputTypes = { Enum.KeyCode.Q },
		Hold = false,
	},
	{
		Action = "Execute",
		ActionName = "Ronin_Execute",
		CreateTouchButton = false,
		InputTypes = { Enum.KeyCode.F },
		Hold = false,
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
		Day 6 · Part 1/2: attacking out of a guard.

		This runs before the normal offer, and it must. `offerIntent` only spends a
		press when the machine is Idle, and a Blocking character is not - so without
		this branch the press would sit in a 200ms queue window the player never asked
		for, and the guard would still be up when it expired. To the player that is
		"my attack did nothing and I am still stuck blocking".

		The release is requested first and the offer second, and the order is load
		bearing: `RequestState` writes `CurrentState` synchronously, so by the time
		`OfferIntent` reads the machine it reads Idle and spends the press on the
		spot. Reversing the two would queue instead.

		`CanRequestState` is asked first purely to keep the console clean - a refusal
		logs a warning inside the machine, and "released a guard that was not up" is
		not a warning worth printing. The actual decision still belongs to
		`RequestState`; this only avoids a spurious log on a state that is already
		correct.
	]]
	if action == "LightAttack" and CombatStateBus.GetCurrentState() == "Blocking" then
		if CombatStateBus.CanRequestState("Idle") then
			CombatStateBus.RequestState("Idle")
			print(string.format("[INPUT] Guard released by attack at %.3f", os.clock()))
		end
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

--[[
	Day 6 · Part 1/2: the hold path, used by the Guard binding.

	`Begin` raises the guard, `End` drops it. Both go straight to the machine rather
	than through `InputBuffer`, because the buffer's 200ms window is the wrong
	container for a button that can be held for as long as the player likes - see the
	"Two input shapes" note in the header.

	`End` is gated on the character actually being in Blocking. Without that check,
	releasing the button during a swing (or after the guard was already dropped by an
	attack-out-of-guard) would request `Idle` from whatever state the character had
	walked into, and `StateMachine` would refuse it and warn - a stream of spurious
	`[FSM] Rejected transition` lines for an input that was perfectly fine.

	`isGameProcessed` is deliberately *not* consulted on the release edge. It exists
	to stop a press being stolen from a focused text box, and a release cannot be
	"typed" - but if the player alt-tabs or opens chat mid-guard, dropping the guard
	is exactly the right outcome, and swallowing the release would leave the character
	permanently guarding with no input still down. For the same reason `Cancel` (the
	window lost focus, or the input was stolen) is treated as a release rather than
	ignored.
]]
local function onHoldInput(action: CombatAction, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		-- The gate is honoured on the way in: a chaos run that is driving the machine
		-- directly must not have a live mouse press also fighting it for the guard.
		if InputGate.IsGated() or isGameProcessed() then
			return Enum.ContextActionResult.Pass
		end

		--[[
			Day 7 · Part 1/2: the press that raises the guard is also the parry press.

			Gated on `action == "Guard"` rather than assumed. The hold path is shared by
			every hold-shaped binding, and it is a table away from gaining a second
			one; a future hold that is not a parry press would otherwise silently open
			a parry window, which is the kind of coupling that is invisible until a
			deflect lands on a dodge.

			`OnBlockPressed()` opens the 133ms window and returns its width, which is
			handed to `CombatController` rather than acted on here. That indirection is
			the point: the binder still decides nothing about whether the parry
			succeeds, and the window it opened is the *client's* prediction.
			`CombatController` is the one observer that already publishes the guard to
			the server, so it is the one place that tells the server a window is open —
			a second publisher would be a second opinion about the same character.

			Called before the state request rather than after, deliberately. The window
			is a property of the *press*, not of the resulting state, and a press whose
			state request is refused (already mid-swing) should still have consumed a
			step off the spam ladder — otherwise a player mashing block during a
			recovery never decays at all, which is exactly the mashing this ladder
			exists to price.
		]]
		if action == "Guard" then
			local window = ParryWindow.OnBlockPressed()
			CombatStateBus.NotifyParryPressed(window)
		end

		-- Only ask when the move is legal, so holding the button through a swing is a
		-- quiet no-op rather than a logged rejection. `ALLOWED_TRANSITIONS` has
		-- Idle -> Blocking and Parrying -> Blocking; every other origin refuses.
		if CombatStateBus.CanRequestState("Blocking") then
			CombatStateBus.RequestState("Blocking")
			print(string.format("[INPUT] Guard raised at %.3f", os.clock()))
		else
			print(string.format(
				"[INPUT] Guard refused: %s -> Blocking is not a legal edge at %.3f",
				tostring(CombatStateBus.GetCurrentState()),
				os.clock()
			))
		end

		return Enum.ContextActionResult.Pass
	end

	-- End and Cancel both mean "the button is no longer down", which is the only thing
	-- this cares about.
	if CombatStateBus.GetCurrentState() == "Blocking" and CombatStateBus.CanRequestState("Idle") then
		CombatStateBus.RequestState("Idle")

		if inputState == Enum.UserInputState.End then
			print(string.format("[INPUT] Guard dropped at %.3f", os.clock()))
		else
			print(string.format("[INPUT] Guard dropped (input cancelled) at %.3f", os.clock()))
		end
	end

	return Enum.ContextActionResult.Pass
end

-- Binding ----------------------------------------------------------------------
for _, binding in ipairs(ACTION_BINDINGS) do
	local action = binding.Action
	local hold = binding.Hold

	ContextActionService:BindAction(
		binding.ActionName,
		function(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject): Enum.ContextActionResult
			-- The hold branch is selected once, at bind time, so the per-press cost is
			-- a boolean test rather than a string comparison against the action name.
			-- The action is handed to the handler because the hold path is no longer
			-- purely guard-shaped: the same `Begin` edge is what opens a parry window,
			-- and that decision needs to know which button produced it.
			if hold then
				return onHoldInput(action, inputState)
			end

			return onActionInput(action, inputState)
		end,
		binding.CreateTouchButton,
		table.unpack(binding.InputTypes)
	)
end
