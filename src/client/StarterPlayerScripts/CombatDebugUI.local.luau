--!strict

--[[
	CombatDebugUI
	Ronin — The Last Blade · combat debug HUD + keyboard harness

	Builds a minimalist dark status card in the top-left corner that mirrors the client
	state machine owned by CombatController (reached through CombatStateBus):
	  * current state badge, colour coded per COMBAT_SPEC state
	  * previous state
	  * milliseconds spent in the current state (updated every RenderStepped)
	  * Day 4: COMBO: [ HIT x / 3 ], the live position in the 3-hit chain, lit while
	    a swing is in flight and dim while the character is actionable
	  * feed of the last four transitions

	Directly beneath it sits the Day 3 Input Telemetry panel, which watches the live
	InputBuffer slot:
	  * BUFFERED: [ NONE ] in grey, or [ LIGHT_ATTACK ] in cyan while an intent waits
	  * a countdown bar plus an `XXX ms` readout of the tolerance window remaining
	  * a rolling feed of the last three consumed inputs and their latency deltas

	Keys (game-processed input is ignored, so typing in chat never fires the harness):
	  [1] Windup then Active     [2] Blocking     [3] Parrying     [4] Stunned
	  [0] force reset to Idle
	  [R] chaos burst: 100 random transition requests inside a single frame
	  [T] Day 3 chaos suite: the three input buffer invariants (spam, expiry, flush)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CombatTypes = require(ReplicatedStorage.CombatTypes)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)
local InputGate = require(script.Parent:WaitForChild("InputGate") :: ModuleScript)

type CombatState = CombatTypes.CombatState
type CombatAction = InputBuffer.CombatAction

local HUD_NAME = "CombatDebugHUD"
local CHAOS_REQUESTS = 100
local HISTORY_DEPTH = 4
local CARD_WIDTH = 256

-- Chaos suite (Key [T]) timing.
local CHAOS_SPAM_REQUESTS = 20 -- presses issued inside a single frame
local EXPIRY_TEST_WAIT = 0.21 -- just beyond the 200ms BUFFER_WINDOW
local FLUSH_SETTLE = 0.02 -- one frame's grace for a task.spawn'd listener to land

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Palette ----------------------------------------------------------------------
local STATE_COLORS: { [CombatState]: Color3 } = {
	Idle = Color3.fromRGB(64, 196, 99), -- green
	Windup = Color3.fromRGB(232, 200, 60), -- yellow
	Active = Color3.fromRGB(220, 62, 62), -- red
	Recovery = Color3.fromRGB(236, 138, 46), -- orange
	Blocking = Color3.fromRGB(58, 124, 232), -- blue
	Parrying = Color3.fromRGB(54, 206, 214), -- cyan
	Stunned = Color3.fromRGB(154, 88, 216), -- purple
	Executing = Color3.fromRGB(186, 24, 66), -- crimson
}

local NEUTRAL_COLOR = Color3.fromRGB(52, 54, 62)
local CARD_BACKGROUND = Color3.fromRGB(16, 17, 21)
local TEXT_DIM = Color3.fromRGB(142, 148, 160)
local TEXT_BRIGHT = Color3.fromRGB(236, 238, 244)
local COLOR_CYAN = Color3.fromRGB(54, 206, 214)
local BAR_BG_COLOR = Color3.fromRGB(34, 36, 44)

-- Construction ------------------------------------------------------------------
local function createLabel(
	parent: Instance,
	name: string,
	text: string,
	textSize: number,
	font: Enum.Font,
	color: Color3,
	position: UDim2,
	size: UDim2
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = textSize
	label.Font = font
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = position
	label.Size = size
	label.Parent = parent
	return label
end

local previousHud = playerGui:FindFirstChild(HUD_NAME)
if previousHud then
	previousHud:Destroy() -- a re-run of the harness must never stack two HUDs
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = HUD_NAME
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Parent = playerGui

local card = Instance.new("Frame")
card.Name = "StatusCard"
card.BackgroundColor3 = CARD_BACKGROUND
card.BackgroundTransparency = 0.05
card.BorderSizePixel = 0
card.Position = UDim2.fromOffset(16, 16)
card.Size = UDim2.fromOffset(CARD_WIDTH, 234)
card.Parent = screenGui

local cardStroke = Instance.new("UIStroke")
cardStroke.Color = Color3.fromRGB(255, 255, 255)
cardStroke.Thickness = 1
cardStroke.Transparency = 0.85
cardStroke.Parent = card

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 6)
cardCorner.Parent = card

local cardPad = Instance.new("UIPadding")
cardPad.PaddingTop = UDim.new(0, 12)
cardPad.PaddingBottom = UDim.new(0, 12)
cardPad.PaddingLeft = UDim.new(0, 12)
cardPad.PaddingRight = UDim.new(0, 12)
cardPad.Parent = card

local stateTitleLabel = createLabel(
	card, "StateTitle", "COMBAT STATE", 10, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 12)
)
stateTitleLabel.TextXAlignment = Enum.TextXAlignment.Left

