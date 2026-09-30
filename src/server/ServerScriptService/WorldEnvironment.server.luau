--!strict

--[[
WorldEnvironment
Ronin - The Last Blade . The Horizon: the lighting, and the four regions beyond
the four torii.

What this file owns
-------------------
Two things, and they are the same thing: the *look* of the world and the
*skyline* of the world.

  1. `Lighting` - the cinematic golden hour. ClockTime 17.5, latitude 45, a warm
     atmosphere, and exactly one of each post effect. The hub already had a
     `SANCTUARY_*` set of effects left behind by a builder script that no longer
     exists, and two Atmospheres stacked on top of each other; both are dealt
     with in S2 rather than ignored, because two atmospheres are not a style,
     they are a bug that renders as haze.
  2. Four horizon regions behind the four torii, so that standing on the spawn
     and turning through 360 degrees finds something worth looking at in every
     direction. North is the Burning Ash Fortress (behind Gate 1), East is the
     Whispering Bamboo Grove, West is the Sunken Pagoda, South is the Crimson
     Eclipse Citadel.

The one number that decides whether any of it is visible
--------------------------------------------------------
From the spawn the four torii are solid up to y = 26 and their openings are
about 20 wide and 10 tall, so every region is read *through* a letterbox - and
the Burning Ash Courtyard, which already stands between the hub and the north
gate, is a second 26-stud wall. A horizon piece shorter than about 60 studs at
the north is simply not in the picture. That is why the fortress sits on a
terraced massif and the citadel on cliffs: the height is not decoration, it is
the only reason the region exists on screen. Each region's tree of numbers below
carries the sight line it was chosen against.

Why one file instead of four
----------------------------
`Arena1Builder` set the precedent: a region is a *function of its own
constants*, and the region, its palette, its props and its particles all move
together from one table. Four files would be four places to look for the same
mistake. The shared kit in S2 is what keeps this from being 4,000 lines of
`Instance.new`: every region below is a handful of loops over a table.

Engine reality this file had to adapt to (Sept 2026 build)
----------------------------------------------------------
  * `Lighting.Technology` is `ReadOnly` with `RobloxScriptSecurity`, so an
    ordinary script cannot read it, let alone write it - and the docs now say it
    has been *superseded* by `Lighting.LightingStyle` ("Realistic - the most
    advanced and realistic lighting and shadows Roblox can deliver") plus
    `Lighting.PrioritizeLightingQuality`. S2 therefore writes those two, and
    attempts `Technology` inside a `pcall` so the intent is recorded and comes
    true for free if the property is ever scriptable again.
  * `Enum.Material.Water` is documented "Applies to Terrain only", and terrain
    water is locked to y = 0 - which is exactly where this place's `Baseplate`
    top face is. The flooded courtyard in S5 is therefore a part-based
    reflective surface (`SmoothPlastic` + `Reflectance`), which is what the
    brief allows by name.
  * `Atmosphere.Decay` only renders when `Haze` *and* `Glare` are both above
    zero, so S2 writes the five requested values plus a small `Glare`; without
    it the requested Decay colour is a value nobody can see.

Architecture rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #3 - the server decides what the world contains. Nothing the
    client sends creates a single part here.
  * ARCHITECTURE.md #4 - no per-frame loop exists in this file at all. Everything
    that moves (bobbing lanterns, swaying banners, flickering braziers) is a
    `TweenService` tween with `RepeatCount = -1`, so the frame loop lives in C++
    and this file allocates nothing after boot.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--[[
The arena's own numbers are *read*, never copied. The Burning Ash Courtyard is
80x80 at z = -116 with 26-stud walls on a 1.0 floor, and the north region has to
sit behind it without touching it; if the arena is ever resized, the terrace
behind it moves with it instead of leaving a gap or a collision.
]]
local BossConfig = require(ReplicatedStorage:WaitForChild("BossConfig") :: ModuleScript)
local Arena = BossConfig.Arena

--===========================================================================
-- S1 - THE WORLD'S SKELETON AND PALETTE
--===========================================================================

--[[
The hub is a 104x104 plinth centred on the origin whose floor top is y = 1, and
its four torii stand on a 46-stud ring. That is the only hard geometry this file
assumes about the hub, and it is all it needs - measured in prose rather than in
constants, because every region grows outward from the hub's *edge* rather than
referencing a number of it. Where a region does need the hub's floor height it
needs its own (the aprons, the basin floor, the docks), and those are written out
where they are used so that changing them cannot silently move a landmark.
]]

--[[
Every region's ground apron sits 0.1 studs *under* the hub floor and 0.1 under
the arena floor, and slides underneath both rather than meeting them edge to
edge. Two coplanar surfaces at the same height flicker; two surfaces 0.1 apart
do not, and 0.1 of a stud is invisible from 40 studs away.
]]
local APRON_TOP: number = 0.9
local APRON_THICKNESS: number = 2

--[[
A fixed seed for every "random" placement in the file. A grove whose culms land
somewhere new on each server boot is a grove that cannot be art-directed, cannot
be reproduced from a bug report, and quietly invalidates every screenshot.
]]
local SEED: number = 20260930

local FOLDER_HORIZON: string = "Horizon"

--[[
The palette, region by region. Dark, desaturated and never black: under a warm
low sun the only thing that makes a silhouette read is that something behind it
is brighter, and a pure-black surface throws away every bounce the atmosphere
would have given it.
]]
local COLOR_ASH_STONE = Color3.fromRGB(48, 43, 40)
local COLOR_ASH_STONE_DARK = Color3.fromRGB(33, 30, 29)
local COLOR_CHARRED = Color3.fromRGB(30, 24, 22)
local COLOR_ROOF_SLATE = Color3.fromRGB(38, 36, 38)
local COLOR_EMBER_TRIM = Color3.fromRGB(122, 44, 22)
local COLOR_IRON = Color3.fromRGB(42, 40, 42)
local COLOR_FIRE = Color3.fromRGB(255, 150, 58)

local COLOR_CULM = Color3.fromRGB(86, 120, 58)
local COLOR_CULM_YOUNG = Color3.fromRGB(128, 158, 74)
local COLOR_LEAF = Color3.fromRGB(64, 96, 46)
local COLOR_MOSS_STONE = Color3.fromRGB(74, 80, 62)
local COLOR_HILL_EARTH = Color3.fromRGB(48, 54, 42)

local COLOR_BASIN_STONE = Color3.fromRGB(40, 44, 48)
local COLOR_WATER = Color3.fromRGB(12, 24, 30)
local COLOR_DOCK_WOOD = Color3.fromRGB(74, 60, 48)
local COLOR_WILLOW = Color3.fromRGB(88, 104, 58)
local COLOR_LANTERN_PAPER = Color3.fromRGB(255, 196, 120)

local COLOR_IMPERIAL_STONE = Color3.fromRGB(46, 42, 44)
local COLOR_PLASTER = Color3.fromRGB(206, 198, 186)
local COLOR_TIMBER = Color3.fromRGB(44, 32, 28)
local COLOR_CRIMSON = Color3.fromRGB(146, 26, 30)
local COLOR_IMPERIAL_ROOF = Color3.fromRGB(34, 32, 36)
local COLOR_GOLD_TRIM = Color3.fromRGB(178, 142, 72)

--[[
The two default particle sheets, borrowed from `BossConfig` rather than retyped:
they are `rbxasset://` textures, so they always resolve, and the arena already
proved they read as ash and as embers when tinted.
]]
local TEXTURE_SMOKE = BossConfig.Particles.Ash
local TEXTURE_SPARK = BossConfig.Particles.Ember

--===========================================================================
-- S2 - THE SHARED KIT
--===========================================================================
--[[
Every region in S4-S8 is built out of these nine helpers. They exist so that the
regions read as *geometry* rather than as a wall of `Instance.new`, and so that
the three collision flags are decided once per kind of object instead of being
guessed at 1,700 call sites.

The flags matter more here than usual. A scenery part with `CanQuery` left on is
a part that can stop the player's katana: `BladeHitbox` casts four swept rays per
frame and resolves the *first* thing it finds, so a bamboo stalk that is
queryable and stands between the blade and a target silently eats the hit. Every
decorative surface below is therefore `CanQuery = false`, and only the ground,
the walls and the zone volumes are queryable.
]]

type EmitterSpec = {
	Rate: number,
	Lifetime: NumberRange,
	Speed: NumberRange,
	Size: NumberSequence,
	Color: ColorSequence,
	Transparency: NumberSequence,
	LightInfluence: number,
	Acceleration: Vector3?,
	Drag: number?,
	SpreadAngle: Vector2?,
	EmissionDirection: Enum.NormalId?,
	LightEmission: number?,
	RotSpeed: NumberRange?,
}

--[[
The one part constructor. Anchored always - nothing in this file is simulated -
with smooth surfaces so the default stud texture never appears on a built face.
]]
local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
A vertical cylinder.

`Enum.PartType.Cylinder` spins and stacks about the part's local **X** axis, so a
culm of height `h` is `Vector3.new(h, d, d)` rotated a quarter turn about Z - not
`Vector3.new(d, h, d)`, which produces a `h`-stud-wide disc standing on its edge.
That mistake hides extremely well in a screenshot taken from far enough away to see
the whole grove, which is the only reason it is worth a comment.
]]
local function makeCylinder(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	base: Vector3,
	yaw: number,
	lean: number,
	color: Color3,
	material: Enum.Material
): Part
	local part = makePart(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(base + Vector3.new(0, height * 0.5, 0)) * CFrame.Angles(lean, yaw, math.pi * 0.5),
		color,
		material
	)
	part.Shape = Enum.PartType.Cylinder
	return part
end

--[[
Scenery: visible, and nothing else. It cannot be walked into, touched, or found
by a spatial query, and it does not cast a shadow unless it is asked to.
]]
local function decorative(part: BasePart, castsShadow: boolean?)
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = castsShadow == true
end

--[[
A phantom: invisible but *present*. Used for the ash and mist volumes and for the
zone anchors. `queryable` is the parameter that matters - a zone anchor that
cannot be found by a spatial query is an anchor for nothing, while an ash volume
that can be is a 260-stud obstacle in front of every blade in the north.
]]
local function phantom(part: BasePart, queryable: boolean)
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = queryable
	part.CastShadow = false
end

--[[
The host for a particle emitter. Weather in this file is always a wide invisible
box with the emitter on it rather than an emitter on a real part, because weather
belongs to the *region* and not to a piece of it - an ash field parented to the
pagoda would move with the pagoda and telegraph where the tower is.
]]
local function phantomVolume(parent: Instance, name: string, size: Vector3, center: Vector3): Part
	local volume = makePart(parent, name, size, CFrame.new(center), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	phantom(volume, false)
	return volume
end

local function makeLight(parent: Instance, brightness: number, range: number, color: Color3, shadows: boolean): PointLight
	local light = Instance.new("PointLight")
	light.Brightness = brightness
	light.Range = range
	light.Color = color
	light.Shadows = shadows
	light.Parent = parent
	return light
end

local function makeEmitter(parent: Instance, name: string, texture: string, spec: EmitterSpec): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.Rate = spec.Rate
	emitter.Lifetime = spec.Lifetime
	emitter.Speed = spec.Speed
	emitter.Size = spec.Size
	emitter.Color = spec.Color
	emitter.Transparency = spec.Transparency
	emitter.LightInfluence = spec.LightInfluence
	emitter.Acceleration = if spec.Acceleration ~= nil then spec.Acceleration else Vector3.zero
	emitter.Drag = if spec.Drag ~= nil then spec.Drag else 0
	emitter.SpreadAngle = if spec.SpreadAngle ~= nil then spec.SpreadAngle else Vector2.new(6, 6)
	emitter.EmissionDirection = if spec.EmissionDirection ~= nil then spec.EmissionDirection else Enum.NormalId.Top
	emitter.LightEmission = if spec.LightEmission ~= nil then spec.LightEmission else 0
	emitter.RotSpeed = if spec.RotSpeed ~= nil then spec.RotSpeed else NumberRange.new(-12, 12)
	emitter.LockedToPart = false
	emitter.Parent = parent
	return emitter
end

--[[
A zone anchor: the invisible volume a future region query will ask about.

`CanQuery = true` by design, and the reason it is safe is worth writing down,
because the obvious reading of the flag says the opposite. `Arena1Zone` is 90x40
x90 around an 86x86 courtyard, so it *encloses* the arena interior - and a ray
whose two ends are both inside a box never crosses that box's surface and never
reports a hit on it. `BladeHitbox`'s swept rays and `HitValidator`'s line-of-
sight rays both start and end inside, so neither can be swallowed by the anchor,
while a query that asks "which region am I in" is answered by it. That only holds
because the anchor is larger than the room it covers; a zone box that clipped the
courtyard's walls would start eating swings at the edges.
]]
local function makeZone(
	parent: Instance,
	name: string,
	size: Vector3,
	center: Vector3,
	regionIndex: number,
	regionName: string,
	direction: string
): Part
	local zone = makePart(parent, name, size, CFrame.new(center), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	phantom(zone, true)
	zone:SetAttribute("RoninZone", regionName)
	zone:SetAttribute("RoninZoneIndex", regionIndex)
	zone:SetAttribute("RoninZoneDirection", direction)
	return zone
end

--[[
Motion, without a loop.

Every moving thing in this file is a tween with `RepeatCount = -1`, which is the
whole trick: an infinite ping-pong tween runs forever inside the engine's own
tween driver, so there is no `while true do task.wait() end` in this file, nothing
to leak when a region is rebuilt, and no per-frame allocation of the kind
ARCHITECTURE.md #4 rules out. `phase` staggers the periods so a row of identical
objects never breathes in lockstep, which is the single most common way a
tween-driven scene reads as artificial.
]]
local function makeBob(part: BasePart, amplitude: number, period: number, phase: number)
	local base = part.CFrame
	part.CFrame = base * CFrame.new(0, amplitude * math.sin(phase), 0)
	local tween = TweenService:Create(
		part,
		TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = base * CFrame.new(0, amplitude, 0) }
	)
	tween:Play()
end

--[[
The same trick for rotation: a hanging banner leans a degree and a half one way,
then the other, forever. `CFrame.Angles` about Z leans it along its own width,
which is the axis a banner actually swings on.
]]
local function makeSway(part: BasePart, radians: number, period: number)
	local base = part.CFrame
	local tween = TweenService:Create(
		part,
		TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = base * CFrame.Angles(0, 0, radians) }
	)
	tween:Play()
end

--[[
A light that breathes. Used on the braziers and the water lanterns, and it is what
turns a warm dot in the dark into something burning: the *rate* of flicker is the
message, so the period is short and the amplitude is small. More than about a
tenth of the brightness reads as a fault in the light rather than as a flame.
]]
local function makeFlicker(light: PointLight, amount: number, period: number, phase: number)
	local base = light.Brightness
	light.Brightness = base * (1 + amount * math.sin(phase))
	local tween = TweenService:Create(
		light,
		TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Brightness = base * (1 + amount) }
	)
	tween:Play()
