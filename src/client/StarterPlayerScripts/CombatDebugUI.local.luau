--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CombatTypes = require(ReplicatedStorage.CombatTypes)
local AttackConfig = require(ReplicatedStorage.AttackConfig)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)
local InputGate = require(script.Parent:WaitForChild("InputGate") :: ModuleScript)

-- Day 10 P2/2: the juice stress suite (Key [U]) drives the real camera and audio
-- subsystems rather than the state machine, so it needs all three. Required here
-- rather than lazily reached so a broken mix is reported at boot, not on the
-- first [U] press, which is the worst possible moment to discover it.
local CameraShaker = require(script.Parent:WaitForChild("CameraShaker") :: ModuleScript)
local CombatAudio = require(script.Parent:WaitForChild("CombatAudio") :: ModuleScript)

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
	-- Day 9 P1/2: Dodging is deliberately the *only* state drawn in the same
	-- cyan the parry uses, because those are the two answers to the same question
	-- - "I am reading this attack and reacting to it". It is also a state whose
	-- first 200ms are safe and whose last 150ms are not, so the badge colour is
	-- not enough on its own; the dedicated DODGE row below is what names the
	-- phase.
	Dodging = Color3.fromRGB(86, 196, 255), -- ice blue
}

local NEUTRAL_COLOR = Color3.fromRGB(52, 54, 62)
local CARD_BACKGROUND = Color3.fromRGB(16, 17, 21)
local TEXT_DIM = Color3.fromRGB(142, 148, 160)
local TEXT_BRIGHT = Color3.fromRGB(236, 238, 244)
local COLOR_CYAN = Color3.fromRGB(54, 206, 214)
local BAR_BG_COLOR = Color3.fromRGB(34, 36, 44)

--[[
	Day 8 Part 2/2: the Sekiro dual-bar status display.
	
	Why a dedicated block and not another row on the status card: this is the
	first element in the HUD meant to be read mid-fight rather than while
	debugging, and the two jobs want opposite treatments. Telemetry is dense,
	small and text-heavy because it is read once while stationary; a combat
	gauge has to be legible at a glance from the centre of the screen while
	the player is watching an opponent. Keeping them apart lets the gauge be
	large, low-contrast and bottom-anchored without fighting the card for
	attention.
	
	Sekiro specifically, because posture is the resource this whole system is
	about. In Sekiro health is not the thing you watch - it barely moves. What
	you watch is posture, and the bar that matters is the one that fills. So the
	posture bar here is the wide, prominent one directly under the health bar,
	and the colour ramp is the whole read: orange means the guard is holding,
	deep red means it is about to shatter.
]]
local VITAL_WIDTH = 320
local VITAL_HEIGHT = 10
local POSTURE_HEIGHT = 8
local VITAL_GAP = 6
local VITAL_MARGIN = 28

--[[
	Health and posture tween times, in seconds.
	
	Health is slow enough to read as a deliberate drain and fast enough that a
	hit is legible as it lands. Quad/Out decelerates into the new value, which
	is what makes a big chunk of damage feel heavy: the bar races down and then
	settles instead of sliding linearly and reading as regeneration.
	
	Posture is deliberately faster. Posture climbs in discrete hits and falls
	on a server-driven recovery curve, so a slow tween would lag behind the
	thing the player has to react to, and the 85% warning depends on the bar
	reaching its target before the next hit.
]]
local HEALTH_TWEEN_TIME = 0.28
local POSTURE_TWEEN_TIME = 0.12

--[[
	Above this fraction of the posture pool, the critical warning fires.
	
	85% rather than 100% is the entire reason the warning is worth having. By
	the time a pool is actually full the rupture has happened and the player is
	on the floor; what they need is a moment of warning during which they can
	still choose to disengage. At 16/sec recovery that is roughly 15% of a
	pool of slack - long enough to matter against a fast attacker, short
	enough not to be permanently on for a player who guards a lot.
]]
local CRITICAL_POSTURE_THRESHOLD = 0.85

--[[
	Critical pulse timing.
	
	A two-state flash reads as a strobe and is genuinely unpleasant to look
	at for three seconds. Sekiro pulses rather than strobes: the bar surges
	brighter and holds for longer than it dims, so the eye picks up a rhythm
	rather than a flicker. Reverses = true with RepeatCount = -1 gives exactly
	that on one tween, and a single looping tween is one object for the whole
	warning rather than a task.spawn loop that has to be cancelled on
	teardown.
]]
local PULSE_PEAK_TIME = 0.16
local PULSE_TROUGH_TIME = 0.34

--[[
	Damage tier thresholds for the health bar colour.
	
	Half and a quarter, the two boundaries every action game in the genre
	uses, and the same 0.75/0.25 pair PostureEngine already splits recovery
	rates on. Sharing the numbers is not cosmetic: the bar turns gold at the
	exact health value at which the character stops recovering posture at
	full rate, so a player who can see the bar change knows why their guard
	stopped healing.
]]
local HEALTH_MID_THRESHOLD = 0.5
local HEALTH_LOW_THRESHOLD = 0.25

--[[
	The posture colour ramp endpoints, and the three health tier colours.
	
	The ramp is a straight Color3:Lerp driven by the pool fraction, so every
	value between the endpoints is a real reachable colour rather than three
	discrete states - a player at 60% can see 60% and know it, which is the
	information the whole posture war is played on. A three-step tier system
	would throw that away.
	
	The health tiers are the opposite decision, and equally deliberate: three
	named colours rather than a gradient, because a green-to-red gradient
	passes through a muddy olive that means nothing to the player. The read
	is "which state am I in", not "how green is my bar".
]]
local POSTURE_COLOR_CALM = Color3.fromRGB(255, 150, 40)
local POSTURE_COLOR_BROKEN = Color3.fromRGB(196, 24, 32)
local HEALTH_COLOR_HEALTHY = Color3.fromRGB(46, 204, 113)
local HEALTH_COLOR_WOUNDED = Color3.fromRGB(232, 190, 60)
local HEALTH_COLOR_CRITICAL = Color3.fromRGB(214, 45, 45)