local stateBadge = createLabel(
	card, "StateBadge", "NO MACHINE", 18, Enum.Font.GothamBold, TEXT_BRIGHT,
	UDim2.fromOffset(0, 18), UDim2.new(1, 0, 0, 24)
)
stateBadge.BackgroundTransparency = 0.82
stateBadge.BackgroundColor3 = NEUTRAL_COLOR
stateBadge.TextXAlignment = Enum.TextXAlignment.Center
stateBadge.Position = UDim2.fromOffset(0, 18)
stateBadge.Size = UDim2.new(1, 0, 0, 26)
local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(0, 4)
badgeCorner.Parent = stateBadge

local prevLabel = createLabel(
	card, "PrevState", "PREV: —", 12, Enum.Font.Gotham, TEXT_DIM,
	UDim2.fromOffset(0, 48), UDim2.new(1, 0, 0, 14)
)

local durationLabel = createLabel(
	card, "Duration", "TIME  — ms", 12, Enum.Font.Gotham, TEXT_DIM,
	UDim2.fromOffset(0, 64), UDim2.new(1, 0, 0, 14)
)

-- Day 4: live 3-hit chain position, mirrored from AttackController through the bus.
-- Lit while a swing is in flight, dim once the character is actionable again.
local comboLabel = createLabel(
	card, "ComboIndex", "COMBO: [ HIT 1 / 3 ]", 13, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 80), UDim2.new(1, 0, 0, 16)
)

--[[
	Day 7 · Part 1/2: the parry result line.

	Sits between the chain row and the transition feed, and it is the only element in
	this HUD that reports something the *server* decided rather than something the
	client observed. That distinction is why it flashes rather than persisting: a
	perfect deflect is an event, and a permanent "PARRY: SUCCESS" row would be a lie
	about the present tense — the window is long closed by the time the player reads
	it.

	The window width it quotes is the one the *server* measured, not the one the
	client predicted. On a press the two can disagree by a rung (they count their own
	presses independently), and the HUD is deliberately on the server's side of that
	disagreement, because the server's number is the one the deflect was judged on.
]]
local parryLabel = createLabel(
	card, "ParryResult", "PARRY: [ — ]", 13, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 98), UDim2.new(1, 0, 0, 16)
)

--[[
	How long the success line stays lit, in seconds.

	1.2s is long enough to be read in the middle of a fight and short enough that a
	second deflect does not have to wait for the first to clear. The line is not a
	timer, so there is no tween and no per-frame allocation to expire it: the render
	loop below compares a deadline, which is the same zero-allocation approach the
	input telemetry's countdown bar already uses.
]]
local PARRY_FLASH_DURATION = 1.2
local parryFlashUntil = 0
local parryFlashMs = 0
local parryFlashReflected = 0