end

--===========================================================================
-- S3 - THE GOLDEN HOUR
--===========================================================================

--[[
The names this file owns under `Lighting`. `WORLD_` for the same reason
`Arena1Builder` uses `ARENA_` for its burn grade: two systems writing the same
global object is a bug that only ever surfaces as "the colour looks off", and a
name prefix is what makes the owner obvious at a glance in the Explorer.

`RESERVED_PREFIX` is the mirror of that: when this file goes looking for an
existing effect to adopt, it refuses to take one that belongs to another system.
Without that check, a boot where `Arena1Builder` happened to run first would find
`ARENA_Burn_Grade`, adopt it as the world's grade, and silently retune the boss
fight's arena-wide colour while the fight's own controller went on tweening it.
]]
local NAME_ATMOSPHERE: string = "WORLD_Atmosphere"
local NAME_BLOOM: string = "WORLD_Bloom"
local NAME_SUNRAYS: string = "WORLD_SunRays"
local NAME_GRADE: string = "WORLD_Grade"
local RESERVED_PREFIX: string = "ARENA_"

--[[
Find-or-create, one instance per class.

The world's post stack is authored *here* and nowhere else, so a place that
already has a hand-made `Atmosphere` reuses it (and is re-tuned to the values
below) rather than ending up with two. When the existing instance has some other
name it is renamed: the name is the contract, and a contract that depends on what
the previous owner happened to call something is not one.
]]
local function adopt(canonicalName: string, className: string, create: () -> Instance): Instance
	local existing = Lighting:FindFirstChild(canonicalName)
	if existing ~= nil and existing:IsA(className) then
		return existing
	end

	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA(className) and child.Name:sub(1, #RESERVED_PREFIX) ~= RESERVED_PREFIX then
			local previous = child.Name
			child.Name = canonicalName
			print(string.format("[WORLD] Adopted Lighting.%s (%s) as %s.", previous, className, canonicalName))
			return child
		end
	end

	local created = create()
	created.Name = canonicalName
	created.Parent = Lighting
	return created
end

--[[
Two Atmospheres is never a style, it is a bug that renders as haze, and the place
this file was written into had exactly that: a hand-placed `Atmosphere` and a
`SANCTUARY_Atmosphere` left behind by a builder script that no longer exists,
stacked, with a `SANCTUARY_Bloom` beside them.

So the rule is: atmosphere, bloom and sun rays are *singular* objects here and
every duplicate is removed. Colour correction is deliberately **not** on that
list, because `ColorCorrectionEffect` composes by design - multiple instances add
their effects together, which is the entire mechanism the boss fight uses to tint
the screen red inside the arena, so deleting "extra" ones would break it.
]]
local function pruneDuplicates(className: string, keep: Instance): number
	local removed = 0
	for _, child in ipairs(Lighting:GetChildren()) do
		if child ~= keep and child:IsA(className) then
			print(string.format("[WORLD] Removing leftover %s (%s): %s owns the world's one.", child.Name, className, keep.Name))
			child:Destroy()
			removed += 1
		end
	end
	return removed
end

--[[
Falling ash and rising embers, once each, because both regions that burn want the
same two materials: the fortress in S4 and the citadel's fires in S8.

`LightInfluence = 0.85` on the ash is the one number that makes it read as ash
rather than as grey confetti - the flakes pick up almost all of their colour from
the environment, so they are bright orange on the brazier side of a room and
nearly black on the other. `LightInfluence = 0` on the embers is the opposite
decision for the opposite object: an ember is self-luminous, so being darkened by
a shadow would be wrong.
]]
local function makeAshEmitter(parent: Instance, name: string, rate: number): ParticleEmitter
	return makeEmitter(parent, name, TEXTURE_SMOKE, {
		Rate = rate,
		Lifetime = NumberRange.new(11, 18),
		Speed = NumberRange.new(1.5, 3.5),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.5, 0.7),
			NumberSequenceKeypoint.new(1, 0.35),
		}),
		Color = ColorSequence.new(Color3.fromRGB(196, 186, 176)),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(0.7, 0.78),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightInfluence = 0.85,
		Acceleration = Vector3.new(0.5, -1.3, 0.4),
		Drag = 0.4,
		SpreadAngle = Vector2.new(180, 180),
		EmissionDirection = Enum.NormalId.Bottom,
		RotSpeed = NumberRange.new(-30, 30),
	})
end

local function makeEmberEmitter(parent: Instance, name: string, rate: number, lifetime: NumberRange): ParticleEmitter
	return makeEmitter(parent, name, TEXTURE_SPARK, {
		Rate = rate,
		Lifetime = lifetime,
		Speed = NumberRange.new(2.5, 6),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.3, 0.3),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 238, 172)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 124, 32)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(96, 18, 6)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.6, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightInfluence = 0,
		LightEmission = 0.8,
		Acceleration = Vector3.new(0.6, 3.2, 0.4),
		Drag = 0.6,
		SpreadAngle = Vector2.new(16, 16),
		EmissionDirection = Enum.NormalId.Top,
	})
end

type EnvironmentReport = {
	Quality: string,
	Pruned: number,
}

--[[
One property, one `pcall`.

Three writes in this file can be refused by the engine, and they are exactly the
three that decide the *quality path*: `Technology` (ReadOnly, RobloxScript) and
`LightingStyle` / `PrioritizeLightingQuality`, which on this build carry
`PluginOrOpenCloud` security. That means they are settable from the command bar, from
a plugin, or from a cloud session, and **not** from a server script at run time.

Verified live, and it is the reason this helper exists: a `Script` that writes
`LightingStyle` raises "The current thread cannot write 'LightingStyle' (lacking
capability PluginOrOpenCloud)" - and because the write was in the same `pcall` as the
`Technology` attempt, the raise took the rest of the boot down with it and not one
region was built. Separate pcalls, one warning, and the boot survives.

The look does not depend on the runtime write: the place itself is authored with
`LightingStyle = Realistic` and `PrioritizeLightingQuality = true`, which save with
the place and are what the client actually renders with. This is the honest shape of
the modern replacement for `Technology = Future` - the setting belongs to the place,
and the script's job is to ask for it and to say so when it cannot have it.
]]
local function trySet(property: string, value: any): boolean
	local writable = Lighting :: any
	return pcall(function()
		writable[property] = value
	end)
end

--[[
The golden hour, written once.

`Ambient` and `OutdoorAmbient` are the one pair of values here that are *not* from
the brief, and they are here because the four that are (ClockTime, latitude,
exposure, atmosphere) do not touch them: the place shipped with a violet-grey
ambient (`96, 92, 112` and `122, 116, 132`) that is a fine dusk hue and reads as
washed-out lilac under a warm sun. The values below keep the brightness within about
8% of what was there and only change the *hue*, so the hub's exposure does not move.
Reverting is a one-line edit in each direction.
]]
local function applyEnvironment(): EnvironmentReport
	local technologyOk = trySet("Technology", Enum.Technology.Future)
	local styleOk = trySet("LightingStyle", Enum.LightingStyle.Realistic)
	local priorityOk = trySet("PrioritizeLightingQuality", true)

	if not (styleOk and priorityOk) then
		warn(
			"[WORLD] Lighting quality is place-level on this engine build: LightingStyle (Realistic) and "
				.. "PrioritizeLightingQuality (true) are PluginOrOpenCloud-locked and cannot be written by a script. "
				.. "Both are already authored on the Lighting service in this place."
		)
	end

	Lighting.ClockTime = 17.5
	Lighting.GeographicLatitude = 45
	Lighting.ExposureCompensation = 0.25
	Lighting.GlobalShadows = true
	Lighting.Ambient = Color3.fromRGB(88, 78, 82)
	Lighting.OutdoorAmbient = Color3.fromRGB(118, 108, 104)

	--[[
	The atmosphere. Density 0.35 is thick enough to hold the sun's colour across
	the whole horizon and thin enough that the north fortress, 200 studs away, is
	still a black silhouette rather than a grey smear.

	`Glare = 0.35` is not in the brief and is required by it: per the Atmosphere
	documentation, `Decay` - the second of the requested colours - "must be used
	with Haze and Glare levels higher than 0 to see any effect". The requested
	`Color` of (190, 160, 140) and `Decay` of (106, 112, 125) are a warm near-sun
	hue cooling into blue-grey away from it, and with Glare at 0 the far half of
	that gradient is simply not rendered.
	]]
	local atmosphere = adopt(NAME_ATMOSPHERE, "Atmosphere", function(): Instance
		return Instance.new("Atmosphere")
	end) :: Atmosphere
	atmosphere.Density = 0.35
	atmosphere.Offset = 0.25
	atmosphere.Haze = 1.5
	atmosphere.Glare = 0.35
	atmosphere.Color = Color3.fromRGB(190, 160, 140)
	atmosphere.Decay = Color3.fromRGB(106, 112, 125)

	--[[
	Bloom at Size 24 rather than the default 16: the sun is low and the fortress
	has braziers in it, and a wide, soft bloom is what makes a golden hour read as
	air rather than as a photograph of a bright lamp.
	]]
	local bloom = adopt(NAME_BLOOM, "BloomEffect", function(): Instance
		return Instance.new("BloomEffect")
	end) :: BloomEffect
	bloom.Enabled = true
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 0.8

	--[[
	Sun rays are deliberately faint (0.08). The effect is a halo drawn *over* the
	world, and at anything above about a tenth it stops reading as sunlight in the
	air and starts reading as a lens artefact - which is exactly the failure mode
	the brief's 0.08 avoids.
	]]
	local sunRays = adopt(NAME_SUNRAYS, "SunRaysEffect", function(): Instance
		return Instance.new("SunRaysEffect")
	end) :: SunRaysEffect
	sunRays.Enabled = true
	sunRays.Intensity = 0.08
	sunRays.Spread = 0.2

	--[[
	The grade, and it is the only one of the four that is *not* pruned if a second
	one exists: `ARENA_Burn_Grade` is live, owned by the fight, and composed on top
	of this one on purpose. Contrast and saturation both nudge up a hair rather
	than up; a golden hour graded hard is an orange filter, and the tint colour to
	(255, 245, 235) is what keeps that from happening by giving the highlights a
	warm cast instead of the whole image one.
	]]
	local grade = adopt(NAME_GRADE, "ColorCorrectionEffect", function(): Instance
		return Instance.new("ColorCorrectionEffect")
	end) :: ColorCorrectionEffect
	grade.Enabled = true
	grade.Contrast = 0.15
	grade.Saturation = 0.12
	grade.TintColor = Color3.fromRGB(255, 245, 235)

	local pruned = pruneDuplicates("Atmosphere", atmosphere)
	pruned += pruneDuplicates("BloomEffect", bloom)
	pruned += pruneDuplicates("SunRaysEffect", sunRays)

	return {
		Quality = if styleOk
			then (if technologyOk then "Technology=Future" else "LightingStyle=Realistic")
			else "LightingStyle authored in the place",
		Pruned = pruned,
	}
end

--===========================================================================
-- S4 - NORTH: THE BURNING ASH FORTRESS  (behind Gate 1)
--===========================================================================

--[[
Sight line arithmetic, done once, because it decides the whole region.

The spawn sits at (0, 6, 0). To the north the view is blocked twice: the hub's own
torii is solid to y = 26 at z = -46, and the Burning Ash Courtyard's south wall is
solid to y = 27 at z = -76 (its own gate opening is 16 wide and 18 tall). The
steepest of those two sight lines is the arena's wall, and it leaves the fortress
visible from about y = 57 upward at the fortress's own distance. Everything that
has to be *seen from the spawn* therefore stands above 64, and that is why the
fortress is a terraced massif with a pagoda on top of it rather than a courtyard
wall with a gate in it: at ground level, 200 studs behind a 27-stud wall, nobody
would ever see any of it.

The region is also deliberately unreachable. The arena seals behind the player,
its north wall has no opening, and none of the flights below climb above y = 64
anywhere near the arena - so the boss fight cannot be walked out of through the
scenery that frames it.

Each terrace is `{ Top, Front, Back, Half }`: Front is the edge nearer the hub.
]]
type Terrace = {
	Top: number,
	Front: number,
	Back: number,
	Half: number,
}

local NORTH_APRON_HALF_X: number = 150
local NORTH_APRON_FRONT: number = -44
local NORTH_APRON_BACK: number = -272

local NORTH_TERRACES: { Terrace } = {
	{ Top = 25.4, Front = -158, Back = -188, Half = 122 },
	{ Top = 46, Front = -188, Back = -218, Half = 100 },
	{ Top = 64, Front = -218, Back = -258, Half = 74 },
}

--[[
The pagoda. Four tiers rather than the three a courtyard gate would have, because
four is the shortest stack whose roof line clears y = 64 *and* the arena's wall
from the spawn; the spire on top takes it to about 156, which is the tallest thing
in the place and the reason the north side of the spawn reads as a horizon rather
than as a fence.
]]
local NORTH_PAGODA_Z: number = -238
local NORTH_PAGODA_PODIUM: number = 8
local NORTH_TIER_WIDTHS: { number } = { 64, 54, 44, 34 }
local NORTH_TIER_HEIGHT: number = 16
local NORTH_TIER_RISE: number = 18

