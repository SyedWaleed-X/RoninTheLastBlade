--!strict

--[[
	BossHUD
	Ronin - The Last Blade . the top-screen boss frame

	A boss bar for one boss, built from six numbers.

	Why it reads attributes instead of listening for them
	----------------------------------------------------
	The HUD needs four live values - Health, max Health, Posture, max Posture - plus
	Phase. All six are attributes on the boss Model, and attributes replicate. So the
	HUD reads them directly and receives *exactly one* message from the server: the
	engage event, whose whole job is to say what the ceilings are and when the fight
	is live. *Where* the HUD may be visible at all is asked on this side of the wire,
	by the arena-zone gate at the bottom of the file - a client that could see the
	boss bar from the spawn hill would be showing a fight to a player who is not in
	the arena.

	That is not a shortcut, it is the design. A per-frame remote would put the boss's
	health bar on the network whether or not anyone was looking at it, and would make
		the HUD a *prediction* of the boss's state that could disagree with the boss. The
	attribute is the boss's actual state, replicated by the engine, and the HUD is a
	pure function of it.

	Why the health bar interpolates and the posture bar does not
	-----------------------------------------------------------
	Because they are two different instruments. A health bar that snaps to 397/400 in
	one frame reads as a UI element; a bar that eases down over 300ms reads as an
	object losing a fight. Posture is the opposite: it is the fight's *rhythm* -
	deflect, deflect, deflect, break - and averaging three deflects in 400ms into one
	smooth movement turns that rhythm into mush.

	So: health eases through `TweenService`, posture is written directly. The asymmetry
	is the design, not an inconsistency. `TweenService` owns the interpolation, so the
	per-frame path allocates nothing - see ARCHITECTURE #4.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BossConfig = require(ReplicatedStorage:WaitForChild("BossConfig") :: ModuleScript)
local BossRegistry = require(ReplicatedStorage:WaitForChild("BossRegistry") :: ModuleScript)

local Attributes = BossConfig.Attributes

--[[
	The palette.

	Health is a *red* bar in a near-black trough, so it reads as blood loss rather than
	as a progress bar. Posture runs deep orange to crimson across its own range, which
	means the player can read how close the break is from the colour alone - before
		they can read the number. The phase pips are the only warm accent on the frame, so
	a phase change is the one thing that changes the frame's *shape*.
]]
local COLOR_HEALTH = Color3.fromRGB(186, 32, 32)
local COLOR_HEALTH_TROUGH = Color3.fromRGB(30, 11, 11)
local COLOR_POSTURE_LOW = Color3.fromRGB(226, 124, 24)
local COLOR_POSTURE_HIGH = Color3.fromRGB(196, 22, 44)
local COLOR_POSTURE_TROUGH = Color3.fromRGB(26, 15, 8)
local COLOR_NAME = Color3.fromRGB(240, 228, 208)
local COLOR_PIP_OFF = Color3.fromRGB(58, 42, 34)
local COLOR_PIP_ON = Color3.fromRGB(255, 196, 96)

local BAR_WIDTH = 560
local BAR_HEIGHT = 20
local POSTURE_HEIGHT = 12
local FADE_IN = 0.55
local FADE_OUT = 0.35
local HEALTH_TWEEN = 0.3
local PIP_COUNT = 2

--[[
	A tiny constructor.

	Every GuiObject here is a property bag, and there are a dozen of them. Writing the
	property lists out inline would be 200 lines of `instance.Name = ...`, and the
	shape of a bar would stop being readable next to the shape of a pip. `props` is
		typed `{ [string]: any }` deliberately: `Instance.new` returns `Instance`, and
	`Instance` has no indexer, so a stricter annotation would force a cast at every
	call site instead of once here.
]]
local function make(className: string, parent: Instance, props: { [string]: any }): any
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		(instance :: any)[key] = value
	end
	instance.Parent = parent
	return instance
end

local previous = playerGui:FindFirstChild("RoninBossHUD")
if previous ~= nil then
	previous:Destroy()
end
--[[
	Build the frame.

	One `ScreenGui` and one root `Frame`. The root was a `CanvasGroup` so the fade
	could be a single `GroupTransparency` tween on the parent; that property has been
	removed from the engine, so the fade is now a per-descendant tween walk (see
	`setVisible`) and the root is an ordinary transparent `Frame`.
	in-and-out read as one object arriving rather than six elements staggering in.

	`IgnoreGuiInset = true` because the top of an arena is *above* the core UI safe
	area: a boss nameplate has to sit high enough that it never collides with the
	player's own posture gauge, and the inset is exactly that collision waiting.
]]
local gui = make("ScreenGui", playerGui, {
	Name = "RoninBossHUD",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 120,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
local screenGui = gui :: ScreenGui

--[[
	Hard off at boot - and the reason is worth writing down, because the fade
	system below cannot express it.

	`setVisible` only ever returns the frame to the transparency it was authored
	at. A HUD that is built at its authored transparency is therefore *visible*
	from the first frame, and "hidden until the player is in the arena" is not a
	fade - it is a state. So the ScreenGui itself starts `Enabled = false`, and
	the only thing in this file that switches it on is the arena-zone gate at the
	bottom: at the SanctuaryHub spawn the boss frame does not exist as far as the
	player is concerned.
]]
screenGui.Enabled = false

local root = make("Frame", screenGui, {
	Name = "Root",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 18),
	Size = UDim2.fromOffset(BAR_WIDTH + 44, 96),
	BackgroundTransparency = 1,
})
local rootFrame = root :: Frame

--[[
	The nameplate. Centred, `TextScaled` so a longer boss name still fits the frame
	instead of spilling past the bars below it. The two ember rules either side are one
	Frame each with a `UIGradient`, which costs a single texture rather than eleven
	little parts.
]]
local nameLabel = make("TextLabel", rootFrame, {
	Name = "Name",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.fromOffset(BAR_WIDTH, 30),
	BackgroundTransparency = 1,
	Text = BossConfig.Name,
	TextColor3 = COLOR_NAME,
	TextStrokeColor3 = Color3.fromRGB(28, 10, 6),
	TextStrokeTransparency = 0.55,
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Center,
})
local nameText = nameLabel :: TextLabel

for _, side in ipairs({ -1, 1 }) do
	local rule = make("Frame", rootFrame, {
		Name = "Rule",
		AnchorPoint = Vector2.new(side < 0 and 1 or 0, 0.5),
		Position = UDim2.new(0.5, side * (BAR_WIDTH * 0.5 + 20), 0, 15),
		Size = UDim2.fromOffset(52, 2),
		BackgroundColor3 = COLOR_PIP_ON,
		BorderSizePixel = 0,
	})
	make("UIGradient", rule, {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, side < 0 and 0.9 or 0),
			NumberSequenceKeypoint.new(1, side < 0 and 0 or 0.9),
		}),
	})