--[[
	Paints the parry line, lit or dimmed.

	`os.clock() >= parryFlashUntil` is the whole expiry rule. It is compared rather
	than decremented, so there is no accumulator to drift and no timer to cancel: a
	second deflect simply pushes the deadline out, and the line stays lit for the
	full window of the *newest* deflect rather than being cut short by the older
	one's remaining time.

	The reflected posture is in the same line rather than a row of its own, because
	the two numbers are one fact: "you timed a 133ms window" and "the attacker eats
	25" are the same event described from two sides, and a player who cannot see the
	cost they inflicted has no reason to keep attempting the timing.
]]
local function paintParryResult()
	if os.clock() >= parryFlashUntil then
		parryLabel.Text = "PARRY: [ — ]"
		parryLabel.TextColor3 = TEXT_DIM
		return
	end

	parryLabel.Text = string.format(
		"PARRY: [ SUCCESS - %dms, +%d reflected ]",
		parryFlashMs,
		parryFlashReflected
	)
	parryLabel.TextColor3 = COLOR_CYAN
end

CombatStateBus.SubscribeParryResults(function(record: CombatStateBus.ParryResultRecord)
	parryFlashMs = math.floor(record.WindowSeconds * 1000)
	parryFlashReflected = record.ReflectedPosture
	parryFlashUntil = os.clock() + PARRY_FLASH_DURATION

	paintParryResult()
end)

local divider = Instance.new("Frame")
divider.Name = "Divider"
divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
divider.BackgroundTransparency = 0.85
divider.BorderSizePixel = 0
divider.Position = UDim2.new(0, 0, 0, 118)
divider.Size = UDim2.new(1, 0, 0, 1)
divider.Parent = card

local feedTitleLabel = createLabel(
	card, "FeedTitle", "TRANSITIONS", 10, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 126), UDim2.new(1, 0, 0, 12)
)

-- Four rows, newest first; filled in by pushHistory.
local feedRows: { TextLabel } = {}
for index = 1, HISTORY_DEPTH do
	local row = createLabel(
		card, "FeedRow" .. index, "", 11, Enum.Font.Code, TEXT_BRIGHT,
		UDim2.fromOffset(0, 142 + (index - 1) * 14), UDim2.new(1, 0, 0, 14)
	)
	feedRows[index] = row
end

--[[
	Input Telemetry panel (Day 3). Sits directly beneath the combat state card and
	renders the live InputBuffer slot: what is queued, how much of the tolerance
	window is left, and what was recently spent.
]]
local inputCard = Instance.new("Frame")
inputCard.Name = "InputTelemetryCard"
inputCard.BackgroundColor3 = CARD_BACKGROUND
inputCard.BackgroundTransparency = 0.05
inputCard.BorderSizePixel = 0
inputCard.Position = UDim2.fromOffset(16, 258)
inputCard.Size = UDim2.fromOffset(CARD_WIDTH, 172)
inputCard.Parent = screenGui

local inputCardStroke = Instance.new("UIStroke")
inputCardStroke.Color = Color3.fromRGB(255, 255, 255)
inputCardStroke.Thickness = 1
inputCardStroke.Transparency = 0.85
inputCardStroke.Parent = inputCard

local inputCardCorner = Instance.new("UICorner")
inputCardCorner.CornerRadius = UDim.new(0, 6)
inputCardCorner.Parent = inputCard

local inputCardPad = Instance.new("UIPadding")
inputCardPad.PaddingTop = UDim.new(0, 12)
inputCardPad.PaddingBottom = UDim.new(0, 12)
inputCardPad.PaddingLeft = UDim.new(0, 12)
inputCardPad.PaddingRight = UDim.new(0, 12)
inputCardPad.Parent = inputCard

local inputTitleLabel = createLabel(
	inputCard, "InputTitle", "INPUT TELEMETRY", 10, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 12)
)

-- Empty state: grey NONE. Switches to vibrant cyan while an action is queued.
local bufferLabel = createLabel(
	inputCard, "BufferedLabel", "BUFFERED: [ NONE ]", 13, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 18), UDim2.new(1, 0, 0, 18)
)