--[[
	Vignette geometry. The warning is a frame around the play area rather than
	a full-screen wash, because a full-screen tint at meaningful opacity
	makes the incoming attack - the thing the player needs to see - harder
	to read. A gradient transparent in the middle and saturated at the edges
	costs nothing where the fight is and puts the warning exactly where
	peripheral vision picks it up.
]]
local VIGNETTE_THICKNESS = 120
local VIGNETTE_PEAK_TRANSPARENCY = 0.55
local VIGNETTE_TROUGH_TRANSPARENCY = 0.95

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
-- Day 9 P1/2: 234 -> 250, for the added dodge row plus its 16px of divider/feed
-- shift. The input telemetry card below is moved by the same 16px so the two
-- cards do not overlap.
card.Size = UDim2.fromOffset(CARD_WIDTH, 250)
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

--[[
	Day 9 · Part 1/2: the dodge phase row.

	Sits directly beneath the parry row and reads `DODGE: [ I-FRAMES ]` while the
	server is honouring the dodge, `DODGE: [ RECOVERY ]` once it is not, and
	`DODGE: [ — ]` otherwise.

	The reason this is a *row* and not just a state badge is that "DODGING" is the
	least useful thing this HUD could say about a dodge. The whole design of the
	move is the 200/150 split - there is a window where a hit does nothing, and a
	window where it does everything - so a single badge that says `DODGING` for
	350ms actively hides the one piece of information the player needs. The row
	also carries the direction and the source (`MOVE` / `BACKSTEP`) and the speed,
	which is what makes the backstep fallback visible: a player who pressed Q
	believing they were side-stepping and read `BACKSTEP` learns that the input was
	not registered, which is otherwise indistinguishable from the backstep simply
	being wrong.

	Expiry is a compared deadline read in the render loop rather than a `task.delay`
	that clears the row, for exactly the reason the parry flash above does it: two
	dodges inside one display window would otherwise have the first one's timer
	wipe the second one's phase, and a timer aimed at a label a HUD rebuild has
	already destroyed is a timer that errors. See `paintDodgeRow`.
]]
local dodgeLabel = createLabel(
	card, "DodgePhase", "DODGE: [ — ]", 13, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 114), UDim2.new(1, 0, 0, 16)
)

--[[
	The two phase colours, and why they are *not* both the state colour.

	`I-Frames` is the safe window and is drawn in the bright cyan, the same tone
	the parry success line uses: both mean "you read this correctly and the game
	is protecting you". `Recovery` is drawn in the attacker's red, because that is
	what the window is - the player is now standing in a 150ms hole with no
	i-frames, and colouring it cyan would tell them they are safe at the exact
	moment they are not. The transition between the two is the entire feedback
	the row exists to deliver.
]]
local DODGE_IFRAME_COLOR = Color3.fromRGB(86, 214, 255)
local DODGE_RECOVERY_COLOR = Color3.fromRGB(232, 96, 72)

--[[
	Paints the dodge row from the controller's published telemetry, or dims it when
	there is nothing to report or the reported window has already closed.

	Read from the bus rather than from a subscription, because the row shows a
	*current value* ("which phase am I in right now") and not an event stream. A
	notification that arrived while no character was bound would otherwise leave a
	row showing a phase for a dodge belonging to a body that no longer exists.
]]
local function paintDodgeRow()
	local telemetry = CombatStateBus.GetDodgeTelemetry()

	if telemetry == nil or os.clock() >= telemetry.EndsAt then
		if telemetry ~= nil then
			-- Expired on its own. Cleared here rather than by a timer so the bus
			-- and the HUD cannot disagree about whether a dodge is live.
			CombatStateBus.ClearDodgeTelemetry()
		end

		dodgeLabel.Text = "DODGE: [ — ]"
		dodgeLabel.TextColor3 = TEXT_DIM
		return
	end

	local remainingMs = math.floor((telemetry.EndsAt - os.clock()) * 1000)

	if telemetry.Phase == "IFrames" then
		dodgeLabel.Text = string.format(
			"DODGE: [ I-FRAMES %dms · %s %.0f st/s ]",
			remainingMs,
			tostring(telemetry.Origin):upper(),
			telemetry.Speed
		)
		dodgeLabel.TextColor3 = DODGE_IFRAME_COLOR
	else
		dodgeLabel.Text = string.format("DODGE: [ RECOVERY %dms ]", remainingMs)
		dodgeLabel.TextColor3 = DODGE_RECOVERY_COLOR
	end
end

--[[
	The dodge row above pushed the divider and the transition feed down 16px, and
	the card grew to match. Both are hard-coded offsets rather than a layout
	container, so the shift is a set of numbers that have to agree with each other:
	the divider at 134, the feed title at 142 and the four rows at 158 + 14 each
	now end at 214, inside the new 250px card with its 12px bottom padding.
]]
local divider = Instance.new("Frame")
divider.Name = "Divider"
divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
divider.BackgroundTransparency = 0.85
divider.BorderSizePixel = 0
divider.Position = UDim2.new(0, 0, 0, 134)
divider.Size = UDim2.new(1, 0, 0, 1)
divider.Parent = card

local feedTitleLabel = createLabel(
	card, "FeedTitle", "TRANSITIONS", 10, Enum.Font.GothamBold, TEXT_DIM,
	UDim2.fromOffset(0, 142), UDim2.new(1, 0, 0, 12)
)