end

--[[
	A bar is three parts: a trough, a fill whose width *is* the value, and a hairline
	inner stroke so the bar keeps an edge at full health instead of dissolving into its
	own colour. The fill is anchored left and sized by scale, so a bar at 1% is a
	sliver rather than a rounded nub.
]]
local function makeBar(name: string, y: number, height: number, trough: Color3): (Frame, Frame)
	local back = make("Frame", rootFrame, {
		Name = name .. "Trough",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, y),
		Size = UDim2.fromOffset(BAR_WIDTH, height),
		BackgroundColor3 = trough,
		BorderSizePixel = 0,
	})
	make("UICorner", back, { CornerRadius = UDim.new(0, height * 0.5) })

	local fill = make("Frame", back, {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
	})
	make("UICorner", fill, { CornerRadius = UDim.new(0, height * 0.5) })
	make("UIStroke", fill, {
		Color = Color3.fromRGB(255, 236, 210),
		Transparency = 0.75,
		Thickness = 1,
	})
	return back :: Frame, fill :: Frame
end

local _, healthFill = makeBar("Health", 34, BAR_HEIGHT, COLOR_HEALTH_TROUGH)
healthFill.BackgroundColor3 = COLOR_HEALTH

local _, postureFill = makeBar("Posture", 34 + BAR_HEIGHT + 6, POSTURE_HEIGHT, COLOR_POSTURE_TROUGH)
postureFill.BackgroundColor3 = COLOR_POSTURE_LOW

--[[
	The posture gradient. A `UIGradient` across the *fill*, so the colour follows the
	value rather than the width: 12/200 reads orange, 188/200 reads crimson, without
	either of them reading a number. Same trick `WeaponVisuals` uses on the blade
		rail, for the same reason - colour is the fast read, bar length is confirmation.
]]
make("UIGradient", postureFill, {
	Name = "PostureGradient",
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, COLOR_POSTURE_LOW),
		ColorSequenceKeypoint.new(1, COLOR_POSTURE_HIGH),
	}),
	Rotation = 0,
})