--[[
An iron brazier, native, small and reusable: the arena has six of its own that
`Arena1Builder` built, and the fortress needs its own because those six are the
fight's light and must not move.

Legs splay outward and the pan is a cylinder, which is the same silhouette the
arena's braziers have already proved reads from a distance under this lighting.
The light is deliberately `Shadows = false` on the far terraces: a Future-lighting
point light with shadows enabled is worth it indoors where it carves a room, and
is pure cost on an open terrace where nothing is close enough to receive one.
]]
local function makeIronBrazier(parent: Instance, position: Vector3, scale: number, castShadows: boolean): PointLight
	--[[
	The pan, as a flat disc: `size.X` is the cylinder's *axial* length, so the small
	number goes in X and the two large ones in Y and Z, and the quarter turn about Z
	stands the axis up. `Vector3.new(2.6 * scale, 0.9 * scale, 2.6 * scale)` - the
	obvious reading of the same intention - is a bowl 2.6 studs tall and 0.9 studs
	across, which is a spike.
	]]
	local bowl = makePart(
		parent,
		"BrazierPan",
		Vector3.new(0.9 * scale, 2.6 * scale, 2.6 * scale),
		CFrame.new(position) * CFrame.Angles(0, 0, math.pi * 0.5),
		COLOR_IRON,
		Enum.Material.Metal
	)
	bowl.Shape = Enum.PartType.Cylinder

	for index = 0, 3 do
		local angle = index * math.pi * 0.5
		makePart(
			parent,
			"BrazierLeg",
			Vector3.new(0.4 * scale, 2.6 * scale, 0.4 * scale),
			CFrame.new(position + Vector3.new(math.cos(angle) * 1.1 * scale, -1.6 * scale, math.sin(angle) * 1.1 * scale))
				* CFrame.Angles(0, -angle, 0.12),
			COLOR_IRON,
			Enum.Material.Metal
		)
	end

	local fire = makePart(
		parent,
		"BrazierFire",
		Vector3.new(1.9 * scale, 0.4, 1.9 * scale),
		CFrame.new(position + Vector3.new(0, 0.35 * scale, 0)),
		Color3.fromRGB(255, 84, 18),
		Enum.Material.Neon
	)
	fire.Transparency = 0.25

	local light = makeLight(fire, 3.2, 46 * scale, COLOR_FIRE, castShadows)
	makeFlicker(light, 0.09, 0.7 + scale * 0.13, scale * 1.7)

	makeEmitter(fire, "Flame", TEXTURE_SMOKE, {
		Rate = 14,
		Lifetime = NumberRange.new(0.5, 1.1),
		Speed = NumberRange.new(2.5, 5),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.1 * scale),
			NumberSequenceKeypoint.new(0.6, 0.7 * scale),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 214, 138)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 128, 34)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 22, 6)),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
		LightInfluence = 0,
		LightEmission = 0.9,
		Acceleration = Vector3.new(0.4, 5.5, 0.4),
		Drag = 0.8,
		SpreadAngle = Vector2.new(12, 12),
		EmissionDirection = Enum.NormalId.Top,
	})

	makeEmberEmitter(fire, "Embers", 5, NumberRange.new(1.8, 3.4))
	return light
end

--[[
The massif: three terraces, each one narrower and taller than the last, with
weathered dark stone walls along their edges.

`CFrame.lookAt` is used for every sloped rail in this file. A stair rail is a box
whose length runs along the slope, and `lookAt(from, to)` puts the box's local Z on
that line with no hand-derived Euler angle to get wrong - the two flights in the
north alone are 39 degrees and 37 degrees, and a sign error in either one is a rail
that sprouts out of the platform.
]]
local function buildNorthMassif(parent: Instance)
	for index, terrace in ipairs(NORTH_TERRACES) do
		local height = terrace.Top - APRON_TOP
		local depth = terrace.Front - terrace.Back
		local midZ = (terrace.Front + terrace.Back) * 0.5

		makePart(
			parent,
			string.format("Terrace%d", index),
			Vector3.new(terrace.Half * 2, height, depth),
			CFrame.new(0, APRON_TOP + height * 0.5, midZ),
			COLOR_ASH_STONE,
			Enum.Material.Slate
		)

		--[[
		Merlons on the front edge, and they are the one detail that survives at
		distance: a flat 122-stud wall reads as a wall, and the same wall with a
		broken line of blocks along the top reads as a fortress. The first
		terrace's merlons deliberately crest at 28.6, just above the 27-stud
		courtyard wall in front of them, so they show as a serrated edge.
		]]
		local merlonCount = 16
		local span = terrace.Half * 2 - 10
		for merlon = 0, merlonCount - 1 do
			local x = -span * 0.5 + (merlon + 0.5) * (span / merlonCount)
			makePart(
				parent,
				"Merlon",
				Vector3.new(3.6, 3.2, 2.6),
				CFrame.new(x, terrace.Top + 1.6, terrace.Front - 1.6),
				COLOR_ASH_STONE_DARK,
				Enum.Material.Slate
			)
		end

		local buttressCount = 5
		for buttress = 0, buttressCount - 1 do
			local x = -terrace.Half + (buttress + 1) * (terrace.Half * 2 / (buttressCount + 1))
			makePart(
				parent,
				"Buttress",
				Vector3.new(5, height, 4),
				CFrame.new(x, APRON_TOP + height * 0.5, terrace.Front + 2),
				COLOR_ASH_STONE_DARK,
				Enum.Material.Basalt
			)
		end

		for _, side in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"Parapet",
				Vector3.new(3, 3.4, depth),
				CFrame.new(side * (terrace.Half - 1.5), terrace.Top + 1.7, midZ),
				COLOR_ASH_STONE_DARK,
				Enum.Material.Slate
			)
		end
	end

	--[[
	Two monumental flights, each climbing from one terrace's platform to the next.
	They zig-zag in Z rather than approaching the massif head on, because the only
	way to reach the first terrace's front face is across the arena.
	]]
	local flights = {
		{ BaseY = NORTH_TERRACES[1].Top, StartZ = -162, Steps = 16 },
		{ BaseY = NORTH_TERRACES[2].Top, StartZ = -192, Steps = 15 },
	}

	for _, flight in ipairs(flights) do
		local stepRise = 1.2
		local stepRun = 1.5
		for step = 0, flight.Steps - 1 do
			local y = flight.BaseY + step * stepRise
			makePart(
				parent,
				"StairStep",
				Vector3.new(12, stepRise, stepRun),
				CFrame.new(0, y + stepRise * 0.5, flight.StartZ - step * stepRun),
				COLOR_ASH_STONE_DARK,
				Enum.Material.Slate
			)
		end

		local topY = flight.BaseY + flight.Steps * stepRise
		local endZ = flight.StartZ - (flight.Steps - 1) * stepRun
		for _, side in ipairs({ -1, 1 }) do
			local from = Vector3.new(side * 7, flight.BaseY + 1.2, flight.StartZ + 1)
			local to = Vector3.new(side * 7, topY + 1.2, endZ - 1)
			local mid = (from + to) * 0.5
			makePart(
				parent,
				"StairRail",
				Vector3.new(1.2, 2.4, (to - from).Magnitude),
				CFrame.lookAt(mid, mid + (to - from)),
				COLOR_ASH_STONE,
				Enum.Material.Basalt
			)
		end
	end
end

--[[
The pagoda, on the third terrace.

Five decisions in here, all of them about reading from 200 studs away:

  * Charred timber (`WoodPlanks` in near-black) against a slate roof, with a
    single ember-red band at the base of every tier. That band is the only
    saturated colour in the region and it is what makes the silhouette legible:
    without it the whole tower is one dark value from top to bottom.
  * Every roof is a slab *plus four flared skirts*, the skirts tipped 18 degrees
    outward. Japanese roofs flare at the eaves, and four tipped slabs is the
    cheapest geometry that gets the read - the flare is the difference between a
    pagoda and a wedding cake.
  * The lattice on the two lower tiers' front faces only. It costs 14 parts and
    it is invisible past the third terrace; putting it on all four would be 28
    parts of detail nobody can resolve.
  * The tiers rise by 18 and are 16 tall, so the two-stud gap between them is
    exactly where each roof sits. A roof that overlaps its neighbour's wall is
    the classic z-fight in a stacked tower.
  * A spire instead of a fifth tier: the sight line wants height, not mass, and a
    thin finial reads as *far* where another solid tier would read as *near*.
]]
local function buildNorthPagoda(parent: Instance, baseY: number)
	makePart(
		parent,
		"PagodaPodium",
		Vector3.new(88, NORTH_PAGODA_PODIUM, 38),
		CFrame.new(0, baseY + NORTH_PAGODA_PODIUM * 0.5, NORTH_PAGODA_Z),
		COLOR_ASH_STONE,
		Enum.Material.Slate
	)

	local podiumTop = baseY + NORTH_PAGODA_PODIUM

	-- The approach up onto the podium, so the tower has a door to be reached by.
	for step = 0, 6 do
		makePart(
			parent,
			"PodiumStep",
			Vector3.new(16, 1.2, 1.4),
			CFrame.new(0, baseY + step * 1.2 + 0.6, NORTH_PAGODA_Z + 21 + (6 - step) * 1.4),
			COLOR_ASH_STONE_DARK,
			Enum.Material.Slate
		)
	end

	local y = podiumTop
	for index, width in ipairs(NORTH_TIER_WIDTHS) do
		local depth = width * 0.46
		local halfDepth = depth * 0.5

		makePart(
			parent,
			string.format("Tier%d", index),
			Vector3.new(width, NORTH_TIER_HEIGHT, depth),
			CFrame.new(0, y + NORTH_TIER_HEIGHT * 0.5, NORTH_PAGODA_Z),
			COLOR_CHARRED,
			Enum.Material.WoodPlanks
		)
		makePart(
			parent,
			string.format("Tier%dTrim", index),
			Vector3.new(width + 0.8, 1.2, depth + 0.8),
			CFrame.new(0, y + 0.6, NORTH_PAGODA_Z),
			COLOR_EMBER_TRIM,
			Enum.Material.SmoothPlastic
		)

		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				makePart(
					parent,
					"TierPost",
					Vector3.new(2.2, NORTH_TIER_HEIGHT, 2.2),
					CFrame.new(sx * (width * 0.5 - 1), y + NORTH_TIER_HEIGHT * 0.5, NORTH_PAGODA_Z + sz * (halfDepth - 1)),
					COLOR_TIMBER,
					Enum.Material.WoodPlanks
				)
			end
		end

		local roofY = y + NORTH_TIER_HEIGHT
		makePart(
			parent,
			string.format("Tier%dRoof", index),
			Vector3.new(width + 16, 1.8, depth + 14),
			CFrame.new(0, roofY + 0.9, NORTH_PAGODA_Z),
			COLOR_ROOF_SLATE,
			Enum.Material.Slate
		)

		-- Front and back skirts: rotating about X lowers the +Z edge, so the front
		-- skirt tips one way and the back skirt tips the other.
		for _, sz in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"RoofSkirt",
				Vector3.new(width + 30, 0.9, 9),
				CFrame.new(0, roofY + 0.2, NORTH_PAGODA_Z + sz * (halfDepth + 5.5))
					* CFrame.Angles(math.rad(18) * sz, 0, 0),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end
		for _, sx in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"RoofSkirt",
				Vector3.new(9, 0.9, depth + 26),
				CFrame.new(sx * (width * 0.5 + 5.5), roofY + 0.2, NORTH_PAGODA_Z)
					* CFrame.Angles(0, 0, math.rad(-18) * sx),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end

		if index <= 2 then
			local latticeWidth = width * 0.82
			for beam = 0, 5 do
				makePart(
					parent,
					"FacadeBeam",
					Vector3.new(1.4, NORTH_TIER_HEIGHT - 1.6, 1.4),
					CFrame.new(
						-latticeWidth * 0.5 + beam * (latticeWidth / 5),
						y + NORTH_TIER_HEIGHT * 0.5,
						NORTH_PAGODA_Z + halfDepth + 0.4
					),
					COLOR_TIMBER,
					Enum.Material.WoodPlanks
				)
			end
			makePart(
				parent,
				"FacadeBeam",
				Vector3.new(width * 0.86, 1.3, 1.4),
				CFrame.new(0, y + NORTH_TIER_HEIGHT * 0.55, NORTH_PAGODA_Z + halfDepth + 0.4),
				COLOR_TIMBER,
				Enum.Material.WoodPlanks
			)
		end

		y += NORTH_TIER_RISE
	end

	local spireBase = y - NORTH_TIER_RISE + NORTH_TIER_HEIGHT + 2
	makePart(parent, "SpireRod", Vector3.new(1.6, 14, 1.6), CFrame.new(0, spireBase + 7, NORTH_PAGODA_Z), COLOR_CHARRED, Enum.Material.WoodPlanks)
	for ring = 0, 2 do
		local ringWidth = 7 - ring * 1.8
		makePart(
			parent,
			"SpireRing",
			Vector3.new(ringWidth, 0.7, ringWidth),
			CFrame.new(0, spireBase + 3 + ring * 3.6, NORTH_PAGODA_Z),
			COLOR_GOLD_TRIM,
			Enum.Material.Metal
		)
	end
end