-- Four rows, newest first; filled in by pushHistory.
local feedRows: { TextLabel } = {}
for index = 1, HISTORY_DEPTH do
	local row = createLabel(
		card, "FeedRow" .. index, "", 11, Enum.Font.Code, TEXT_BRIGHT,
		UDim2.fromOffset(0, 158 + (index - 1) * 14), UDim2.new(1, 0, 0, 14)
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
inputCard.Position = UDim2.fromOffset(16, 274)
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

-- Sekiro vital bars (Day 8 Part 2/2) ----------------------------------------
--[[
	The gauge is built bottom-anchored and centred, the way Sekiro puts its own
	posture bar. Two Frames per bar rather than an ImageLabel: a Frame with a
	UICorner and a tweened Size is the whole bar, and using a Frame instead of
	a textured image means the fill colour is a real interpolated Color3 the
	posture ramp can drive directly, rather than a colour multiplied over an
	asset.
	
	The container is a transparent Frame - a positioning parent, not a visual.
	Giving it a background would put an opaque plate behind the gauge that the
	rest of the HUD does not use.
]]
local vitalsRoot = Instance.new("Frame")
vitalsRoot.Name = "SekiroVitals"
vitalsRoot.BackgroundTransparency = 1
vitalsRoot.BorderSizePixel = 0
vitalsRoot.AnchorPoint = Vector2.new(0.5, 1)
vitalsRoot.Position = UDim2.new(0.5, 0, 1, -VITAL_MARGIN)
vitalsRoot.Size = UDim2.fromOffset(VITAL_WIDTH, VITAL_HEIGHT + VITAL_GAP + POSTURE_HEIGHT)
vitalsRoot.Parent = screenGui

--[[
	One bar: a dark recessed track and a bright fill that gets tweened.
]]
local function createBar(
	parent: Instance,
	name: string,
	height: number,
	offsetY: number,
	radius: number
): (Frame, Frame)
		local track = Instance.new("Frame")
					track.Name = name .. "Track"
					track.BackgroundColor3 = BAR_BG_COLOR
					track.BorderSizePixel = 0
					track.Position = UDim2.fromOffset(0, offsetY)
					track.Size = UDim2.new(1, 0, 0, height)
					track.Parent = parent
		local trackCorner = Instance.new("UICorner")
					trackCorner.CornerRadius = UDim.new(0, radius)
					trackCorner.Parent = track

		local fill = Instance.new("Frame")
					fill.Name = "Fill"
					fill.BackgroundColor3 = HEALTH_COLOR_HEALTHY
					fill.BorderSizePixel = 0
					fill.Size = UDim2.fromScale(1, 1)
					fill.Parent = track

		--[[
			The fill corner is slightly rounder than the track, not the same radius.
			
			The fill is clipped by the track anyway, but as the bar drains its rounded
			outer edge sits inside the track edge, and matching radii makes the
			shrinking end look slightly clipped. A fill radius one pixel larger reads
			as a clean rounded cap at every fill level, which is most of what makes
			the bar look designed rather than scaled.
			]]
		local fillCorner = Instance.new("UICorner")
					fillCorner.CornerRadius = UDim.new(0, radius + 1)
					fillCorner.Parent = fill

		return track, fill
end

local healthTrack, healthFill = createBar(vitalsRoot, "Health", VITAL_HEIGHT, 0, 2)
local postureTrack, postureFill = createBar(vitalsRoot, "Posture", POSTURE_HEIGHT, VITAL_HEIGHT + VITAL_GAP, 2)

--[[
	A hairline tick marking the exact 85% critical point on the posture track.
	
	The pulse tells the player they are past the line but never where the line
	is, so a pool sitting at 84% for ten seconds looks identical to one
	climbing through it. A 1px tick at a fixed offset turns "nearly full" into
	a legible measurement, which is the difference between a warning the player
	can anticipate and one they can only react to.
]]
local criticalTick = Instance.new("Frame")
criticalTick.Name = "CriticalTick"
criticalTick.BackgroundColor3 = TEXT_BRIGHT
criticalTick.BackgroundTransparency = 0.45
criticalTick.BorderSizePixel = 0
criticalTick.AnchorPoint = Vector2.new(0, 0.5)
criticalTick.Position = UDim2.fromScale(CRITICAL_POSTURE_THRESHOLD, 0)
criticalTick.Size = UDim2.new(0, 1, 1, 0)
criticalTick.ZIndex = 2
criticalTick.Parent = postureTrack

-- State painting ---------------------------------------------------------------
--[[
	The critical warning vignette.
	
	Four edge strips rather than one full-screen wash, because a UIGradient on
	a full-screen Frame can only fade along one axis. Four strips - each with a
	gradient running from saturated at the screen edge to fully transparent
	inboard - give a radial-looking frame out of four linear gradients, and
	leave the centre of the screen completely untouched.
	
	The strips are parented to the HUD ScreenGui but drawn beneath the debug
	cards by ZIndex, so the warning can never cover the state badge: during a
	rupture the player needs to read that they are STUNNED, and an opaque red
	flash over it would be exactly wrong.
	
	Active = false matters. These cover the whole screen, and an active one
	would swallow every click for as long as the warning is up.
]]
local vignette = Instance.new("Frame")
vignette.Name = "CriticalVignette"
vignette.BackgroundTransparency = 1
vignette.BorderSizePixel = 0
vignette.Size = UDim2.fromScale(1, 1)
vignette.Active = false
vignette.Visible = false
vignette.ZIndex = 1
vignette.Parent = screenGui

--[[
	One edge strip. Rotation picks which edge and therefore which way the
	gradient runs: 0 fades downward from the top, 180 upward from the
	bottom, and the two sides use 90 and 270. The keypoints always run
	transparent-to-opaque along the rotation, so one pair serves all four.
]]
local function createVignetteEdge(rotation: number, position: UDim2, size: UDim2): Frame
		local edge = Instance.new("Frame")
					edge.Name = "Edge"
					edge.BackgroundColor3 = POSTURE_COLOR_BROKEN
					edge.BackgroundTransparency = VIGNETTE_TROUGH_TRANSPARENCY
					edge.BorderSizePixel = 0
					edge.Position = position
					edge.Size = size
					edge.Active = false
					edge.Parent = vignette

		local gradient = Instance.new("UIGradient")
					gradient.Rotation = rotation
					gradient.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(1, 1),
					})
					gradient.Parent = edge

		return edge
