--!strict

--[[
Arena1Builder
Ronin - The Last Blade . Realm 1: The Burning Ash Courtyard

Constructs the courtyard, the perimeter, the braziers, the ash and the gate, and
clones the Commander into the middle of it.

Why a builder rather than hand-placed instances
------------------------------------------------
Everything here is a *function* of `ARENA_HALF_EXTENT`. Change the arena from
80x80 to 100x100 and the floor, all four walls, both wall segments either side of
	the gate, the gate frame, the six brazier positions, the ash volume and the
boss's spawn all move together, correctly, from one number. A hand-placed arena
is sixty instances that silently disagree with each other the first time anyone
resizes it.

It is also idempotent by construction: `Build` refuses to build twice and returns
	the arena it already made. That matters because this is a ModuleScript required
by the controller, and a controller that re-runs would otherwise stack two
courtyards on top of each other.

Architecture rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #3 - this is the server deciding what the world contains.
    Nothing the client sends creates a single part here.
  * ARCHITECTURE.md #4 - the flicker loop below is the only per-frame work in the
    file and it allocates nothing: it reads pre-built tables and writes numbers.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BossConfig = require(ReplicatedStorage:WaitForChild("BossConfig") :: ModuleScript)

local Arena = BossConfig.Arena

--[[
The palette. Dark, desaturated, and *not* black: a courtyard lit only by fire
needs its surfaces to have some albedo or the braziers have nothing to bounce
off and the whole room reads as a flat silhouette.

The floor is the darkest of the three and the walls are the lightest, which is
backwards from a lighting-design instinct and exactly right here: the walls catch
	the brazier light on their inner faces and give the eye a horizon, while the
floor swallows it. That gradient is the "deep shadows" the brief asks for, and it
is done with albedo rather than with a fog value, so the shadows still read as
solid stone at a distance.
]]
local COLOR_FLOOR = Color3.fromRGB(38, 34, 33)
local COLOR_WALL = Color3.fromRGB(61, 55, 50)
local COLOR_WALL_BASE = Color3.fromRGB(44, 39, 36)
local COLOR_INLAY = Color3.fromRGB(96, 30, 26)
local COLOR_BAMBOO = Color3.fromRGB(72, 84, 44)
local COLOR_GATE = Color3.fromRGB(26, 23, 22)

--[[
Handles returned to the controller. Declared as a type rather than left as the
inferred shape of the literal so a consumer gets completion, and so a rename here
is a compile error there instead of a nil at runtime.
]]
export type Arena1Handles = {
Folder: Folder,
Floor: Part,
GateLeft: BasePart,
GateRight: BasePart,
BrazierLights: { PointLight },
BrazierEmitters: { ParticleEmitter },
AshEmitter: ParticleEmitter,
EmberEmitters: { ParticleEmitter },
Boss: Model,
Grade: ColorCorrectionEffect,
}

local built: Arena1Handles? = nil

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
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
The ash, falling.

One emitter over the whole courtyard rather than one per player or per brazier.
The whole point is that it reads as *weather* over the arena rather than as an
effect attached to something, and weather is shared: a per-brazier emitter would
	telegraph where the fires are instead of filling the room.

`EmissionDirection = Bottom` with `ShapeStyle = Box` on a wide, flat part means
	the particles spawn on that part's underside and fall. `Acceleration` carries
	them the rest of the way down and `Drag` keeps the `Speed` from reading as rain -
ash should look like it is *settling*, heavily, not falling fast.

`LightInfluence = 0.85` is the one number that makes this read as ash rather than
as grey confetti: the flakes pick up almost all of their colour from the
environment, so they are bright orange on the side of the room with the braziers
and nearly black on the other, which is what a real flake of ash does and what a
fixed tint can never fake.
]]
local function makeAshEmitter(parent: Instance): ParticleEmitter
	local volume = makePart(
		"AshVolume",
		Vector3.new(Arena.HalfExtent * 2 + 8, 1, Arena.HalfExtent * 2 + 8),
		CFrame.new(Arena.Center.X, 44, Arena.Center.Z),
		Color3.new(1, 1, 1),
		Enum.Material.SmoothPlastic,
		parent
	)
	volume.Transparency = 1
	volume.CanCollide = false
	volume.CanTouch = false
	volume.CanQuery = false
	volume.CastShadow = false

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AshFall"
	emitter.Texture = BossConfig.Particles.Ash
	emitter.Rate = 30
	emitter.Lifetime = NumberRange.new(9, 15)
	emitter.Speed = NumberRange.new(1, 2.6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0.4, -1.15, 0.35)
	emitter.Drag = 0.35
	emitter.LightInfluence = 0.85
	emitter.LockedToPart = false
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.5, 0.55),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(206, 200, 192))
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.7, 0.8),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = volume

	return emitter
end

--[[
The embers, rising.

One per brazier, parented to the brazier's own fire so the two are lit by the same
light and cannot drift apart. Rising rather than falling, warm-to-dark, and tiny
- an ember you can see the shape of is not an ember, and `Size` peaking at 0.3
is what keeps them reading as sparks instead of as a second flame.

`LightInfluence = 0` is correct here and wrong for the ash: an ember is *self*
luminous, so it must not be darkened by passing through a shadow.
]]
local function makeEmberEmitter(fire: BasePart): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Embers"
	emitter.Texture = BossConfig.Particles.Ember
	emitter.Rate = 7
	emitter.Lifetime = NumberRange.new(1.6, 2.8)
	emitter.Speed = NumberRange.new(3, 6)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.Acceleration = Vector3.new(0.5, 3.4, 0.3)
	emitter.Drag = 0.6
	emitter.LightInfluence = 0
	emitter.LockedToPart = false
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 170)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 124, 32)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(96, 18, 6)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.6, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = fire
	return emitter