--[[
The north region, assembled.

The ground is `Material.Ground` in a burnt brown rather than stone: the terraces
above it are stone, and a stone plateau on a stone plain has no bottom edge. The
apron is the one surface in this file that is deliberately *large* - 300 by 228 -
because the baseplate underneath it is a 2048-stud grey plate, and a region that
stops at its own walls shows that plate from every long sight line.
]]
local function buildNorthFortress(parent: Instance)
	makePart(
		parent,
		"AshApron",
		Vector3.new(NORTH_APRON_HALF_X * 2, APRON_THICKNESS, NORTH_APRON_FRONT - NORTH_APRON_BACK),
		CFrame.new(0, APRON_TOP - APRON_THICKNESS * 0.5, (NORTH_APRON_FRONT + NORTH_APRON_BACK) * 0.5),
		COLOR_HILL_EARTH,
		Enum.Material.Ground
	)

	buildNorthMassif(parent)

	local topTerrace = NORTH_TERRACES[3]
	buildNorthPagoda(parent, topTerrace.Top)

	--[[
	Watchtowers on the top terrace's shoulders. They exist to widen the silhouette:
	the pagoda alone is a spike, and the two towers turn it into a fortress without
	adding a single stud of height.
	]]
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (topTerrace.Half - 12)
		makePart(parent, "Watchtower", Vector3.new(14, 30, 14), CFrame.new(x, topTerrace.Top + 15, -246), COLOR_ASH_STONE, Enum.Material.Slate)
		makePart(parent, "WatchtowerRoof", Vector3.new(19, 1.6, 19), CFrame.new(x, topTerrace.Top + 30.8, -246), COLOR_ROOF_SLATE, Enum.Material.Slate)
		for _, sx in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"WatchtowerSkirt",
				Vector3.new(8, 0.8, 20),
				CFrame.new(x + sx * 6, topTerrace.Top + 30.1, -246) * CFrame.Angles(0, 0, math.rad(-16) * sx),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end
		for _, sz in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"WatchtowerSkirt",
				Vector3.new(20, 0.8, 8),
				CFrame.new(x, topTerrace.Top + 30.1, -246 + sz * 6) * CFrame.Angles(math.rad(16) * sz, 0, 0),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end
		makeIronBrazier(parent, Vector3.new(x, topTerrace.Top + 34, -246), 1.3, false)
	end

	--[[
	The burning gate, on the second terrace's front face.

	It is a porch of solid dark stone rather than a hole, because a part cannot
	subtract one: at 30 studs it reads as a doorway with fire behind it, and that is
	all a doorway 200 studs away has ever needed to be.
	]]
	makePart(parent, "GatePorch", Vector3.new(38, 24, 3), CFrame.new(0, NORTH_TERRACES[2].Top - 15, NORTH_TERRACES[2].Front + 1.5), COLOR_ASH_STONE_DARK, Enum.Material.Basalt)
	for _, x in ipairs({ -14, -5, 5, 14 }) do
		makePart(parent, "GateBar", Vector3.new(0.9, 22, 0.9), CFrame.new(x, NORTH_TERRACES[2].Top - 15, NORTH_TERRACES[2].Front + 3.2), COLOR_IRON, Enum.Material.Metal)
	end
	makeIronBrazier(parent, Vector3.new(-13, NORTH_TERRACES[2].Top - 19, NORTH_TERRACES[2].Front + 3), 1.4, false)
	makeIronBrazier(parent, Vector3.new(13, NORTH_TERRACES[2].Top - 19, NORTH_TERRACES[2].Front + 3), 1.4, false)

	--[[
	The fires. On the top terrace they are what the spawn actually sees above the
	arena wall; on the two lower ones they are there for the player who has crossed
	the courtyard and is looking north over its far wall. `surfaceTop + 3` is the
	brazier helper's own convention: its pan sits three studs up so its splayed legs
	land on the surface rather than through it.
	]]
	local fires: { { x: number, y: number, z: number, scale: number, shadows: boolean } } = {
		{ x = -30, y = topTerrace.Top, z = -226, scale = 1.7, shadows = true },
		{ x = 30, y = topTerrace.Top, z = -226, scale = 1.7, shadows = false },
		{ x = -62, y = topTerrace.Top, z = -252, scale = 1.6, shadows = false },
		{ x = 62, y = topTerrace.Top, z = -252, scale = 1.6, shadows = false },
		{ x = 0, y = topTerrace.Top + NORTH_PAGODA_PODIUM, z = -230, scale = 2.1, shadows = true },
		{ x = -72, y = NORTH_TERRACES[2].Top, z = -198, scale = 1.5, shadows = false },
		{ x = 72, y = NORTH_TERRACES[2].Top, z = -198, scale = 1.5, shadows = false },
		{ x = -100, y = NORTH_TERRACES[1].Top, z = -170, scale = 1.4, shadows = false },
		{ x = 100, y = NORTH_TERRACES[1].Top, z = -170, scale = 1.4, shadows = false },
	}
	for _, fire in ipairs(fires) do
		makeIronBrazier(parent, Vector3.new(fire.x, fire.y + 3, fire.z), fire.scale, fire.shadows)
	end

	--[[
	Weather. One ash volume at 118 studs with a wide, slow fall, and three ember
	bands stacked under it at 70, 95 and 120. The embers are the part that matters
	from the spawn: ash falls *behind* the pagoda's roofline and is only visible
	where the sky is, while embers drift up past the silhouette and catch the light.
	]]
	local ash = phantomVolume(parent, "AshField", Vector3.new(300, 1, 170), Vector3.new(0, 118, -196))
	makeAshEmitter(ash, "AshFall", 20)
	for index, y in ipairs({ 70, 95, 120 }) do
		local embers = phantomVolume(
			parent,
			string.format("EmberDrift%d", index),
			Vector3.new(230, 1, 110),
			Vector3.new(0, y, -200 - (index - 1) * 22)
		)
		makeEmberEmitter(embers, "Embers", 7, NumberRange.new(5, 9))
	end

	makeZone(
		parent,
		"Arena1Zone",
		Vector3.new(90, 40, 90),
		Vector3.new(Arena.Center.X, 20, Arena.Center.Z),
		1,
		"The Burning Ash Fortress",
		"North"
	)
end

--===========================================================================
-- S5 - EAST: THE WHISPERING BAMBOO GROVE  (behind Gate 2)
--===========================================================================

--[[
The grove has two altitudes and they are answering two different questions.

The *flat* grove, from the gate out to about 130 studs, is the one the player
walks into: clusters of 35-to-45-stud culms with a stone path through them, stone
lanterns, and a floor of mossy earth. It is what the east gate frames at eye
level, and it is why the gate is worth walking through.

The *hillside* behind it rises in three tiers to 65 studs with its own bamboo on
top, which puts the grove's skyline at about 110 - over the top of the eastern
torii but under the north fortress's pagoda. Without it the east side of the
panorama is a green band that stops at the gate's lintel; with it, the grove has
a *top*, and the eye reads distance rather than a hedge.
]]
local EAST_APRON_NEAR: number = 44
local EAST_APRON_FAR: number = 268
local EAST_APRON_HALF_Z: number = 130

type BambooHill = {
	Center: Vector3,
	Size: Vector3,
}

local EAST_HILLS: { BambooHill } = {
	{ Center = Vector3.new(188, 10, 0), Size = Vector3.new(156, 20, 220) },
	{ Center = Vector3.new(200, 31.5, 0), Size = Vector3.new(120, 23, 170) },
	{ Center = Vector3.new(212, 53.5, 0), Size = Vector3.new(80, 21, 120) },
}

--[[
Eight cluster centres, hand-placed rather than random. A seeded scatter of culms
produces an even forest, and an even forest reads as a texture; eight clumps with
gaps between them is what a bamboo grove actually looks like, and the gaps are
where the player walks and where the light falls through.
]]
local EAST_CLUSTERS: { Vector2 } = {
	Vector2.new(64, -54),
	Vector2.new(78, -18),
	Vector2.new(62, 22),
	Vector2.new(84, 58),
	Vector2.new(98, -62),
	Vector2.new(112, -8),
	Vector2.new(104, 40),
	Vector2.new(124, 66),
}

--[[
One culm, in segments.

Bamboo's whole read is the *node*: a stalk of constant width is a pole, and a
stalk of three telescoping sections with a step at each joint is bamboo, from any
distance, with no textures at all. Three sections for the culms the player walks
among, two for the hillside where the joint is three pixels wide.

Cylinders are cylindrical about their local X, so `makeCylinder` does the quarter
turn - see the note on that helper for what happens when it is left out.
]]
local function makeCulm(parent: Instance, base: Vector3, height: number, segments: number, rng: Random)
	local yaw = rng:NextNumber(0, math.pi * 2)
	local lean = rng:NextNumber(-0.035, 0.035)
	local diameter = rng:NextNumber(1.2, 1.6)
	local sectionHeight = height / segments
	local y = base.Y

	for segment = 1, segments do
		local color = if segment == segments then COLOR_CULM_YOUNG else COLOR_CULM
		local culm = makeCylinder(
			parent,
			"Culm",
			sectionHeight + 0.4,
			diameter * (1 - (segment - 1) * 0.085),
			Vector3.new(base.X, y, base.Z),
			yaw,
			lean,
			color,
			Enum.Material.Wood
		)
		decorative(culm, true)
		y += sectionHeight
	end
end

local function makeCulmCluster(parent: Instance, center: Vector3, count: number, segments: number, rng: Random, leafEvery: number)
	for culm = 1, count do
		local angle = (culm / count) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local radius = if culm % 2 == 0 then rng:NextNumber(3.5, 6.5) else rng:NextNumber(8.5, 13)
		local x = center.X + math.cos(angle) * radius
		local z = center.Z + math.sin(angle) * radius
		local height = rng:NextNumber(35, 45)

		makeCulm(parent, Vector3.new(x, center.Y, z), height, segments, rng)

		if culm % leafEvery == 0 then
			local leaves = makePart(
				parent,
				"CulmLeaves",
				Vector3.new(6, 0.5, 6),
				CFrame.new(x, center.Y + height - 1.2, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				COLOR_LEAF,
				Enum.Material.LeafyGrass
			)
			decorative(leaves, true)
			makePart(
				parent,
				"CulmLeaves",
				Vector3.new(4.4, 0.5, 4.4),
				CFrame.new(x, center.Y + height - 4.6, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				COLOR_LEAF,
				Enum.Material.LeafyGrass
			)
		end
	end
end

--[[
A mossy stone lantern: base, pillar, light box, roof and two tipped eaves.

Six parts and, on half of them, one point light. The light is `Shadows = false`
deliberately - a shadow-casting light inside a grove of 400 shadow casters is the
one place in this file where the cost is real and the return is a pattern of bars
on the ground nobody will look at.
]]
local function makeStoneLantern(parent: Instance, x: number, z: number, groundY: number, lit: boolean, phase: number)
	makePart(parent, "LanternBase", Vector3.new(2.8, 0.7, 2.8), CFrame.new(x, groundY + 0.35, z), COLOR_MOSS_STONE, Enum.Material.Rock)
	makeCylinder(parent, "LanternPillar", 3.2, 1.1, Vector3.new(x, groundY + 0.7, z), 0, 0, COLOR_MOSS_STONE, Enum.Material.Rock)
	makePart(parent, "LanternBox", Vector3.new(2.2, 1.9, 2.2), CFrame.new(x, groundY + 4.85, z), COLOR_MOSS_STONE, Enum.Material.Rock)

	local window = makePart(
		parent,
		"LanternWindow",
		Vector3.new(1.5, 1.1, 2.35),
		CFrame.new(x, groundY + 4.85, z),
		Color3.fromRGB(255, 206, 138),
		Enum.Material.Neon
	)
	window.Transparency = if lit then 0.2 else 0.72

	makePart(parent, "LanternRoof", Vector3.new(3.6, 0.6, 3.6), CFrame.new(x, groundY + 6.1, z), COLOR_MOSS_STONE, Enum.Material.Rock)
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			parent,
			"LanternEave",
			Vector3.new(2.1, 0.5, 3.9),
			CFrame.new(x + side * 1.7, groundY + 5.7, z) * CFrame.Angles(0, 0, math.rad(-14) * side),
			COLOR_MOSS_STONE,
			Enum.Material.Rock
		)
	end

	if lit then
		local light = makeLight(window, 1.5, 24, Color3.fromRGB(255, 188, 122), false)
		makeFlicker(light, 0.06, 0.9, phase)
	end
end

local function buildEastGrove(parent: Instance, rng: Random)
	makePart(
		parent,
		"MossApron",
		Vector3.new(EAST_APRON_FAR - EAST_APRON_NEAR, APRON_THICKNESS, EAST_APRON_HALF_Z * 2),
		CFrame.new((EAST_APRON_NEAR + EAST_APRON_FAR) * 0.5, APRON_TOP - APRON_THICKNESS * 0.5, 0),
		COLOR_HILL_EARTH,
		Enum.Material.Ground
	)

	--[[
	The path in, curving. Its slabs' tops land at 1.08 against the hub floor's 1.00,
	so walking east out of the sanctuary is a step down of two tenths and then a
	flat walk, with no seam left for the eye to trip on.
	]]
	for slab = 0, 13 do
		local x = 54 + slab * 5.2
		local z = math.sin(slab * 0.34) * 10
		local stone = makePart(
			parent,
			"PathSlab",
			Vector3.new(3.4, 0.35, 7),
			CFrame.new(x, APRON_TOP + 0.18, z) * CFrame.Angles(0, math.cos(slab * 0.34) * 0.14, 0),
			COLOR_MOSS_STONE,
			Enum.Material.Cobblestone
		)
		stone.CanTouch = false
		stone.CanQuery = false
	end

	--[[
	The hillside, as three stacked blocks. `Material.Ground` for all three so the
	terraces read as one landform rather than as a staircase of platforms, and each
	tier's colour lifts a notch - a hill that is one flat value from its base to its
	top has no readable depth under a low warm sun.
	]]
	for index, hill in ipairs(EAST_HILLS) do
		local earth = makePart(
			parent,
			"GroveHill",
			hill.Size,
			CFrame.new(hill.Center),
			COLOR_HILL_EARTH:Lerp(COLOR_MOSS_STONE, index * 0.12),
			Enum.Material.Ground
		)
		earth.CanTouch = false
	end

	for _, cluster in ipairs(EAST_CLUSTERS) do
		makeCulmCluster(parent, Vector3.new(cluster.X, APRON_TOP, cluster.Y), 13, 3, rng, 2)
	end

	--[[
	The hillside's own bamboo: two sections per culm and a leaf cluster every third.
	At 150 studs both the joint and the leaves are sub-pixel, and three-section
	bamboo up there would be 120 parts spent on detail nobody can resolve.
	]]
	for index, hill in ipairs(EAST_HILLS) do
		local top = hill.Center.Y + hill.Size.Y * 0.5
		for culm = 1, 14 do
			local x = hill.Center.X + rng:NextNumber(-hill.Size.X * 0.5 + 8, hill.Size.X * 0.5 - 8)
			local z = rng:NextNumber(-hill.Size.Z * 0.5 + 8, hill.Size.Z * 0.5 - 8)
			local height = rng:NextNumber(35, 45)
			makeCulm(parent, Vector3.new(x, top, z), height, 2, rng)
			if culm % 3 == 0 then
				decorative(
					makePart(
						parent,
						"LeafCanopy",
						Vector3.new(7, 0.6, 7),
						CFrame.new(x, top + height - 1.4, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
						COLOR_LEAF,
						Enum.Material.LeafyGrass
					),
					true
				)
			end
		end
		decorative(
			makePart(
				parent,
				"LeafCanopy",
				Vector3.new(hill.Size.X - 4, 1.4, hill.Size.Z - 4),
				CFrame.new(hill.Center.X, top + 33 + index * 3, hill.Center.Z),
				COLOR_LEAF:Lerp(COLOR_HILL_EARTH, 0.25),
				Enum.Material.LeafyGrass
			),
			true
		)
	end

	--[[
	Six rafts of leaves across the walkable grove at 34 to 40 studs. They are the
	reason the grove is *whispering* rather than merely green: under a low sun a flat
	canopy at head height drops moving shadow on everything below it, and it gives
	the fireflies something to be bright against.
	]]
	for raft = 0, 5 do
		decorative(
			makePart(
				parent,
				"LeafCanopy",
				Vector3.new(rng:NextNumber(26, 44), 0.6, rng:NextNumber(26, 44)),
				CFrame.new(66 + raft * 11, 34 + rng:NextNumber(0, 6), rng:NextNumber(-50, 50))
					* CFrame.Angles(rng:NextNumber(-0.06, 0.06), rng:NextNumber(0, math.pi), rng:NextNumber(-0.06, 0.06)),
				COLOR_LEAF,
				Enum.Material.LeafyGrass
			),
			true
		)
	end

	local lanternSpots: { Vector2 } = {
		Vector2.new(58, -9),
		Vector2.new(70, 11),
		Vector2.new(82, -3),
		Vector2.new(94, 16),
		Vector2.new(106, 4),
		Vector2.new(118, -12),
		Vector2.new(74, -34),
		Vector2.new(96, 36),
		Vector2.new(120, 52),
		Vector2.new(130, -40),
	}
	for index, spot in ipairs(lanternSpots) do
		makeStoneLantern(parent, spot.X, spot.Y, APRON_TOP, index % 2 == 1, index * 0.9)
	end

	for boulder = 0, 7 do
		--[[
		Along the length of the grove, not around it. Scattering boulders on a circle
		around the path put two of them at x = 29 and x = 36, which is *inside the
		SanctuaryHub floor* - a pair of solid, colliding rocks standing in the middle
		of the courtyard the player spawns in.
		]]
		local x = 62 + boulder * 7.5
		local z = math.sin(boulder * 1.1) * 52
		local rock = makePart(
			parent,
			"MossBoulder",
			Vector3.new(rng:NextNumber(5, 10), rng:NextNumber(3, 6), rng:NextNumber(5, 10)),
			CFrame.new(x, APRON_TOP + 1.6, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), rng:NextNumber(-0.14, 0.14)),
			COLOR_MOSS_STONE,
			Enum.Material.Rock
		)
		-- Collides but is invisible to spatial queries: something to stand on, never
		-- something that eats a swing.
		rock.CanTouch = false
		rock.CanQuery = false
	end

	--[[
	Jade fireflies. `LightInfluence = 0` and `LightEmission = 1` because a firefly is
	a light source rather than a lit object, and `Drag = 0.9` against a slow `Speed`
	is the whole difference between "particles rising" and "insects drifting".
	]]
	local fireflySpots: { Vector3 } = {
		Vector3.new(72, 9, -40),
		Vector3.new(92, 11, 18),
		Vector3.new(108, 9, -58),
		Vector3.new(86, 12, 48),
		Vector3.new(126, 13, -12),
		Vector3.new(140, 11, 62),
	}
	for _, spot in ipairs(fireflySpots) do
		local volume = phantomVolume(parent, "FireflyField", Vector3.new(28, 14, 28), spot)
		makeEmitter(volume, "JadeFireflies", TEXTURE_SPARK, {
			Rate = 9,
			Lifetime = NumberRange.new(7, 12),
			Speed = NumberRange.new(0.4, 1.7),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.15),
				NumberSequenceKeypoint.new(0.4, 0.42),
				NumberSequenceKeypoint.new(1, 0.1),
			}),
			Color = ColorSequence.new(Color3.fromRGB(138, 255, 196)),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.15),
				NumberSequenceKeypoint.new(0.75, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			}),
			LightInfluence = 0,
			LightEmission = 1,
			Acceleration = Vector3.new(0.3, 0.12, 0.4),
			Drag = 0.9,
			SpreadAngle = Vector2.new(180, 180),
			EmissionDirection = Enum.NormalId.Bottom,
		})
	end

	makeZone(
		parent,
		"BambooGroveZone",
		Vector3.new(216, 70, 240),
		Vector3.new(164, 35, 0),
		2,
		"The Whispering Bamboo Grove",
		"East"
	)