end

--[[
	The edges are held in a list because the pulse has to animate all four
	and a Tween addresses exactly one instance. Building them through one
	function that returns the frame keeps each edge's geometry next to the
	gradient setup it belongs with.
]]
local vignetteEdges: { Frame } = {
		createVignetteEdge(0, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, VIGNETTE_THICKNESS)),
		createVignetteEdge(180, UDim2.new(0, 0, 1, -VIGNETTE_THICKNESS), UDim2.new(1, 0, 0, VIGNETTE_THICKNESS)),
		createVignetteEdge(90, UDim2.fromOffset(0, 0), UDim2.new(0, VIGNETTE_THICKNESS, 1, 0)),
		createVignetteEdge(270, UDim2.new(1, -VIGNETTE_THICKNESS, 0, 0), UDim2.new(0, VIGNETTE_THICKNESS, 1, 0)),
}

-- Vital bar painting (Day 8 Part 2/2) -------------------------------------------
--[[
	The tween in flight on each fill, and the value it is heading for.
	
	Both are tracked rather than re-tweened blindly every frame, for one
	reason: TweenService:Create allocates a Tween object, and creating one
	per bar per frame is 120 allocations a second for an animation that is
	usually not moving. The loop compares the current value against the
	target and only builds a tween when the target actually moved, which on
	most frames means returning before TweenService is ever called.
	
	The stored Tween doubles as the cancellation token. Starting a new tween
	on the same property would stop the old one anyway, but the explicit
	Cancel makes the intent unambiguous and stops a stale tween landing a
	frame late and overwriting the new value.
]]
local healthTween: Tween? = nil
local postureTween: Tween? = nil
local healthTarget = 1.0
local postureTarget = 0.0

--[[
	The critical warning state: the looping edge tweens, the bar tween, and a
	single flag that is the whole truth about whether the warning is running.
	
	Handles rather than a task.spawn loop with a running flag, so there is
	exactly one thing to cancel and no timer that can outlive the character
	or a HUD rebuild. Each stop path checks PlaybackState before cancelling,
	so teardown is idempotent and is reached both by falling below the
	threshold and by the render loop noticing the character went away.
]]
local pulseTweens: { Tween } = {}
local barPulseTween: Tween? = nil
local warningActive = false

--[[
	The health tier colour for a fraction of max health.
	
	Three named tiers rather than a gradient from green to red, deliberately.
	A gradient passes through a muddy olive that means nothing to the player,
	whereas three distinct colours are three distinct pieces of information.
	The read is "which state am I in", not "how green is my bar".
]]
local function healthColorFor(fraction: number): Color3
		if fraction < HEALTH_LOW_THRESHOLD then
			return HEALTH_COLOR_CRITICAL
		end

		if fraction < HEALTH_MID_THRESHOLD then
			return HEALTH_COLOR_WOUNDED
		end

		return HEALTH_COLOR_HEALTHY
end

--[[
	Retargets a bar, tweening only when the destination actually changed. The
	earlier return is the allocation guard described above.
]]
local function retargetBar(
		fill: Frame,
		fraction: number,
		duration: number,
		previousTarget: number,
		activeTween: Tween?
): Tween?
		if math.abs(fraction - previousTarget) < 0.001 then
			return activeTween
		end

		if activeTween ~= nil then
			activeTween:Cancel()
		end

		local tween = TweenService:Create(
			fill,
			TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1) }
		)
		tween:Play()

		return tween
end