--[[
	Phase pips.

	Two of them, filled from `RoninBossPhase`. They are the only discrete element on
		the frame, deliberately: a phase change has to be legible in one glance in a way a
	moving number is not, and a pip going from one lit to two is the clearest possible
	signal that the fight just escalated.
]]
local pips: { Frame } = {}
for index = 1, PIP_COUNT do
	local pip = make("Frame", rootFrame, {
		Name = "PhasePip" .. index,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, (index - (PIP_COUNT + 1) / 2) * 26, 0, 78),
		Size = UDim2.fromOffset(18, 4),
		BackgroundColor3 = COLOR_PIP_OFF,
		BorderSizePixel = 0,
	})
	make("UICorner", pip, { CornerRadius = UDim.new(0, 2) })
	pips[index] = pip :: Frame
end
--[[
	State.

	`bossModel` is resolved on engage rather than at boot, because the arena builder
	clones the Commander at runtime and the HUD has no reason to know where a boss
	lives before it is told one exists. On a respawn the same model object is reused
	(the controller revives rather than re-clones), so the reference stays valid.

	`shownPhase` is the last phase whose pips were lit, compared before writing so the
	HUD is genuinely idle - no tween, no property write - whenever nothing changed,
	which during a boss fight is most of the time.
]]
local bossModel: Model? = nil
local maxHealth = BossConfig.MaxHealth
local maxPosture = BossConfig.MaxPosture
local healthTarget = 1
local shownPhase = 0
local visible = false
local fading = false
local healthTween: Tween? = nil

local function setPips(phase: number)
	if phase == shownPhase then
	return
	end
	shownPhase = phase
	for index = 1, PIP_COUNT do
	local pip = pips[index]
	if pip ~= nil then
			pip.BackgroundColor3 = if index <= phase then COLOR_PIP_ON else COLOR_PIP_OFF
	end
	end
end

--[[
	Find the boss through the arena folder rather than by searching all of Workspace.

	The path is the same documented one `Boss1Controller` builds the Commander
	into at boot, so both sides agree by construction instead of by a search that
	would also match a boss in some future region.
]]
local function findBoss(): Model?
	local hub = workspace:FindFirstChild("SanctuaryHub")
	if hub == nil then
	return nil
	end
	local arena = hub:FindFirstChild(BossConfig.Arena.FolderName)
	if arena == nil then
	return nil
	end
		-- By name, not by attribute: an Instance-valued attribute reads back as an
		-- `InstanceHandle`, which cannot even answer `IsA`. The name is the one
		-- `Boss1Controller` builds the Commander under at boot.
		local boss = arena:FindFirstChild("CorruptedCommander")
		if boss == nil or not boss:IsA("Model") then
			return nil
		end
		return boss :: Model
end

--[[
	Fade.

	One property on the parent frame, tweened. `Cancel` on the previous tween is what
	makes a rapid re-engage safe: without it a fade-out still in flight would keep
	writing transparency over the fade-in that replaced it, and the bar would stall
	half-visible for the length of the older tween.
]]
--[[
	The fade, without `GroupTransparency`.

	This was one tween on a `CanvasGroup`'s `GroupTransparency`, which is the right
	instrument and no longer exists: the engine has removed `GroupTransparency` and
	`GroupColor3` from every `GuiObject`, and reading or tweening either now raises
	"GroupTransparency is not a valid member". Verified live on this build, not
	assumed from documentation.

	So the fade walks the frame's descendants and tweens each one's own
`Transparency` toward its authored value, offset by one for the hidden state. The
	authored values are captured once, after the tree is built, and never re-read -
	otherwise a fade-in would treat its own end state as the new baseline and the
	frame would ratchet itself invisible.

	`TextStrokeTransparency` is faded alongside `Transparency` so the nameplate does
	not keep a hard outline once the plate behind it has gone.

	`fadeTween` is now a *list*, and cancelling means cancelling every tween in it:
	a fade-out still in flight would otherwise keep writing over the fade-in that
	replaced it and the bar would stall half-visible for the length of the older
	tween. That is the same reason the single-tween version cancelled.
]]
local fadeTweens: { Tween } = {}