end

--===========================================================================
-- S6 - WEST: THE SUNKEN PAGODA  (behind Gate 3)
--===========================================================================

--[[
Water, without terrain.

The obvious way to build a flooded courtyard is `Terrain:FillBlock(..., Water)`,
and it does not work here for two independent reasons. `Enum.Material.Water` is
documented "Applies to Terrain only", and terrain water's surface is locked to
y = 0 - which is precisely where this place's 2048-stud `Baseplate` has its top
face. A pool carved at y = 0 would be a pool inside the baseplate.

So the water is a *part*: a thin dark slab with `Reflectance` on it. That is not a
compromise, it is the right tool for this shot. Reflectance reflects the skybox,
and the sun in this scene is 17:30 at latitude 45 - low, warm and directly down
the west gate - so the water reads as a sheet of beaten gold with the pagoda black
in front of it, and it does that for the cost of one part.

Three things make it read as water rather than as a mirror:

  * A rim wall, so the water is visibly *in* something. A water plane that ends in
    mid-air at a cliff edge reads as a rendering error.
  * Ruins crossing the waterline. Nothing tells the eye where a surface is like
    something half-drowned in it, and a flat reflective plane with no object
    intersecting it has no depth at all.
  * A 0.9-stud depth of *opaque* basin floor under 1.3 studs of water, in near
    black, so the water has a bottom tone to be transparent against.
]]
local WEST_APRON_NEAR: number = -44
local WEST_APRON_FAR: number = -272
local WEST_APRON_HALF_Z: number = 140

local WEST_BASIN_NEAR: number = -58
local WEST_BASIN_FAR: number = -218
local WEST_BASIN_HALF_Z: number = 78

local WEST_BASIN_FLOOR_TOP: number = 0.05
local WEST_RIM_TOP: number = 1.35
local WEST_WATER_TOP: number = 0.95
local WEST_DOCK_TOP: number = 3.3

--[[
A weeping willow.

The trunk is two telescoping cylinders and the canopy is five flat plates, which
is three parts more than a hill tree needs - what makes a willow a willow is the
*twelve strands* hanging off the canopy's rim, and those are what the palette and
the count below are chosen for: long, thin, near-vertical, in a yellow-green that
reads as backlit against the water.

The strands are `CanQuery = false` and `CanCollide = false` like all scenery, and
they hang low enough to brush the water without touching it.
]]
local function makeWillow(parent: Instance, x: number, z: number, groundY: number, rng: Random)
	makeCylinder(parent, "WillowTrunk", 9, 3.4, Vector3.new(x, groundY, z), 0, 0, COLOR_TIMBER, Enum.Material.Wood)
	makeCylinder(parent, "WillowTrunk", 8, 2.2, Vector3.new(x, groundY + 8.4, z), 0, 0, COLOR_TIMBER, Enum.Material.Wood)

	for plate = 0, 4 do
		local angle = plate * 1.25
		local radius = if plate == 0 then 0 else 4.6
		decorative(
			makePart(
				parent,
				"WillowCanopy",
				Vector3.new(rng:NextNumber(12, 17), 1.2, rng:NextNumber(12, 17)),
				CFrame.new(
					x + math.cos(angle) * radius,
					groundY + 16 + plate * 0.9,
					z + math.sin(angle) * radius
				) * CFrame.Angles(rng:NextNumber(-0.05, 0.05), angle, rng:NextNumber(-0.05, 0.05)),
				COLOR_WILLOW,
				Enum.Material.LeafyGrass
			),
			true
		)
	end

	for strand = 1, 12 do
		local angle = (strand / 12) * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
		local radius = rng:NextNumber(6.5, 10)
		local length = rng:NextNumber(10, 22)
		decorative(
			makePart(
				parent,
				"WillowStrand",
				Vector3.new(0.7, length, 0.7),
				CFrame.new(
					x + math.cos(angle) * radius,
					groundY + 15 - length * 0.5,
					z + math.sin(angle) * radius
				) * CFrame.Angles(math.sin(angle) * 0.16, 0, -math.cos(angle) * 0.16),
				COLOR_WILLOW:Lerp(COLOR_GOLD_TRIM, rng:NextNumber(0, 0.25)),
				Enum.Material.LeafyGrass
			),
			true
		)
	end
end

--[[
A floating water lantern: one Neon box, one warm point light, and a two-and-a-half
second bob.

One part, not a base and a paper hood welded together, and the reason is that a
`WeldConstraint` between two *anchored* parts does not move the second one. The
alternatives are an unanchored lantern (physics, forever, for a decoration) or two
tweens that can drift a frame apart. One part cannot come apart from itself.
]]
local function makeWaterLantern(parent: Instance, x: number, z: number, phase: number, bobbing: boolean): Part
	local lantern = makePart(
		parent,
		"WaterLantern",
		Vector3.new(0.9, 1.1, 0.9),
		CFrame.new(x, WEST_WATER_TOP + 0.4, z),
		COLOR_LANTERN_PAPER,
		Enum.Material.Neon
	)
	lantern.Transparency = 0.12
	lantern.CanTouch = false
	lantern.CanQuery = false

	local light = makeLight(lantern, 1.1, 18, Color3.fromRGB(255, 172, 96), false)
	makeFlicker(light, 0.07, 1.1, phase)

	if bobbing then
		makeBob(lantern, 0.14, 2.6 + phase * 0.3, phase)
	end
	return lantern
end

--[[
The flooded courtyard itself: four apron bands, the basin floor, the rim, the
water, and the ruins that cross it.

The bands are four parts rather than one plate with the water on top, because the
water is 0.9 studs *below* the apron and a plate under both would show through the
water's transparency as a lighter layer - the basin has to be a hole in the ground,
and a hole is built out of edges.
]]
local function buildWestBasin(parent: Instance)
	local floorHalfZ = WEST_BASIN_HALF_Z
	local basinWidth = WEST_BASIN_NEAR - WEST_BASIN_FAR

	-- The near band, tucked under the hub floor so walking west is a step down of
	-- one tenth of a stud and not a seam.
	makePart(
		parent,
		"SunkenApron",
		Vector3.new(WEST_APRON_NEAR - WEST_BASIN_NEAR, APRON_THICKNESS, WEST_APRON_HALF_Z * 2),
		CFrame.new((WEST_APRON_NEAR + WEST_BASIN_NEAR) * 0.5, APRON_TOP - APRON_THICKNESS * 0.5, 0),
		COLOR_BASIN_STONE,
		Enum.Material.Slate
	)
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			parent,
			"SunkenApron",
			Vector3.new(basinWidth, APRON_THICKNESS, WEST_APRON_HALF_Z - floorHalfZ),
			CFrame.new(
				(WEST_BASIN_NEAR + WEST_BASIN_FAR) * 0.5,
				APRON_TOP - APRON_THICKNESS * 0.5,
				side * (floorHalfZ + (WEST_APRON_HALF_Z - floorHalfZ) * 0.5)
			),
			COLOR_BASIN_STONE,
			Enum.Material.Slate
		)
	end
	--[[
	The far bank. `WEST_BASIN_FAR - WEST_APRON_FAR`, not the other way round: every
	west coordinate is negative and the far bank is the *more* negative one, so the
	obvious expression evaluates to -54 and a part cannot have a negative size - it
	silently clamps to 0.05, and 54 studs of far shore quietly disappears back onto
	the bare `Baseplate`. Caught by raycasting the ground, not by looking at it.
	]]
	makePart(
		parent,
		"SunkenApron",
		Vector3.new(WEST_BASIN_FAR - WEST_APRON_FAR + 2, APRON_THICKNESS, WEST_APRON_HALF_Z * 2),
		CFrame.new((WEST_BASIN_FAR + WEST_APRON_FAR) * 0.5, APRON_TOP - APRON_THICKNESS * 0.5, 0),
		COLOR_BASIN_STONE,
		Enum.Material.Slate
	)

	--[[
	The basin floor. Its top face is 0.05, which is five hundredths of a stud above
	the baseplate's top face at 0 - the one place in this file where the geometry is
	chosen by what is *under* it: a floor any lower would show the baseplate through
	the water, and a floor exactly at 0 would z-fight with it.
	]]
	local floorTop = makePart(
		parent,
		"BasinFloor",
		Vector3.new(basinWidth - 2, 2, floorHalfZ * 2 - 2),
		CFrame.new((WEST_BASIN_NEAR + WEST_BASIN_FAR) * 0.5, WEST_BASIN_FLOOR_TOP - 1, 0),
		Color3.fromRGB(14, 17, 20),
		Enum.Material.Slate
	)
	floorTop.CanTouch = false

	-- The rim: a 1.3-stud stone lip around all four sides, holding the water in.
	local rimThickness = 1.8
	makePart(
		parent,
		"BasinRim",
		Vector3.new(rimThickness, WEST_RIM_TOP - WEST_BASIN_FLOOR_TOP, floorHalfZ * 2 + rimThickness),
		CFrame.new(WEST_BASIN_NEAR, (WEST_RIM_TOP + WEST_BASIN_FLOOR_TOP) * 0.5, 0),
		COLOR_BASIN_STONE,
		Enum.Material.Basalt
	)
	makePart(
		parent,
		"BasinRim",
		Vector3.new(rimThickness, WEST_RIM_TOP - WEST_BASIN_FLOOR_TOP, floorHalfZ * 2 + rimThickness),
		CFrame.new(WEST_BASIN_FAR, (WEST_RIM_TOP + WEST_BASIN_FLOOR_TOP) * 0.5, 0),
		COLOR_BASIN_STONE,
		Enum.Material.Basalt
	)
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			parent,
			"BasinRim",
			Vector3.new(basinWidth + rimThickness, WEST_RIM_TOP - WEST_BASIN_FLOOR_TOP, rimThickness),
			CFrame.new((WEST_BASIN_NEAR + WEST_BASIN_FAR) * 0.5, (WEST_RIM_TOP + WEST_BASIN_FLOOR_TOP) * 0.5, side * floorHalfZ),
			COLOR_BASIN_STONE,
			Enum.Material.Basalt
		)
	end

	--[[
	The water. `CanCollide = false` and `CanQuery = false`: the player wades *in* it
	on the basin floor, ankle deep, and a queryable water sheet under a swinging
	katana would be the worst possible neighbour for a hitbox. Reflectance at 0.42
	is the whole look; the tint is nearly black because the sky it reflects is not.
	]]
	local water = makePart(
		parent,
		"SunkenWater",
		Vector3.new(basinWidth - rimThickness * 2, 0.3, floorHalfZ * 2 - rimThickness * 2),
		CFrame.new((WEST_BASIN_NEAR + WEST_BASIN_FAR) * 0.5, WEST_WATER_TOP - 0.15, 0),
		COLOR_WATER,
		Enum.Material.SmoothPlastic
	)
	water.Reflectance = 0.42
	water.Transparency = 0.12
	water.CanCollide = false
	water.CanTouch = false
	water.CanQuery = false
	water.CastShadow = false
	water.TopSurface = Enum.SurfaceType.Smooth

	--[[
	The drowned ruins. Six pillars and two fallen columns, all of them crossing the
	waterline on purpose: they are the depth cue that turns the reflective slab into
	a body of water, and they are also what tells the player where the basin's edges
	are without a single line of UI.
	]]
	local ruinedPillars: { Vector3 } = {
		Vector3.new(-72, 0, -44),
		Vector3.new(-70, 0, 38),
		Vector3.new(-96, 0, -62),
		Vector3.new(-124, 0, 58),
		Vector3.new(-186, 0, -40),
		Vector3.new(-202, 0, 46),
	}
	for index, spot in ipairs(ruinedPillars) do
		local height = 6 + (index % 3) * 2.5
		local pillar = makePart(
			parent,
			"DrownedPillar",
			Vector3.new(3.2, height, 3.2),
			CFrame.new(spot.X, WEST_BASIN_FLOOR_TOP + height * 0.5, spot.Z) * CFrame.Angles(0, index * 0.6, 0),
			COLOR_BASIN_STONE,
			Enum.Material.Basalt
		)
		pillar.CanTouch = false
		-- A submerged half, in the darker tone: the water is only 0.12 transparent, and
		-- a pillar that is one flat colour all the way down has no waterline.
		local submerged = makePart(
			parent,
			"DrownedPillarFoot",
			Vector3.new(3.6, WEST_WATER_TOP, 3.6),
			CFrame.new(spot.X, WEST_BASIN_FLOOR_TOP + WEST_WATER_TOP * 0.5, spot.Z),
			Color3.fromRGB(20, 24, 28),
			Enum.Material.Basalt
		)
		submerged.CanTouch = false
		submerged.CanQuery = false
	end

	for index, spot in ipairs({ Vector3.new(-88, 0, -16), Vector3.new(-150, 0, 52) }) do
		--[[
		`makeCylinder` rotates the cylinder about the point it is handed, so a column
		lying down is handed a base 13 studs *below* where its centre should be. A
		fallen column's centre belongs 1.9 up: half its diameter, resting on the
		basin floor, with the waterline crossing it.
		]]
		local fallen = makeCylinder(
			parent,
			"FallenColumn",
			26,
			3.6,
			Vector3.new(spot.X, 1.9 - 13, spot.Z),
			index * 1.1,
			math.rad(88),
			COLOR_BASIN_STONE,
			Enum.Material.Basalt
		)
		fallen.CanTouch = false
		fallen.CanQuery = false
	end