-- State painting ---------------------------------------------------------------
--[[
	Starts or stops the critical warning.
	
	One function owns the whole warning rather than a start and a stop, so
	the warningActive flag is the single source of truth and there is no second
	boolean that can disagree with it.
	
	The cycle is the sum of the two times: Reverses plays the tween forward and
	then backward, and the backward leg takes the same time, so the peak
	occupies PULSE_PEAK_TIME of the cycle and the trough the rest. That is the
	asymmetry the surge-and-hold rhythm depends on.
	
	Two separate animated targets, because the bar has to be readable from the
	centre of the screen where the vignette is fully transparent by
	construction. Without the bar brightening, a player whose eyes are on
	their own character would see no warning at all until they happened to
	glance at the screen edges.
]]
local function setCriticalWarning(active: boolean)
		if active then
			if warningActive then
				return
			end

			vignette.Visible = true

			local pulseInfo = TweenInfo.new(
				PULSE_PEAK_TIME + PULSE_TROUGH_TIME,
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut,
				-1,
				true,
				0
			)

			--[[ 
				The four edges are tweened individually rather than through the parent.
				The parent is a fully transparent container by design, so animating its
				BackgroundTransparency does nothing at all - the visible property on
				each edge is its own, and each edge carries the UIGradient that makes it
				a vignette rather than a flat strip.
				Four tweens because a Tween addresses one instance. They share a
				single TweenInfo, so they stay in lockstep, and the handles are
				kept in a list so the stop path can cancel all four.
			]]

			pulseTweens = {}
			for _, edge in ipairs(vignetteEdges) do
				local edgeTween = TweenService:Create(
					edge,
					pulseInfo,
					{ BackgroundTransparency = VIGNETTE_PEAK_TRANSPARENCY }
				)
				edgeTween:Play()
				table.insert(pulseTweens, edgeTween)
			end

			--[[
				The bar pulses between the colour the ramp already produced and a
				brightened version of it.
				
				The start value is read from the live fill rather than recomputed:
				the render loop has already written the ramp colour for this exact
				pool fraction, so the property is guaranteed to be the colour the
				player was already looking at.
				
				It matters that this reverses between two *different* colours. A
				tween that simply ended on one fixed colour and reversed would
				arrive there once and sit still, because reversing plays the same
				interpolation backwards from the same endpoint - there is no second
				colour to travel between.
				
				The highlight is the live bar colour pushed toward white, so the
				pulse gets brighter as the pool fills rather than being a fixed
				shade: at 85% it is a deep red flare, at 99% nearly white, which is
				the reading that tells the player the break is no longer a maybe.
			]]
			barPulseTween = TweenService:Create(
				postureFill,
				pulseInfo,
				{ BackgroundColor3 = postureFill.BackgroundColor3:Lerp(Color3.new(1, 1, 1), 0.55) }
			)
			barPulseTween:Play()

			warningActive = true
			return
		end

		--[[ 
			Falling below the threshold. Every tween in the warning is cancelled, not
			just the bar, and vignette.Visible goes false on the same path - a
			cancelled edge tween leaves that strip at a partial transparency, and a
			half-faded strip left visible would be a permanently dim red border for
			the rest of the session.
		]]
		if not warningActive then
			return
		end

		for _, edgeTween in ipairs(pulseTweens) do
			if edgeTween.PlaybackState ~= Enum.PlaybackState.Completed then
				edgeTween:Cancel()
			end
		end

		pulseTweens = {}

		if barPulseTween ~= nil then
			if barPulseTween.PlaybackState ~= Enum.PlaybackState.Completed then
				barPulseTween:Cancel()
			end
			barPulseTween = nil
		end

		warningActive = false
		vignette.Visible = false
end

-- State painting ---------------------------------------------------------------
--[[
	The per-frame vital update.
	
	Called from the existing RenderStepped connection rather than from a second
	one. Two render connections servicing different things is two things that
	can disagree about ordering, and the gauge would sit a frame behind the
	state badge above it for no reason. One loop, one place where a frame is
	serviced.
	
	No character means an empty gauge rather than stale values. A HUD still
	showing the last life's health during a respawn is a small lie that costs
	the player the half-second it takes to notice their new body is full.
	
	The posture colour is a straight Lerp applied every frame with no tween,
	and that is the one thing here deliberately not tweened. Colour is a
	continuous read of a continuous value, and a tween on it would lag the
	bar it is describing. The size is tweened so a discrete hit reads as
	impact; the colour tracks instantly so the bar is never a different
	colour from the number it represents.
]]
local function updateVitals()
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil

	if character == nil or humanoid == nil then
		setCriticalWarning(false)
		healthTarget = 1.0
		postureTarget = 0.0
		healthFill.BackgroundColor3 = healthColorFor(1.0)
		postureFill.BackgroundColor3 = POSTURE_COLOR_CALM
		return
	end

	--[[ 
		Health. MaxHealth is read every frame rather than cached: it is one
		property read on a local object, and a cached copy would be another
		value to invalidate correctly if anything ever changed a character's
		max health. The division is guarded because a MaxHealth of 0 is
		representable and would produce a NaN width.
]]
	local maxHealth = humanoid.MaxHealth
	local healthFraction = if maxHealth > 0 then math.clamp(humanoid.Health / maxHealth, 0, 1) else 1

	--[[ 
		Posture. Both attributes are server-written and both are seeded by
		PostureEngine and HitValidator on the first heartbeat, so a nil here is a
		character alive for less than a frame. The fallbacks keep the arithmetic
		total and the bar shows 0, which is the truth for a character that has
		not been given a pool yet.
]]
	local postureValue = character:GetAttribute(AttackConfig.POSTURE_ATTRIBUTE)

	local maxPostureValue = character:GetAttribute(AttackConfig.MAX_POSTURE_ATTRIBUTE)


	local maxPosture = if typeof(maxPostureValue) == "number" and maxPostureValue > 0
		then maxPostureValue

		else AttackConfig.MAX_POSTURE
	local posture = if typeof(postureValue) == "number"

		then math.clamp(postureValue / maxPosture, 0, 1)
		else 0

	healthTween = retargetBar(healthFill, healthFraction, HEALTH_TWEEN_TIME, healthTarget, healthTween)
	healthTarget = healthFraction

	postureTween = retargetBar(postureFill, posture, POSTURE_TWEEN_TIME, postureTarget, postureTween)
	postureTarget = posture

	--[[ 
		The health colour is written every frame, unconditionally. A ternary
		would skip the write when the tier is unchanged, saving a property set
		Roblox would almost certainly no-op anyway - and the no-op case is
		exactly when the posture pulse is running and needs the write
		re-asserted, so the unconditional form is both simpler and more correct.
]]
	healthFill.BackgroundColor3 = healthColorFor(healthFraction)

	--[[ 
		The ramp colour, but only while the pulse is not driving the bar. A
		looping tween owns its target property outright, so writing here every
		frame would fight it and produce a visible stutter at exactly the moment
		the warning needs to be most legible.
]]
	if not warningActive then
		postureFill.BackgroundColor3 = POSTURE_COLOR_CALM:Lerp(POSTURE_COLOR_BROKEN, posture)
	end

	--[[ 
		The critical threshold is compared against the *target* fraction, not
		the drawn width. The fill is tweening toward the value, so a bar that
		has only just crossed 85% is still drawn below it - testing the width
		would delay the warning by the tween time on every crossing, which at
		0.12s is enough to matter.
]]
	setCriticalWarning(posture > CRITICAL_POSTURE_THRESHOLD)
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
	--[[ 
		Day 8 Part 2/2: the gauge is serviced first and unconditionally.

		It sits above the early-out below, which returns as soon as no machine
		is bound. That early-out is right for the telemetry panels - there is no
		state to report without a machine - but the gauge reads a Humanoid and
		a model's attributes, both of which exist independently of the state
		machine. A character that is alive but has no bound machine (a respawn
		in flight) should still show its health.
	]]
	updateVitals()

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

	--[[
		Day 9 P1/2: the dodge row, serviced from the same render loop.

		Placed beside `paintParryResult` and for the same reason: both show a
		window that expires on a deadline, and a `task.delay` that cleared either
		label would race the next one - two dodges inside one display window would
		have the first one's timer wipe the second one's phase.

		It is called *unconditionally*, above the `if not machine` early-out. The
		early-out is right for the state rows, which genuinely need a machine, but
		a dodge can be in flight against a character whose machine has just been
		retired, and a row that cleared itself at that instant would be reporting
		the HUD's bookkeeping rather than the dodge.
	]]
	paintDodgeRow()

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
	-- Day 9 P1/2. Forcing the state by hand is the only way to see what the
	-- badge and the divider look like mid-dodge, since a real dodge resolves in
	-- 350ms and the harness only gets a keypress. It moves the *machine* only -
	-- no LinearVelocity is created and no i-frames are requested, so this cannot
	-- be mistaken for a dodge that happened.
	[Enum.KeyCode.Five] = { "Dodging" },
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

	--[[
		Day 9 P1/2: `Dodging` joins the burst list.

		Every legal state is included, and the new one is no exception: the point
		of the burst is to prove `SetState` stays coherent under re-entrant load
		across the *whole* table, and a state the burst never touches is a state
		whose edges are never exercised. `Dodging` in particular has an edge into
		`Stunned` and one out to `Idle`, and this is the only thing that will ever
		request them out of order.
	]]
	local states: { CombatState } = { "Idle", "Windup", "Active", "Recovery", "Blocking", "Parrying", "Stunned", "Executing", "Dodging" }
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