-- Countdown bar: barFill is rescaled every RenderStepped to the remaining window.
local barBg = Instance.new("Frame")
barBg.Name = "BufferBar"
barBg.BackgroundColor3 = BAR_BG_COLOR
barBg.BorderSizePixel = 0
barBg.Position = UDim2.fromOffset(0, 40)
barBg.Size = UDim2.new(1, 0, 0, 6)
barBg.Parent = inputCard
local barBgCorner = Instance.new("UICorner")
barBgCorner.CornerRadius = UDim.new(0, 3)
barBgCorner.Parent = barBg

local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.BackgroundColor3 = COLOR_CYAN
barFill.BorderSizePixel = 0
barFill.Position = UDim2.fromOffset(0, 0)
barFill.Size = UDim2.fromScale(0, 1)
barFill.Parent = barBg
local barFillCorner = Instance.new("UICorner")
barFillCorner.CornerRadius = UDim.new(0, 3)
barFillCorner.Parent = barFill

local countdownLabel = createLabel(
	inputCard, "Countdown", "— ms", 11, Enum.Font.Code, TEXT_DIM,
	UDim2.fromOffset(0, 48), UDim2.new(1, 0, 0, 14)
)

local inputDivider = Instance.new("Frame")
inputDivider.Name = "InputDivider"
inputDivider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
inputDivider.BackgroundTransparency = 0.85
inputDivider.BorderSizePixel = 0
inputDivider.Position = UDim2.new(0, 0, 0, 68)
inputDivider.Size = UDim2.new(1, 0, 0, 1)
inputDivider.Parent = inputCard

local consumedTitleLabel = createLabel(
	inputCard, "ConsumedTitle", "CONSUMED (last 3)", 10, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 76), UDim2.new(1, 0, 0, 12)
)

-- Up to three rows of "<ACTION> · +XX ms", newest first.
local consumedRows: { TextLabel } = {}
for index = 1, 3 do
	local row = createLabel(
		inputCard, "ConsumedRow" .. index, "", 11, Enum.Font.Code, TEXT_DIM,
		UDim2.fromOffset(0, 92 + (index - 1) * 14), UDim2.new(1, 0, 0, 14)
	)
	consumedRows[index] = row
end

-- State painting ---------------------------------------------------------------
local paintedState: CombatState? = nil

local function paintState(state: CombatState?)
	paintedState = state
	if state == nil then
		stateBadge.Text = "NO MACHINE"
		stateBadge.BackgroundColor3 = NEUTRAL_COLOR
		prevLabel.Text = "PREV: —"
		return
	end

	local color: Color3 = state == nil and NEUTRAL_COLOR or STATE_COLORS[state]
	stateBadge.Text = state:upper()
	stateBadge.BackgroundColor3 = color
end

local function paintPreviousState(state: CombatState?)
	prevLabel.Text = if state == nil then "PREV: —" else "PREV: " .. state:upper()
end

local function pushHistory(fromState: CombatState, toState: CombatState)
	for index = HISTORY_DEPTH, 2, -1 do
		feedRows[index].Text = feedRows[index - 1].Text
	end
	feedRows[1].Text = string.format("%s → %s", fromState:upper(), toState:upper())
end

-- Painting ---------------------------------------------------------------------
CombatStateBus.Subscribe(function(fromState: CombatState, toState: CombatState)
	paintState(toState)
	paintPreviousState(fromState)
	pushHistory(fromState, toState)
end)

--[[
	Paints the live chain position of the 3-hit attack chain.

	AttackController is a LocalScript, so the HUD cannot require it and reads the index
	through the bus mirror instead. `inSwing` is derived from the machine rather than
	tracked separately: Windup/Active/Recovery is exactly the window in which the hit
	the index names is the hit being played, so the row is lit during a swing and dims
	once the character is actionable again (showing the hit the next press will play).
	A chain length of 0 means AttackController has not published one yet, which leaves
	the placeholder text alone.
]]
local function paintComboState(inSwing: boolean)
	local activeIndex, totalHits = CombatStateBus.GetComboState()
	if totalHits < 1 then
		return
	end

	comboLabel.Text = string.format("COMBO: [ HIT %d / %d ]", activeIndex, totalHits)
	comboLabel.TextColor3 = if inSwing then COLOR_CYAN else TEXT_DIM