end

--[[
A dock run.

`alongZ` is the only parameter that differs between the pier out into the basin and
the walkway that crosses it, and it exists so that both are the *same* thirty parts
of geometry built by the same loop. Two copies of this code would be two places to
fix the day the dock needs to be wider.
]]
local function makeDockRun(parent: Instance, along0: number, along1: number, cross: number, alongZ: boolean)
	local length = math.abs(along1 - along0)
	local middle = (along0 + along1) * 0.5
	local width = 9

	local function dim(alongSize: number, crossSize: number, height: number): Vector3
		return if alongZ then Vector3.new(crossSize, height, alongSize) else Vector3.new(alongSize, height, crossSize)
	end
	local function at(alongPos: number, crossPos: number, y: number): Vector3
		return if alongZ then Vector3.new(crossPos, y, alongPos) else Vector3.new(alongPos, y, crossPos)
	end

	-- Two longitudinal beams, then cross planks over them: a deck that reads as
	-- planks rather than as one board, for one extra part every 2.6 studs.
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			parent,
			"DockBeam",
			dim(length, 1.5, 0.6),
			CFrame.new(at(middle, cross + side * (width * 0.5 - 0.8), WEST_DOCK_TOP - 0.3)),
			COLOR_DOCK_WOOD,
			Enum.Material.WoodPlanks
		)
	end

	local plankCount = math.floor(length / 2.6)
	for plank = 0, plankCount - 1 do
		local alongPos = along0 + (if along1 > along0 then 1 else -1) * (1.3 + plank * 2.6)
		makePart(
			parent,
			"DockPlank",
			dim(2.2, width, 0.4),
			CFrame.new(at(alongPos, cross, WEST_DOCK_TOP - 0.2)),
			COLOR_DOCK_WOOD:Lerp(COLOR_MOSS_STONE, (plank % 3) * 0.07),
			Enum.Material.WoodPlanks
		)
	end

	-- Posts, down past the waterline to the basin floor, which is what makes a dock
	-- a pier instead of a floating platform.
	local postCount = math.max(2, math.floor(length / 8))
	for post = 0, postCount do
		local alongPos = along0 + (post / postCount) * (along1 - along0)
		for _, side in ipairs({ -1, 1 }) do
			local pile = makePart(
				parent,
				"DockPost",
				dim(0.9, 0.9, WEST_DOCK_TOP - WEST_BASIN_FLOOR_TOP),
				CFrame.new(at(alongPos, cross + side * (width * 0.5 - 0.6), (WEST_BASIN_FLOOR_TOP + WEST_DOCK_TOP) * 0.5)),
				COLOR_DOCK_WOOD,
				Enum.Material.Wood
			)
			pile.CanTouch = false
			pile.CanQuery = false
		end
	end

	-- One rail, on one side only: a dock with both rails reads as a bridge, and
	-- wading the shallows alongside it is the point of the basin.
	makePart(
		parent,
		"DockRail",
		dim(length, 0.4, 0.4),
		CFrame.new(at(middle, cross + width * 0.5 - 0.4, WEST_DOCK_TOP + 1.5)),
		COLOR_DOCK_WOOD,
		Enum.Material.Wood
	)
end

--[[
The Sunken Pagoda itself: three tiers and the stump of a fourth, leaning 2.6
degrees off vertical and standing in 1.3 studs of water.

Everything is placed in the tilted frame - `at(localY)` - rather than in world
space, which is the only reason a leaning tower is not forty separate hand-tuned
rotations that disagree about where the next tier goes. The lean is 2.6 degrees:
about 1.4 studs of offset over the tower's height, enough to read as subsidence and
small enough that the roofs still line up.
]]
local function buildSunkenPagoda(parent: Instance)
	local base = CFrame.new(-152, WEST_BASIN_FLOOR_TOP, 0) * CFrame.Angles(0, -0.22, math.rad(-2.6))
	local function at(localY: number): CFrame
		return base * CFrame.new(0, localY, 0)
	end

	makePart(parent, "SunkenPagodaBase", Vector3.new(46, 6, 46), at(3), COLOR_BASIN_STONE, Enum.Material.Slate)

	local tierWidths: { number } = { 38, 32, 26 }
	local y = 6
	for index, width in ipairs(tierWidths) do
		local depth = width * 0.94
		makePart(
			parent,
			string.format("SunkenTier%d", index),
			Vector3.new(width, 20, depth),
			at(y + 10),
			COLOR_CHARRED,
			Enum.Material.WoodPlanks
		)
		makePart(
			parent,
			string.format("SunkenTier%dTrim", index),
			Vector3.new(width + 0.8, 1.2, depth + 0.8),
			at(y + 0.6),
			COLOR_CRIMSON,
			Enum.Material.SmoothPlastic
		)

		local roofY = y + 20
		makePart(parent, "SunkenRoof", Vector3.new(width + 15, 1.8, depth + 13), at(roofY + 0.9), COLOR_ROOF_SLATE, Enum.Material.Slate)
		for _, sz in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"SunkenRoofSkirt",
				Vector3.new(width + 28, 0.9, 9),
				at(roofY + 0.2) * CFrame.new(0, 0, sz * (depth * 0.5 + 5.5)) * CFrame.Angles(math.rad(19) * sz, 0, 0),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end
		for _, sx in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"SunkenRoofSkirt",
				Vector3.new(9, 0.9, depth + 24),
				at(roofY + 0.2) * CFrame.new(sx * (width * 0.5 + 5.5), 0, 0) * CFrame.Angles(0, 0, math.rad(-19) * sx),
				COLOR_ROOF_SLATE,
				Enum.Material.Slate
			)
		end

		--[[
		A dark standing window on the front face of the two sound tiers, and the bay
		of the third that is *gone*. A tower that is only tilted reads as one somebody
		built badly; a tower with a collapsed bay reads as one that is sinking, and the
		collapse is the part the eye finds first.
		]]
		if index < 3 then
			local window = makePart(
				parent,
				"SunkenWindow",
				Vector3.new(width * 0.34, 6, 1.2),
				at(y + 13) * CFrame.new(0, 0, depth * 0.5 + 0.3),
				Color3.fromRGB(24, 20, 19),
				Enum.Material.SmoothPlastic
			)
			window.CanTouch = false
			window.CanQuery = false
		end

		y += 20
	end

	-- The stump of the fourth tier: one wall standing, the rest gone. Three parts,
	-- and the whole story of the region.
	local stumpY = y
	makePart(parent, "PagodaStump", Vector3.new(24, 9, 2.4), at(stumpY + 4.5) * CFrame.Angles(math.rad(-7), 0, 0), COLOR_CHARRED, Enum.Material.WoodPlanks)
	makePart(parent, "PagodaStump", Vector3.new(2.4, 7, 20), at(stumpY + 3.5) * CFrame.Angles(math.rad(5), 0, 0), COLOR_CHARRED, Enum.Material.WoodPlanks)
	makePart(parent, "SunkenSpire", Vector3.new(1.6, 12, 1.6), at(stumpY + 8), COLOR_CHARRED, Enum.Material.WoodPlanks)
	for ring = 0, 2 do
		local ringWidth = 6.5 - ring * 1.7
		makePart(
			parent,
			"SpireRing",
			Vector3.new(ringWidth, 0.7, ringWidth),
			at(stumpY + 5 + ring * 3.4),
			COLOR_GOLD_TRIM,
			Enum.Material.Metal
		)
	end
end

--[[
The west region, assembled.

Access is deliberately awkward, and that is the region's character: from the hub
the player steps down onto the apron, over a 0.45-stud stone lip, and into ankle
deep water, or takes four steps up onto the wooden pier and crosses dry. Two routes
into the same courtyard, one of which is a wade, is the whole *feel* of a flooded
place, and it costs four step parts.
]]
local function buildWestSunken(parent: Instance, rng: Random)
	buildWestBasin(parent)

	-- Steps from the apron (0.9) up to the deck (3.3), four of them, so the pier is
	-- reachable on foot without a jump.
	for step = 0, 3 do
		makePart(
			parent,
			"DockStep",
			Vector3.new(1.6, 0.6, 9),
			CFrame.new(-52.4 - step * 1.6, APRON_TOP + 0.3 + step * 0.6, 0),
			COLOR_BASIN_STONE,
			Enum.Material.Cobblestone
		)
	end

	-- The pier out into the basin, the walkway that crosses it, and the viewing
	-- platform past the pagoda's shoulder.
	makeDockRun(parent, WEST_BASIN_NEAR - 1, -120, 0, false)
	makeDockRun(parent, -48, 48, -114, true)
	buildSunkenPagoda(parent)

	--[[
	The viewing platform, offset to the south of the pagoda rather than centred on
	it: the tower's base is 46 studs square, so a deck at its own coordinates would
	pass straight through its first tier.
	]]
	local platformZ = -46
	local platform = makePart(
		parent,
		"ViewingPlatform",
		Vector3.new(34, 0.7, 34),
		CFrame.new(-152, WEST_DOCK_TOP - 0.35, platformZ),
		COLOR_DOCK_WOOD,
		Enum.Material.WoodPlanks
	)
	platform.CanTouch = false
	for post = 0, 3 do
		local angle = post * math.pi * 0.5 + math.pi * 0.25
		local pile = makePart(
			parent,
			"PlatformPost",
			Vector3.new(0.9, WEST_DOCK_TOP - WEST_BASIN_FLOOR_TOP, 0.9),
			CFrame.new(-152 + math.cos(angle) * 14, (WEST_BASIN_FLOOR_TOP + WEST_DOCK_TOP) * 0.5, platformZ + math.sin(angle) * 14),
			COLOR_DOCK_WOOD,
			Enum.Material.Wood
		)
		pile.CanTouch = false
		pile.CanQuery = false
	end

	--[[
	Five willows. Four stand on the far bank with their canopies leaning out over the
	water, one stands on the north shore: a willow whose strands do not reach water is
	just a tree, and the low strands are the only thing in the region that moves at
	eye level.
	]]
	local willowSpots: { Vector3 } = {
		Vector3.new(-224, APRON_TOP, -34),
		Vector3.new(-236, APRON_TOP, 46),
		Vector3.new(-246, APRON_TOP, -92),
		Vector3.new(-230, APRON_TOP, 112),
		Vector3.new(-150, APRON_TOP, -104),
	}
	for _, spot in ipairs(willowSpots) do
		makeWillow(parent, spot.X, spot.Z, spot.Y, rng)
	end

	--[[
	Sixteen floating lanterns, and only eight of them bob.

	A tween is cheap to *create* and not free to *replicate*: the server sends a
	CFrame update per tweened instance per frame, so sixteen bobbing lanterns is
	roughly a thousand property updates a second spent on decoration. Eight is
	indistinguishable in motion to a camera that cannot see two lanterns at once
	carefully enough to compare, and it halves that number.
	]]
	local lanternSpots: { Vector2 } = {
		Vector2.new(-70, 30),
		Vector2.new(-68, -30),
		Vector2.new(-84, 60),
		Vector2.new(-86, -64),
		Vector2.new(-98, 18),
		Vector2.new(-100, -22),
		Vector2.new(-126, 62),
		Vector2.new(-128, -60),
		Vector2.new(-160, 40),
		Vector2.new(-162, -44),
		Vector2.new(-180, 12),
		Vector2.new(-184, -24),
		Vector2.new(-196, 56),
		Vector2.new(-200, -58),
		Vector2.new(-132, 30),
		Vector2.new(-144, -66),
	}
	for index, spot in ipairs(lanternSpots) do
		makeWaterLantern(parent, spot.X, spot.Y, index * 0.7, index % 2 == 1)
	end

	--[[
	Mist on the water, at 2.2 studs, in two 94-stud volumes placed to stop exactly on
	the basin's rims. The first one used to run 15 studs past the west rim and hang
	its fog over the SanctuaryHub courtyard; a particle volume is not clipped to the
	water below it, so its edges have to be placed by hand.

	`LightInfluence = 0.55` and a pale blue-grey tint: mist over water is lit from
	above by a warm sky and from below by nothing, and a mist that is fully lit reads
	as steam off a cooking pot.
	]]
	for _, spot in ipairs({ Vector3.new(-105, 2.2, 0), Vector3.new(-176, 2.2, 0) }) do
		local volume = phantomVolume(parent, "WaterMist", Vector3.new(94, 5, 140), spot)
		makeEmitter(volume, "Mist", TEXTURE_SMOKE, {
			Rate = 6,
			Lifetime = NumberRange.new(14, 22),
			Speed = NumberRange.new(0.3, 0.9),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 5),
				NumberSequenceKeypoint.new(0.5, 11),
				NumberSequenceKeypoint.new(1, 16),
			}),
			Color = ColorSequence.new(Color3.fromRGB(168, 176, 186)),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.88),
				NumberSequenceKeypoint.new(0.4, 0.8),
				NumberSequenceKeypoint.new(1, 1),
			}),
			LightInfluence = 0.55,
			Acceleration = Vector3.new(0.2, 0.06, 0.25),
			Drag = 1.2,
			SpreadAngle = Vector2.new(180, 180),
			EmissionDirection = Enum.NormalId.Top,
			RotSpeed = NumberRange.new(-4, 4),
		})
	end

	makeZone(
		parent,
		"SunkenPagodaZone",
		Vector3.new(200, 60, 220),
		Vector3.new(-156, 30, 0),
		3,
		"The Sunken Pagoda",
		"West"
	)