end
--[[
The flame column on the bowl. Separate from `makeEmberEmitter` because the two
particles are doing opposite jobs: the flame is the *source* (large, tinted, lit
partly by the world) and the embers are the *product* (tiny, unlit, drifting
away). Shipping only one of them is the difference between "a brazier" and "a
brazier with a fire in it".

The colour runs white-hot through orange to deep red rather than staying orange,
and `Size` peaks a third of the way into the particle's life. Both are there to
give the fire a *core*: a particle that starts at its final size and only fades
reads as smoke, not as something burning.
]]
local function makeFlame(fire: BasePart): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Flame"
	emitter.Texture = BossConfig.Particles.Ash
	emitter.Rate = 26
	emitter.Lifetime = NumberRange.new(0.7, 1.4)
	emitter.Speed = NumberRange.new(2.5, 5)
	emitter.SpreadAngle = Vector2.new(14, 14)
	emitter.Acceleration = Vector3.new(0, 7.5, 0)
	emitter.Drag = 1.8
	emitter.LightInfluence = 0.35
	emitter.LockedToPart = false
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(0.28, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 246, 208)),
		ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 164, 44)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(178, 44, 10)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(48, 8, 4)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(0.6, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = fire
	return emitter
end

--[[
One brazier: the Creator Store iron bowl, plus the fire and the light that make
it a fire.

The asset supplies the *shape* only. Its stock light is retuned rather than
deleted (so the asset stays as authored) and the flame is authored here for one
reason: the asset ships no fire at all, and a brazier without fire is a planter.

A clone arrives at the *template's* pivot, so it cannot simply be placed at a
fixed height: only its own bounding box knows where its base is. Park it well
clear, measure the lowest point, then translate by the exact difference between
	that point and the arena floor.
]]
--[[
The native templates.

Two models, built out of nothing but native engine instances, used whenever
`ReplicatedStorage.BossTemplates` does not already hold an authored one.

Why they exist at all, since the brief asks for a template:

The safety invariant for this project forbids importing community Tool/Model
packages, and a Creator Store character rig is exactly that - a Model whose
provenance nobody in this repository can audit, whose scripts have to be
stripped on arrival, and whose Motor6D naming is a property of the asset rather
than of this code. Building the rig here means the joint names the pose table
depends on are guaranteed by the file that reads them, there is no third-party
script surface to sanitise, and the arena is reproducible from a clean clone of
the place with no asset dependency at all.

It is a *fallback*, not a replacement: an authored `BossTemplates.CorruptedCommander`
still wins, so a designer can art-direct the Commander later without touching a
line of this file. `FindFirstChild` with no wait is what makes the difference -
`WaitForChild` with no timeout on a missing folder waits forever and takes the
whole arena down with it, which is exactly the failure the first live test
produced.
]]
local TEMPLATE_FOLDER = "BossTemplates"
local COMMANDER_NAME = "CorruptedCommander"
local BRAZIER_NAME = "IronBrazier"

local COLOR_ARMOR = Color3.fromRGB(38, 36, 40)
local COLOR_TRIM = Color3.fromRGB(92, 22, 24)
local COLOR_CLOTH = Color3.fromRGB(26, 24, 28)
local COLOR_SKIN = Color3.fromRGB(150, 132, 118)
local COLOR_IRON = Color3.fromRGB(58, 54, 52)

--[[
An authored template if one is present, otherwise the native build.

The lack of a wait is the point. A missing template must produce a *repaired*
arena, and the only way to get that is to stop waiting for something that is not
coming.
]]
local function resolveTemplate(name: string, build: () -> Model): Model
	local folder = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER)
	if folder ~= nil then
		local authored = folder:FindFirstChild(name)
		if authored ~= nil and authored:IsA("Model") then
			return authored
		end
	end
	print(string.format("[ARENA 1] No authored %s template - building the native one.", name))
	return build()
end