--[[
	Authored transparency per GuiObject, captured once after the build.

	`Transparency` and `TextTransparency` are **not interchangeable any more**. On a
	`TextLabel` this engine build exposes them as two independent properties, where
	they used to be aliases of one another, so a fade written against `Transparency`
	animates a property the text does not read and leaves the nameplate blank while
	every bar around it fades correctly. Verified live: tweening `Transparency` to 0
	left `TextTransparency` at 1; tweening `TextTransparency` worked.

	So text elements are captured and driven through `TextTransparency` and
	`TextStrokeTransparency`, and non-text elements through `Transparency`. A nameplate
	that is in the tree, correctly sized, correctly worded and invisible reads as a
	layout bug, so the reason is written down here rather than left to be rediscovered.
]]
local baseTransparency: { [GuiObject]: { Alpha: number, Stroke: number? } } = {}
for _, descendant in ipairs(rootFrame:GetDescendants()) do
	if descendant:IsA("GuiObject") then
		local isText = descendant:IsA("TextLabel") or descendant:IsA("TextButton")
		local entry: { Alpha: number, Stroke: number? } = {
			Alpha = if isText then descendant.TextTransparency else descendant.Transparency,
		}
		if isText then
			entry.Stroke = descendant.TextStrokeTransparency
		end
		baseTransparency[descendant] = entry
	end
end


local function setVisible(on: boolean)
	if visible == on then
		return
	end

	-- A fade already in flight is *cancelled and reversed*, not ignored. The old
	-- `or fading` guard made a re-entrant request a no-op, so a player who crossed
	-- the arena boundary twice during a fade was left with a bar whose nameplate had
	-- faded out and whose bars had not - a permanently half-drawn boss frame.
	-- Direction is taken from `on` and the tween list below is cancelled first, so
	-- the last request always wins.
	fading = true
	visible = on

	-- The ScreenGui is the hard gate: switched on *before* the fade-in starts,
	-- so a frame that is fading in is never fading in behind a disabled parent
	-- (which would make the fade invisible and the HUD pop at the end of it).
	if on then
		screenGui.Enabled = true
	end

	for _, tween in ipairs(fadeTweens) do
		tween:Cancel()
	end
	table.clear(fadeTweens)

	local info = TweenInfo.new(
		if on then FADE_IN else FADE_OUT,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)

	for descendant, entry in pairs(baseTransparency) do
		local isText = descendant:IsA("TextLabel") or descendant:IsA("TextButton")
		local alphaKey = if isText then "TextTransparency" else "Transparency"
		local props: { [string]: any } = {
			[alphaKey] = if on then entry.Alpha else 1,
		}
		if entry.Stroke ~= nil then
			props.TextStrokeTransparency = if on then entry.Stroke else 1
		end
		local tween = TweenService:Create(descendant, info, props)
		table.insert(fadeTweens, tween)
		tween:Play()
	end

	-- The root itself is transparent by design, so it is driven directly rather
	-- than through the table (it has no authored value worth offsetting).
	local rootTween = TweenService:Create(
		rootFrame,
		info,
		{ BackgroundTransparency = 1 }
	)
	table.insert(fadeTweens, rootTween)
	rootTween:Play()

	if #fadeTweens > 0 then
		fadeTweens[1].Completed:Once(function()
			fading = false
			-- Off again only once the fade-out has actually landed. Disabling on
			-- the first frame instead would cut the fade short and read as a
			-- blink rather than as the frame leaving.
			if not visible then
				screenGui.Enabled = false
			end
		end)
	end
end

--[[
	The single wire message.

	`(engaged, name, maxHealth, maxPosture)` - see `BossConfig` S2. The name is used
	verbatim rather than ignored, so a second boss reusing this HUD needs no change
	here at all. Only the attribute *read* below is Commander-specific, and that is
	four lines and is marked as such.
]]
local remote = ReplicatedStorage:WaitForChild(BossConfig.RemoteEngage)
if remote ~= nil and remote:IsA("RemoteEvent") then
	local engageEvent = remote :: RemoteEvent
	engageEvent.OnClientEvent:Connect(function(
		engaged: boolean,
		name: any,
		ceiling: any,
		postureCeiling: any
	)
	if typeof(ceiling) == "number" and ceiling > 0 then
			maxHealth = ceiling
	end
	if typeof(postureCeiling) == "number" and postureCeiling > 0 then
			maxPosture = postureCeiling
	end
	if typeof(name) == "string" and name ~= "" then
			nameText.Text = name
	end

	if engaged then
			bossModel = findBoss()
			healthTarget = 1
			shownPhase = 0
			setPips(1)
	else
			-- Visibility is deliberately *not* written here. The arena-zone gate
			-- owns it, so a disengage that fires while the player is still
			-- standing in the courtyard cannot yank the frame away mid-fade, and
			-- an engage that fires before the player has walked in cannot show it
			-- to somebody who is not there.
			bossModel = findBoss()
	end
	end)
end