end

RunService.RenderStepped:Connect(function()
	local machine = CombatStateBus.GetActiveMachine()

	if not machine then
		if paintedState ~= nil then
			paintState(nil)
			paintPreviousState(nil)
		end
		durationLabel.Text = "TIME  — ms"
		paintComboState(false)
		return
	end

	local currentState = machine.CurrentState
	if currentState ~= paintedState then
		-- Catches a machine that was bound after its last transition (respawn).
		paintState(currentState)
		paintPreviousState(machine.PreviousState)
	end

	local elapsedMs = math.floor((os.clock() - machine.LastTransitionTime) * 1000)
	durationLabel.Text = string.format("TIME  %d ms", elapsedMs)

	paintComboState(currentState == "Windup" or currentState == "Active" or currentState == "Recovery")

	--[[
		Day 7 · Part 1/2: expire the parry flash from the existing render loop rather
		than on a timer.

		A `task.delay` that reset the label would race the next deflect — two parries
		inside the flash window would have the first one's timer clear the second
		one's success line — and it would leave a pending callback aimed at a label
		that a HUD rebuild may already have destroyed. A deadline compared here cannot
		be stale, and it costs the loop one comparison and no allocation.

		Note this sits *after* the `if not machine then ... return` early-out above and
		is therefore skipped while no character is bound. That is deliberate: a flash
		raised with no machine behind it belongs to a character that is being torn
		down, and `ClearParryResult` on teardown is what clears that case.
	]]
	paintParryResult()

	-- Update Input Telemetry panel (zero per-frame table allocations)
	local pendingAction = InputBuffer.Peek()
	local timeRemainingMs = InputBuffer.GetTimeRemaining()

	if pendingAction then
		local actionTag = if pendingAction == "LightAttack"
			then "LIGHT_ATTACK"
			elseif pendingAction == "Guard"
			then "GUARD"
			elseif pendingAction == "Dodge"
			then "DODGE"
			elseif pendingAction == "Execute"
			then "EXECUTE"
			else string.upper(pendingAction)

		bufferLabel.Text = string.format("BUFFERED: [ %s ]", actionTag)
		bufferLabel.TextColor3 = COLOR_CYAN

		countdownLabel.Text = string.format("%d ms", timeRemainingMs)
		countdownLabel.TextColor3 = COLOR_CYAN

		-- Bar depletes left-to-right across the tolerance window.
		local windowMs = InputBuffer.BUFFER_WINDOW * 1000
		local barScale = math.clamp(timeRemainingMs / windowMs, 0, 1)
		barFill.Size = UDim2.fromScale(barScale, 1)
	else
		bufferLabel.Text = "BUFFERED: [ NONE ]"
		bufferLabel.TextColor3 = TEXT_DIM

		countdownLabel.Text = "— ms"
		countdownLabel.TextColor3 = TEXT_DIM

		barFill.Size = UDim2.fromScale(0, 1)
	end

	-- Consumed-input history feed, newest first.
	local history = CombatStateBus.GetConsumedHistory()
	for index = 1, 3 do
		local entry = history[index]
		local row = consumedRows[index]
		if entry then
			row.Text = string.format("%s · +%d ms", string.upper(entry.Action), math.floor(entry.LatencyDelta * 1000))
			row.TextColor3 = TEXT_BRIGHT
		else
			row.Text = "—"
			row.TextColor3 = TEXT_DIM
		end
	end
end)