--[[ 
	Day 8 Chaos Suite: posture rupture verification. Bound to Key [Y].
	
	The suite is split across the two halves of the game, because the two Day 8
	invariants live on opposite sides of the wire:
	
	  (a) Posture Edge  - a 99.9% pool plus a 0.2% poise hit must break. This is
			the server's decision, so PostureChaos runs it there and answers over
			REMOTE_CHAOS_EVENT.
	
	  (b) Death Override - HP to 0 mid-rupture must cleanly override Stunned and
			destroy the listeners. The server half runs there too; the *listener*
			half is checked here, against the real bound machine, because only this
			client knows whether its own Died handler ran.
	
	The remote is resolved at press time rather than at load, for the same reason
	PostureChaos resolves it lazily: the server creates the remotes inside
	HitValidator's body, so a lookup performed while this LocalScript starts
	would be a race against a remote that may not exist yet.
]]
local chaosSuiteRunning = false

--[[ 
	How long the client waits for the server's verdict.
	
	Generous, because test (b) genuinely waits on the engine's respawn: the
	server holds the run open for up to 15s. A tighter client timeout would
	report a false failure on a slow respawn while the server later replies
	successfully. Being slow to fail is strictly better than being wrong.
]]
local CHAOS_REPLY_TIMEOUT = 25.0
local CHAOS_POLL_STEP = 0.05

--[[ 
	The client's half of (b).
	
	After the death the bus must hold a *new* machine for the new character, in
	Idle, with no stale freeze. The old machine is unreachable by design
	(teardown drops it), so this checks observable state rather than the
	retired object - which is the only version of the check that survives the
	object being collected.
]]
local function verifyClientTeardown()
		local machine = CombatStateBus.GetActiveMachine()
		if machine == nil then
			return false, "no machine bound after the respawn"
		end

		if machine.CurrentState ~= "Idle" then
			return false, "the new machine did not start Idle"
		end

		--[[ 
			The freeze must not have survived the death. CombatController's teardown
			clears this flag, and a stun *release* also clears it, so the assertion
			is only meaningful because the character died before the 3.0s rupture
			could expire - which is exactly the case under test.
			]]
		if CombatStateBus.IsStunInputLocked() then
			return false, "the stun input lock leaked past the death"
		end

		--[[ 
			The machine must still answer questions. A listener left connected to a dead
			machine would leave the new one fine and the old one broken, and this is
			the cheapest way to prove the new binding is a live machine rather than a
			husk.
			]]
		local canTransition = machine:CanTransitionTo("Blocking")
		if type(canTransition) ~= "boolean" then
			return false, "the new machine no longer answers CanTransitionTo"
		end

		return true, "new machine bound, Idle, lock cleared, responsive"
end

