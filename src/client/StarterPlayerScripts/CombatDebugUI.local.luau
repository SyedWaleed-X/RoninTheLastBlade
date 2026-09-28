--!strict

--[[
	CombatDebugUI
	Ronin — The Last Blade · combat debug HUD + keyboard harness

	Builds a minimalist dark status card in the top-left corner that mirrors the client
	state machine owned by CombatController (reached through CombatStateBus):
	  * current state badge, colour coded per COMBAT_SPEC state
	  * previous state
	  * milliseconds spent in the current state (updated every RenderStepped)
	  * feed of the last four transitions

	Keys (game-processed input is ignored, so typing in chat never fires the harness):
	  [1] Windup then Active     [2] Blocking     [3] Parrying     [4] Stunned
	  [0] force reset to Idle
	  [R] chaos burst: 100 random transition requests inside a single frame
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CombatTypes = require(ReplicatedStorage.CombatTypes)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

type CombatState = CombatTypes.CombatState

local HUD_NAME = "CombatDebugHUD"
local CHAOS_REQUESTS = 100
local HISTORY_DEPTH = 4
local CARD_WIDTH = 248

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
local PADDING = 12

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

local card = Instance.new("Frame")
card.Name = "StatusCard"
card.BackgroundColor3 = CARD_BACKGROUND
card.BackgroundTransparency = 0.05
card.BorderSizePixel = 0
card.Position = UDim2.fromOffset(16, 16)
card.Size = UDim2.fromOffset(CARD_WIDTH, 214)
card.Parent = screenGui

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 10)
cardCorner.Parent = card

local cardStroke = Instance.new("UIStroke")
cardStroke.Color = Color3.fromRGB(255, 255, 255)
cardStroke.Transparency = 0.86
cardStroke.Thickness = 1
cardStroke.Parent = card

createLabel(card, "Title", "RONIN · COMBAT FSM", 11, Enum.Font.GothamBold, TEXT_DIM, UDim2.fromOffset(PADDING, 7), UDim2.new(1, -PADDING * 2, 0, 14))

local stateBadge = Instance.new("TextLabel")
stateBadge.Name = "StateBadge"
stateBadge.BackgroundColor3 = NEUTRAL_COLOR
stateBadge.BorderSizePixel = 0
stateBadge.Position = UDim2.fromOffset(PADDING, 27)
stateBadge.Size = UDim2.new(1, -PADDING * 2, 0, 34)
stateBadge.Font = Enum.Font.GothamBold
stateBadge.Text = "—"
stateBadge.TextColor3 = TEXT_BRIGHT
stateBadge.TextSize = 17
stateBadge.Parent = card

local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(0, 6)
badgeCorner.Parent = stateBadge

local previousStateLabel = createLabel(card, "PreviousState", "PREV  —", 12, Enum.Font.Code, TEXT_DIM, UDim2.fromOffset(PADDING, 69), UDim2.new(1, -PADDING * 2, 0, 14))
local durationLabel = createLabel(card, "StateDuration", "TIME  — ms", 12, Enum.Font.Code, TEXT_DIM, UDim2.fromOffset(PADDING, 85), UDim2.new(1, -PADDING * 2, 0, 14))

local divider = Instance.new("Frame")
divider.Name = "Divider"
divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
divider.BackgroundTransparency = 0.88
divider.BorderSizePixel = 0
divider.Position = UDim2.fromOffset(PADDING, 107)
divider.Size = UDim2.new(1, -PADDING * 2, 0, 1)
divider.Parent = card

createLabel(card, "HistoryCaption", "HISTORY", 10, Enum.Font.GothamBold, TEXT_DIM, UDim2.fromOffset(PADDING, 114), UDim2.new(1, -PADDING * 2, 0, 12))

local historyRows: { TextLabel } = {}
for index = 1, HISTORY_DEPTH do
	historyRows[index] = createLabel(
		card,
		"History" .. index,
		"",
		12,
		Enum.Font.Code,
		TEXT_DIM,
		UDim2.fromOffset(PADDING, 128 + (index - 1) * 16),
		UDim2.new(1, -PADDING * 2, 0, 14)
	)
end

createLabel(card, "KeyHint", "[1][2][3][4] states  [0] reset  [R] chaos", 10, Enum.Font.Code, TEXT_DIM, UDim2.fromOffset(PADDING, 196), UDim2.new(1, -PADDING * 2, 0, 12))

screenGui.Parent = playerGui

-- Rendering ---------------------------------------------------------------------
local paintedState: CombatState? = nil

local function paintState(state: CombatState?)
	paintedState = state

	if not state then
		stateBadge.Text = "—"
		stateBadge.BackgroundColor3 = NEUTRAL_COLOR
		return
	end

	stateBadge.Text = state
	stateBadge.BackgroundColor3 = STATE_COLORS[state]
end

local function paintPreviousState(state: CombatState?)
	if state then
		previousStateLabel.Text = "PREV  " .. state
	else
		previousStateLabel.Text = "PREV  —"
	end
end

local historyEntries: { string } = table.create(HISTORY_DEPTH, "")

local function pushHistory(fromState: CombatState, toState: CombatState)
	-- Shift the ring down one slot (no allocation) so the newest entry stays on top.
	for index = HISTORY_DEPTH, 2, -1 do
		historyEntries[index] = historyEntries[index - 1]
	end
	historyEntries[1] = string.format("%s -> %s", fromState, toState)

	for index = 1, HISTORY_DEPTH do
		historyRows[index].Text = historyEntries[index]
	end
end

CombatStateBus.Subscribe(function(fromState: CombatState, toState: CombatState)
	paintState(toState)
	paintPreviousState(fromState)
	pushHistory(fromState, toState)
end)

RunService.RenderStepped:Connect(function()
	local machine = CombatStateBus.GetActiveMachine()

	if not machine then
		if paintedState ~= nil then
			paintState(nil)
			paintPreviousState(nil)
		end
		durationLabel.Text = "TIME  — ms"
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
end)

-- Keyboard harness ---------------------------------------------------------------
local KEY_SEQUENCES: { [Enum.KeyCode]: { CombatState } } = {
	[Enum.KeyCode.One] = { "Windup", "Active" },
	[Enum.KeyCode.Two] = { "Blocking" },
	[Enum.KeyCode.Three] = { "Parrying" },
	[Enum.KeyCode.Four] = { "Stunned" },
}

-- Derived from the shared type mirror, so the chaos burst can never request a state
-- that CombatTypes does not define.
local stateNames: { CombatState } = {}
for _, state in CombatTypes.CombatStates do
	table.insert(stateNames, state)
end

local function runChaosTest()
	local machine = CombatStateBus.GetActiveMachine()
	if not machine then
		warn("[CHAOS TEST] no active state machine; spawn a character first.")
		return
	end

	local accepted = 0
	local rejected = 0
	local failure: string? = nil

	-- Every request is issued in the same frame, with no yield between them: this is the
	-- burst the state machine has to survive.
	local completed, chaosError = pcall(function()
		for _ = 1, CHAOS_REQUESTS do
			local targetState = stateNames[math.random(1, #stateNames)]
			if machine:SetState(targetState) then
				accepted += 1
			else
				rejected += 1
			end
		end
	end)

	if not completed then
		failure = tostring(chaosError)
	end

	local finalState = machine.CurrentState
	local previousState = machine.PreviousState

	-- "Not locked up": the machine must still evaluate its transition rules.
	local probeOk, canStillTransition = pcall(function()
		return machine:CanTransitionTo("Idle")
	end)

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

	local sequence = KEY_SEQUENCES[keyCode]
	if not sequence then
		return
	end

	for _, targetState in ipairs(sequence) do
		CombatStateBus.RequestState(targetState)
	end
end)