end

--===========================================================================
-- S7 - SOUTH: THE CRIMSON ECLIPSE CITADEL  (behind Gate 4)
--===========================================================================

--[[
The citadel is built the way a mountain castle actually is: three terraces of dark
stone with a single 44-stud-wide staircase cut straight up the middle of all three,
and the castle on the top plateau bridging the corridor it climbed.

That corridor is the whole trick, and it is what makes this region different from
the north fortress's. The north is a silhouette seen from 200 studs; the south is a
*route* - the one horizon region in the file that a player arriving through the gate
can actually walk up, from the apron at 0.9 to the keep's gate at 82. It has to be
readable on the way, which is why its terraces are wider than the north's, its
staircase is twice as wide as the courtyard's own gate, and its detail is on the
faces beside the climb rather than on a distant roofline.

Sight line: from the spawn, the southern torii is solid to y = 26 at z = 46, so the
castle needs only to clear 34 - it clears 150. What the height buys here is not
visibility but *scale*: a keep seen down the length of its own staircase has to be
tall enough that the stairs do not vanish by the second landing.
]]
type CitadelTerrace = {
	Top: number,
	Front: number,
	Back: number,
	Half: number,
}

local SOUTH_APRON_NEAR: number = 44
local SOUTH_APRON_FAR: number = 300
local SOUTH_APRON_HALF_X: number = 150

local SOUTH_TERRACES: { CitadelTerrace } = {
	{ Top = 18, Front = 64, Back = 120, Half = 124 },
	{ Top = 40, Front = 120, Back = 176, Half = 100 },
	{ Top = 62, Front = 176, Back = 252, Half = 74 },
}

--[[
The stair corridor is 44 wide and the flights are 40, so there are two studs of
stone either side of the player's shoulders the whole way up.
]]
local SOUTH_CORRIDOR_HALF: number = 22
local SOUTH_STAIR_HALF: number = 20
local SOUTH_LANDING_DEPTH: number = 6

--[[
The three terraces, each as two flanking blocks with the corridor between them.

Merlons and buttresses on the front faces, exactly as on the north massif, and for
the same reason: a 248-stud wall of dark stone with a broken line of blocks along
its top is a fortress, and the same wall without them is a retaining wall.
]]
local function buildSouthCliffs(parent: Instance)
	for index, terrace in ipairs(SOUTH_TERRACES) do
		local height = terrace.Top - APRON_TOP
		local depth = terrace.Back - terrace.Front
		local midZ = (terrace.Front + terrace.Back) * 0.5
		local blockWidth = terrace.Half - SOUTH_CORRIDOR_HALF

		for _, side in ipairs({ -1, 1 }) do
			makePart(
				parent,
				string.format("CitadelTerrace%d", index),
				Vector3.new(blockWidth, height, depth),
				CFrame.new(side * (SOUTH_CORRIDOR_HALF + blockWidth * 0.5), APRON_TOP + height * 0.5, midZ),
				COLOR_IMPERIAL_STONE,
				Enum.Material.Basalt
			)
		end

		local merlonCount = 14
		local span = terrace.Half * 2 - 12
		for merlon = 0, merlonCount - 1 do
			local x = -span * 0.5 + (merlon + 0.5) * (span / merlonCount)
			makePart(
				parent,
				"CitadelMerlon",
				Vector3.new(4, 3.4, 3),
				CFrame.new(x, terrace.Top + 1.7, terrace.Front + 1.8),
				Color3.fromRGB(36, 33, 35),
				Enum.Material.Basalt
			)
		end

		local buttressCount = 5
		for buttress = 0, buttressCount - 1 do
			local x = -terrace.Half + (buttress + 1) * (terrace.Half * 2 / (buttressCount + 1))
			if math.abs(x) > SOUTH_CORRIDOR_HALF + 4 then
				makePart(
					parent,
					"CitadelButtress",
					Vector3.new(5.5, height, 4.5),
					CFrame.new(x, APRON_TOP + height * 0.5, terrace.Front - 2),
					Color3.fromRGB(36, 33, 35),
					Enum.Material.Basalt
				)
			end
		end
	end
end
--[[
The grand staircase: three flights and two landings, 61 studs of climb over 184
studs of run, straight up the corridor in a single axis.

Every step is a box three studs tall whose *top* sits at its own height. Steps rise
only 1.1 studs apart, so each box overlaps the one below it twice over and the
staircase is solid from every angle; a step exactly one rise tall leaves a hollow
staircase whose undersides are the first thing anyone sees from the side.

The rails are the fourth and last use of `CFrame.lookAt` in this file, and they need
it: the three flights are 18.2, 23.7 and 17.4 degrees, and a rail that is one degree
out over 52 studs visibly leaves its steps.
]]
type SouthFlight = {
	StartZ: number,
	StartY: number,
	EndY: number,
	Steps: number,
	Run: number,
}

local function buildSouthStair(parent: Instance)
	local flights: { SouthFlight } = {
		{ StartZ = 64, StartY = APRON_TOP, EndY = SOUTH_TERRACES[1].Top, Steps = 16, Run = 52 },
		{ StartZ = 122, StartY = SOUTH_TERRACES[1].Top, EndY = SOUTH_TERRACES[2].Top, Steps = 20, Run = 50 },
		{ StartZ = 178, StartY = SOUTH_TERRACES[2].Top, EndY = SOUTH_TERRACES[3].Top, Steps = 20, Run = 70 },
	}

	for _, flight in ipairs(flights) do
		local rise = (flight.EndY - flight.StartY) / flight.Steps
		local run = flight.Run / flight.Steps

		for step = 0, flight.Steps - 1 do
			local top = flight.StartY + (step + 1) * rise
			makePart(
				parent,
				"CitadelStep",
				Vector3.new(SOUTH_STAIR_HALF * 2, 3, run),
				CFrame.new(0, top - 1.5, flight.StartZ + (step + 0.5) * run),
				Color3.fromRGB(52, 47, 49),
				Enum.Material.Cobblestone
			)
		end

		local endZ = flight.StartZ + flight.Run
		for _, side in ipairs({ -1, 1 }) do
			local from = Vector3.new(side * (SOUTH_STAIR_HALF + 1.2), flight.StartY + 1.8, flight.StartZ)
			local to = Vector3.new(side * (SOUTH_STAIR_HALF + 1.2), flight.EndY + 1.8, endZ)
			local mid = (from + to) * 0.5
			makePart(
				parent,
				"CitadelRail",
				Vector3.new(1.6, 2.6, (to - from).Magnitude),
				CFrame.lookAt(mid, mid + (to - from)),
				Color3.fromRGB(36, 33, 35),
				Enum.Material.Basalt
			)
		end
	end

	makePart(
		parent,
		"SouthLanding",
		Vector3.new(SOUTH_CORRIDOR_HALF * 2 + 4, 1.4, SOUTH_LANDING_DEPTH),
		CFrame.new(0, SOUTH_TERRACES[1].Top - 0.7, 120),
		Color3.fromRGB(52, 47, 49),
		Enum.Material.Cobblestone
	)
	makePart(
		parent,
		"SouthLanding",
		Vector3.new(SOUTH_CORRIDOR_HALF * 2 + 4, 1.4, SOUTH_LANDING_DEPTH),
		CFrame.new(0, SOUTH_TERRACES[2].Top - 0.7, 176),
		Color3.fromRGB(52, 47, 49),
		Enum.Material.Cobblestone
	)

	--[[
	Six lanterns: four on the landings and two at the foot of the climb. They are the
	only warm light in a region built out of dark stone and crimson, and they are also
	the only thing that marks how far up a player has got - a staircase lit from below
	reads as a *height*, where an evenly lit one reads as a ramp.
	]]
	makeStoneLantern(parent, -16, 120, SOUTH_TERRACES[1].Top, true, 0.4)
	makeStoneLantern(parent, 16, 120, SOUTH_TERRACES[1].Top, true, 1.3)
	makeStoneLantern(parent, -16, 176, SOUTH_TERRACES[2].Top, true, 2.2)
	makeStoneLantern(parent, 16, 176, SOUTH_TERRACES[2].Top, true, 3.1)
	makeStoneLantern(parent, -30, 58, APRON_TOP, true, 4.0)
	makeStoneLantern(parent, 30, 58, APRON_TOP, true, 4.9)
end



















--===========================================================================
-- S7b - THE CASTLE: BANNERS, THE KEEP, THE ECLIPSE
--===========================================================================

--[[
One cascading banner.

A mounting pole, a 26-stud cloth, and a gold hem - three parts, and the hem is the
one that matters: a rectangle of red that ends in a rectangle of red reads as a
flag, and the same rectangle ending in a gold band reads as a *banner* hung from a
Japanese roof.

The cloth sways on an infinite ping-pong tween of 1.6 degrees about its own width.
That is four tenths of a stud of movement at its hem, which is the most that can be
added before the cloth visibly detaches from the roof it is hanging from.
]]
local function makeBanner(parent: Instance, x: number, z: number, roofY: number, index: number, rng: Random)
	local length = rng:NextNumber(24, 30)
	local pole = makePart(
		parent,
		"BannerPole",
		Vector3.new(0.8, 7, 0.8),
		CFrame.new(x, roofY + 2, z),
		COLOR_TIMBER,
		Enum.Material.Wood
	)
	pole.CanTouch = false
	pole.CanQuery = false

	local cloth = makePart(
		parent,
		"BannerCloth",
		Vector3.new(5.2, length, 0.4),
		CFrame.new(x, roofY - length * 0.5 + 0.6, z),
		COLOR_CRIMSON,
		Enum.Material.Fabric
	)
	cloth.CanTouch = false
	cloth.CanQuery = false

	local hem = makePart(
		parent,
		"BannerHem",
		Vector3.new(5.2, 1.6, 0.45),
		CFrame.new(x, roofY - length + 0.4, z),
		COLOR_GOLD_TRIM,
		Enum.Material.Fabric
	)
	hem.CanTouch = false
	hem.CanQuery = false

	--[[
	Two tweens of the same length and phase, so the cloth and its hem move together.
	They rotate about their own centres rather than about the roof, which is what
	keeps this to two parts: hanging them from a shared pivot would need a third part
	and an unanchored assembly, and the drift at 1.6 degrees is four tenths of a stud.
	]]
	makeSway(cloth, math.rad(1.6), 5 + (index % 5) * 0.6)
	makeSway(hem, math.rad(1.6), 5 + (index % 5) * 0.6)
end