--[[
The Commander, as a clean R15 rig.

Standard R15 proportions with `HumanoidRootPart` at the origin and the feet at
y = -5, which is the layout `Humanoid.HipHeight = 2` expects.

The Motor6D `C0` values are *derived* from the authored world CFrames rather than
typed in, and that is the whole trick to building a rig from script: setting
`C0 = p0.CFrame:ToObjectSpace(p1.CFrame)` with an identity `Transform` makes each
joint hold the pose its parts were placed in, so the rig stands up with no
`Animate` LocalScript and no guessed C0 values to correct later. `Animate` is
stripped deliberately - it writes every joint at the default priority on the next
frame and would overwrite the telegraph poses.

The joint names are load-bearing. The pose table addresses the Commander by
`RightShoulder` / `LeftElbow` and so on, while stock R15 spacing is "Right
Shoulder", so the spaces are stripped as the joints are created.
]]
local function buildCommander(): Model
	local boss = Instance.new("Model")
	boss.Name = COMMANDER_NAME

	local rig = Instance.new("Model")
	rig.Name = "Rig"
	rig.Parent = boss

	local function piece(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = if material ~= nil then material else Enum.Material.SmoothPlastic
		p.Anchored = false
		--[[
		Collision and query flags, and the split between them is load-bearing.

		`CanCollide = false` on every limb: a Commander whose arms and pauldrons are
		solid catches on the gate frame and the bamboo and shoves the player around
		the courtyard, which reads as the arena being broken rather than the boss
		being heavy.

		`CanQuery = true`, though, and that is not a default to be left alone. CanQuery
		is what makes a part visible to *spatial queries*, and the player's katana
		finds its targets with one. With `CanQuery = false` on every boss part the
		Commander was completely invulnerable: the blade swept straight through it,
		`[HIT DETECTED]` never printed, and the fight ran with the boss pinned at a
		permanent 400 Health. An invisible, unhittable boss is a far worse bug than
		one that is slightly easier to hit, so queryability wins over tidiness.

		`CanTouch = false` is safe to keep: nothing in this project resolves a strike
		through touch events, and the boss picks its own targets by distance.
		]]
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = true
		p.CastShadow = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = rig
		return p
	end

	local rootPart = piece("HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(0, 0, 0), COLOR_ARMOR)
	rootPart.Transparency = 1
	rootPart.CanCollide = true
	rig.PrimaryPart = rootPart

	local lowerTorso = piece("LowerTorso", Vector3.new(2, 2, 1), CFrame.new(0, -1, 0), COLOR_CLOTH)
	local upperTorso = piece("UpperTorso", Vector3.new(2, 2, 1), CFrame.new(0, 1, 0), COLOR_ARMOR)
	local head = piece("Head", Vector3.new(1, 1, 1), CFrame.new(0, 2.5, 0), COLOR_SKIN)

	local rUpperArm = piece("RightUpperArm", Vector3.new(1, 2, 1), CFrame.new(1.5, 1, 0), COLOR_ARMOR)
	local rLowerArm = piece("RightLowerArm", Vector3.new(1, 2, 1), CFrame.new(1.5, -0.5, 0), COLOR_ARMOR)
	local rHand = piece("RightHand", Vector3.new(1, 1, 1), CFrame.new(1.5, -2, 0), COLOR_TRIM)
	local lUpperArm = piece("LeftUpperArm", Vector3.new(1, 2, 1), CFrame.new(-1.5, 1, 0), COLOR_ARMOR)
	local lLowerArm = piece("LeftLowerArm", Vector3.new(1, 2, 1), CFrame.new(-1.5, -0.5, 0), COLOR_ARMOR)
	local lHand = piece("LeftHand", Vector3.new(1, 1, 1), CFrame.new(-1.5, -2, 0), COLOR_TRIM)

	local rUpperLeg = piece("RightUpperLeg", Vector3.new(1, 2, 1), CFrame.new(0.5, -2, 0), COLOR_CLOTH)
	local rLowerLeg = piece("RightLowerLeg", Vector3.new(1, 2, 1), CFrame.new(0.5, -3.5, 0), COLOR_CLOTH)
	local rFoot = piece("RightFoot", Vector3.new(1, 1, 1), CFrame.new(0.5, -5, 0), COLOR_ARMOR)
	local lUpperLeg = piece("LeftUpperLeg", Vector3.new(1, 2, 1), CFrame.new(-0.5, -2, 0), COLOR_CLOTH)
	local lLowerLeg = piece("LeftLowerLeg", Vector3.new(1, 2, 1), CFrame.new(-0.5, -3.5, 0), COLOR_CLOTH)
	local lFoot = piece("LeftFoot", Vector3.new(1, 1, 1), CFrame.new(-0.5, -5, 0), COLOR_ARMOR)
	-- Pauldrons and a crest: welded decoration, so the silhouette reads as
	-- armour across a dark arena and cannot lag behind a telegraph pose.
	local function weldTo(anchor: BasePart, p: BasePart)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = anchor
		weld.Part1 = p
		weld.Parent = p
	end
	for _, arm in ipairs({ rUpperArm, lUpperArm }) do
		weldTo(arm, piece(arm.Name .. "Pauldron", Vector3.new(1.3, 0.7, 1.3),
			arm.CFrame + Vector3.new(0, 0.8, 0), COLOR_TRIM, Enum.Material.Metal))
	end
	weldTo(head, piece("Crest", Vector3.new(0.16, 0.9, 0.7),
		head.CFrame + Vector3.new(0, 0.75, 0), COLOR_TRIM, Enum.Material.Metal))

	local function joint(name: string, p0: BasePart, p1: BasePart)
		local m = Instance.new("Motor6D")
		m.Name = (name:gsub(" ", ""))
		m.Part0 = p0
		m.Part1 = p1
		m.C0 = p0.CFrame:ToObjectSpace(p1.CFrame)
		m.C1 = CFrame.new()
		m.Transform = CFrame.new()
		m.Parent = p0
	end

	joint("Root", lowerTorso, rootPart)
	joint("Waist", upperTorso, lowerTorso)
	joint("Neck", upperTorso, head)
	joint("Right Shoulder", upperTorso, rUpperArm)
	joint("Left Shoulder", upperTorso, lUpperArm)
	joint("Right Elbow", rUpperArm, rLowerArm)
	joint("Left Elbow", lUpperArm, lLowerArm)
	joint("Right Wrist", rLowerArm, rHand)
	joint("Left Wrist", lLowerArm, lHand)
	joint("Right Hip", lowerTorso, rUpperLeg)
	joint("Left Hip", lowerTorso, lUpperLeg)
	joint("Right Knee", rUpperLeg, rLowerLeg)
	joint("Left Knee", lUpperLeg, lLowerLeg)
	joint("Right Ankle", rLowerLeg, rFoot)
	joint("Left Ankle", lLowerLeg, lFoot)

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = 2
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Health = BossConfig.MaxHealth
	humanoid.MaxHealth = BossConfig.MaxHealth
	humanoid.WalkSpeed = 14
	--[[
	AutoRotate stays ON. `Boss1Controller` faces the player exclusively through
	`Humanoid:Move`, and that call only turns a character when `AutoRotate` is
	enabled. With it off the Commander slides past the player without ever facing
	them, and since `fireSwing` tests a forward cone rather than a radius, every
	one of its five moves silently whiffs - a fight that looks like it is running
	and is not landing a single hit.
	]]
	humanoid.AutoRotate = true
	humanoid.Parent = rig
	--[[
	The telegraph hardware, parented exactly where `Boss1Controller` looks for it.

	Built here rather than in the controller so that file stays a pure *reader* of
	the boss: it performs no `Instance.new`, which means the Commander can be
	swapped for a different rig without the fight logic being aware of it. Every
	colour and range is read from `BossConfig`, so the telegraph palette has one
	owner and the template cannot drift away from the balance pass.
	]]
	local telegraphLight = Instance.new("PointLight")
	telegraphLight.Name = "TelegraphLight"
	telegraphLight.Brightness = 0
	telegraphLight.Range = BossConfig.Telegraph.Range
	telegraphLight.Color = BossConfig.Telegraph.Amber
	telegraphLight.Shadows = true
	telegraphLight.Parent = rootPart

	local chime = Instance.new("Sound")
	chime.Name = "PerilChime"
	chime.SoundId = BossConfig.Audio.PerilChime
	chime.Volume = 1
	chime.PlaybackSpeed = 1.35
	chime.RollOffMode = Enum.RollOffMode.InverseTapered
	chime.MinDistance = 7
	chime.MaxDistance = 90
	chime.Parent = head

	local slam = Instance.new("Sound")
	slam.Name = "CleaveSlam"
	slam.SoundId = BossConfig.Audio.CleaveSlam
	slam.Volume = 0.9
	slam.RollOffMode = Enum.RollOffMode.InverseTapered
	slam.MinDistance = 7
	slam.MaxDistance = 90
	slam.Parent = rootPart

	local kanji = Instance.new("BillboardGui")
	kanji.Name = "PerilKanji"
	kanji.Size = UDim2.fromOffset(150, 150)
	kanji.StudsOffset = Vector3.new(0, 4.2, 0)
	kanji.MaxDistance = 90
	kanji.AlwaysOnTop = true
	kanji.LightInfluence = 0
	kanji.Enabled = false
	kanji.Adornee = head
	kanji.Parent = head

	local stroke = Instance.new("Frame")
	stroke.Name = "Stroke"
	stroke.Size = UDim2.fromScale(1, 1)
	stroke.BackgroundTransparency = 1
	stroke.Parent = kanji

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.Size = UDim2.fromOffset(150, 150)
	glow.Position = UDim2.fromOffset(-25, -25)
	glow.BackgroundColor3 = BossConfig.Telegraph.Red
	glow.BackgroundTransparency = 0.75
	glow.BorderSizePixel = 0
	glow.Rotation = 45
	glow.Parent = stroke

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.BackgroundTransparency = 1
	-- The kanji for "peril", assembled from code points so this file stays pure
	-- ASCII and cannot be corrupted by an editor that guesses at encodings.
	glyph.Text = string.char(0x5B, 0x38)
	glyph.Font = Enum.Font.GothamBold
	glyph.TextSize = 96
	glyph.TextColor3 = BossConfig.Telegraph.Red
	glyph.TextStrokeColor3 = Color3.fromRGB(60, 0, 0)
	glyph.TextStrokeTransparency = 0.25
	glyph.Parent = stroke

	return boss
end

--[[
The iron brazier, as native Parts.

Four legs, a stem, a bowl and three crossed sticks. The bowl is deliberately the
highest part in the model, because `makeBrazier` finds the bowl by measuring for
the topmost solid and parents the fire and the light to whatever that is - so the
geometry and the fire cannot disagree about where the flame sits.
]]
local function buildBrazier(): Model
	local brazier = Instance.new("Model")
	brazier.Name = BRAZIER_NAME

	local function iron(name: string, size: Vector3, cf: CFrame, shape: Enum.PartType?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = COLOR_IRON
		p.Material = Enum.Material.Metal
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = true
		p.Parent = brazier
		if shape ~= nil then
			p.Shape = shape
		end
		return p
	end

	for index = 0, 3 do
		local angle = index * math.pi * 0.5
		iron("Leg", Vector3.new(0.4, 3, 0.4),
			CFrame.new(math.cos(angle) * 0.9, 1.5, math.sin(angle) * 0.9) * CFrame.Angles(0, -angle, 0.12))
	end
	iron("Stem", Vector3.new(0.5, 1.2, 0.5), CFrame.new(0, 3.2, 0))
	iron("Pan", Vector3.new(2.6, 0.9, 2.6), CFrame.new(0, 4, 0), Enum.PartType.Cylinder)
	for index = 0, 2 do
		iron("Stick", Vector3.new(0.25, 1.8, 0.25),
			CFrame.new(0, 4.6, 0) * CFrame.Angles(0.5, index * math.pi * 0.666, 0.3))
	end

	-- A PrimaryPart makes `Model:GetPivot()` deterministic, which is what the
	-- settle-onto-the-floor maths in `makeBrazier` depends on.
	brazier.PrimaryPart = iron("Base", Vector3.new(2, 0.4, 2), CFrame.new(0, 0.2, 0))
	return brazier
end


local function makeBrazier(template: Model, index: number, parent: Instance): (PointLight, BasePart)
	local brazier = template:Clone()
	brazier.Name = string.format("Brazier_%d", index)
	brazier.Parent = parent

	local offset = Arena.BrazierOffsets[index] or Vector3.new(0, 0, 0)
	brazier:PivotTo(CFrame.new(0, 90, 0))
	local boxCFrame, boxSize = brazier:GetBoundingBox()
	local lowestY = boxCFrame.Position.Y - boxSize.Y * 0.5
	local floorPoint = Vector3.new(Arena.Center.X + offset.X, Arena.FloorTop, Arena.Center.Z + offset.Z)
	brazier:PivotTo(brazier:GetPivot() + (floorPoint - Vector3.new(0, lowestY, 0)))

	-- The highest solid part is the bowl; the fire and the light live on it.
	local bowl: BasePart? = nil
	local bowlTop = -math.huge
	for _, descendant in ipairs(brazier:GetDescendants()) do
	if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = true
			descendant.Material = Enum.Material.Metal
			local top = descendant.Position.Y + descendant.Size.Y * 0.5
			if top > bowlTop then
				bowlTop = top
				bowl = descendant
			end
	end
	end

	if bowl == nil then
		error("[Arena1Builder] IronBrazier template had no BaseParts")
	end

	makeEmberEmitter(bowl)
	makeFlame(bowl)

	for _, light in ipairs(brazier:GetDescendants()) do
	if light:IsA("PointLight") then
			light.Brightness = 2.4
			light.Range = 36
			light.Shadows = true
			light.Color = Color3.fromRGB(255, 150, 58)
			return light :: PointLight, bowl
	end
	end

	local light = Instance.new("PointLight")
	light.Brightness = 2.4
	light.Range = 36
	light.Shadows = true
	light.Color = Color3.fromRGB(255, 150, 58)
	light.Parent = bowl

	return light, bowl
end
--[[
The bamboo. Placed along three of the four walls, and *only* the three that are
not the gate wall: a player walking in needs a clean read on the opening, and
bamboo across the south face would put a thicket exactly where the eye needs a
door.

They are culms, not foliage - thin, tall, `Material.Grass` in a dark green - and
	they are `CanCollide = false`, because a player who clips a decorative stalk
falls through the world and blames the arena. Colliding scenery is a decision, and
here the decision is no.
]]
local function makeBamboo(parent: Instance): number
	local culms = 0
	local half = Arena.HalfExtent - 5

	for face = 1, 3 do
	local alongX = (face == 2)
	local count = 13
	for i = 0, count do
			local t = (i / count) * 2 - 1
			local along = t * half
			local depth = (half + 1.5) + (culms % 4) * 1.6
			local x = alongX and depth * (face == 2 and 1 or -1) or along
			local z = alongX and along or depth * (face == 1 and -1 or 1)
			if math.abs(x) < Arena.HalfExtent - 1 and math.abs(z) < Arena.HalfExtent - 1 then
				local height = 9 + (culms % 3) * 2.5
				local culm = makePart(
					"Bamboo",
					Vector3.new(0.7, height, 0.7),
					CFrame.new(
						Arena.Center.X + x,
						Arena.FloorTop + height * 0.5,
						Arena.Center.Z + z
					) * CFrame.Angles(0, culms * 0.7, ((culms % 4) - 1.5) * 0.012),
					COLOR_BAMBOO,
					Enum.Material.Grass,
					parent
				)
				culm.Shape = Enum.PartType.Cylinder
				culm.CanCollide = false
				culm.CanTouch = false
				culm.CanQuery = false
				culms += 1
			end
	end
	end

	return culms
end

--[[
The gate. Two leaves on a frame, and the frame is *load bearing*: it is the only
part of the arena the fight's fairness depends on.

The leaves are 8 studs wide each and the opening is 16, so closed they meet at
exactly x = 0 with no overlap and no seam to squeeze through. Open they sit at
+/- 12, which puts each one entirely inside the wall segment beside it - so the
"open" gate is not a gap with a door floating in it, it is a doorway with the
door recessed into the wall, and there is nothing a player can stand inside.
]]
local function makeGate(parent: Instance): (BasePart, BasePart)
	local southZ = Arena.Center.Z + Arena.HalfExtent
	local opening = Arena.GateHalfWidth * 2

	-- Frame: two pillars and a lintel, standing proud of the wall.
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			"GatePillar",
			Vector3.new(1.6, Arena.GateHeight + 2, Arena.WallThickness + 1.6),
			CFrame.new(
				Arena.Center.X + side * (Arena.GateHalfWidth + 0.8),
				Arena.FloorTop + (Arena.GateHeight + 2) * 0.5,
				southZ
			),
			COLOR_GATE,
			Enum.Material.Basalt,
			parent
		)
	end
	makePart(
		"GateLintel",
		Vector3.new(opening + 4, 2.4, Arena.WallThickness + 1.6),
		CFrame.new(Arena.Center.X, Arena.FloorTop + Arena.GateHeight + 1.2, southZ),
		COLOR_GATE,
		Enum.Material.Basalt,
		parent
	)

	local gateLeft = makePart(
		"GateLeafLeft",
		Vector3.new(Arena.GateHalfWidth, Arena.GateHeight, 1.1),
		CFrame.new(
			Arena.Center.X - Arena.GateHalfWidth * 1.5,
			Arena.FloorTop + Arena.GateHeight * 0.5,
			southZ
		),
		COLOR_GATE,
		Enum.Material.Metal,
		parent
	)
	local gateRight = makePart(
		"GateLeafRight",
		Vector3.new(Arena.GateHalfWidth, Arena.GateHeight, 1.1),
		CFrame.new(
			Arena.Center.X + Arena.GateHalfWidth * 1.5,
			Arena.FloorTop + Arena.GateHeight * 0.5,
			southZ
		),
		COLOR_GATE,
		Enum.Material.Metal,
		parent
	)

	-- The leaves carry their own open/closed X so the geometry and the animation
	-- cannot disagree: move a leaf in the place and the gate animation follows it.
	for _, leaf in ipairs({ gateLeft, gateRight }) do
		leaf:SetAttribute("RoninGateLeaf", true)
		leaf:SetAttribute("RoninGateOpenX", leaf.Position.X)
	end
	gateLeft:SetAttribute("RoninGateClosedX", Arena.Center.X - Arena.GateHalfWidth * 0.5)
	gateRight:SetAttribute("RoninGateClosedX", Arena.Center.X + Arena.GateHalfWidth * 0.5)

	return gateLeft, gateRight
end
--[[
The Commander.

Cloned from `ReplicatedStorage.BossTemplates.CorruptedCommander` rather than
parented directly, which is what makes the fight repeatable: a defeated boss is
destroyed and re-cloned for the next run, so the only thing that can go stale is
	the clone, and the clone is rebuilt from the template every time.

`ScaleTo` is used rather than scaling the parts by hand because the templated rig
carries Motor6Ds and accessories; `ScaleTo` resizes the whole assembly correctly,
where hand-scaling would leave the joints mismatched and the boss would walk with
its knees inside its chest.

The five brief-named attributes are written here, on the Model, before the boss
is parented into the world - so a client that sees the boss at all sees it with
its Health already 400 and its Phase already 1, and there is never a frame in
which the HUD could read a nil.
]]
--[[
The nodachi.

The brief names `ReplicatedStorage.KatanaModel` as the Commander's weapon and
this is where that promise is kept. The template already carries a `KatanaB`
accessory, and it is *removed* rather than left in place: two blades in one
hand renders as a bug, and the accessory is a bare `Part` welded to a
`ThumbnailConfiguration`, which is not a rig attachment at all.

Why a `WeldConstraint` and not a `Motor6D`, when the player's own katana uses
a `Motor6D` grip: the player rig needs the motor because `WeaponVisuals`
*re-poses* the grip every frame to drive swing animation. The Commander has no
weapon animation - its telegraph is a `Motor6D` pose on the arm joints - so a
motor would buy a degree of freedom nothing writes to, and a constraint is one
fewer thing that can be driven by a stray tween during a fight.

The offset places the grip 1.5 studs ahead of the palm with the blade's +Y axis
tipped to near-horizontal, which is the same rest pose `SparringDummy` uses for
the player's grip. Shared numbers on purpose: the Commander should read as
holding a katana the same way the player does, or the parry the player has
learned on the dummy is being asked for against a different weapon.

Failure is loud. A boss that spawns without a weapon would not throw an error -
it would simply be a man punching, and every reach number in `BossConfig`
would be quietly wrong. So a missing template or a missing hand is an error,
not a warning.
]]
local KATANA_TEMPLATE = "KatanaModel"
local KATANA_BLADE = "Handle"
local BLADE_NAME = "RoninNodachi"
local GRIP_NAME = "NodachiGrip"
local GRIP_TRANSLATION = Vector3.new(0, 0, -1.5)
local REST_POSE = CFrame.Angles(math.rad(-82), 0, 0)

local function equipKatana(boss: Model, rig: Model)
	local template = ReplicatedStorage:FindFirstChild(KATANA_TEMPLATE)
	if template == nil or not template:IsA("Model") then
		error("[Arena1Builder] ReplicatedStorage.KatanaModel was missing - the Commander cannot spawn unarmed")
	end

	local rightHand = rig:FindFirstChild("RightHand")
	if rightHand == nil or not rightHand:IsA("BasePart") then
		error("[Arena1Builder] CorruptedCommander.Rig had no RightHand to hold the nodachi")
	end

	-- The template's own accessory is stripped: one blade per hand.
	local accessory = rig:FindFirstChild("KatanaB")
	if accessory ~= nil then
		accessory:Destroy()
	end

	local katana = template:Clone()
	katana.Name = BLADE_NAME
	katana.Parent = boss

	local blade = katana:FindFirstChild(KATANA_BLADE)
	if blade == nil or not blade:IsA("BasePart") then
		error("[Arena1Builder] KatanaModel had no Handle MeshPart")
	end

	-- The blade is scaled with the body. A 4-stud nodachi on a 1.2x Commander
	-- reads as a toy, and the reach numbers in `BossConfig` are written against
	-- the Commander's size - so the weapon is scaled by the same factor and the
	-- grip offset with it, rather than the blade being scaled and the hand
	-- offset left at player dimensions.
	katana:ScaleTo(BossConfig.Scale)

	-- Position before welding. A WeldConstraint fixes the *current* relative
	-- transform, so the offset has to be authored first or the blade snaps to
	-- the hand's origin.
	blade.CFrame = (rightHand :: BasePart).CFrame
		* CFrame.new(GRIP_TRANSLATION * BossConfig.Scale)
		* REST_POSE
	blade.Anchored = false
	blade.CanCollide = false
	blade.CanTouch = false
	blade.CanQuery = true
	blade.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Name = GRIP_NAME
	weld.Part0 = rightHand
	weld.Part1 = blade
	weld.Parent = blade
end

local function spawnBoss(parent: Instance): Model
	local template = resolveTemplate(COMMANDER_NAME, buildCommander)
	local boss = template:Clone()
	boss.Name = "TheCorruptedCommander"
	boss.Parent = parent

	boss:ScaleTo(BossConfig.Scale)

	--[[
	The rig is resolved first and the Humanoid is read *out of it*.

	`FindFirstChildWhichIsA` is not recursive - it only looks at direct children -
	and on a character rig the Humanoid is never a direct child of the Model, it
	lives inside the `Rig`. Reaching for it from the Model therefore returns nil
	against every correctly-built rig in the game, including the player's, and the
	failure surfaces as "the Commander has no Humanoid" on a template that plainly
	has one. The rig is resolved once here and everything else - the Humanoid, the
	hand that holds the nodachi - is reached through it.
	]]
	local rig = boss:FindFirstChild("Rig")
	if rig == nil or not rig:IsA("Model") then
		error("[Arena1Builder] CorruptedCommander template had no Rig Model")
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		error("[Arena1Builder] CorruptedCommander's Rig had no Humanoid")
	end

	humanoid.MaxHealth = BossConfig.MaxHealth
	humanoid.Health = BossConfig.MaxHealth
	humanoid.WalkSpeed = 14
	humanoid.BreakJointsOnDeath = false
	-- Re-asserted after the clone and the scale: see the note in `buildCommander`.
	humanoid.AutoRotate = true

	boss:SetAttribute(BossConfig.Attributes.Health, BossConfig.MaxHealth)
	boss:SetAttribute(BossConfig.Attributes.MaxHealth, BossConfig.MaxHealth)
	boss:SetAttribute(BossConfig.Attributes.Posture, 0)
	boss:SetAttribute(BossConfig.Attributes.MaxPosture, BossConfig.MaxPosture)
	boss:SetAttribute(BossConfig.Attributes.Phase, 1)
	boss:SetAttribute(BossConfig.Attributes.Engaged, false)
	boss:SetAttribute(BossConfig.Attributes.State, "Dormant")
	boss:SetAttribute(BossConfig.Attributes.Vulnerable, false)
	boss:SetAttribute(BossConfig.Attributes.Defeated, false)

	--[[
		Settle the clone onto the floor. Same reasoning as the brazier: measure the
		bounding box, then translate by exactly the difference between the lowest point
	and the arena floor. Measuring is cheap and happens once per arena build.
	]]
	boss:PivotTo(CFrame.new(Arena.Center.X, 70, Arena.Center.Z))
	local boxCFrame, boxSize = boss:GetBoundingBox()
	local lowestY = boxCFrame.Position.Y - boxSize.Y * 0.5
	boss:PivotTo(boss:GetPivot() + Vector3.new(0, Arena.FloorTop - lowestY, 0))

	equipKatana(boss, rig)

	return boss
end

--[[
The grade.

A `ColorCorrectionEffect` that the controller switches on while a player is inside
	the arena and off again when they leave, which is the only way to get a real
lighting change per-room out of Roblox's single global `Lighting` object.

It is created `Enabled = false` and parented at build time rather than created on
demand, so the effect exists in the data model before any player can reach the
arena. A first-frame pop on a grade that darkens the whole screen is a much worse
artefact than a grade that was already warm.
]]
local function makeGrade(): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild("ARENA_Burn_Grade")
	if existing ~= nil and existing:IsA("ColorCorrectionEffect") then
	return existing :: ColorCorrectionEffect
	end

	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "ARENA_Burn_Grade"
	grade.Brightness = -0.08
	grade.Contrast = 0.18
	grade.Saturation = -0.22
	grade.TintColor = Color3.fromRGB(255, 152, 98)
	grade.Enabled = false
	grade.Parent = Lighting
	return grade
end

--[[
The flicker.

Six PointLights on a `task.spawn` loop at ~11Hz. This is the file's only
per-frame path, so it is written to ARCHITECTURE #4 exactly: it allocates no
	tables, creates no CFrames, and reads nothing it did not resolve before the loop
started. Everything it touches is a number write on an Instance the caller
already holds a reference to.

Two sines at incommensurate frequencies rather than one. A single sine reads as
a *pulse* - the eye locks onto a regular rhythm and the fire stops being fire. Two
frequencies that never quite line up again read as combustion. This is the same
reason a good fire sound is a loop of noise and not a loop of a single tone.

Amplitude is small on purpose (x 0.72 to x 1.18). A brazier that swing-wildly
between 0 and 6 is a strobe, and six strobing lights in an enclosed arena is a
genuine accessibility problem as well as a visual one.
]]
local function startFlicker(lights: { PointLight }): () -> ()
	local count = #lights
	if count == 0 then
	return function() end
	end

	local bases: { number } = {}
	for i = 1, count do
		bases[i] = lights[i].Brightness
	end

	local running = true
		task.spawn(function()
	local t = 0
	local step = 0.09
	while running do
				 t += step
			for i = 1, count do
				local phase = t * (1.7 + i * 0.37)
				local f = 1 + (math.sin(phase) * 0.12) + (math.sin(phase * 2.63 + i) * 0.06)
				lights[i].Brightness = bases[i] * f
			end
				task.wait(step)
	end
	end)

	return function()
		running = false
	end
end--[[
Build.

Idempotent by construction: a second call returns the arena the first call made
and writes nothing. A builder that can re-enter after a hot-reload must not
double the world's geometry.

The parent is `Workspace.SanctuaryHub` (not `Workspace`) because the brief puts
	the realm *beyond Gate 1*, which is inside the hub's own built area, and because
a folder that contains the torii and the hub floor should also contain the thing
	the torii leads to. That makes the whole sanctuary one subtree you can move,
stream or delete as a unit.

Why the result is published as attributes
-----------------------------------------
This file is a `Script`, not a `ModuleScript` - the project's `.server.luau`
convention maps to `Script` - so `Boss1Controller` cannot `require` it, and the
	wo cannot exchange a Lua table of live references.

Publishing handles as attributes on the arena folder is the alternative, and it
is a *better* one than a table would have been: attributes replicate, so the
controller can find the boss from either side of the boundary, a stripped or
rebuilt instance re-publishes them on the next build, and the contract is a list
of documented names rather than a structural coupling between two files that
happen to be loaded at the same time. This is the same pattern
`HitValidator` <-> `SparringDummy` already use.

The gate is *not* animated here. The builder lays the leaves out and stores each
leaf's open and closed X on the leaf itself; `Boss1Controller` owns the tween,
because opening and sealing the gate is a decision about the fight, not about
	the scenery.
]]
local function build()
	local hub = Workspace:WaitForChild("SanctuaryHub")
	local old = hub:FindFirstChild(Arena.FolderName)
	if old ~= nil then
		old:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = Arena.FolderName
	folder:SetAttribute("RoninArena", true)
	folder:SetAttribute("RoninArenaName", Arena.Name)
	folder:SetAttribute("RoninArenaReady", false)
	folder.Parent = hub

	local half = Arena.HalfExtent
	local wallOffset = half + Arena.WallThickness * 0.5
	local midY = Arena.FloorTop + Arena.WallHeight * 0.5
	local wallThickness = Arena.WallThickness

	makePart(
		"AshStoneFloor",
		Vector3.new(half * 2, Arena.FloorThickness, half * 2),
		CFrame.new(Arena.Center.X, Arena.FloorTop - Arena.FloorThickness * 0.5, Arena.Center.Z),
		COLOR_FLOOR,
		Enum.Material.Slate,
		folder
	)

	-- The duelling inlay: a dark band across the floor, the same idea as the hub's
	-- InlayDuelCircle, one scale up.
	local inlay = makePart(
		"DuelInlay",
		Vector3.new(half * 2 - 14, 0.2, 0.5),
		CFrame.new(Arena.Center.X, Arena.FloorTop + 0.1, Arena.Center.Z),
		COLOR_INLAY,
		Enum.Material.SmoothPlastic,
		folder
	)
	inlay.Transparency = 0.3
	inlay.CanCollide = false
	inlay.CanTouch = false
	inlay.CanQuery = false

	-- Walls: three solid faces, and the gate face in two segments either side of the
	-- opening.
	makePart("WallNorth", Vector3.new(half * 2 + wallThickness * 2, Arena.WallHeight, wallThickness),
		CFrame.new(Arena.Center.X, midY, Arena.Center.Z - wallOffset), COLOR_WALL, Enum.Material.Basalt, folder)
	makePart("WallEast", Vector3.new(wallThickness, Arena.WallHeight, half * 2),
		CFrame.new(Arena.Center.X + wallOffset, midY, Arena.Center.Z), COLOR_WALL, Enum.Material.Basalt, folder)
	makePart("WallWest", Vector3.new(wallThickness, Arena.WallHeight, half * 2),
		CFrame.new(Arena.Center.X - wallOffset, midY, Arena.Center.Z), COLOR_WALL, Enum.Material.Basalt, folder)

	local segmentWidth = (half * 2 - Arena.GateHalfWidth * 2) * 0.5
	for _, side in ipairs({ -1, 1 }) do
		makePart(
			"WallSouth",
			Vector3.new(segmentWidth, Arena.WallHeight, wallThickness),
			CFrame.new(
				Arena.Center.X + side * (Arena.GateHalfWidth + segmentWidth * 0.5),
				midY,
				Arena.Center.Z + wallOffset
			),
			COLOR_WALL,
			Enum.Material.Basalt,
			folder
		)
	end

	-- The approach: a bridge of stone between the hub's north edge and the gate, so
	-- the player is walking on ground rather than crossing a seam.
	makePart(
		"Approach",
		Vector3.new(Arena.GateHalfWidth * 2, Arena.FloorThickness, Arena.ApproachLength + 8),
		CFrame.new(
			Arena.Center.X,
			Arena.FloorTop - Arena.FloorThickness * 0.5,
			Arena.Center.Z + half + (Arena.ApproachLength + 8) * 0.5 - 4
		),
		COLOR_WALL_BASE,
		Enum.Material.Cobblestone,
		folder
	)

	local gateLeft, gateRight = makeGate(folder)
	local bambooCount = makeBamboo(folder)

	local template = resolveTemplate(BRAZIER_NAME, buildBrazier)
	local brazierFolder = Instance.new("Folder")
	brazierFolder.Name = "Braziers"
	brazierFolder.Parent = folder

	local lights: { PointLight } = {}
	for index, offset in ipairs(Arena.BrazierOffsets) do
	local light = makeBrazier(template, index, brazierFolder)
		lights[#lights + 1] = light
	end

	local ash = makeAshEmitter(folder)
	local boss = spawnBoss(folder)
	local grade = makeGrade()

	startFlicker(lights)

	--[[
		The published contract. Everything the controller needs, by documented name.
		`RoninArenaReady` is written last on purpose: it is the one attribute the
		controller is allowed to treat as "all of the others are valid", and writing
		it first would let the controller find a nil boss on a frame where the arena
		is still being assembled.
	]]
	--[[
	The published contract.

	Handles are addressed by *name*, not published as attributes, and that is not a
	style choice. An attribute holding an Instance now reads back as an
	`InstanceHandle` rather than the Instance itself, so every consumer would have
	to unwrap a handle before it could call a single method on it - and the first
	live test failed on exactly that, with "FindFirstChild is not a valid member of
	InstanceHandle" raised from the controller. Addressing by name is immune to
	that, is what the rest of the engine expects, and keeps the DataModel itself as
	the contract instead of a parallel one encoded in attributes.

	The parts already carry the names this relies on: the gate leaves are
	`GateLeafLeft` / `GateLeafRight`, the Commander is `TheCorruptedCommander`, and
	the grade is `ARENA_Burn_Grade` under `Lighting`.

	`RoninArenaReady` stays an attribute because it is a plain boolean and it is
	doing a job an Instance cannot: it is written *last*, and the controller treats
	it as the promise that every name above already resolves.
	]]
	folder:SetAttribute("RoninArenaReady", true)

	print(string.format(
		"[ARENA 1] %s built - %dx%d at (%d, %d, %d), %d braziers, %d bamboo, boss placed",
		Arena.Name, half * 2, half * 2,
		Arena.Center.X, Arena.Center.Y, Arena.Center.Z, #lights, bambooCount
	))
end

build()