-- Keyboard harness -------------------------------------------------------------
local KEY_SEQUENCES: { [Enum.KeyCode]: { CombatState } } = {
	[Enum.KeyCode.One] = { "Windup", "Active" },
	[Enum.KeyCode.Two] = { "Blocking" },
	[Enum.KeyCode.Three] = { "Parrying" },
	[Enum.KeyCode.Four] = { "Stunned" },
}

--[[
	Chaos burst (Key [R]): fires CHAOS_REQUESTS random transitions inside a single
	frame. The point is to prove SetState stays coherent under re-entrant load: the
	final state must be a legal value, the accept/reject tally must add up, and the
	machine must still answer questions afterwards.
]]
local function runChaosTest()
	local machine = CombatStateBus.GetActiveMachine()
	if not machine then
		warn("[CHAOS TEST] Skipped: no state machine bound.")
		return
	end

	local states: { CombatState } = { "Idle", "Windup", "Active", "Recovery", "Blocking", "Parrying", "Stunned", "Executing" }
	local accepted = 0
	local rejected = 0
	local failure: string? = nil

	for _ = 1, CHAOS_REQUESTS do
		local target = states[math.random(1, #states)]
		local ok = machine:SetState(target)
		if ok then
			accepted += 1
		else
			rejected += 1
		end

		-- A rejected move must leave CurrentState untouched and still a legal value.
		local observed = machine.CurrentState
		if not CombatTypes.IsCombatState(observed) then
			failure = string.format("CurrentState became %s mid-burst", tostring(observed))
			break
		end
	end

	local finalState = machine.CurrentState
	local previousState = machine.PreviousState
	local probeOk = CombatTypes.IsCombatState(finalState) and CombatTypes.IsCombatState(previousState)
	local canStillTransition = machine:CanTransitionTo("Idle")

	local clean = failure == nil
		and CombatTypes.IsCombatState(finalState)
		and CombatTypes.IsCombatState(previousState)
		and accepted + rejected == CHAOS_REQUESTS
		and probeOk == true
		and type(canStillTransition) == "boolean"

	if not clean then
		warn(string.format(
			"[CHAOS TEST] FAILED: error=%s finalState=%s accepted=%d rejected=%d probeOk=%s",
			tostring(failure),
			tostring(finalState),
			accepted,
			rejected,
			tostring(probeOk)
		))
		return
	end

	print(string.format("[CHAOS TEST] %d rapid transitions resolved cleanly. Final state: %s", CHAOS_REQUESTS, finalState))
end

--[[
	Day 3 Chaos Suite: Input Buffer Invariant Verification
	Bound to Key [T]. Validates:
	  a) Rapid Spam Test: 20 rapid Push requests; only ONE latest action remains buffered.
	  b) Expiration Test: Push action, wait 210ms (>200ms window); Peek returns nil.
	  c) Hitstun Flush Test: Push action, enter Stunned state; buffer is instantly cleared.

	Every test asserts against the live InputBuffer, so a guard keeps a second [T] press
	from interleaving with a run in progress and corrupting the result. StateMachine
	dispatches listeners through task.spawn, so the controller's Stunned handler lands a
	frame after the transition; FLUSH_SETTLE covers that hop.
]]
local chaosSuiteRunning = false