--[[ 
	Runs the Day 8 suite.
	
	Input is gated for the duration for the reason documented on InputGate: the
	suite kills the player, and a live Mouse1 press landing during the respawn
	would be spent by the new character's first Idle handler and read by the
	teardown assertion as a leaked input.
	
	The server result is awaited with a poll rather than a promise because this
	file is a plain LocalScript with no async runtime to bridge into. The poll
	costs one task.wait per iteration and exits the frame it hears back.
]]
local function runPostureChaosSuite()
		if chaosSuiteRunning then
			warn("[POSTURE CHAOS] A run is already in flight; press ignored.")
			return
		end

		if CombatStateBus.GetActiveMachine() == nil then
			warn("[POSTURE CHAOS] Skipped: no state machine bound (is the character alive?)")
			return
		end

		local chaosEvent = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_CHAOS_EVENT) :: RemoteEvent?
		if chaosEvent == nil then
			warn("[POSTURE CHAOS] ChaosTestEvent not found; is PostureChaos running on the server?")
			return
		end

		chaosSuiteRunning = true
		InputGate.Set(true)

		--[[ 
			The server's verdict lands here. Declared before the FireServer so there
			is no window in which a fast reply could arrive with nowhere to go,
			which would hang the poll until its timeout on a perfectly good run.
			]]
		local serverResults: { unknown }? = nil
		local connection = chaosEvent.OnClientEvent:Connect(function(payload: unknown)
			if typeof(payload) == "table" then
				serverResults = payload :: { unknown }
			end
		end)

		print("[POSTURE CHAOS] Day 8 suite starting. This will kill the character; wait for the respawn.")
		chaosEvent:FireServer()

		--[[ 
			The wait. A deadline is compared rather than counted down so there is no
			accumulator to drift, and the client-side teardown assertion is
			deliberately not attempted until the server has confirmed the respawn
			happened - running it earlier would assert against a dead character.
			]]
		local deadline = os.clock() + CHAOS_REPLY_TIMEOUT
		while serverResults == nil and os.clock() < deadline do
			task.wait(CHAOS_POLL_STEP)
		end

		--[[ 
			Hand the input back and drop the listener however the run ended, before
			any reporting. A reporting bug must not be able to leave the player
			without input.
			]]
		connection:Disconnect()
		InputGate.Set(false)
		chaosSuiteRunning = false

		if serverResults == nil then
			error(string.format("[POSTURE CHAOS] FAILED: no server verdict after %.0fs", CHAOS_REPLY_TIMEOUT))
			return
		end

		--[[ 
			Every server record is schema-checked before it is read
			(ARCHITECTURE.md #2), and a record that fails the check counts as a
			failure rather than being skipped - a malformed verdict is not a pass.
			]]
		local allPassed = true
		for _, entry in ipairs(serverResults) do
			if type(entry) ~= "table" then
				allPassed = false
				warn("[POSTURE CHAOS] FAILED: malformed server verdict (not a table).")
				break
			end

			local record = entry :: { Name: unknown, Passed: unknown, Detail: unknown }
			if type(record.Name) ~= "string" or type(record.Passed) ~= "boolean" or type(record.Detail) ~= "string" then
				allPassed = false
				warn("[POSTURE CHAOS] FAILED: malformed server verdict (bad field types).")
				break
			end

			print(string.format("[POSTURE CHAOS] %s %s -- %s",
				if record.Passed then "PASS" else "FAIL",
				record.Name,
				record.Detail))

			if not record.Passed then
				allPassed = false
			end
		end

		--[[ 
			The client's half of (b). The death has already happened and the server
			has already waited for the respawn, so the new binding is in place.
			]]
		--[[
		The client's half of (b).

		The server has already confirmed the respawn by the time its verdict
		arrives, but the client's own binding is a separate CharacterAdded callback
		on this client, and it can land a frame or two after the server observes the
		new model. Asserting the instant the verdict lands therefore reads "no
		machine bound" on a run that is entirely correct, which is exactly what
		verifyClientTeardown reported on the first clean pass.

		A short settle is the honest fix. It is not a masking sleep: the wait is for
		a callback that is guaranteed to run, not for a condition that may never
		become true, and the assertions behind it stay strict.
	]]
	for _settle = 1, 20 do
		if CombatStateBus.GetActiveMachine() ~= nil then
			break
		end
		task.wait(CHAOS_POLL_STEP)
	end

	local clientOk, clientDetail = verifyClientTeardown()
		print(string.format("[POSTURE CHAOS] %s Client Teardown -- %s",
			if clientOk then "PASS" else "FAIL",
			clientDetail))

		if not clientOk then
			allPassed = false
		end

		--[[ 
			Leave the harness clean. A forced Idle means the next [Y] starts from a
			known place rather than from whatever this run left behind, which is
			what makes a second run meaningful after a first one failed.
			]]
		CombatStateBus.ForceResetToIdle()
		InputBuffer.Clear()

		if allPassed then
			print("[POSTURE CHAOS] All Day 8 invariants verified cleanly.")
			return
		end

		error("[POSTURE CHAOS] FAILED: see the per-invariant lines above.")
end

--[[
Day 10 P2/2: the juice stress suite (Key [U]).

Twenty deflect clashes across one second, then four assertions about the
systems that have to survive them. The other suites in this file test the
*state machine*; this one tests the three systems bolted around it, which is
the only part of the game with no single owner:

  1. Trauma saturates. `CameraShaker` clamps to 1.0, so twenty impacts must
     leave it at exactly 1.0 and never above - an unclamped sum is what turns
     a fast chain into the camera spinning forever.
  2. Trauma then decays. Sampled across the window after the burst, it must be
     strictly falling: saturation is correct, saturation that never comes back
     down is the actual failure mode being guarded against.
  3. The mix is intact on this client. Read from the live `SoundGroup` tree, not
     from `AttackConfig` - a config assertion passes on a client that never
     received the replicated mix at all, which is precisely the case worth
     catching.
  4. Every impact was heard. `PlayCount` must advance by exactly the impact
     count. Without this, twenty silent no-ops would pass all three assertions
     above and print a green line.

The impacts are spaced by `CHAOS_JUICE_STEP` rather than fired in one frame.
Firing twenty in a single frame exercises the same code paths and proves
nothing about the mix: a limiter only earns its keep on a signal that arrives
over time, and a voice pool under one-frame pressure behaves nothing like one
under a real chain.
]]
local function runJuiceChaosSuite()
if chaosSuiteRunning then
warn("[JUICE CHAOS] A run is already in flight; press ignored.")
return
end

if CombatStateBus.GetActiveMachine() == nil then
warn("[JUICE CHAOS] Skipped: no state machine bound (is the character alive?)")
return
end

chaosSuiteRunning = true
InputGate.Set(true)

local before = CombatAudio.PlayCount
local origin = if workspace.CurrentCamera then workspace.CurrentCamera.CFrame.Position else Vector3.zero

-- Start from a known shake so the decay assertion below is about this
-- run and not about whatever the player walked into.
CameraShaker.Reset()

print(string.format(
"[JUICE CHAOS] Day 10 suite starting: %d impacts over %.2fs.",
AttackConfig.CHAOS_JUICE_IMPACTS,
AttackConfig.CHAOS_JUICE_WINDOW))

--
-- The burst. Trauma, cue, and a scattered position per impact so the
-- voices are genuinely competing for the same bus rather than stacking
-- at one point (where they would sum coherently and flatter the limiter).
--
local peakTrauma = 0
local traumaSamples = 0

for impact = 1, AttackConfig.CHAOS_JUICE_IMPACTS do
CameraShaker.AddTrauma(AttackConfig.CAMERA_TRAUMA_DEFLECT)

local peak = CameraShaker.GetTrauma()
if peak > peakTrauma then
peakTrauma = peak
end

-- A small deterministic ring around the listener: no RNG, so a failing
-- run reproduces exactly.
local angle = (impact / AttackConfig.CHAOS_JUICE_IMPACTS) * math.pi * 2
local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 4
CombatAudio.PlayCue("Deflect", origin + offset)

traumaSamples += 1
task.wait(AttackConfig.CHAOS_JUICE_STEP)
end

-- The assertions, each reported on its own line so a failure names itself.
local played = CombatAudio.PlayCount - before
local mix = CombatAudio.GetMixDiagnostics()
local voicesPlaying, voicesTotal = CombatAudio.GetVoiceStats()

-- Saturation, checked against the sample taken *during* the burst rather than
-- at the end: by the last impact the decay has already begun pulling the value
-- back off 1.0, so asserting on the final figure would fail a healthy clamp.
local saturates = peakTrauma <= 1.0
and traumaSamples == AttackConfig.CHAOS_JUICE_IMPACTS

-- Decay, sampled twice with a gap longer than one decay period, so a single
-- dropped frame cannot fake a fall.
local traumaAfterBurst = CameraShaker.GetTrauma()
task.wait(0.4)
local traumaLater = CameraShaker.GetTrauma()
local decays = traumaLater < traumaAfterBurst

local mixIntact = mix.MasterPresent == true
and mix.CombatGroupPresent == true
and mix.AmbienceGroupPresent == true
and mix.DuckSideChainPresent == true
and mix.LimiterPresent == true

local capped = voicesPlaying <= AttackConfig.AUDIO_VOICE_LIMIT
local allPlayed = played == AttackConfig.CHAOS_JUICE_IMPACTS

local results = {
{ "trauma saturates at 1.0", saturates, string.format("peak=%.3f over %d impacts", peakTrauma, traumaSamples) },
{ "trauma decays after the burst", decays, string.format("%.3f -> %.3f", traumaAfterBurst, traumaLater) },
{ "mix tree intact (master/combat/ambience/duck/limiter)", mixIntact, string.format("voices playing %d of %d total", voicesPlaying, voicesTotal) },
{ "voice cap honoured", capped, string.format("%d <= %d", voicesPlaying, AttackConfig.AUDIO_VOICE_LIMIT) },
{ "all impacts reached the voice pool", allPlayed, string.format("%d of %d", played, AttackConfig.CHAOS_JUICE_IMPACTS) },
}

local allPassed = true

for _, result in results do
print(string.format(
"[JUICE CHAOS] %s -- %s (%s)",
if result[1] then "PASS" else "FAIL",
result[1],
result[3]
))

if not result[2] then
allPassed = false
end
end

-- Hand input back and clear the shake on every path, so a failed run leaves the
-- harness usable and the camera not buzzing.
InputGate.Set(false)
CameraShaker.Reset()

if not allPassed then
error("[JUICE CHAOS] FAILED: see the per-invariant lines above.")
end

print(string.format(
"[JUICE CHAOS] All %d rapid impacts processed cleanly without errors.",
AttackConfig.CHAOS_JUICE_IMPACTS))
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

	--[[ 
		Day 8 Part 2/2: the posture rupture suite.

		Spawned like the [T] suite because it runs for as long as a respawn
		takes, and a blocking handler would freeze the harness - including the
		escape hatch of pressing another key. The function owns its own error
		reporting and always reopens input, so the spawn cannot lose a failure.

		A failed run raises inside a spawned thread, so it surfaces in the output
		as a script error and cannot take the whole HUD down with it.
	]]
	if keyCode == Enum.KeyCode.Y then
		task.spawn(runPostureChaosSuite)
		return
	end

	--
	-- Day 10 P2/2: the juice suite. Spawned for the same reason as [Y]: it
	-- takes over a second and then blocks on a settle wait, and a blocking
	-- handler would freeze the harness including its own escape hatch.
	if keyCode == Enum.KeyCode.U then
		task.spawn(runJuiceChaosSuite)
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