--[[
	The live read.

	`RenderStepped` rather than a timer, because the *interpolation* has to be smooth
		to the frame or the easing is visible as steps - which is the one thing easing
	exists to hide. The loop is written to ARCHITECTURE #4: no table allocations, no
	CFrame construction, and the visibility check is the first statement so the
	overwhelming majority of frames do four comparisons and return.

	Two attributes drive the bars and one drives the pips. Everything is compared
	before it is written, so a frame in which nothing changed writes nothing.
]]
local function onRenderStep()
	if not visible or fading then
	return
	end
	local model = bossModel
	if model == nil then
	return
	end

	local health = model:GetAttribute(Attributes.Health)
	local posture = model:GetAttribute(Attributes.Posture)
	local phase = model:GetAttribute(Attributes.Phase)

	if typeof(health) == "number" and maxHealth > 0 then
	local target = math.clamp(health / maxHealth, 0, 1)
	if math.abs(target - healthTarget) > 0.0005 then
			healthTarget = target
			if healthTween ~= nil then
				healthTween:Cancel()
			end
			healthTween = TweenService:Create(
				healthFill,
				TweenInfo.new(HEALTH_TWEEN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(target, 1) }
			)
			healthTween:Play()
	end
	end

	if typeof(posture) == "number" and maxPosture > 0 then
		postureFill.Size = UDim2.fromScale(math.clamp(posture / maxPosture, 0, 1), 1)
	end

	if typeof(phase) == "number" then
		setPips(math.clamp(math.floor(phase), 1, PIP_COUNT))
	end

	--[[
		A guard break is the fight's loudest state and it is deliberately *not* a
		colour change on the health bar - the health bar already means something. The
		nameplate is what shouts, because the nameplate is what the player is reading
	while they wait for an opening.
	]]
	if model:GetAttribute(Attributes.Vulnerable) == true then
		nameText.TextStrokeTransparency = 0.0
	else
		nameText.TextStrokeTransparency = 0.55
	end
end

--[[
	The arena-zone gate.

	The engage event says *a* fight has started; this says whether *this* player
	is standing inside the arena it started in. Those are different questions,
	and only the second one is allowed to make the HUD visible: at the
	SanctuaryHub spawn the boss frame has to be 100% absent, and no distance
	check can promise that because spawn sits inside line of sight of the
	courtyard.

	`workspace:GetPartsInPart` with an `Include` filter of the local character is
	the spatial-query form of "is my character inside `Arena1Zone`": the answer
	comes from geometry rather than from coordinates, so the world builder can
	move or resize the anchor without this file knowing. The anchor itself is
	the invisible 90x40x90 volume `WorldEnvironment` publishes over the
	courtyard, deliberately `CanQuery = true` for exactly this kind of question.

	The loop is a 0.2s `task.wait`, not a per-frame callback: it owns a *fade*,
	not an interpolation, and the fade already has its own clock inside
	`TweenService`. Everything it writes happens on the transition, so a steady
	state costs one boolean comparison per tick.
]]
local zoneOverlap = OverlapParams.new()
zoneOverlap.FilterType = Enum.RaycastFilterType.Include
zoneOverlap.FilterDescendantsInstances = {}

local arenaZone: BasePart? = nil
local zoneCharacter: Model? = nil

local function resolveZone(): BasePart?
	local hub = workspace:FindFirstChild("SanctuaryHub")
	if hub == nil then
		return nil
	end
	local zone = hub:FindFirstChild("Arena1Zone", true)
	if zone ~= nil and zone:IsA("BasePart") then
		return zone :: BasePart
	end
	return nil
end

local function insideArena(): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	-- The Include filter is rebuilt only when the character reference changes,
	-- so the steady-state poll allocates nothing.
	if zoneCharacter ~= character then
		zoneCharacter = character
		zoneOverlap.FilterDescendantsInstances = { character }
	end
	local zone = arenaZone
	if zone == nil then
		zone = resolveZone()
		arenaZone = zone
		if zone == nil then
			return false
		end
	end
	return #workspace:GetPartsInPart(zone, zoneOverlap) > 0
end

local wasInside = false
task.spawn(function()
	while true do
		local inside = insideArena()
		if inside ~= wasInside then
			wasInside = inside
			if inside then
				bossModel = findBoss()
				healthTarget = 1
				shownPhase = 0
				setPips(1)
			end
			setVisible(inside)
		end
		task.wait(0.2)
	end
end)

RunService.RenderStepped:Connect(onRenderStep)

print("[BOSS HUD] Commander frame online - waiting for engagement.")