--[[
	Runs the three invariant checks with Push gated, then always restores the buffer
	and the re-entrancy flag. Wrapping the body means a failed assertion still hands
	input back to the player instead of leaving the game deaf for the rest of the
	session.
]]
local function runInputChaosSuite()
	if chaosSuiteRunning then
		warn("[INPUT CHAOS] Suite already running; ignoring this [T] press.")
		return
	end
	chaosSuiteRunning = true

	print("[INPUT CHAOS] Starting Day 3 Input Buffer Chaos Suite...")

	local ok, err = pcall(function()
		-- Close the live-input edge for the duration: a real keypress landing between
		-- an assertion and the check that follows it would otherwise look like a leak.
		InputGate.Set(true)

		-- Let any transition still in flight settle so a late handler cannot consume a
		-- value a later assertion is about to inspect.
		task.wait(FLUSH_SETTLE)

		-- a) Rapid Spam Test
		--    20 pushes inside a single frame (far inside the 10ms budget). The buffer holds
		--    one slot, so exactly one action may come back out.
		for _ = 1, CHAOS_SPAM_REQUESTS do
			InputBuffer.Push("LightAttack")
		end
		local spamPeek = InputBuffer.Peek()
		assert(spamPeek == "LightAttack", string.format("Rapid Spam: Peek returned %s, expected LightAttack", tostring(spamPeek)))
		local consumedOnce, spamLatency = InputBuffer.Consume()
		assert(consumedOnce == "LightAttack", string.format("Rapid Spam: First Consume returned %s, expected LightAttack", tostring(consumedOnce)))
		assert(spamLatency ~= nil and spamLatency >= 0, "Rapid Spam: Consume did not report a latency delta")
		local consumedTwice = InputBuffer.Consume()
		assert(consumedTwice == nil, string.format("Rapid Spam: Second Consume returned %s, expected nil (duplicate leak)", tostring(consumedTwice)))

		-- b) Expiration Test
		InputBuffer.Push("LightAttack")
		local freshPeek = InputBuffer.Peek()
		assert(freshPeek == "LightAttack", "Expiration: Fresh Push was not buffered")
		task.wait(EXPIRY_TEST_WAIT)
		local expiredPeek = InputBuffer.Peek()
		assert(expiredPeek == nil, string.format("Expiration: Peek after 210ms returned %s, expected nil (stale input retained)", tostring(expiredPeek)))

		-- c) Hitstun Flush Test
		--    Drives the real bound machine, so this exercises the production handler in
		--    CombatController rather than a stand-in that could drift from it. The reset to
		--    Idle happens first and is given a settle, because the Idle handler consumes
		--    the buffer and would otherwise eat the action this test is about to queue.
		CombatStateBus.ForceResetToIdle()
		task.wait(FLUSH_SETTLE)

		InputBuffer.Push("LightAttack")
		local preStunPeek = InputBuffer.Peek()
		assert(preStunPeek == "LightAttack", "Hitstun Flush: Pre-stun Push was not buffered")

		local machine = CombatStateBus.GetActiveMachine()
		assert(machine ~= nil, "Hitstun Flush: no state machine bound (is the character alive?)")

		local transitionSuccess = CombatStateBus.RequestState("Stunned")
		assert(transitionSuccess == true, "Hitstun Flush: transition to Stunned was rejected")

		-- The controller clears the buffer from a task.spawn'd listener, so give that hop a
		-- frame to land before asserting the flush.
		task.wait(FLUSH_SETTLE)

		local postStunPeek = InputBuffer.Peek()
		assert(postStunPeek == nil, string.format("Hitstun Flush: Peek after Stunned returned %s, expected nil (buffer not flushed)", tostring(postStunPeek)))

		-- Leave the harness in a clean, actionable state for the next run.
		CombatStateBus.ForceResetToIdle()
		InputBuffer.Clear()
		task.wait(FLUSH_SETTLE)

		print("[INPUT CHAOS] All 3 buffer invariants passed without dropped or leaked inputs.")
	end)

	-- Hand input back to the player however the run ended, so a failed assertion
	-- cannot leave the game deaf for the rest of the session.
	InputGate.Set(false)
	chaosSuiteRunning = false

	if not ok then
		error("[INPUT CHAOS] FAILED: " .. tostring(err))
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end

	local keyCode = input.KeyCode

	if keyCode == Enum.KeyCode.Zero then
		CombatStateBus.ForceResetToIdle()
		return
	end

	if keyCode == Enum.KeyCode.R then
		runChaosTest()
		return
	end

	if keyCode == Enum.KeyCode.T then
		task.spawn(runInputChaosSuite)
		return
	end

	local sequence = KEY_SEQUENCES[keyCode]
	if not sequence then
		return
	end

	for _, targetState in ipairs(sequence) do
		CombatStateBus.RequestState(targetState)
	end
end)