--[[
The castle: a stone podium with a red-doored gate, four tiers of plaster and timber
with flared slate roofs, two flanking turrets, twelve cascading crimson banners, and
- 980 studs out in the southern sky - the crimson eclipse the region is named for.

Three things are doing the work here:

  * White plaster against near-black timber framing, which is what a Japanese castle
    *is*. The plaster is `Material.Concrete` at (206, 198, 186): a bright value that
    the warm atmosphere tints toward cream on its own, so the region's palette is
    stone grey, cream and one saturated red, with nothing else competing.
  * Roofs that overhang their walls by ten studs and flare 24 degrees at the eaves.
    Every roof in this file uses the same four-skirt trick, and the citadel is where
    the flare is largest: from the bottom of a 180-stud staircase the eaves are what
    a player reads the tower's shape from.
  * The banners. Twelve of them, 26 to 30 studs long, off every roof edge on the
    front face. They are the only saturated colour in the region, they are the only
    thing in it that moves, and they are why the citadel reads as *inhabited* rather
    than as a monument.
]]
local function buildCitadel(parent: Instance, rng: Random)
	local plateau = SOUTH_TERRACES[3].Top
	local podiumTop = plateau + 20
	local keepZ = 214

	makePart(parent, "CitadelPodium", Vector3.new(104, 20, 76), CFrame.new(0, plateau + 10, keepZ), COLOR_IMPERIAL_STONE, Enum.Material.Basalt)

	--[[
	The gate. A dark recess rather than a hole, for the same reason the north
	fortress's gate is a porch: a part cannot subtract one, and a 26-by-24 black
	rectangle with a red door in it reads as a way in from the bottom of the stairs.
	]]
	local gate = makePart(parent, "CitadelGate", Vector3.new(26, 24, 3), CFrame.new(0, plateau + 12, 177.5), Color3.fromRGB(17, 15, 16), Enum.Material.SmoothPlastic)
	gate.CanTouch = false
	gate.CanQuery = false
	for _, side in ipairs({ -1, 1 }) do
		local door = makePart(parent, "CitadelDoor", Vector3.new(11.6, 22, 1), CFrame.new(side * 6, plateau + 11, 176.8), COLOR_CRIMSON, Enum.Material.WoodPlanks)
		door.CanTouch = false
		--[[
		Two crimson lights, the only lights in the file that are not orange. A red
		glow inside a dark gate at the top of a long staircase is the first thing
		visible from the courtyard below, and it is what makes the climb read as
		something other than a wall.
		]]
		local light = makeLight(door, 2.2, 34, Color3.fromRGB(255, 92, 68), false)
		makeFlicker(light, 0.08, 1.5 + side * 0.3, side * 2.1)
	end
	for _, x in ipairs({ -9, 0, 9 }) do
		local bar = makePart(parent, "GateBar", Vector3.new(0.9, 22, 0.9), CFrame.new(x, plateau + 11, 178.4), COLOR_IRON, Enum.Material.Metal)
		bar.CanTouch = false
		bar.CanQuery = false
	end
	for _, side in ipairs({ -1, 1 }) do
		makePart(parent, "GuardianPedestal", Vector3.new(5.5, 8, 5.5), CFrame.new(side * 17, plateau + 4, 176), Color3.fromRGB(36, 33, 35), Enum.Material.Basalt)
		makePart(parent, "Guardian", Vector3.new(3.6, 3.4, 4), CFrame.new(side * 17, plateau + 9.7, 175.6), Color3.fromRGB(30, 28, 30), Enum.Material.Basalt)
	end

	--[[
	Four tiers. The rise is 18 against a tier height of 16, so the two-stud gap
	between tiers is exactly where each roof sits.
	]]
	local tierWidths: { number } = { 56, 48, 40, 30 }
	local rise = 18
	local tierHeight = 16
	local y = podiumTop
	local bannerIndex = 0

	for index, width in ipairs(tierWidths) do
		local depth = width * 0.78
		makePart(parent, string.format("KeepTier%d", index), Vector3.new(width, tierHeight, depth), CFrame.new(0, y + tierHeight * 0.5, keepZ), COLOR_PLASTER, Enum.Material.Concrete)

		for _, beamY in ipairs({ y + 1.2, y + tierHeight - 1.2 }) do
			makePart(parent, "KeepBeam", Vector3.new(width + 0.6, 1.6, depth + 0.6), CFrame.new(0, beamY, keepZ), COLOR_TIMBER, Enum.Material.WoodPlanks)
		end
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				makePart(
					parent,
					"KeepPost",
					Vector3.new(2.2, tierHeight, 2.2),
					CFrame.new(sx * (width * 0.5 - 1), y + tierHeight * 0.5, keepZ + sz * (depth * 0.5 - 1)),
					COLOR_TIMBER,
					Enum.Material.WoodPlanks
				)
			end
		end
		makePart(parent, "KeepTrim", Vector3.new(width + 1, 1.4, depth + 1), CFrame.new(0, y + tierHeight - 0.4, keepZ), COLOR_CRIMSON, Enum.Material.SmoothPlastic)

		local roofY = y + tierHeight
		makePart(parent, "KeepRoof", Vector3.new(width + 20, 2, depth + 16), CFrame.new(0, roofY + 1, keepZ), COLOR_IMPERIAL_ROOF, Enum.Material.Slate)
		for _, sz in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"KeepRoofSkirt",
				Vector3.new(width + 34, 1, 11),
				CFrame.new(0, roofY + 0.2, keepZ + sz * (depth * 0.5 + 8)) * CFrame.Angles(math.rad(24) * sz, 0, 0),
				COLOR_IMPERIAL_ROOF,
				Enum.Material.Slate
			)
		end
		for _, sx in ipairs({ -1, 1 }) do
			makePart(
				parent,
				"KeepRoofSkirt",
				Vector3.new(11, 1, depth + 30),
				CFrame.new(sx * (width * 0.5 + 8), roofY + 0.2, keepZ) * CFrame.Angles(0, 0, math.rad(-24) * sx),
				COLOR_IMPERIAL_ROOF,
				Enum.Material.Slate
			)
		end
		makePart(parent, "KeepEaveTrim", Vector3.new(width + 20.6, 0.8, depth + 16.6), CFrame.new(0, roofY, keepZ), COLOR_GOLD_TRIM, Enum.Material.Metal)

		for _, side in ipairs({ -1, 1 }) do
			bannerIndex += 1
			makeBanner(parent, side * width * 0.38, keepZ - (depth * 0.5 + 9), roofY, bannerIndex, rng)
		end

		y += rise
	end

	--[[
	Two turrets, flanking the keep at the podium's shoulders. Three tiers of 24
	studs: their job is to widen the castle's silhouette so the keep reads as the
	centre of a fortress rather than as a lone tower, and they are the reason the
	castle is not symmetric-looking when a player sees it at an angle.
	]]
	for _, side in ipairs({ -1, 1 }) do
		local turretX = side * 40
		local turretY = podiumTop
		local turretWidths: { number } = { 26, 22, 18 }
		for index, width in ipairs(turretWidths) do
			local depth = width * 0.86
			makePart(parent, "TurretTier", Vector3.new(width, 14, depth), CFrame.new(turretX, turretY + 7, keepZ), COLOR_PLASTER, Enum.Material.Concrete)
			for _, beamY in ipairs({ turretY + 1.2, turretY + 12.8 }) do
				makePart(parent, "TurretBeam", Vector3.new(width + 0.6, 1.5, depth + 0.6), CFrame.new(turretX, beamY, keepZ), COLOR_TIMBER, Enum.Material.WoodPlanks)
			end

			local roofY = turretY + 14
			makePart(parent, "TurretRoof", Vector3.new(width + 15, 1.6, depth + 13), CFrame.new(turretX, roofY + 0.8, keepZ), COLOR_IMPERIAL_ROOF, Enum.Material.Slate)
			for _, sz in ipairs({ -1, 1 }) do
				makePart(
					parent,
					"TurretSkirt",
					Vector3.new(width + 26, 0.9, 9),
					CFrame.new(turretX, roofY + 0.2, keepZ + sz * (depth * 0.5 + 6)) * CFrame.Angles(math.rad(24) * sz, 0, 0),
					COLOR_IMPERIAL_ROOF,
					Enum.Material.Slate
				)
			end
			for _, sx in ipairs({ -1, 1 }) do
				makePart(
					parent,
					"TurretSkirt",
					Vector3.new(9, 0.9, depth + 24),
					CFrame.new(turretX + sx * (width * 0.5 + 6), roofY + 0.2, keepZ) * CFrame.Angles(0, 0, math.rad(-24) * sx),
					COLOR_IMPERIAL_ROOF,
					Enum.Material.Slate
				)
			end
			makePart(parent, "TurretTrim", Vector3.new(width + 1, 1.3, depth + 1), CFrame.new(turretX, turretY + 13, keepZ), COLOR_CRIMSON, Enum.Material.SmoothPlastic)

			if index < 3 then
				bannerIndex += 1
				makeBanner(parent, turretX, keepZ - (depth * 0.5 + 7), roofY, bannerIndex, rng)
			end
			turretY += 16
		end
	end

	--[[
	The spire, and then the eclipse.

	The spire is a rod and three gold rings, four parts for 14 studs of silhouette.
	The eclipse is two Neon discs 980 studs into the southern sky: one solid crimson
	at 200 studs across, one halo at 320 and 0.88 transparency behind it.

	It is placed far enough out, and high enough at 420, that it reads as *distant
	sky* rather than as an object - which is the entire difference between a crimson
	moon over a citadel and a red circle floating behind a castle. `CanQuery` is off
	on both discs out of principle: nothing in this world should be found by a ray
	unless it is meant to be, however far away it is.
	]]
	local spireY = y - rise + tierHeight
	makePart(parent, "KeepSpire", Vector3.new(1.8, 16, 1.8), CFrame.new(0, spireY + 8, keepZ), COLOR_TIMBER, Enum.Material.WoodPlanks)
	for ring = 0, 2 do
		local ringWidth = 8 - ring * 2.1
		makePart(parent, "SpireRing", Vector3.new(ringWidth, 0.8, ringWidth), CFrame.new(0, spireY + 4 + ring * 4.6, keepZ), COLOR_GOLD_TRIM, Enum.Material.Metal)
	end

	local eclipse = makePart(
		parent,
		"CrimsonEclipse",
		Vector3.new(10, 200, 200),
		CFrame.new(0, 420, 980) * CFrame.Angles(0, math.pi * 0.5, 0),
		Color3.fromRGB(148, 32, 36),
		Enum.Material.Neon
	)
	eclipse.Shape = Enum.PartType.Cylinder
	eclipse.Transparency = 0.45
	eclipse.CanCollide = false
	eclipse.CanTouch = false
	eclipse.CanQuery = false
	eclipse.CastShadow = false

	local halo = makePart(
		parent,
		"CrimsonEclipseHalo",
		Vector3.new(10, 320, 320),
		CFrame.new(0, 420, 1000) * CFrame.Angles(0, math.pi * 0.5, 0),
		Color3.fromRGB(120, 40, 44),
		Enum.Material.Neon
	)
	halo.Shape = Enum.PartType.Cylinder
	halo.Transparency = 0.88
	halo.CanCollide = false
	halo.CanTouch = false
	halo.CanQuery = false
	halo.CastShadow = false
end

local function buildSouthCitadel(parent: Instance, rng: Random)
	makePart(
		parent,
		"CitadelApron",
		Vector3.new(SOUTH_APRON_HALF_X * 2, APRON_THICKNESS, SOUTH_APRON_FAR - SOUTH_APRON_NEAR),
		CFrame.new(0, APRON_TOP - APRON_THICKNESS * 0.5, (SOUTH_APRON_NEAR + SOUTH_APRON_FAR) * 0.5),
		COLOR_HILL_EARTH,
		Enum.Material.Ground
	)

	buildSouthCliffs(parent)
	buildSouthStair(parent)
	buildCitadel(parent, rng)

	makeZone(
		parent,
		"CrimsonCitadelZone",
		Vector3.new(260, 100, 236),
		Vector3.new(0, 50, 178),
		4,
		"The Crimson Eclipse Citadel",
		"South"
	)
end

--===========================================================================
-- S8 - BUILD
--===========================================================================

--[[
The four regions, as data.

This is the list the boot loop walks, and it is a list rather than four calls for a
practical reason: the loop is what guarantees every region gets the same treatment -
the same idempotent teardown, the same attributes, the same part count, the same
line in the boot log. Four hand-written blocks drift apart the first time one of
them is edited.
]]
type RegionPlan = {
	Folder: string,
	Direction: string,
	Region: string,
	Build: (Instance, Random) -> (),
}

local REGION_PLANS: { RegionPlan } = {
	{
		Folder = "North_BurningAshFortress",
		Direction = "North",
		Region = "The Burning Ash Fortress",
		Build = function(parent: Instance, _rng: Random)
			buildNorthFortress(parent)
		end,
	},
	{
		Folder = "East_WhisperingBambooGrove",
		Direction = "East",
		Region = "The Whispering Bamboo Grove",
		Build = function(parent: Instance, rng: Random)
			buildEastGrove(parent, rng)
		end,
	},
	{
		Folder = "West_SunkenPagoda",
		Direction = "West",
		Region = "The Sunken Pagoda",
		Build = function(parent: Instance, rng: Random)
			buildWestSunken(parent, rng)
		end,
	},
	{
		Folder = "South_CrimsonEclipseCitadel",
		Direction = "South",
		Region = "The Crimson Eclipse Citadel",
		Build = function(parent: Instance, rng: Random)
			buildSouthCitadel(parent, rng)
		end,
	},
}

--[[
What the boot log has to be able to answer: how many parts did each region cost, and
did it get its zone anchor. Both are read back off the built tree rather than
counted as they were created, so the number in the log is the number in the world -
a part the builder forgot to parent is a part this does not count.
]]
local function countRegion(folder: Folder): (number, number)
	local parts = 0
	local zones = 0
	for _, descendant in ipairs(folder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts += 1
			if descendant:GetAttribute("RoninZone") ~= nil then
				zones += 1
			end
		end
	end
	return parts, zones
end

--[[
Boot.

Idempotent by construction, exactly as `Arena1Builder` is: the `Horizon` folder is
destroyed and rebuilt, and a second call leaves one world where the first left one.
That matters because this is a `Script`: on a hot reload, or a re-run from the
command bar, a builder that appends is a builder that doubles every region.

The parent is `Workspace.SanctuaryHub` rather than `Workspace` so the sanctuary
stays one subtree - the floor, the torii, the courtyard and everything the four
torii lead to - that can be moved, streamed or deleted as a unit.

Order of operations, and the one ordering promise in the file: the regions are built
first and the environment is applied last, but *both* before `RoninHorizonReady` is
written. That attribute is the only thing a consumer is allowed to treat as
"everything below it is valid" - the same contract `RoninArenaReady` carries for the
arena - and writing it first would let a consumer find a half-built region.

`Baseplate` is the one instance outside the sanctuary this file touches, and only
its colour and material. It is a 2048-stud grey plate at y = 0 that sits under every
region here and shows in every long sight line of the panorama, so it is re-toned to
the aprons' slate. No geometry changes and nothing is deleted: a place whose safest
fallback floor is removed is a place where a hole in someone else's region becomes a
fall out of the world.
]]
local function build()
	local hub = Workspace:WaitForChild("SanctuaryHub")

	local existing = hub:FindFirstChild(FOLDER_HORIZON)
	if existing ~= nil then
		existing:Destroy()
	end

	local horizon = Instance.new("Folder")
	horizon.Name = FOLDER_HORIZON
	horizon:SetAttribute("RoninHorizon", true)
	horizon:SetAttribute("RoninHorizonReady", false)
	horizon.Parent = hub

	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate ~= nil and baseplate:IsA("BasePart") then
		baseplate.Color = Color3.fromRGB(58, 55, 51)
		baseplate.Material = Enum.Material.Slate
	end

	local rng = Random.new(SEED)
	local totalParts = 0
	local totalZones = 0
	local lines: { string } = {}

	for _, plan in ipairs(REGION_PLANS) do
		local folder = Instance.new("Folder")
		folder.Name = plan.Folder
		folder:SetAttribute("RoninRegion", plan.Region)
		folder:SetAttribute("RoninRegionDirection", plan.Direction)
		folder:SetAttribute("RoninRegionReady", false)
		folder.Parent = horizon

		plan.Build(folder, rng)

		local parts, zones = countRegion(folder)
		totalParts += parts
		totalZones += zones
		folder:SetAttribute("RoninRegionParts", parts)
		folder:SetAttribute("RoninRegionReady", true)

		lines[#lines + 1] = string.format("%-5s %s - %d parts, %d zone", plan.Direction, plan.Region, parts, zones)
	end

	local environment = applyEnvironment()

	horizon:SetAttribute("RoninHorizonParts", totalParts)
	horizon:SetAttribute("RoninHorizonZones", totalZones)
	horizon:SetAttribute("RoninHorizonReady", true)

	print(string.format(
		"[WORLD] Horizon built: %d parts across %d regions, %d zone anchors, %d stale Lighting effect(s) removed, %s.",
		totalParts,
		#REGION_PLANS,
		totalZones,
		environment.Pruned,
		environment.Quality
	))
	for _, line in ipairs(lines) do
		print("[WORLD]   " .. line)
	end
end

build()




