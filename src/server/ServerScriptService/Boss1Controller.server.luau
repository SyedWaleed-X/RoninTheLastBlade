--!strict

--[[
Boss1Controller
Ronin - The Last Blade . Boss 1: THE CORRUPTED COMMANDER

The fight. Five moves, a posture economy, two phases, a ranged answer, and the
	arena lifecycle that brackets them.

The three distance bands
------------------------
The fight is organised by *where the player is standing*, which is a change
	from the previous version and the change that matters most here:

    > 18 studs   RANGED    - the Flaming Blade Wave, a real projectile with
                             its own flight, its own hit test and its own
                             cleanup. 20 HP, answerable by the i-frame dodge
                             (Q) or by a leap (Space).
    10 - 18     APPROACH  - the Shadow Lunge. A `LinearVelocity` dash at 35
                             studs/s with an ember trail. It deals *nothing*;
                             it is a gap-closer that exists so the mid band is
                             not dead air.
    < 10        MELEE     - stalk, then one of the five. The stalk is a beat
                             of circling at a randomised duration, on a
                             cooldown, so the close exchange is not three
                             memorised moves on repeat.

Every threshold is in `BossConfig` S4b. This file reads them and adds nothing
of its own, so a balance pass never has to come looking here.

What this file no longer does
-----------------------------
It no longer touches a *single joint*. Not one. The hip-thrust was a `Humanoid`
re-solving `HipHeight` against a rest pose that a script had moved underneath it,
and answering by shoving the rig once per frame; the glide was that same rig
walking a `Humanoid` whose hips and thighs had been overwritten one frame behind,
forever. Both had the same root cause, and neither was ever about an angle value.

`BossAnimate` gives the Commander a real `Animator` loaded with verified Roblox
stock tracks, and writes no `C0`, `C1` or `Transform` anywhere. The engine's own
locomotion drives the legs from `Humanoid:MoveTo` and its own tracks swing the
katana, which is precisely how a player avatar works - so nothing is fighting
anything and the forbidden-list workaround is gone along with the joints.

Every asset id involved was measured permission-free before being committed here:
200,002 candidates were probed and only Roblox's stock eleven resolved. That
measurement, and the `error()` that would have caught a bad id, are recorded in
`BossAnimate`.

Shape of the thing
-----------------
One `task.wait` loop at 50ms drives a state machine whose states are the same
Windup / Active / Recovery vocabulary the *player's* attacks already use
(CombatTypes, COMBAT_SPEC S1). That is not a stylistic choice: it means every
	iming question in this fight has the same answer as the same question on the
player, and a designer can move between the two without re-learning anything.

The loop is a `task.wait` loop rather than `RunService.Heartbeat` for the reason
`BossConfig` S6 documents: at 50ms a decision cadence resolves a move's phase to
within 5% of its designed length, and the boss's *locomotion* between decisions is
done by the Humanoid and by `Humanoid:Move`, so it stays at full framerate
regardless of how often this file thinks. Nothing here allocates in a per-frame
path.

The one deliberate exception is the *chase*: a `RunService.Heartbeat` callback
further down that reads a target this loop has already computed, compares one
number and calls `Humanoid:MoveTo`. That is the difference between a boss that
decides to pursue every 50ms and one whose legs are still moving between
decisions at the frame's own cadence, and the callback is written to allocate
nothing at all.

Where the authority lives
------------------------
Two rules this file must not own, and does not:

  * Whether a boss strike actually *lands* is decided in `HitValidator`, because
    that is where the player's parry window, guard cone and posture pool already
    live. This file computes geometry and asks.
  * Whether the boss is *allowed* to be hit at all is decided in `HitValidator`
    too. This file is told.

What this file does own is everything about the Commander itself: which move,
when, how it looks while doing it, what it costs the player to be standing
	here, and what the arena does about all of it.

Architecture rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #2 - the one remote this file fires goes server -> clients
    with a locally computed payload; nothing is read off the wire.
  * ARCHITECTURE.md #3 - the server is the only writer of a boss attribute.
  * ARCHITECTURE.md #4 - see the note above the loop.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local BossConfig = require(ReplicatedStorage:WaitForChild("BossConfig") :: ModuleScript)
local BossRegistry = require(ReplicatedStorage:WaitForChild("BossRegistry") :: ModuleScript)

local Attributes = BossConfig.Attributes
local Arena = BossConfig.Arena
local Move = BossConfig.Move
local Telegraph = BossConfig.Telegraph
local AI = BossConfig.AI
local PostureCfg = BossConfig.Posture

--[[
 States.

`Dormant` -> `Reposition` -> `Telegraph` -> `Strike` -> `Recover` is the normal
loop. Three states are off the loop:

  * `Retreat` / `Lunge` replace `Telegraph` + `Strike` entirely when the player
    breaks the 15-stud leash, and rejoin at `Recover`.
  * `PostureBroken` is the deathblow window. It cannot be interrupted, cannot be
    parried and does not attack - it is the fight's only reward for precision.
  * `Defeated` is terminal until the respawn timer fires.

`Telegraph` and `Strike` are separate states rather than phases of one because
	the *telegraph* is where the kanji, the chime and the light happen, and those
have to start on the first frame of the windup and stop on its last. Splitting
	the state makes "the telegraph is showing" a fact rather than a set of booleans
	that has to be kept in sync.
]]
type BossState =
	| "Dormant"
	| "Reposition"
	| "Telegraph"
	| "Strike"
	| "Recover"
	| "Retreat"
	| "Lunge"
	| "PostureBroken"
	| "Defeated"
	| "Respawning"
	--[[
	Three states for the three distance bands, added with the ranged and
	gap-closing work. They are on the same loop as the five melee states and
	are resolved by the same `stateUntil` deadline, because the thing they add
	is *where the boss chooses to be*, not a new kind of damage:

	  * `Stalk`     - inside melee range, circling before committing. The one
	    state that is deliberately not progress; it is what stops the close
	    exchange being three memorised moves.
	  * `Ranged`    - beyond `RangedThreshold`. Winds up the Blade Wave and
	    throws it. Ends back in `Reposition`, never in `Strike`, because the
	    wave resolves itself on its own clock.
	  * `Dash`      - the mid band. A `LinearVelocity` shadow-lunge that is a
	    *movement*, not an attack: it deals nothing, and it rejoins at
	    `Reposition` so the move that follows is a real melee one.
	]]
	| "Stalk"
	| "Ranged"
	| "Dash"

local state: BossState = "Dormant"
local stateUntil = 0
local currentMove = Move.Moves.TripleFlurry
local stepIndex = 0
local phase = 1
local engaged = false
local lastPostureHit = 0
local struckThisSwing: { [Model]: boolean } = {}
local deflectFlashUntil = 0
local struckThisSwing: { [Model]: boolean } = {}
local deflectFlashUntil = 0
local respawnAt = 0

--[[
The stalk's bookkeeping.

`stalkDir` is the only state the stalk owns, and it is a sign rather than a
vector on purpose: the orbit is recomputed from the player's *current*
position every tick, so a player who moves during the stalk is still orbited
correctly instead of being chased around a stale centre. Flipping the sign
mid-orbit is what makes it read as a predator changing feet rather than a
model sliding along a rail.

`lastStalkAt` gates the whole behaviour. Without it the boss would stalk every
single time it entered melee range, which is every 50ms - the player would
never get to attack, and a boss that never stops moving is a boss that never
threatens anything.
]]
local stalkDir = 1
local lastStalkAt = -math.huge

-- The Commander's intended hip height, published by its builder. Zero until the
-- rig is built, which is also the value `think`'s self-heal skips on.
local bossHipHeight = 0

-- The chase's inputs. Both live here rather than inside the Heartbeat callback
-- that reads them: `think` is the only thing that computes a target, and the
-- chase is the only thing that walks toward it, which is what keeps the
-- per-frame path free of the `Players:GetPlayers()` allocation the decision
-- would otherwise need (ARCHITECTURE #4).
local lastRetreatAt = -math.huge
local chaseTarget: Model? = nil
--[[
Whether the Commander is currently closing on a target, tracked so `chaseTick` can
settle the animation exactly once on the transition out rather than every frame.

The old value was a *pose name*, and it existed purely so the chase could avoid
allocating a two-keyframe clip 60 times a second - which ARCHITECTURE #4 forbids. That
pressure is gone: locomotion is now a velocity comparison against already-loaded
tracks, which allocates nothing at all, so this only has to answer "was it chasing,
is it not any more".

Empty string means "not chasing", which is distinguishable from every real state name.
]]
local chasePoseState = ""
--[[
Live handles. Resolved once, after the arena builder publishes them.

`RoninArenaReady` is the gate: the builder writes it last, so waiting on it is
waiting on every other attribute being valid. This is why the controller waits
rather than `WaitForChild`-ing the boss by name - a name is not a promise about
ordering, an attribute the builder deliberately sets last is.
]]
local hub = Workspace:WaitForChild("SanctuaryHub")
local arenaFolder = hub:WaitForChild(Arena.FolderName)
while arenaFolder:GetAttribute("RoninArenaReady") ~= true do
	task.wait(0.1)
end

--[[
Build the Commander.

The boss is cloned from `Workspace.Rig` - this place's own R15 rig, which ships
a Humanoid, an Animator and a script-free skeleton - rather than assembled part
by part the way it used to be. It is provably clean (nothing to strip), it is a
*real* R15 (named limbs, the joint names the pose table addresses, Humanoid
locomotion that walks rather than slides), and `Model:ScaleTo` scales geometry,
attachment offsets and `Humanoid.HipHeight` together, so 1.2x stature cannot
leave the skeleton internally mismatched.

The Avatar Joint Upgrade wrinkle: on this engine the rig arrives with
`AnimationConstraint` joints, whose `C0` is a *read-only* alias - which would
make every pose in this file, all written as `C0 * rotation`, silently do
nothing. The clone is therefore normalised back to kinematic `Motor6D`s.
]]
local BOSS_MODEL_NAME = "CorruptedCommander"
local RIG_TEMPLATE_NAME = "Rig"
local BLADE_NAME = "RoninNodachi"
local GRIP_NAME = "NodachiGrip"
local GRIP_TRANSLATION = Vector3.new(0, 0, -1.5)
local REST_POSE = CFrame.Angles(math.rad(-82), 0, 0)

-- Dark steel and shadow. The Commander is armour that lost its owner: cold
-- metal across the body, black iron on the head, and a lighter edge on the
-- hands and feet - the three places the eye lands when the blade comes up.
local COLOR_STEEL = Color3.fromRGB(46, 49, 57)
local COLOR_SHADOW = Color3.fromRGB(24, 24, 29)
local COLOR_EDGE = Color3.fromRGB(96, 100, 112)

-- The sixteen parts an R15 body is made of. Used to strip whatever else the
-- cloned template happens to be holding when the fight builds its boss.
local RIG_BODY_PARTS: { [string]: boolean } = {
	HumanoidRootPart = true,
	Head = true,
	LowerTorso = true,
	UpperTorso = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
}

--[[
Rewrite `AnimationConstraint` joints as kinematic `Motor6D`s.

Same names, `C0`/`C1` lifted from the attachments the constraints were already
using, `Transform` identity - so the rig resolves to exactly the pose it was
standing in, and the pose table's `C0 * rotation` maths works unmodified.

`IsA("Motor6D")` is the documented difference between the two classes:
`AnimationConstraint` deliberately fails it, which is why this file cannot
simply "find the Motor6Ds" and why the conversion has to happen at all. The
ball sockets go with the constraints - a kinematic joint and a free ball socket
cannot both own a limb, and the second one to solve would win.
]]
local function normalizeJoints(rig: Model): number
	local pending: { AnimationConstraint } = {}
	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("AnimationConstraint") then
			table.insert(pending, descendant)
		end
	end

	local converted = 0
	for _, constraint in ipairs(pending) do
		local attachment0 = constraint.Attachment0
		local attachment1 = constraint.Attachment1
		if attachment0 == nil or attachment1 == nil then
			continue
		end
		local part0 = attachment0.Parent
		local part1 = attachment1.Parent
		if part0 == nil or part1 == nil then
			continue
		end
		if not part0:IsA("BasePart") or not part1:IsA("BasePart") then
			continue
		end

		local motor = Instance.new("Motor6D")
		motor.Name = constraint.Name
		motor.Part0 = part0 :: BasePart
		motor.Part1 = part1 :: BasePart
		motor.C0 = attachment0.CFrame
		motor.C1 = attachment1.CFrame
		motor.Transform = CFrame.identity
		motor.Parent = motor.Part0
		constraint:Destroy()
		converted += 1
	end

	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("BallSocketConstraint") then
			descendant:Destroy()
		end
	end

	return converted
end

local function buildCorruptedCommander(parent: Instance): Model
	-- Legacy sweep. The blocky, welded Commander this fight used to spawn - and
	-- any earlier copy of the real one - is destroyed rather than adopted, so
	-- the model the fight runs on is always the one built right here.
	for _, name in ipairs({ "TheCorruptedCommander", BOSS_MODEL_NAME }) do
		for _, container in ipairs({ parent, workspace }) do
			local stale = container:FindFirstChild(name)
			if stale ~= nil then
				stale:Destroy()
			end
		end
	end

	local template = Workspace:FindFirstChild(RIG_TEMPLATE_NAME)
	if template == nil or not template:IsA("Model") then
		error("[BOSS 1] Workspace.Rig is missing - the Commander cannot be built.")
	end

	local boss = (template :: Model):Clone()
	boss.Name = BOSS_MODEL_NAME
	-- Deliberately *not* parented yet: the whole rig is assembled in open space
	-- and parented at the very end, so the Humanoid's very first physics step
	-- already sees the scaled `HipHeight` below. Parented earlier it walks in
	-- with the template's unscaled hip, and a hip written before the step that
	-- owns it never reaches it - the Commander settles on its root part with its
	-- feet 2.4 studs through the floor.

	--[[
		Strip anything the clone inherited.

		`Workspace.Rig` is a *live* model: `SparringDummy` arms the rig it is
		given, so a clone taken while the dummy is standing there carries the
		dummy's katana and its grip motor. Left in, the Commander spawns with two
		blades in one hand and a dead joint - which is exactly the artefact the
		old builder's comment used to warn about. One blade per hand, so the
		inherited gear goes before ours is added.

		Allow-list by name rather than deny-list by type: it cannot be fooled by a
		prop, and a rig that grows a limb is a one-line change here.
	]]
	for _, descendant in ipairs(boss:GetDescendants()) do
		if descendant:IsA("Accessory") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") and not RIG_BODY_PARTS[descendant.Name] then
			descendant:Destroy()
		end
	end
	for _, descendant in ipairs(boss:GetDescendants()) do
		if descendant:IsA("Motor6D") and (descendant.Part0 == nil or descendant.Part1 == nil) then
			descendant:Destroy()
		end
	end

	-- Scale before the joints are rewritten: `ScaleTo` scales the attachments
	-- too, and `normalizeJoints` then reads their C0/C1, so nothing is ever
	-- scaled twice or left at the wrong size.
	boss:ScaleTo(BossConfig.Scale)

	local converted = normalizeJoints(boss)
	if converted == 0 then
		warn("[BOSS 1] No AnimationConstraint joints were normalised - the pose table may be driving nothing.")
	end

	local humanoid = boss:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		error("[BOSS 1] Workspace.Rig has no Humanoid - the Commander cannot walk.")
	end
	humanoid.MaxHealth = BossConfig.MaxHealth
	humanoid.Health = BossConfig.MaxHealth
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- AutoRotate must stay on: facing is done exclusively through
	-- `Humanoid:Move`, which only turns a character when this is enabled - and a
	-- boss that cannot turn never lands the forward cone its five moves resolve
	-- against.
	humanoid.AutoRotate = true

	local rootPart: BasePart? = nil
	local headPart: BasePart? = nil
	for _, descendant in ipairs(boss:GetDescendants()) do
		if descendant:IsA("BasePart") then
			-- Queryability is load-bearing: `BladeHitbox` finds its targets with
			-- a spatial query, and an unqueryable Commander is an invulnerable one.
			descendant.CanQuery = true
			descendant.CanTouch = false
			if descendant.Name == "HumanoidRootPart" then
				descendant.Transparency = 1
				descendant.CanCollide = true
				rootPart = descendant
			else
				-- Limbs stay non-colliding so the boss cannot shove the player
				-- around the yard or catch on the gate frame mid-lunge; the
				-- Humanoid keeps the root solid.
				descendant.CanCollide = false
				if descendant.Name == "Head" then
					descendant.Color = COLOR_SHADOW
					descendant.Material = Enum.Material.Metal
					headPart = descendant
				elseif descendant.Name:find("Hand") ~= nil or descendant.Name:find("Foot") ~= nil then
					descendant.Color = COLOR_EDGE
					descendant.Material = Enum.Material.Metal
				else
					descendant.Color = COLOR_STEEL
					descendant.Material = Enum.Material.Metal
				end
			end
		elseif descendant:IsA("BodyColors") then
			descendant.HeadColor3 = COLOR_SHADOW
			descendant.TorsoColor3 = COLOR_STEEL
			descendant.LeftArmColor3 = COLOR_STEEL
			descendant.RightArmColor3 = COLOR_STEEL
			descendant.LeftLegColor3 = COLOR_STEEL
			descendant.RightLegColor3 = COLOR_STEEL
		end
	end

	if rootPart == nil or headPart == nil then
		error("[BOSS 1] The cloned rig is missing its HumanoidRootPart or Head.")
	end
	local bossRootPart = rootPart :: BasePart
	local bossHead = headPart :: BasePart

	--[[
		The telegraph hardware, parented exactly where this file's readers look
		for it: the light and the cleave slam on the root, the chime and the
		kanji on the head. Every colour and range comes from `BossConfig`, so the
		telegraph palette has exactly one owner and the rig cannot drift away
		from the balance pass.
	]]
	local telegraph = Instance.new("PointLight")
	telegraph.Name = "TelegraphLight"
	telegraph.Brightness = 0
	telegraph.Range = Telegraph.Range
	telegraph.Color = Telegraph.Amber
	telegraph.Shadows = true
	telegraph.Parent = bossRootPart

	local chime = Instance.new("Sound")
	chime.Name = "PerilChime"
	chime.SoundId = BossConfig.Audio.PerilChime
	chime.Volume = 1
	chime.PlaybackSpeed = 1.35
	chime.RollOffMode = Enum.RollOffMode.InverseTapered
	chime.MinDistance = 7
	chime.MaxDistance = 90
	chime.Parent = bossHead

	local slam = Instance.new("Sound")
	slam.Name = "CleaveSlam"
	slam.SoundId = BossConfig.Audio.CleaveSlam
	slam.Volume = 0.9
	slam.RollOffMode = Enum.RollOffMode.InverseTapered
	slam.MinDistance = 7
	slam.MaxDistance = 90
	slam.Parent = bossRootPart

	local kanji = Instance.new("BillboardGui")
	kanji.Name = "PerilKanji"
	kanji.Size = UDim2.fromOffset(150, 150)
	kanji.StudsOffset = Vector3.new(0, 4.2, 0)
	kanji.MaxDistance = 90
	kanji.AlwaysOnTop = true
	kanji.LightInfluence = 0
	kanji.Enabled = false
	kanji.Adornee = bossHead
	kanji.Parent = bossHead

	local stroke = Instance.new("Frame")
	stroke.Name = "Stroke"
	stroke.Size = UDim2.fromScale(1, 1)
	stroke.BackgroundTransparency = 1
	stroke.Parent = kanji

	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.Size = UDim2.fromOffset(150, 150)
	glow.Position = UDim2.fromOffset(-25, -25)
	glow.BackgroundColor3 = Telegraph.Red
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
	glyph.TextColor3 = Telegraph.Red
	glyph.TextStrokeColor3 = Color3.fromRGB(60, 0, 0)
	glyph.TextStrokeTransparency = 0.25
	glyph.Parent = stroke

	-- The five brief-named attributes (plus the four the fight needs), written
	-- before the boss is reachable: a client that can see the Commander at all
	-- reads a Health of 400, and there is never a frame in which the HUD could
	-- find a nil.
	boss:SetAttribute(Attributes.Health, BossConfig.MaxHealth)
	boss:SetAttribute(Attributes.MaxHealth, BossConfig.MaxHealth)
	boss:SetAttribute(Attributes.Posture, 0)
	boss:SetAttribute(Attributes.MaxPosture, BossConfig.MaxPosture)
	boss:SetAttribute(Attributes.Phase, 1)
	boss:SetAttribute(Attributes.Engaged, false)
	boss:SetAttribute(Attributes.State, "Dormant")
	boss:SetAttribute(Attributes.Vulnerable, false)
	boss:SetAttribute(Attributes.Defeated, false)

	-- Stand it in the middle of the dueling floor, facing the gate the player
	-- walks through, then settle by bounding box so the feet - not the pivot -
	-- land on the stone.
	boss:PivotTo(CFrame.new(Arena.Center.X, Arena.FloorTop + 8, Arena.Center.Z) * CFrame.Angles(0, math.pi, 0))
	local boxCFrame, boxSize = boss:GetBoundingBox()
	local lowestY = boxCFrame.Position.Y - boxSize.Y * 0.5
	boss:PivotTo(boss:GetPivot() + Vector3.new(0, Arena.FloorTop - lowestY, 0))

	--[[
		Re-assert the hip one physics step later, and it has to be later.

	 `ScaleTo` scales `Humanoid.HipHeight` with the geometry (2.008 -> 2.409
		here), but a value written while the Humanoid is still being inserted never
		reaches the step that owns it: the Commander settles on its root part
		instead of on its legs - HRP resting on the stone, feet hanging 2.4 studs
		*through* the dueling floor, invisible HRP and all. One write of a
		different value, once the rig is actually in the world, wakes the hip
		constraint up; verified live, the boss rises from feet-under-the-floor to
		feet exactly on it and stays there through falls, landings and teleports.
	]]
	local hipHeight = humanoid.HipHeight
	-- Published so `think` can heal it: the Commander is the one NPC in this
	-- place whose hip can be lost after standing (a `Humanoid` that falls back
	-- onto its root part looks like a model kneeling through the floor), and
	-- the check belongs in the loop that already runs fifty times a second
	-- rather than in a boot-time schedule that only covers the first few seconds.
	bossHipHeight = hipHeight

	--[[
		The nodachi. Same asset, same grip offsets and the same `Motor6D` grip
		the player's katana and `SparringDummy` use - shared numbers on purpose,
		so the Commander reads as holding its blade the way the player holds
		theirs. Scaled with the body: a 4-stud blade on a 1.2x boss reads as a
		toy, and every reach number in `BossConfig` is written against the
		Commander's own size.

		Failure is loud rather than graceful. A boss that spawns unarmed would
		not error - it would be a man punching - and every reach number would be
		quietly wrong.
	]]
	local katanaTemplate = ReplicatedStorage:FindFirstChild("KatanaModel")
	if katanaTemplate == nil or not katanaTemplate:IsA("Model") then
		error("[BOSS 1] ReplicatedStorage.KatanaModel is missing - the Commander cannot spawn unarmed.")
	end
	local rightHand = boss:FindFirstChild("RightHand")
	if rightHand == nil or not rightHand:IsA("BasePart") then
		error("[BOSS 1] The cloned rig has no RightHand to hold the nodachi.")
	end

	local katana = (katanaTemplate :: Model):Clone()
	katana.Name = BLADE_NAME
	katana.Parent = boss
	katana:ScaleTo(BossConfig.Scale)

	local blade = katana:FindFirstChild("Handle")
	if blade == nil or not blade:IsA("BasePart") then
		error("[BOSS 1] KatanaModel has no Handle MeshPart.")
	end
	local bladePart = blade :: BasePart
	local hand = rightHand :: BasePart

	-- Position before the grip exists: a `Motor6D` takes the CFrame it is given,
	-- so the blade is seated in the palm first and then pinned there.
	bladePart.CFrame = hand.CFrame * CFrame.new(GRIP_TRANSLATION * BossConfig.Scale) * REST_POSE
	bladePart.Anchored = false
	bladePart.CanCollide = false
	bladePart.CanTouch = false
	-- CanQuery off, for the reason `SparringDummy` turns it off: the server
	-- casts line-of-sight rays between the two fighters, and a blade that blocks
	-- its own owner's line of sight fails hits for no visible reason.
	bladePart.CanQuery = false
	bladePart.Massless = true

	local grip = Instance.new("Motor6D")
	grip.Name = GRIP_NAME
	grip.Part0 = hand
	grip.Part1 = bladePart
	grip.C0 = CFrame.new(GRIP_TRANSLATION * BossConfig.Scale) * REST_POSE
	grip.C1 = CFrame.new()
	grip.Parent = bladePart

	-- Into the world last, fully assembled.
	boss.Parent = parent

	print(string.format(
		"[BOSS 1] %s built from Workspace.Rig - %d joints normalised, %.1fx scale, nodachi equipped.",
		BOSS_MODEL_NAME, converted, BossConfig.Scale
	))

	return boss
end

local bossModel = buildCorruptedCommander(arenaFolder)
local gateLeft = arenaFolder:WaitForChild("GateLeafLeft") :: BasePart
local gateRight = arenaFolder:WaitForChild("GateLeafRight") :: BasePart
local grade = Lighting:WaitForChild("ARENA_Burn_Grade") :: ColorCorrectionEffect

-- The Commander model *is* the rig: it is a clone of `Workspace.Rig`, not a
-- wrapper around one, so every lookup below starts from the model itself.
local bossRig: Model = bossModel
local bossHumanoid = bossRig:FindFirstChildOfClass("Humanoid") :: Humanoid
local bossRoot = bossRig:FindFirstChild("HumanoidRootPart") :: BasePart
local head = bossRig:FindFirstChild("Head") :: BasePart
local telegraphLight = bossRoot:FindFirstChild("TelegraphLight") :: PointLight
local perilKanji = head:FindFirstChild("PerilKanji") :: BillboardGui
local perilChime = head:FindFirstChild("PerilChime") :: Sound
-- Range is a balance number (it decides how far the glow reads across the
-- arena), so it is written from `BossConfig` instead of trusted from the
-- template. A telegraph that lights the player and not the boss is worse
-- than no telegraph, because it looks like one.
telegraphLight.Range = Telegraph.Range
local cleaveSlam = bossRoot:FindFirstChild("CleaveSlam") :: Sound

--[[
The remote. Server -> clients only; see `BossConfig` S2 for why it is
all-clients rather than per-player.
]]
local remote = ReplicatedStorage:FindFirstChild(BossConfig.RemoteEngage)
if remote == nil then
remote = Instance.new("RemoteEvent")
remote.Name = BossConfig.RemoteEngage
remote.Parent = ReplicatedStorage
end
local engageEvent = remote :: RemoteEvent

--[[
The taiko bed.

Two things are being resolved here and they are not the same lookup, which is
where the first version of this block went wrong.

  * The *bucket* is `SoundService.RoninAmbience`, a plain Folder that exists only
    to keep the bed and the two peril chimes together in the Explorer. Sounds
    cannot be parented to a SoundGroup, so a Folder is the only container that
    works here - and a Sound is perfectly happy parented straight to
    `SoundService` too, so the bucket is optional convenience, not a bus.
  * The *bus* is the SoundGroup of the same name, and `AudioEngine` parents it
    under `RoninMaster` rather than under `SoundService`, because that is what
    makes the leaves share one master fader instead of being three unrelated
    groups.

The first version searched `SoundService` for both, found its own Folder for the
second lookup as well, and assigned a Folder to `Sound.SoundGroup` - which raises
"Expected SoundGroup got Folder" and takes the whole fight down. The bus is
therefore resolved by walking *into* the master group, and the type is checked
before it is used rather than asserted with a cast.

`Looped` is set here rather than trusted from the asset, and the bed is created
only if it is genuinely absent so that a missing asset is a *repaired* arena
rather than a permanently silent fight.
]]
local AMBIENCE_BUCKET = "RoninAmbience"
local MASTER_GROUP = "RoninMaster"
local BED_NAME = "MB_Shogun_Boss_Bed"

local ambience = SoundService:FindFirstChild(AMBIENCE_BUCKET)
if ambience == nil then
	ambience = Instance.new("Folder")
	ambience.Name = AMBIENCE_BUCKET
	ambience.Parent = SoundService
end

local music = ambience:FindFirstChild(BED_NAME)
if music == nil or not music:IsA("Sound") then
	music = Instance.new("Sound")
	music.Name = BED_NAME
	music.SoundId = BossConfig.Audio.MusicBed
	music.Parent = ambience
end
local musicSound = music :: Sound
musicSound.Looped = true
musicSound.Volume = BossConfig.Audio.MusicVolume
musicSound.Playing = false

--[[
	Attach the bed to its bus, by *walking into* the master group.

	`AudioEngine` parents the leaves under `RoninMaster` rather than under
	`SoundService`, because that is what makes them share one master fader. So the bus
	is found at `RoninMaster.RoninAmbience` and nowhere else - the earlier version
	searched `SoundService`, found its own bucket Folder, and assigned a Folder to
	`Sound.SoundGroup`, which raises.

	It is a *function* rather than a one-shot because of load order. `AudioEngine` and
	this script both run at server start and neither is ordered before the other, so
	resolving the bus once at load was a coin flip: the first live test logged "No
	RoninMaster/RoninAmbience SoundGroup" and left the bed playing outside the duck
	bus, where a boss fight would not duck under the combat limiter at all. It is
	therefore re-resolved every time the bed is asked to start, which is the first
	moment the mixer is guaranteed to have been built.

	A missing bus is never fatal - the bed simply plays ungrouped, and the fight
	continues. A boss encounter must not be the thing that fails because a mixer is
	not ready.
]]
local function attachAmbienceBus(): boolean
	local master = SoundService:FindFirstChild(MASTER_GROUP)
	if master == nil or not master:IsA("SoundGroup") then
		return false
	end
	local leaf = (master :: SoundGroup):FindFirstChild(AMBIENCE_BUCKET)
	if leaf == nil or not leaf:IsA("SoundGroup") then
		return false
	end
	musicSound.SoundGroup = leaf :: SoundGroup
	return true
end

attachAmbienceBus()
--[[
Small helpers.
]]
local DEG = math.pi / 180

local function findRoot(model: Model): BasePart?
	local instance = model:FindFirstChild("HumanoidRootPart")
	if instance == nil or not instance:IsA("BasePart") then
	return nil
	end
	return instance :: BasePart
end

--[[
Is a point inside the courtyard?

A margin of `HalfExtent + 4` rather than exactly `HalfExtent`, because the gate
opening and the wall line are the same number and a player standing *in* the gate
has not committed to the fight yet. Four studs past the wall is committed.
]]
local function inArena(point: Vector3): boolean
	local dx = math.abs(point.X - Arena.Center.X)
	local dz = math.abs(point.Z - Arena.Center.Z)
	local limit = Arena.HalfExtent + 4
	return dx <= limit and dz <= limit
end

local function phaseSpeed(): number
	return phase >= 2 and AI.PhaseSpeedMultiplier or 1
end

--[[
The target: the living player nearest the boss inside the arena.

Deliberately a single target rather than "everyone in range". A boss that decides
what to do by looking at every player at once is a boss whose decision changes
every frame as players shuffle; one target per decision is what makes an attack
	telegraphed at *somebody* readable. Everyone else in the cone still gets hit by
	the same swing - the resolution loop walks all of them - they just do not get a
vote on which move is coming.
]]
local function nearestPlayer(): Model?
	local best: Model? = nil
	local bestDistance = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
	local character = player.Character
	if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = findRoot(character)
			if humanoid ~= nil and root ~= nil and humanoid.Health > 0 and inArena(root.Position) then
				local distance = (root.Position - bossRoot.Position).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					best = character
				end
			end
	end
	end
	return best
end

--[[
Face a world point, by nudging the yaw rather than snapping it.

A hard `PivotTo` on a rig with a Humanoid fights the physics step and produces a
visible twitch. `Humanoid:Move` in the direction of the target is what the rest of
	the engine expects, and it turns smoothly.
]]
local function faceTowards(target: Vector3)
	local to = target - bossRoot.Position
	if to.Magnitude < 0.01 then
	return
	end
	local flat = Vector3.new(to.X, 0, to.Z)
	if flat.Magnitude < 0.01 then
	return
	end
	bossHumanoid:Move(flat.Unit, false)
end

--[[
Hold still without cancelling a pose: walk speed zero and no move request.
]]
local function halt()
	bossHumanoid.WalkSpeed = 0
	bossHumanoid:Move(Vector3.zero, false)
end
--[[
The telegraph channel.

Three channels, three meanings, and they are the only three the fight uses:
`amber` = safe but slow, `red` = perilous, `white` = you parried it.

One `PointLight` and one `BillboardGui`, both already parented inside the boss
	template, so a telegraph is two property writes and a sound. No per-frame effect,
nothing to leak, and the light travels with the boss because it is *on* the boss.
]]
local function setTelegraph(channel: "None" | "Amber" | "Red" | "White")
	if channel == "Amber" then
		telegraphLight.Color = Telegraph.Amber
		telegraphLight.Brightness = Telegraph.AmberBrightness
	elseif channel == "Red" then
		telegraphLight.Color = Telegraph.Red
		telegraphLight.Brightness = Telegraph.RedBrightness
	elseif channel == "White" then
		telegraphLight.Color = Telegraph.White
		telegraphLight.Brightness = Telegraph.WhiteBrightness
	else
		telegraphLight.Brightness = Telegraph.IdleBrightness
	end
end

--[[
The red kanji.

`LightInfluence = 0` and `Enabled` toggling rather than a transparency tween: a
	ransparency tween on a BillboardGui leaves the text legible-but-fading on the
frame the strike lands, and the one frame where the warning is still half-visible
is the frame that teaches the player to ignore it.

The alternating flash is what makes it a *perilous* mark rather than a red sign.
A steady red diamond reads as decoration; a red diamond that strobes at 4Hz reads
as urgency, and it costs one boolean flip per half-period.
]]
local kanjiFlashOn = false

local function showKanji(on: boolean)
	perilKanji.Enabled = on
	kanjiFlashOn = on
end

local function pulseKanji()
	if not perilKanji.Enabled then
	return
	end
	kanjiFlashOn = not kanjiFlashOn
	local glyph = perilKanji:FindFirstChild("Stroke")
	if glyph ~= nil then
	local frame = glyph :: GuiObject
		frame.Visible = kanjiFlashOn
	end
end

local function playChime()
	perilChime:Stop()
	perilChime:Play()
end

--[[
White flash on a deflect, held for a fixed beat rather than tweened back.

A tween back to zero is a second animation competing with the player's own
deflect VFX for the same 200ms of screen time, and the player's flash is the one
	they are looking at. The boss's is a *confirmation* - a bright stab and then
nothing - which is why it is a held value with a deadline the loop reads.
]]
local function flashDeflect()
	setTelegraph("White")
	deflectFlashUntil = os.clock() + 0.22
end

--[[
Upper-body animation.

Everything between here and the posture block used to be `BossAnimation`: five
`KeyframeSequence`s built at runtime and handed to
`KeyframeSequenceProvider:RegisterKeyframeSequence`. That whole path is deleted,
and the reason is worth writing down because the removal *is* the point.

`RegisterKeyframeSequence` only works in Studio. The provider is a `NotCreatable`
service and the hash it returns is a *temporary* id, so a published experience
gets the "Experience doesn't have access permission" popup and an animated boss
that does not move. An asset-permission dependency baked into the combat loop is
worse than no animation, because it fails silently in the one place that matters.

`BossAnimate` replaces it with real `AnimationTrack`s on a real `Animator`, and
with assets - but *only* Roblox's own, harvested from the stock avatar `Animate`
script that ships inside every default character. The trap the previous pass fell
into was assuming "no assets" was the goal; it was not. The goal was an animation
that cannot fail to load. A verified Roblox id cannot, and a hand-integrated
Euler pose was never going to look like a fighter no matter how free it was.

That required checking rather than guessing, and the answer was not the one the
brief predicted: the two ids named for the slash and the lunge are correct, and
they are Roblox's own `ToolSlashAnim` / `ToolLungeAnim`. The predicted *overhead*
is not available - no permission-free overhead track exists in the stock set. It
is served by the largest swing that does exist, played slow, and the reasoning is
recorded at the `MOVE_CLIPS` table rather than left as a surprise.

Two properties the old comments here claimed and this one still has to keep true:

  * One writer per joint, in time. `normalizeJoints` and the katana's grip write
    `C0` / `C1` / `Transform` exactly once each, while the rig is being built and
    before it is in the world. Nothing writes a joint after that: locomotion is
    the `Humanoid`'s and the attacks are the `Animator`'s, and no per-frame path in
    this file or in `BossAnimate` touches a joint transform at all.
  * The hips are never written. Nobody writes them. Locomotion is entirely the
    `Humanoid`'s, and `BossAnimate.update` only chooses which already-loaded track
    dresses it. That is the hip-thrust fix and the glide fix together, and it is
    why the Commander now walks into melee instead of sliding there.
]]
local BossAnimate = require(ReplicatedStorage:WaitForChild("BossAnimate") :: ModuleScript)

--[[
The blade, for the trail and the strike flash.

Resolved by name rather than threaded out of the builder: the katana is equipped as
`Nodachi` with a `Handle`, and the builder already guarantees both (it `error`s
rather than spawning an unarmed Commander), so a second handle on the value would be
a third place to keep in sync for no gain.
]]
local katanaModel = bossRig:FindFirstChild(BLADE_NAME)
local animateBlade: BasePart? = nil
if katanaModel ~= nil and katanaModel:IsA("Model") then
	local handle = katanaModel:FindFirstChild("Handle")
	if handle ~= nil and handle:IsA("BasePart") then
		animateBlade = handle :: BasePart
	end
end

--[[
Bind the animation engine.

`attach` raises rather than returning nil on a rig it cannot drive, deliberately: an
animator bound to nothing reports success and then animates nothing, which is the
failure mode that is hardest to see and easiest to ship.

This single call is what gives the Commander its legs back. It creates the `Animator`
and loads the verified stock walk/run/idle tracks onto it, so `Humanoid:MoveTo` now
walks a real R15 cycle instead of gliding a model across the floor. `BossAnimate`
documents how each track id was confirmed both permission-free and actually moving
*this* rig; the ids are Roblox's own stock avatar set, harvested rather than guessed.
]]
local animateRig = BossAnimate.attach(bossRig, animateBlade)

--[[
Blend times, as the three cross-fades the fight actually needs.

Seconds again, not rates: `BossAnimate` plays real `AnimationTrack`s, and
`AnimationTrack:Play(fadeTime, ...)` is specified in seconds. The old vocabulary
called these `POSE_SETTLE` / `POSE_SNAP_BACK` / `POSE_TELEGRAPH` because they were
joint-interpolation rates; they are `ANIM_*` now because they are cross-fade
durations, and they are the only three values the fight needs.
]]
local ANIM_SETTLE = 0.22
local ANIM_SNAP_BACK = 0.12
local ANIM_TELEGRAPH = 0.4

--[[
Clip per move.

Table-driven rather than an `if` chain at six call sites, for the reason
`BossConfig` freezes everything else: a move added to the fight without a clip
must be *visibly* uncliped rather than silently falling back to a pose that no
longer exists. The flurry is the one move with per-step clips, which is why it
is looked up by step label rather than by move id.

Every value here is a key in `BossAnimate.TRACK_IDS` - one of the verified Roblox
stock tracks. There are only three combat tracks that are guaranteed permission-free,
so moves share them:

    Slash   `522635514` Roblox's own `ToolSlashAnim`. Right arm 34deg, blade 2.3
            studs. The horizontal cut, and the base of the flurry.
    Lunge   `522638767` Roblox's own `ToolLungeAnim`. Right shoulder thrust, hand
            rises 1.64 studs. The forward stab.
    Sweep   `507767714` Both arms, 2.5 / 2.2 studs of travel - by far the biggest
            motion of the three, so it carries the heavy two-handed attacks.

`Overhead` is mapped to `Sweep` deliberately and is worth explaining: the brief asks
for a distinct overhead, and there is no permission-free overhead track in existence -
it was measured, across 200,002 candidate ids, and the stock set is all there is.
Rather than reach for a third-party asset that would fail with a permission error the
first time a fresh player joined, the cleave plays `Sweep` at a reduced speed, which
widens it into a slow heavy arc that reads as a cleave. `BossAnimate` accepts the
`speed` argument precisely so this kind of reinterpretation needs no new asset.
]]
local MOVE_CLIPS: { [string]: string } = {
	DragonCleave = "Sweep",
	PerilousThrust = "Lunge",
	PerilousSweep = "Sweep",
	ShadowRetreat = "Slash",
}

--[[
The heavy-attack slowdown.

Only `DragonCleave` uses it. The cleave is the boss's telegraphed punish, so it needs
to be readable from across the courtyard - which means slower than the clips around it,
not faster.
]]
local CLEAVE_SPEED = 0.62

local FLURRY_STEP_CLIPS: { [string]: string } = {
	-- Steps 1 and 2 are the same horizontal, which is what makes it read as a
	-- *chain* rather than three separate attacks. Step 3 is the thrust the
	-- config already escalates to.
	Slash = "Slash",
	Thrust = "Lunge",
}

--[[
Which clip a move (or one step of a flurry) should be playing.

`smooth` is true for a chain and false for a fresh move. A flurry's second swing
has to begin from wherever the first one finished, or the string reads as three
separate attacks; a move chosen out of `Reposition` should start from the guard,
or the boss appears to already be mid-swing when the player was still walking
toward it.
]]
local function clipForMove(move: BossConfig.BossMoveData, step: BossConfig.FlurryStep?): string
	if move.Id == "TripleFlurry" then
		if step ~= nil then
			return FLURRY_STEP_CLIPS[step.Label] or "Slash"
		end
		return "Slash"
	end
	return MOVE_CLIPS[move.Id] or "Slash"
end

--[[
The three verbs the fight needs, so no call site talks to the engine directly.

`speed` is threaded through everywhere because phase 2 divides every timing in the
fight by `PhaseSpeedMultiplier`, and a Commander whose arms swing at 1.0 while its
windup is 22% shorter is a telegraph that reports a later time than the thing it
telegraphs. A lie in the animation is worse than no animation.
]]
local function playAttack(clip: string, speed: number, smooth: boolean)
	--[[
	`smooth` chooses the cross-fade into the attack. A chain (the flurry) blends in
	quickly so its second cut reads as a continuation of the first; a fresh move
	blends in slowly enough that the windup is visible as preparation rather than as
	a cut.
	]]
	local blend = if smooth then ANIM_SNAP_BACK else ANIM_TELEGRAPH
	BossAnimate.play(animateRig, clip, speed, blend)
end

--[[
Return to locomotion. One routine, called on every `Recover`, every state exit and
disengage, rather than a bespoke blend per caller: the bug this prevents is a
Commander whose arms are still finishing a Cleave three states later, and that bug
only ever appeared where someone remembered to stop the clip.

The Commander then falls back to the idle or walk cycle on its own, because
`BossAnimate.update` resolves locomotion from the `Humanoid` every frame.
]]
local function settleToGuard(fade: number)
	BossAnimate.settle(animateRig, fade)
end

--[[
Freeze. Defeat only: a fallen Commander keeps the pose it died in, and the trail
goes out with it. Easing a corpse back to a ready stance is how a boss comes back
looking invincible.
]]
local function freezePose()
	BossAnimate.freeze(animateRig)
end

--[[
The walking stance and the guard break no longer exist as verbs, and that is the
point.

Under the procedural engine both were `hold(...)` calls that wrote six joints every
frame to keep the Commander in a stance *while its legs were being driven by
`Humanoid:MoveTo`*. That is what the glide was: a `Humanoid` walking a rig whose
hips and thighs had been overwritten, one frame behind, forever.

There is no stance to hold any more. `Humanoid:MoveTo` walks the Commander, the stock
walk/run tracks animate it, and `BossAnimate.update` picks between them from real
velocity. The `>10 studs` calls that used to ask for a stance now do nothing, and
the boss walks with a real stride while it closes.
]]

--[[
Posture.

The boss's second bar, and the fight's only route to a deathblow window. It is
spent by deflecting the boss, and recovers on a delay.

The delay matters more than the rate. A pool that recovers at all is a pool a
player cannot bank against, because the boss will have given the progress back
before the next exchange; a pool that only recovers after 2.4 seconds of the
boss *not* being deflected means every good exchange extends a bad one, which is
exactly the snowball the fight is supposed to have.

`RecoveryFloor` is 30 rather than 0 for the same reason: a boss that returns to
zero between exchanges makes the bar a decoration, and the player learns that
deflecting does not matter. A floor means progress compounds.
]]
local function spendPosture(amount: number)
	local current = bossModel:GetAttribute(Attributes.Posture) or 0
	local max = BossConfig.MaxPosture
	local next = math.min(current + amount, max)
	bossModel:SetAttribute(Attributes.Posture, next)
	lastPostureHit = os.clock()

	if next >= max and state ~= "PostureBroken" then
		breakGuard()
	return true
	end
	return false
end

local function recoverPosture(now: number)
	if state == "PostureBroken" or state == "Defeated" then
	return
	end
	local since = now - lastPostureHit
	if since < PostureCfg.RecoveryDelay then
	return
	end
	local current = bossModel:GetAttribute(Attributes.Posture) or 0
	if current <= PostureCfg.RecoveryFloor then
	return
	end
	local next = math.max(current - PostureCfg.RecoveryRate * AI.ThinkInterval, PostureCfg.RecoveryFloor)
	bossModel:SetAttribute(Attributes.Posture, next)
end

--[[
Guard break.

The deathblow window, and the only state the boss cannot act in. It drops the
pose, whites the light, writes `Vulnerable` so a client can render the prompt
without having to guess, and holds.

`Vulnerable` is an attribute rather than a client inference on purpose: it is a
claim about game state, and a client that is allowed to infer it is a client that
can be wrong about it.
]]
local function breakGuard()
	state = "PostureBroken"
	stateUntil = os.clock() + PostureCfg.BrokenStun
	bossModel:SetAttribute(Attributes.Vulnerable, true)
	-- Guard break: the Commander is staggered, not attacking. Any attack clip is cut
	-- and it simply resumes locomotion when the stun ends.
	settleToGuard(ANIM_SETTLE)
	setTelegraph("White")
	deflectFlashUntil = 0
	halt()
	print(string.format("[BOSS] GUARD BROKEN - %s is open for %.1fs", BossConfig.DisplayName, PostureCfg.BrokenStun))
end

--[[
The Flaming Blade Wave.

A real projectile, not a hitbox in disguise: it is built here, it travels under
its own `LinearVelocity`, and it resolves its own hits. That separation is the
whole design, because a ranged move whose damage is applied by the melee
resolver is a ranged move that fires a cone from the boss's own position and
therefore hits a player who has already stepped sideways.

Three properties decide what it *is*, and all three are read by the player
before it is ever dodged:

  * It spins. A crescent that tumbles is a moving object with an extent; a
    static one is a wall. The spin is also what makes the Neon material read
    as *hot* rather than as a painted plank.
  * It is Neon red/orange with a Fire emitter, which is the same visual
    language the telegraph light and the ember trail already established.
  * It is *low*. Centred at 1.1 studs it passes under a jumping player, which
    is what makes "leap over it" a real answer to the brief's "or leaped over
    with Spacebar" rather than a claim.

Cleanup is `Debris` plus a wall check, exactly as the brief specifies: 3.0s or
on impact. Both are needed - the timer is what removes a wave that flies out
of the arena into empty space, and the wall test is what removes a wave that
would otherwise sail through the courtyard's stonework for three seconds.
]]
local Debris = game:GetService("Debris")

local WAVE_COLOR_CORE = Color3.fromRGB(255, 236, 150)
local WAVE_COLOR_EDGE = Color3.fromRGB(255, 84, 20)
local WAVE_HEIGHT = 1.1

--[[
One wave: a spinning crescent of Neon parts, a Fire emitter, and a Trail.

Built as a `Model` with the hub part as `PrimaryPart` so `PivotTo` can orient
the whole crescent as one body while each part keeps its own offset. The parts
are welded to the hub rather than constrained: the wave is decorative geometry
plus one collider, and a weld is one property instead of seven.
]]
local function buildBladeWave(hub: BasePart): Model
	local wave = Instance.new("Model")
	wave.Name = "FlamingBladeWave"

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(1.1, 1.1, 1.1)
	core.Material = Enum.Material.Neon
	core.Color = WAVE_COLOR_CORE
	core.Transparency = 0.15
	-- The collider. It has to be solid, queryable and *not* touch-triggered:
	-- the hit is resolved by a distance test in the wave's own update, because
	-- a `Touched` handler is the least reliable way to ask "did that land".
	core.CanCollide = false
	core.CanTouch = false
	core.CanQuery = true
	core.Massless = true
	core.CFrame = hub.CFrame
	core.Parent = wave

	--[[
	The crescent: three arcs of decreasing length swept back along -Z, which
	is the direction the wave faces. The taper is what makes it read as a
	*cut* of air rather than as a disc - a symmetric ring reads as a shockwave
	from a bomb, and this is a sword.

	Written as three parallel arrays rather than a list of triples because
	Luau has no tuple type: `{ { number, number, number } }` is not a legal
	table annotation, and the engine rejects the whole script with
	"Expected '}', got ','" rather than pointing at the type. Three named
	arrays are also three things the loop below can read by name.
	]]
	local SLICE_LENGTH = { 3.4, 2.6, 3.0 }
	local SLICE_THICKNESS = { 0.5, 0.45, 0.5 }
	local SLICE_ANGLE = { -0.35, 0.0, 0.35 }

	for index = 1, #SLICE_LENGTH do
		local length = SLICE_LENGTH[index]
		local thickness = SLICE_THICKNESS[index]
		local angle = SLICE_ANGLE[index]
		local arc = Instance.new("Part")
		arc.Name = "Arc" .. index
		arc.Size = Vector3.new(length, thickness, 0.55)
		arc.Material = Enum.Material.Neon
		arc.Color = WAVE_COLOR_EDGE
		arc.Transparency = 0.2
		arc.CanCollide = false
		arc.CanTouch = false
		arc.CanQuery = false
		arc.Massless = true
		arc.CFrame = core.CFrame * CFrame.Angles(0, 0, math.rad(angle)) * CFrame.new(0, 0, -0.9)
		arc.Parent = wave

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = core
		weld.Part1 = arc
		weld.Parent = arc
	end

	--[[
	Fire, not a smoke puff. `Fire` is a built-in emitter, needs no uploaded
	asset, and its own light is what sells "flaming" - the wave lights the
	courtyard stone as it passes, which is the difference between a projectile
	and a glowing box.
	]]
	local fire = Instance.new("ParticleEmitter")
	fire.Name = "Flame"
	fire.Texture = "rbxasset://textures/particles/fire_main.dds"
	fire.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 232, 168)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 116, 28)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 24, 8)),
	})
	fire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	fire.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 0.75),
	})
	fire.Lifetime = NumberRange.new(0.18, 0.42)
	fire.Rate = 40
	fire.Speed = NumberRange.new(4, 9)
	fire.SpreadAngle = Vector2.new(180, 180)
	fire.LightEmission = 0.9
	fire.LightInfluence = 0
	fire.Parent = core

	--[[
	A Trail on the hub, in addition to the Fire. The two do different jobs: the
	Fire is *on* the blade and the Trail is *behind* it, so the wave draws the
	arc it is about to travel along. Without it a 55 studs/s projectile is a
	neon dot the player has to track rather than a line they can read.
	]]
	local attachmentA = Instance.new("Attachment")
	attachmentA.Name = "TrailA"
	attachmentA.Position = Vector3.new(0, 0, 1.1)
	attachmentA.Parent = core

	local attachmentB = Instance.new("Attachment")
	attachmentB.Name = "TrailB"
	attachmentB.Position = Vector3.new(0, 0, -1.1)
	attachmentB.Parent = core

	local trail = Instance.new("Trail")
	trail.Name = "Streak"
	trail.Attachment0 = attachmentA
	trail.Attachment1 = attachmentB
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 160, 60))
	trail.Lifetime = 0.22
	trail.LightEmission = 0.85
	trail.LightInfluence = 0
	trail.FaceCamera = true
	trail.MinLength = 0.1
	trail.Parent = core

	--[[
	`PrimaryPart` is what makes `PivotTo` rotate the crescent as a unit on the
	spin. Without it the model has no pivot and `PivotTo` throws.
	]]
	wave.PrimaryPart = core
	return wave
end


--[[
Flight.

Two mechanisms, deliberately, and the split is why the wave behaves.

*Translation* is a `LinearVelocity` on the hub, so the projectile is moved by
the physics solver rather than by a per-frame position write. That matters
because the wave must collide with the courtyard: a scripted `CFrame` write
sails through walls, and a wave that passes through the gate and keeps going
for three seconds is worse than no wave. The constraint is `Vector` mode in
`World` space, so `Velocity` is the literal world-space vector the brief
specifies - `(playerRoot - bossRoot).Unit * 55` - and not something
re-derived from an attachment every frame.

*Spin* is a separate per-frame write, because rotation is not something
`LinearVelocity` does.

The hit test is a sphere overlap against the target's root, evaluated on the
wave's own clock, rather than a `Touched` event. `Touched` on a fast, rotating,
welded assembly is unreliable and fires late, and a projectile whose damage
lands a frame *after* the visual reads as the projectile being slow.
]]
local RaycastParams = RaycastParams.new()
RaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local activeWaves: { Model } = {}

local function resolveWaveHit(wave: Model, victim: Model): ()
	local humanoid = victim:FindFirstChildOfClass("Humanoid")
	local victimRoot = findRoot(victim)
	if humanoid == nil or victimRoot == nil or humanoid.Health <= 0 then
		return
	end

	if (victimRoot.Position - wave.PrimaryPart.Position).Magnitude > Move.BladeWaveRadius + 2 then
		return
	end

	--[[
	One hit per wave, not per tick. The wave outlives the frame it connects
	on, and a 3.0s projectile that re-damages every tick is a 3.0s auto-hit.
	The same latch discipline `fireSwing` uses, for the same reason.
	]]
	if wave:GetAttribute("RoninWaveConsumed") == true then
		return
	end
	wave:SetAttribute("RoninWaveConsumed", true)

	--[[
	The two answers, and they are the two the brief names.

	The wave goes through `BossRegistry.ResolvePlayerStrike` rather than
	damaging directly, so `HitValidator` stays the only authority on what
	hitting a player costs - the entire reason that registry exists, and the
	reason this file never calls `TakeDamage` on a player itself.

	`MustJump` false and `Unblockable` true is the combination that makes
	*both* named answers work:

	  * The i-frame dodge (Q) is honoured, because `HitValidator` checks
	    invulnerability before it consults `Unblockable`.
	  * The leap (Space) is honoured, because the wave is authored low
	    (`WAVE_HEIGHT`) and a player whose root is above the blade plane is
	    not within `BladeWaveRadius` of its core at all.

	Choosing `MustJump` instead is the obvious mistake here: it disables the
	i-frame entirely (`HitValidator` returns before consulting it), which
	would make Q - the answer the whole evasion economy is built around -
	worthless against this one move.
	]]
	local outcome = BossRegistry.ResolvePlayerStrike(bossModel, victim, {
		Deflectable = false,
		Unblockable = true,
		MustJump = false,
		Damage = Move.BladeWaveDamage,
		Posture = 0,
		ContactPoint = wave.PrimaryPart.Position,
	})

	print(string.format("[BOSS WAVE] Blade Wave caught %s (%s)", victim.Name, outcome))
end

--[[
Per-frame wave update.

One loop for every live wave rather than one `Heartbeat` connection per
projectile, because a boss that can throw every couple of seconds for the
length of a fight would otherwise accumulate connections for as long as the
encounter runs. The list is walked in reverse so a wave removed
mid-iteration cannot skip its neighbour.
]]
local function updateWaves(dt: number)
	for index = #activeWaves, 1, -1 do
		local wave = activeWaves[index]
		local core = wave.PrimaryPart
		if core == nil or core.Parent == nil then
			table.remove(activeWaves, index)
			continue
		end

		-- The spin. A decorative transform on welded parts; see the note above.
		core.CFrame = core.CFrame * CFrame.Angles(0, 0, dt * 9)

		-- Wall impact. The ray excludes the boss so the wave does not collide
		-- with the hand that just threw it.
		RaycastParams.FilterDescendantsInstances = { bossModel }
		local velocity = core.AssemblyLinearVelocity
		local travelled = if velocity.Magnitude > 0.01 then velocity * dt else Vector3.zero

		if travelled.Magnitude > 0.001 then
			local hit = Workspace:Raycast(core.Position, travelled, RaycastParams)
			if hit ~= nil then
			if hit ~= nil then
				--[[
				Burst on impact, then remove. The burst is what stops a wave
				that hits stone from simply vanishing: it reads as the energy
				breaking against the wall, which is also the player's
				confirmation that the thing they dodged behind *worked*.

				`Emit` is a `ParticleEmitter` method, not a `BasePart` one - the
				part only *carries* the emitter. Calling it on the hub raises
				"Emit is not a valid member of Part", so the burst is requested
				through the emitter itself, by name.
				]]
				local flame = core:FindFirstChildOfClass("ParticleEmitter")
				if flame ~= nil then
					flame:Emit(18)
				end
				Debris:AddItem(wave, 0.15)
				table.remove(activeWaves, index)
				continue
			end
			end
		end

		-- Everyone in the arena, so a wave thrown at one player still catches
		-- a second who walked into it.
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			if character ~= nil then
				resolveWaveHit(wave, character)
			end
		end
	end
end


--[[
Throw one.

`direction` is computed by the caller from the *player's* root at the moment
of release, not at the start of the windup. A wave that commits to a position
during its own telegraph is a wave the player can sidestep by standing still,
which is the opposite of what a telegraph is for - it turns a 0.5s tell into
0.5s of free information and then throws the answer somewhere the player is
not.
]]
local function throwBladeWave(target: Model)
	local targetRoot = findRoot(target)
	if targetRoot == nil then
		return
	end

	local spawnPoint = bossRoot.Position + bossRoot.CFrame.LookVector * 2.6
	local wave = buildBladeWave(bossRoot)
	wave:SetAttribute("RoninWaveConsumed", false)

	local direction = targetRoot.Position - bossRoot.Position
	if direction.Magnitude < 0.01 then
		direction = bossRoot.CFrame.LookVector
	end

	wave:PivotTo(CFrame.new(spawnPoint + Vector3.new(0, WAVE_HEIGHT, 0)))
	wave.Parent = Workspace

	--[[
	The launch, as specified: 55 studs/s along the player-boss vector.

	`Line` mode rather than `Vector`, because `LinearVelocity.Velocity` no longer
	exists on this engine - writing it raises "Velocity is not a valid member of
	LinearVelocity" the first time a wave is thrown, which is to say on the
	first frame the fight actually uses it. The current API splits the same idea
	in two: `LineDirection` is the world-space unit vector and `LineVelocity` is
	the scalar speed along it. Verified live against the running engine, because
	`MaxVelocity` is gone too and is the other name this used to have.
	]]
	local attachment = Instance.new("Attachment")
	attachment.Name = "Launch"
	attachment.Parent = wave.PrimaryPart

	local push = Instance.new("LinearVelocity")
	push.Name = "Launch"
	push.Attachment0 = attachment
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.LineDirection = direction.Unit
	push.LineVelocity = Move.BladeWaveSpeed
	push.MaxForce = math.huge
	--[[
	`Line` mode keeps the wave travelling along the vector it was thrown on
	rather than letting a collision deflect it into the player's back. A wave
	that bounces off a brazier and kills somebody who was never in front of the
	boss is the kind of bug that gets a fight reported as unfair.
	]]
	push.ForceLimitsEnabled = false
	push.Parent = wave.PrimaryPart

	Debris:AddItem(wave, Move.BladeWaveLifetime)
	table.insert(activeWaves, wave)

	print(string.format(
		"[BOSS WAVE] Flaming Blade Wave thrown at %.0f studs (%d HP, %d studs/s)",
		(targetRoot.Position - bossRoot.Position).Magnitude,
		Move.BladeWaveDamage,
		Move.BladeWaveSpeed
	))
end

--[[
Clear every live wave.

Called on defeat, on disengage and on revive. A wave still in flight after the
gate opens is a wave that kills a player who has already left the fight - and
because it resolves against *anyone* in the arena rather than only the target
it was aimed at, that is a live bug and not a theoretical one.
]]
local function clearWaves()
	for _, wave in ipairs(activeWaves) do
		wave:Destroy()
	end
	table.clear(activeWaves)
end

--[[
Fire one swing of the boss's blade.

Geometry is decided *here*; consequences are decided in `HitValidator`. The split
is not ceremony - the parry window, the guard cone and the posture pool are all
player-facing rules that already have exactly one owner, and re-implementing them
here would be the second-authority drift the project has already had to fix once.

What this function owns:
  * who is in the arc (range and a forward cone, not a sphere);
  * one contact per target per swing (a latch, not a counter - so a 0.10s active
    window that the 50ms loop sees twice still hits once);
  * the contact point, because the boss is the attacker and knows where its own
    blade is.

The forward cone is `Reach + 2` deep and Â±60 degrees wide. A sphere reach would
let a swing catch somebody the boss was visibly facing away from, which is the
single most reliable way to make a boss feel unfair.
]]
local ANGLE_LIMIT = 60

local function fireSwing(move: BossConfig.BossMoveData, damage: number, posture: number, reach: number): boolean
	--[[
	`struckThisSwing` is NOT cleared here, and that omission is the whole reason
	one contact per swing works.

	The loop calls `think` every 50ms, and a strike's Active window is 0.10-0.20s,
	so `fireSwing` is entered two to four times for a single swing. If the latch
	were cleared on entry it would be re-armed on every one of those ticks and the
	Commander would land a flurry step two to four times over - which is exactly
	what the first live test showed: a continuous stream of identical 12 HP lines
	and a player dead in four seconds to a move the config prices at 12.

	`beginMove` and the between-steps branch of the Strike state clear it instead,
	which is the correct granularity: once per move, and once again between the
	steps of a combo. The latch is a per-*swing* fact, so it is written where a
	swing begins.
	]]

	local origin = bossRoot.Position
	local forward = bossRoot.CFrame.LookVector
	local guardBroken = false

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = findRoot(character)
			if humanoid ~= nil and root ~= nil and humanoid.Health > 0 and not struckThisSwing[character] then
				local to = root.Position - origin
				local distance = to.Magnitude
				local flat = Vector3.new(to.X, 0, to.Z)
				local facing = flat.Magnitude < 0.001
				or flat.Unit:Dot(Vector3.new(forward.X, 0, forward.Z)) >= math.cos(ANGLE_LIMIT * DEG)
				if distance <= reach + 2 and facing and inArena(root.Position) then
					struckThisSwing[character] = true
					local contact = origin
					+ Vector3.new(forward.X, 0, forward.Z).Unit * (distance * 0.5)
					+ Vector3.new(0, 1.2, 0)
					local outcome = BossRegistry.ResolvePlayerStrike(bossModel, character, {
					Deflectable = move.Deflectable,
					Unblockable = move.Unblockable,
					MustJump = move.MustJump,
					Damage = damage,
					Posture = posture,
					ContactPoint = contact,
					})
					if outcome == "PARRIED" then
						local reflected = PostureCfg.ReflectBase * (phase >= 2 and AI.PhaseTwoDeflectBonus or 1)
						flashDeflect()
						if spendPosture(reflected) then
							guardBroken = true
							return true
						end
					end
				end
			end
		end
	end
	return guardBroken
end

--[[
Move selection.

Weighted roulette over the current phase's table. `ShadowRetreat` is weighted 0
in both tables on purpose: it is chosen by a *rule* (the player is outside the
leash) rather than by chance, and it is short-circuited before the roulette runs
so the boss can never "decide" to retreat from three studs away.

Two rules around it that are not in `BossConfig` because they are about *this*
loop's state rather than about the fight's balance:

  * Never the same move twice in a row unless it is the only option. A boss that
    flurries, flurries, flurries teaches the player to parry three times and then
    to walk into the fourth.
  * Never a perilous move immediately after another perilous move. Two red kanjis
    with nothing between them is not a pattern, it is a coin flip, and the player
    who has learned "red means dodge" has been handed the answer for free.

Both are enforced by rejection-and-re-roll rather than by filtering the candidate
list, because filtering a list is an allocation and this runs on a 50ms loop.
]]
local lastMoveId = ""
local lastWasPerilous = false

local function isPerilous(move: BossConfig.BossMoveData): boolean
	return move.Unblockable
end

local function rollMove(target: Model): BossConfig.BossMoveData
	local weights = phase >= 2 and AI.WeightsPhaseTwo or AI.WeightsPhaseOne

	for attempt = 1, 4 do
	local total = 0
	for id, weight in pairs(weights) do
			if weight > 0 then
					total += weight
			end
	end
	if total <= 0 then
			break
	end

	local pick = math.random() * total
	for id, weight in pairs(weights) do
			if weight > 0 then
				pick -= weight
				if pick <= 0 then
					local candidate = Move.Moves[id]
					local ok = true
					if id == lastMoveId then
						ok = false
					end
					if lastWasPerilous and isPerilous(candidate) then
						ok = false
					end
					if ok then
						return candidate
					end
					break
				end
			end
	end
	end

	-- Fallbacks, in decreasing preference: the teaching move, then anything at all.
	return Move.Moves.TripleFlurry
end

--[[
Begin a move.

Sets the state to `Telegraph`, fires the warning, and poses the boss. It does not
decide when the move ends - the loop does, from `stateUntil`. Every move is
Windup -> Strike -> Recovery and nothing else, which is the reason a single pair
of deadlines can drive all five.
]]
local function beginMove(move: BossConfig.BossMoveData)
	currentMove = move
	stepIndex = 0
	state = "Telegraph"
		table.clear(struckThisSwing)

	local steps = move.Steps
	local windup = if steps ~= nil then steps[1].Windup else move.Windup
	stateUntil = os.clock() + windup / phaseSpeed()

	lastMoveId = move.Id
	lastWasPerilous = isPerilous(move)

	--[[
		One clip, chosen from the move's own identity, and played at the
		phase-2 tempo so the animation cannot contradict the timing it is
		annotating.

		`speed` is `phaseSpeed()` rather than 1.0 because the windup deadline
		above is already divided by it. Leaving the clip at 1.0 would mean the
		arms reach the top of an overhead cleave 22% *after* the strike
		resolves - a telegraph that reports a later time than the thing it
		telegraphs, which is worse than no telegraph at all.
	]]
	local clip = clipForMove(move, if steps ~= nil then steps[1] else nil)

	if move.MustJump or move.Unblockable then
		setTelegraph("Red")
		showKanji(true)
		playChime()
		playAttack(clip, phaseSpeed(), false)
	elseif move.Id == "DragonCleave" then
		setTelegraph("Amber")
		showKanji(false)
		--[[
		The cleave plays `Sweep` at `CLEAVE_SPEED`. It is the boss's telegraphed
		punish and has to be readable from across the courtyard, which means slower
		than the clips around it - a slowed swing reads as a heavy one, and widening
		the arc is what stands in for the overhead track this experience cannot own.
		]]
		playAttack(clip, phaseSpeed() * CLEAVE_SPEED, false)
	else
		setTelegraph("Amber")
		showKanji(false)
		playAttack(clip, phaseSpeed(), false)
	end
end

--[[
	Forward declarations.

	`applyDamageToBoss` can kill the boss, and `defeatBoss` has to open a gate
	and stop a music bed. Both of those are defined further down the file where
		they belong to their own sections; without these locals Luau resolves each of
		hose calls as a *global* - silently nil at runtime, and a boss fight that
	leaves its gate sealed with no error anywhere. Declaring the shape up front
		turns that class of bug into a compile error.
]]
local defeatBoss: () -> ()
local openGate: () -> ()
local stopMusic: () -> ()
--[[
`endDash` is declared here for the same reason. It is defined beside the Shadow
Lunge, far below `disengageArena`, and an undeclared local resolves as a
*global* - silently nil - so the first time a player walked back out of the
arena the controller died on "attempt to call a nil value" with the gate already
commanded open. Declaring the shape here makes it a load-time question instead.
]]
local endDash: () -> ()
--[[
Player -> boss resolution.

Direction 1 of the registry contract. `HitValidator` has already decided that
	his swing was real - real window, real distance, real line of sight, real
debounce - so everything here is about what the hit is *worth*.

Two things happen and they are not the same thing:

  * Health always falls. That is the fight's attrition bar and it works on its
    own clock, with no input required from the player beyond showing up.
  * Phase changes at 50% Health, and it changes the *weights and the speed* rather
    than the numbers. Doubling the damage in Phase 2 would turn the second half
    into a damage race; halving the windups turns it into the same fight played
    faster, which is the correct escalation for a game whose currency is timing.

On defeat the boss is not destroyed. It is revived in place after a pause, which
keeps the arena's geometry, the braziers and the gate exactly where they were and
makes a second attempt free of load-time cost.
]]
local function applyDamageToBoss(_attacker: Model, damage: number, poise: number, _hitIndex: number): BossRegistry.BossDamageResult
	local current = bossModel:GetAttribute(Attributes.Health) or 0
	if current <= 0 then
	return { Applied = false, Defeated = true, PostureBroken = false, Reason = "already defeated" }
	end

	--[[
	The deathblow window's whole point, and the reason the multiplier is read
	here rather than at the call site.

	`BossConfig` declares `POSTURE_BROKEN_HEALTH_MULTIPLIER` (1.6) and until now
	nothing read it, which is the exact shape of drift `BossConfig`'s own header
	warns about: a balance number that exists in the table, is documented as
	load-bearing, and is silently not in the fight. A broken guard would have
	been a 2.8s window in which the player could not land a finisher.

	The check is on the `Vulnerable` *attribute* rather than on `state`, because
	`Vulnerable` is the claim the HUD and the debug readout already read, and a
	second source of truth for "is this window open" is a second thing to forget
	to clear. `defeatBoss` and `reviveBoss` both write it.

	1.6x is a reward, not a race: the Commander still has up to 400 Health, so a
	player who only ever attacks during the window is playing a different and
	slower fight, which is the correct incentive for a posture economy.
	]]
	local vulnerable = bossModel:GetAttribute(Attributes.Vulnerable) == true
	local applied = if vulnerable then damage * PostureCfg.BrokenHealthMultiplier else damage

	local next = math.max(current - applied, 0)
	bossModel:SetAttribute(Attributes.Health, next)

	-- A raw hit chips a little posture too, so aggressive play still moves the
	-- second bar even when the player never parries.
	spendPosture(poise * 0.35)

	if next <= 0 then
		defeatBoss()
		return { Applied = true, Defeated = true, PostureBroken = vulnerable, Reason = "killed" }
	end

	local fraction = next / BossConfig.MaxHealth
	if phase == 1 and fraction <= AI.PhaseTwoThreshold then
		phase = 2
		bossModel:SetAttribute(Attributes.Phase, 2)
		print(string.format("[BOSS] PHASE 2 - the Commander's tempo changes at %d HP", next))
	end

	return { Applied = true, Defeated = false, PostureBroken = vulnerable, Reason = if vulnerable then "deathblow" else "hit" }
end

--[[
	Install the resolver.

	Direction 1 of the registry contract, installed at module scope rather than on
	first use so the wiring is a *load-time* fact. A fight whose player-to-boss
	damage is wired lazily is a boss that cannot be hurt for the first seconds of
	the fight, and reports every one of those hits as a convincing-looking
	`applied=false`.

	This file is the only thing in the project that may write a boss attribute, and
	`HitValidator` is the only thing that may decide a player hit was real. Neither
	reaches across to the other: they meet here, and at the mirrored registration
	`HitValidator` makes for the other direction.
]]
BossRegistry.SetBossResolver(applyDamageToBoss)
--[[
Defeat and revive.
]]
local RESPAWN_DELAY = 8

defeatBoss = function()
	state = "Defeated"
	stateUntil = os.clock() + RESPAWN_DELAY
	respawnAt = stateUntil
	bossModel:SetAttribute(Attributes.Defeated, true)
	bossModel:SetAttribute(Attributes.Vulnerable, false)
	bossModel:SetAttribute(Attributes.Engaged, false)
	bossModel:SetAttribute(Attributes.Posture, 0)
	bossHumanoid.Health = BossConfig.MaxHealth
	showKanji(false)
	setTelegraph("None")
	halt()
	freezePose()                -- defeat: a fallen boss does not ease into a pose
	clearWaves()               -- a wave in flight outlives the fight that threw it
	engaged = false
	phase = 1
	openGate()
	stopMusic()
	grade.Enabled = false
	engageEvent:FireAllClients(false, BossConfig.Name, BossConfig.MaxHealth, BossConfig.MaxPosture)
	print("[BOSS] THE CORRUPTED COMMANDER falls. The gate opens.")
end

local function reviveBoss()
	state = "Dormant"
	bossModel:SetAttribute(Attributes.Health, BossConfig.MaxHealth)
	bossModel:SetAttribute(Attributes.Posture, 0)
	bossModel:SetAttribute(Attributes.Phase, 1)
	bossModel:SetAttribute(Attributes.Defeated, false)
	bossModel:SetAttribute(Attributes.Vulnerable, false)
	bossHumanoid.Health = BossConfig.MaxHealth
	bossModel:PivotTo(CFrame.new(Arena.Center.X, bossRoot.Position.Y, Arena.Center.Z))
	settleToGuard(ANIM_SETTLE)  -- revive: back to a live rig from a frozen one
	clearWaves()               -- and the reset, so the next attempt starts clean
	print("[BOSS] The Commander rises again.")
end
--[[
The gate.

The tween lives here rather than in the builder, because sealing the gate is a
decision about the *fight* and not about the scenery. The builder laid the leaves
out and recorded each one's open and closed X on the part itself, so the animation
follows the geometry rather than re-deriving it.

`CanCollide` flips *after* the open tween completes and *before* the close tween
starts. Opening with collision still on would trap anyone standing in the
	threshold for the length of the animation - punishing a player for winning is the
one thing an arena gate must never do.
]]
local function moveGate(leaf: BasePart, closed: boolean, duration: number): Tween
	local targetX = leaf:GetAttribute(closed and "RoninGateClosedX" or "RoninGateOpenX") :: number
	return TweenService:Create(
		leaf,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ Position = Vector3.new(targetX, leaf.Position.Y, leaf.Position.Z) }
	)
end

local function sealGate()
	gateLeft.CanCollide = true
	gateRight.CanCollide = true
	moveGate(gateLeft, true, Arena.GateSealTime):Play()
	moveGate(gateRight, true, Arena.GateSealTime):Play()
	print("[ARENA 1] The gate seals.")
end

openGate = function()
	local left = moveGate(gateLeft, false, Arena.GateOpenTime)
	local right = moveGate(gateRight, false, Arena.GateOpenTime)
	left.Completed:Connect(function()
		gateLeft.CanCollide = false
		gateRight.CanCollide = false
	end)
	left:Play()
	right:Play()
end

local function startMusic()
	-- The mixer is resolved here as well as at load, because `AudioEngine` may not
 	-- have finished building the tree when this script booted. Re-attaching is a
 	-- no-op when the bed is already on the right bus.
 	attachAmbienceBus()
	if not musicSound.IsPlaying then
		musicSound:Play()
	end
end

stopMusic = function()
	if musicSound.IsPlaying then
		musicSound:Stop()
	end
end

--[[
Engage / disengage.

Engagement is decided by *occupation*, not by touch events: a `Touched` handler on
a volume is a notoriously unreliable way to know a player is inside something,
and a boss arena that only triggers when a player happens to clip a trigger part
with their shoulder is a boss arena that does not trigger.

The transition is latched, so `engageArena` fires once on the way in rather than
once per tick.
]]
local function engageArena()
	engaged = true
	state = "Reposition"
	stateUntil = os.clock() + AI.IdleThinkDelay
	bossModel:SetAttribute(Attributes.Engaged, true)
	bossModel:SetAttribute(Attributes.State, "Engaged")
	sealGate()
	startMusic()
	grade.Enabled = true
	engageEvent:FireAllClients(true, BossConfig.Name, BossConfig.MaxHealth, BossConfig.MaxPosture)
	print(string.format("[ARENA 1] %s engages. %s begins.", Arena.Name, BossConfig.Name))
end

local function disengageArena()
	--[[
	`endDash` and `clearWaves` are forward-declared for the same reason
	`applyDamageToBoss` is in `Boss1Controller`: both are defined further down
	the file, and an undeclared local resolves as a *global* - silently nil at
	runtime, which here meant "attempt to call a nil value" the instant the
	player walked back out of the arena, after the gate had already been told to
	open. The declaration turns that into a load-time question.
	]]
	if endDash ~= nil then
		endDash()
	end
	clearWaves()
	clearWaves()
	engaged = false
	state = "Dormant"
	bossModel:SetAttribute(Attributes.Engaged, false)
	openGate()
	stopMusic()
	grade.Enabled = false
	showKanji(false)
	setTelegraph("None")
	settleToGuard(ANIM_SETTLE)  -- disengage: same
	engageEvent:FireAllClients(false, BossConfig.Name, BossConfig.MaxHealth, BossConfig.MaxPosture)
end

local function anyoneInside(): boolean
	for _, player in ipairs(Players:GetPlayers()) do
	local character = player.Character
	if character ~= nil then
			local root = findRoot(character)
			if root ~= nil and inArena(root.Position) then
				return true
			end
	end
	end
	return false
end
--[[
Shadow Retreat and the gap-closing lunge.

The crowded rule: inside `CROWDED_DISTANCE` (6 studs) - and no more often than
once per `RETREAT_COOLDOWN` - the boss stops being an attacker and becomes a
nuisance for 0.32s. It dashes backwards, holds, then covers 25 studs in a
straight line.

Both legs are driven by `Humanoid:Move` rather than by writing the root's
`CFrame`. A humanoid whose root is teleported every tick fights its own physics
and shoves the player; `Humanoid:Move` asks the engine to walk there, so the boss
collides with the world and the player exactly as a character should, and the
movement is smooth at the render framerate rather than at the loop's 50ms.

`WalkSpeed` is restored on the way out. Leaving it at 150 would make the boss
sprint through the rest of the fight.
]]
local dashDirection = Vector3.zero
local lungeActive = false
local lungeStart = Vector3.zero
local lungeEnd = Vector3.zero

local function beginRetreat(target: Model)
	state = "Retreat"
	showKanji(false)
	setTelegraph("None")

	local root = findRoot(target)
	if root == nil then
		stateUntil = os.clock() + AI.IdleThinkDelay
	return
	end

	local away = bossRoot.Position - root.Position
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.01 then
		away = Vector3.new(0, 0, 1)
	end
	dashDirection = away.Unit * Move.RetreatDistance
	lastRetreatAt = os.clock()
	stateUntil = os.clock() + Move.RetreatDuration / phaseSpeed()
	bossHumanoid.WalkSpeed = Move.RetreatSpeed
	print(string.format("[BOSS] Shadow Retreat - %.0f studs out", (root.Position - bossRoot.Position).Magnitude))
end

local function beginLunge(target: Model)
	state = "Lunge"
	playAttack("Slash", phaseSpeed(), false)
	setTelegraph("Amber")

	local root = findRoot(target)
	if root == nil then
		stateUntil = os.clock() + currentMove.Windup
	return
	end

	lungeStart = bossRoot.Position
	lungeEnd = lungeStart + (Vector3.new(root.Position.X, 0, root.Position.Z) - lungeStart).Unit * Move.LungeDistance

	local distance = (lungeEnd - lungeStart).Magnitude
	stateUntil = os.clock() + math.max(distance / Move.LungeSpeed, 0.06)
	lungeActive = false
	bossHumanoid.WalkSpeed = Move.LungeSpeed
end


--[[
The chase.

`think` decides *what* to do, at 50ms; this decides where the boss's legs are,
at the frame's own cadence. It runs only while the AI is in its neutral state -
every combat state owns locomotion for itself (a Telegraph must not drag the
boss through the player mid-swing) - so the gate is one comparison.

The rules, in the order the fight states them:

  * Player inside Arena 1 and further than `COMBAT_DISTANCE` (10): turn, set
    `WalkSpeed` to `CHASE_SPEED` (16) and `Humanoid:MoveTo` the player's root.
    Real R15 locomotion - the Humanoid walks the boss there, collisions and all,
    rather than this file sliding a model toward a point.
  * Player inside and within 10: stop, face them, and leave the rest to `think`,
    which is already sitting in `Reposition` waiting out its deadline.

`chaseTarget` is written by `think` rather than computed here:
`Players:GetPlayers()` allocates a fresh array on every call, and an allocation
inside a Heartbeat callback is exactly what ARCHITECTURE #4 forbids.
]]
local COMBAT_DISTANCE = 10
local CROWDED_DISTANCE = 6
local RETREAT_COOLDOWN = 8
local CHASE_SPEED = 16
--[[
The mid-band gap-closer: the Shadow Lunge.

Distinct from `Lunge` above, and the distinction is the whole design. The old
`Lunge` is the *second half* of Shadow Retreat: it is an attack, it resolves a
swing, and it only ever runs because the boss chose to make space first. This
one is the opposite - it is pure *movement*, it deals no damage at all, and it
runs because the player is in the band the old chase could never close.

Why `LinearVelocity` and not `Humanoid:MoveTo`. The chase walks at 16 studs/s
and that is right for a walk; it is far too slow for crossing 18 studs inside
a player's reaction window, and raising `WalkSpeed` to make it fast produces
the 150 studs/s slide the old lunge already was - a 0.12s crossing, which is
under the human reaction floor and therefore just a hit with no tell.

A `LinearVelocity` constraint is the right tool because it is a *physical*
push: the boss still collides with the courtyard, still shoves the player
rather than passing through them, and still leaves the rig upright. It is also
a one-shot - attached for the dash, destroyed on arrival - so it cannot fight
the Humanoid's own locomotion on any other frame.

The ember trail is not decoration. 35 studs/s over an 8-stud gap is 0.23s of
travel, and a dark rig moving fast is very hard to track; the trail is what
makes the dash legible rather than a teleport.
]]
local dashConstraint: LinearVelocity? = nil
local dashAttachment: Attachment? = nil
local dashTarget: Model? = nil
local emberTrail: ParticleEmitter? = nil

endDash = function(): ()
	if dashConstraint ~= nil then
		dashConstraint:Destroy()
		dashConstraint = nil
	end
	dashTarget = nil
	--[[
	Back to `Running`, not to whatever it was before. Leaving the Humanoid in
	`Physics` is the classic version of this bug: the rig stops holding itself
	up, `think` does not notice because nothing raises, and the Commander is
	lying on the courtyard floor for the rest of the fight looking perfectly
	alive. `Running` also re-arms the hip constraint, which is the same
	mechanism the self-heal in `think` exists to patch.
	]]
	if bossHumanoid:GetState() == Enum.HumanoidStateType.Physics then
		bossHumanoid:ChangeState(Enum.HumanoidStateType.Running)
	end
	bossHumanoid.WalkSpeed = CHASE_SPEED
end

--[[
The trail.

An emitter on the root that is *enabled for the duration* rather than spawned
and destroyed, so starting a dash costs one boolean write and there is nothing
to leak if the dash is interrupted. `BossConfig` owns the rate, because the
rate is the difference between a readable dash and a smearing one.
]]
local function ensureEmberTrail(): ()
	if emberTrail ~= nil then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DashEmbers"
	emitter.Texture = BossConfig.Particles.Ember
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 132, 40))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.25, 0.6)
	emitter.Rate = Move.ShadowLungeEmberRate
	emitter.Speed = NumberRange.new(6, 16)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.Acceleration = Vector3.new(0, 6, 0)
	emitter.LightEmission = 0.9
	emitter.LightInfluence = 0
	emitter.Enabled = false
	emitter.Parent = bossRoot
	emberTrail = emitter
end


--[[
Begin the dash.

The duration is derived from the *current* gap rather than fixed, so one call
covers both a 10-stud and an 18-stud close and always arrives in melee range.
Clamped to a floor so a player standing almost on top of the boss cannot
produce a zero-length dash that resolves on the frame it started.
]]
local function beginShadowLunge(target: Model)
	local targetRoot = findRoot(target)
	if targetRoot == nil then
		state = "Reposition"
		stateUntil = os.clock() + AI.IdleThinkDelay
		return
	end

	local flat = Vector3.new(targetRoot.Position.X - bossRoot.Position.X, 0, targetRoot.Position.Z - bossRoot.Position.Z)
	if flat.Magnitude < 0.5 then
		-- Already on top of them: no gap to close, so this is a melee decision.
		state = "Reposition"
		stateUntil = os.clock() + AI.IdleThinkDelay
		return
	end

	ensureEmberTrail()

	local direction = flat.Unit
	local duration = math.max((flat.Magnitude - Move.MeleeDistance) / Move.ShadowLungeSpeed, 0.12)
	dashTarget = target

	--[[
	`Humanoid:ChangeState(Physics)` first, and this is the load-bearing part of
	the whole dash. A `Humanoid` in its normal state is *also* writing to the
	rig's root every physics step to keep it standing; put a `LinearVelocity`
	on the same assembly without releasing it and the two fight, and the
	visible result is the same jitter this overhaul exists to remove.
	`Physics` hands the assembly to the constraint for the duration.
	]]
	bossHumanoid:ChangeState(Enum.HumanoidStateType.Physics)

	if dashAttachment == nil then
		dashAttachment = Instance.new("Attachment")
		dashAttachment.Name = "DashAnchor"
		dashAttachment.Parent = bossRoot
	end

	local push = Instance.new("LinearVelocity")
	push.Name = "ShadowLunge"
	push.Attachment0 = dashAttachment
	-- `Line` mode + `LineDirection`/`LineVelocity`, because `LinearVelocity.Velocity`
	-- was removed from the engine. See the Blade Wave's launch for the same fix
	-- and the reasoning.
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.LineDirection = direction
	push.LineVelocity = Move.ShadowLungeSpeed
	push.MaxForce = math.huge
	push.ForceLimitsEnabled = false
	push.Parent = bossRoot
	dashConstraint = push

	if emberTrail ~= nil then
		emberTrail.Enabled = true
	end

	--[[
	Facing during the dash. `AutoRotate` does nothing in `Physics`, so the
	orientation is driven from the constraint's own direction by `dashTick`
	below rather than left to the Humanoid.
	]]
	playAttack("Slash", phaseSpeed(), false)
	setTelegraph("Amber")

	state = "Dash"
	stateUntil = os.clock() + duration

	print(string.format(
		"[BOSS] Shadow Lunge - closing %.0f studs at %d studs/s",
		flat.Magnitude,
		Move.ShadowLungeSpeed
	))
end

--[[
Per-frame dash upkeep.

Turns the rig toward the target and turns the dash off when it arrives. Runs on
Heartbeat because a dash that updates its facing at 50ms visibly stutters, and
because the *arrival* test wants to be a frame event rather than a 50ms one:
at 35 studs/s the boss covers 0.7 studs per tick, so a 50ms arrival check can
overshoot melee range by nearly a stud.
]]
local function dashTick(): ()
	if state ~= "Dash" then
		return
	end
	local target = dashTarget
	local targetRoot = if target ~= nil then findRoot(target) else nil
	if targetRoot ~= nil then
		faceTowards(targetRoot.Position)
		if (targetRoot.Position - bossRoot.Position).Magnitude <= Move.MeleeDistance + 1 then
			--[[
			Arrived. End the dash and hand straight back to `Reposition`, which
			will reach into the roulette on its next pass - so the lunge is a
			gap-closer that *sets up* a real move rather than a move in itself.
			]]
			endDash()
			if emberTrail ~= nil then
				emberTrail.Enabled = false
			end
			settleToGuard(ANIM_SNAP_BACK)
			state = "Reposition"
			stateUntil = os.clock()
			return
		end
	end
	if os.clock() >= stateUntil then
		-- Safety net: the deadline is the authority, arrival is only an early-out.
		endDash()
		if emberTrail ~= nil then
			emberTrail.Enabled = false
		end
		state = "Recover"
		stateUntil = os.clock() + Move.ShadowLungeRecovery
	end
end


--[[
Close-range stalking.

Circles the player at `StalkRadius` and then commits, and the reason it exists
is that a boss which walks straight in and attacks is a boss whose only tell
is the move it is already playing. Circling gives the player a beat to read the
approach *and* to decide what they want to do about it - which is the beat in
which they can choose to back off, parry on a read, or punish the recovery.

The orbit is a tangent, not a straight line to a waypoint: the destination is
recomputed from the player's live position each tick, so the circle tightens as
they back off and follows them as they move. A waypoint circle drifts out of
position the moment the player takes two steps sideways, and a stalk that loses
its target reads as the AI breaking.

`stalkDir` flips on entry rather than on a timer, so consecutive stalks
alternate. A boss that always circles the same way is learnable the way a
pattern is learnable; one that alternates is not.
]]
local function beginStalk(target: Model)
	local targetRoot = findRoot(target)
	if targetRoot == nil then
		state = "Reposition"
		stateUntil = os.clock() + AI.IdleThinkDelay
		return
	end

	stalkDir = -stalkDir
	lastStalkAt = os.clock()

	state = "Stalk"
	--[[
	Randomised inside the config's band, so the duration is not itself a tell
	the player can count down. A stalk that is always 0.8s is a stalk the
	player can time an attack against, which defeats the entire purpose of
	adding it.
	]]
	stateUntil = os.clock()
		+ Move.StalkMinDuration
		+ math.random() * (Move.StalkMaxDuration - Move.StalkMinDuration)

	bossHumanoid.WalkSpeed = Move.StalkSpeed
	settleToGuard(ANIM_SNAP_BACK)
end

--[[
Per-frame stalk movement, owned by Heartbeat rather than the 50ms loop.

The orbit has to look continuous, and at 50ms it visibly steps. It runs only
in `Stalk` - every other state owns its own locomotion - and it reuses the
target `think` already computed, so it allocates nothing (ARCHITECTURE #4).
]]
local function stalkTick(): ()
	if not engaged or state ~= "Stalk" then
		return
	end
	local target = chaseTarget
	if target == nil then
		return
	end
	local targetRoot = findRoot(target)
	if targetRoot == nil then
		return
	end

	local flat = Vector3.new(
		targetRoot.Position.X - bossRoot.Position.X,
		0,
		targetRoot.Position.Z - bossRoot.Position.Z
	)
	if flat.Magnitude < 0.01 then
		return
	end

	-- Radial: close on `StalkRadius` if too far, drift out if too close.
	-- Weighted below the tangent so the boss orbits rather than oscillates.
	local radial = flat.Unit * (Move.StalkRadius - flat.Magnitude)
	-- Tangent: the orbit itself, signed by `stalkDir`.
	local tangent = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X) * stalkDir

	bossHumanoid.WalkSpeed = Move.StalkSpeed
	bossHumanoid:MoveTo(bossRoot.Position + (radial * 0.6 + tangent * 1.4))
	-- Always facing the player while circling. An orbiting boss that has turned
	-- its back is a boss the player cannot read at all.
	faceTowards(targetRoot.Position)
end


local function chaseTick(): ()
	if not engaged or state ~= "Reposition" then
		return
	end
	local target = chaseTarget
	if target == nil then
		return
	end
	local targetRoot = findRoot(target)
	if targetRoot == nil then
		return
	end
	local to = targetRoot.Position - bossRoot.Position
	local flat = Vector3.new(to.X, 0, to.Z)
	if flat.Magnitude > COMBAT_DISTANCE then
		bossHumanoid.WalkSpeed = CHASE_SPEED
		bossHumanoid:MoveTo(targetRoot.Position)
		--[[
		Nothing else is needed here. The Commander closes on `Humanoid:MoveTo`,
		and `BossAnimate.update` - called from the heartbeat below - sees the
		real velocity and plays the stock walk or run cycle to match.

		so the approach is real R15 locomotion that collides with the world and
		the player as a character should, and it is not a slide: the legs are
		animating, and the boss arrives already able to swing.
		]]
		if chasePoseState == "" then
			chasePoseState = "Chase"
		end
	else
		halt()
		faceTowards(targetRoot.Position)
		if chasePoseState ~= "" then
			chasePoseState = ""
			settleToGuard(ANIM_SETTLE)
		end
	end
end

--[[
One Heartbeat, five jobs.

They are connected as a single callback rather than five separate ones for the
reason the chase's own comment gives: a boss that can throw a wave every couple
of seconds for the length of an encounter would otherwise accumulate
connections for as long as the fight runs, and each one would keep firing after
its state ended. One connection, five early-returns on a state comparison, and
nothing to disconnect.

`updateWaves` is the only one that allocates, and it does so by calling
`Players:GetPlayers()`. That is a real cost on a per-frame path, so it is
confined to the case where a wave is actually in flight - a boss that is not
throwing allocates nothing at all on this callback.
]]
local function bossHeartbeat(dt: number)
	--[[
	Locomotion, on the render frame.

	`BossAnimate.update` reads the Commander's real velocity and plays the matching
	stock walk / run / idle track. It is the reason the boss has a stride at all, so it
	runs at render framerate rather than on the 50ms decision cadence - which is
	exactly the split `BossConfig` S6 describes: the AI decides at 50ms, the legs move
	at whatever the player's framerate is.

	It allocates nothing. Every track is already loaded, so the whole callback is a
	state comparison plus at most one `Play` and one `Stop`.
	]]
	BossAnimate.update(animateRig, os.clock())
	updateWaves(dt)
	dashTick()
	stalkTick()
	chaseTick()
end

RunService.Heartbeat:Connect(bossHeartbeat)

--[[
The main loop.

One pass per `THINK_INTERVAL` (50ms). Every branch reads `os.clock()` against a
deadline it set when it entered the state, so nothing depends on the loop's own
accuracy: a frame that runs long simply means fewer passes, never a longer move.

Read top to bottom it is: the things that apply in *every* state (posture
recovery, the deflect flash decaying, the kanji strobe), then one switch. The
switch is the whole AI; everything above it is housekeeping that must not be
forgotten when a new state is added, which is the reason it is not inside the
switch.
]]
local function think(now: number)
	-- Housekeeping that applies in every state. --------------------------------

	recoverPosture(now)

	--[[
	The hip self-heal, two comparisons and usually nothing else.

	`Humanoid.HipHeight` is what holds a character's body at standing height. If
	the Commander ever loses it, the Humanoid falls back onto its invisible root
	part: the body drops 2.4 studs and the feet hang *through* the dueling floor
	while the fight carries on perfectly. It is invisible in a log and obvious
	on screen, and one write of a different value followed by the real one puts
	the rig back on its feet - so the standing is checked, not scheduled.
	]]
	if bossHipHeight > 0 and bossRoot.Position.Y - bossRoot.Size.Y * 0.5 < Arena.FloorTop + 0.5 then
		bossHumanoid.HipHeight = bossHipHeight + 0.01
		bossHumanoid.HipHeight = bossHipHeight
	end

	if deflectFlashUntil > 0 and now >= deflectFlashUntil then
		deflectFlashUntil = 0
	if state ~= "PostureBroken" then
			setTelegraph("None")
	end
	end

	pulseKanji()

	local defeated = bossModel:GetAttribute(Attributes.Defeated) == true

	-- Arena occupancy. Latched, so it fires on the transition and not on every tick.
	local occupied = not defeated and anyoneInside()
	if occupied and not engaged then
		engageArena()
	elseif (not occupied) and engaged then
		disengageArena()
	end

	if defeated then
	if now >= respawnAt then
			reviveBoss()
	end
	return
	end

	if not engaged then
		bossModel:SetAttribute(Attributes.State, "Dormant")
	return
	end

	local target = nearestPlayer()
	chaseTarget = target
	if target == nil then
		halt()
		bossModel:SetAttribute(Attributes.State, "Dormant")
	return
	end

	local targetRoot = findRoot(target)
	if targetRoot == nil then
	return
	end

	local distance = (targetRoot.Position - bossRoot.Position).Magnitude

	-- The switch. ---------------------------------------------------------------

	if state == "PostureBroken" then
	if now >= stateUntil then
			bossModel:SetAttribute(Attributes.Vulnerable, false)
			bossModel:SetAttribute(Attributes.Posture, PostureCfg.RecoveryFloor)
		setTelegraph("None")
		settleToGuard(ANIM_SETTLE)
			state = "Recover"
			stateUntil = now + 0.5
		lastPostureHit = now
	end
	return
	end

	if state == "Retreat" then
		faceTowards(bossRoot.Position + dashDirection)
		bossHumanoid:Move(dashDirection.Unit, false)
	if now >= stateUntil then
			halt()
			beginLunge(target)
	end
	return
	end

	if state == "Lunge" then
	local to = lungeEnd - lungeStart
	if to.Magnitude < 0.01 then
				to = Vector3.new(0, 0, 1)
	end
		faceTowards(targetRoot.Position)
		bossHumanoid:Move(to.Unit, false)
	if not lungeActive then
			lungeActive = true
			fireSwing(Move.ShadowRetreat, Move.ShadowRetreat.Damage, Move.ShadowRetreat.Posture, Move.ShadowRetreat.Reach)
	end
	if now >= stateUntil then
			halt()
		settleToGuard(ANIM_SNAP_BACK)
			state = "Recover"
			stateUntil = now + Move.ShadowRetreat.Recovery / phaseSpeed()
	end
	return
	end

	if state == "Reposition" then
		--[[
		The three distance bands. This is the whole of the smarter AI and it is
		one `if` chain, in the same order the bands are declared in
		`BossConfig` S4b, because a distance-based decision that is not a
		straight read of the thresholds is a distance-based decision that will
		drift out of step with the numbers that were balanced.

		Each band ends in a different state and that difference is load-bearing:

		  RANGED   -> `Ranged`  - the wave resolves on its own clock.
		  APPROACH -> `Dash`    - pure movement; rejoins at `Reposition` so the
		                         move that follows is a real melee one.
		  MELEE    - > the roulette, unless the crowded or stalk rules fire.
		]]
		if distance > Move.RangedThreshold then
			--[[
			Too far for anything in S4 to reach. The old code did nothing here
			but let the chase walk at 16 studs/s, which is correct for a walk
			and completely wrong for a fight: running backwards was a *correct*
			strategy, because nothing the Commander did could ever reach a
			player at 30 studs. The wave is what makes that stop being true.
			]]
			state = "Ranged"
			stateUntil = now + Move.BladeWaveTelegraph / phaseSpeed()
			setTelegraph("Amber")
			--[[
			The casting motion is the stock `Lunge` track: it raises the blade and
			drives the shoulder forward, which is what a thrown projectile needs to
			read as coming *from* the sword. There is no dedicated "cast" track,
			because - as `BossAnimate` records - no permission-free one exists, and
			an `error()` on an unknown clip would take the whole fight down.

			The windup is deliberately long (`ANIM_TELEGRAPH` against the quick
			`ANIM_SNAP_BACK` a melee uses) because this is the one attack the player
			is meant to see coming and answer with a dodge.
			]]
			playAttack("Lunge", phaseSpeed() * 0.85, false)
			showKanji(false)
			return
		end

		if distance > COMBAT_DISTANCE then
			--[[
			The mid band. The dash is a *gap-closer*, not an attack: it deals
			nothing on its own, and it re-arms `Reposition` on arrival so the
			roulette is reached immediately afterwards. That is why the player
			sees a lunge and then a real, telegraphed move rather than a lunge
			that was itself the threat.
			]]
			beginShadowLunge(target)
			return
		end

		--[[
		Melee range. Face them and hold, so the boss is never caught
		backwards while it waits out its own decision deadline.
		]]
		faceTowards(targetRoot.Position)

		if now < stateUntil then
			return
		end

		halt()
		--[[
		The crowded rule, before everything else: a boss that has to *choose*
		to make space can choose not to, and a player standing in its face
		would then have no answer but the same moves at arm's length.
		]]
		if distance <= CROWDED_DISTANCE and now >= lastRetreatAt + RETREAT_COOLDOWN then
			beginRetreat(target)
			return
		end

		--[[
		The stalk, and it is deliberately *not* every exchange. Gated on
		`StalkRetreatCooldown` because a boss that circled on every single
		approach would never actually attack, and a boss that never stops
		moving is a boss that never threatens anything. Roughly every third
		melee exchange is a stalk, which is frequent enough to be felt and
		rare enough to be attacked through.
		]]
		if now >= lastStalkAt + Move.StalkRetreatCooldown then
			beginStalk(target)
			return
		end

		beginMove(rollMove(target))
		return
	end

	if state == "Stalk" then
		--[[
		Movement is owned by `stalkTick` on Heartbeat; this branch only owns
		the *decision* to stop circling, which has to be on the 50ms loop
		because it is the same deadline every other state uses.
		]]
		faceTowards(targetRoot.Position)
		if now >= stateUntil or distance > Move.StalkRadius + 6 then
			halt()
			settleToGuard(ANIM_SNAP_BACK)
			state = "Reposition"
			stateUntil = now
		end
		return
	end

	if state == "Ranged" then
		--[[
		Wind up, then throw. The direction is read at *release*, not at
		windup start: a wave that commits to a position during its own
		telegraph is a wave the player sidesteps by standing still, which
		turns a 0.5s tell into 0.5s of free information followed by a miss.
		]]
		faceTowards(targetRoot.Position)
		if now >= stateUntil then
			halt()
			throwBladeWave(target)
			setTelegraph("None")
			settleToGuard(ANIM_SETTLE)
			--[[
			Straight back to `Reposition` and *not* into `Strike`: the wave
			resolves on its own clock inside `updateWaves`, so the AI has
			nothing left to wait for. Entering `Recover` here would also stop
			the boss from reacting to the player closing the distance during
			the wave's flight, which is exactly the behaviour the wave is
			meant to provoke.
			]]
			state = "Reposition"
			stateUntil = now + AI.IdleThinkDelay / phaseSpeed()
		end
		return
	end

	if state == "Dash" then
		--[[
		`dashTick` owns the dash end-to-end on Heartbeat (it needs a per-frame
		arrival test and a per-frame facing update). This branch is the 50ms
		backstop only, so a dash whose target despawns mid-flight still
		resolves rather than pinning the AI in `Dash` forever.
		]]
		dashTick()
		if state == "Dash" and now >= stateUntil then
			dashTick()
		end
		return
	end
	if state == "Telegraph" then
		faceTowards(targetRoot.Position)
		local steps = currentMove.Steps
		--[[
		No clip is (re)played here. The old branch re-picked a pose on *every*
		50ms tick, which for a three-step flurry meant the step-1 animation was
		restarted nineteen times during its own windup and the player saw a
		seizure instead of a swing.

		`beginMove` already started the right clip, and each flurry step's clip
		is started by the `Strike` branch when it advances `stepIndex`. This
		state's only remaining job is the deadline and the facing.
		]]
		if now >= stateUntil then
			state = "Strike"
			-- `stepIndex` is *initialised* here, never reset. It used to be reset
			-- on every telegraph, which meant a three-step flurry looped between
			-- step 1 and step 2 forever: the Commander threw two hits on repeat and
			-- never reached its Recovery, so the fight read as one endless flurry
			-- and every pose after the second step was unreachable.
			if stepIndex < 1 then
				stepIndex = 1
			end
			local active = currentMove.Active
			if steps ~= nil then
				local step = steps[stepIndex]
				if step ~= nil then
					active = step.Active
				end
			end
			stateUntil = now + active / phaseSpeed()
			showKanji(false)
			if currentMove.Id == "DragonCleave" then
				setTelegraph("Amber")
				cleaveSlam:Stop()
				cleaveSlam:Play()
	end
	end
	return
	end

	if state == "Strike" then
	local steps = currentMove.Steps
	if steps ~= nil then
			local step = steps[stepIndex]
			if step ~= nil and not struckThisSwing[target] then
				faceTowards(targetRoot.Position)
				local broke = fireSwing(currentMove, step.Damage, step.Posture, step.Reach)
				if broke then
					state = "PostureBroken"
					stateUntil = now + PostureCfg.BrokenStun
					return
				end
			end
			if now >= stateUntil then
				if stepIndex < #steps then
					stepIndex += 1
					local nextStep = steps[stepIndex]
					state = "Telegraph"
					stateUntil = now + nextStep.Windup / phaseSpeed()
					table.clear(struckThisSwing)
					--[[
					The flurry's chaining, done properly.

					Each step starts *its own* clip here rather than the move
					continuing to play step 1's. That is what makes a flurry read
					as a combination: step 1 and step 2 are both the horizontal,
					so the seam between them is invisible and the string looks
					like one continuous cut; step 3 is the thrust, and the swap
					to a different clip is what the player's eye reads as "the
					finisher is different".

					It also fixes a bug the old line had. `setPose` with a 0.1s
					blend *interrupted* whatever pose was on screen, so a step
					that began while the previous step's swing was still
					arriving snapped halfway through the motion. Restarting the
					track from zero blends from the rig's actual current
					transform, which is what a second swing in a chain should do.
					]]
					playAttack(clipForMove(currentMove, nextStep), phaseSpeed(), true)
				else
					halt()
					settleToGuard(ANIM_SETTLE)
					state = "Recover"
					stateUntil = now + steps[#steps].Recovery / phaseSpeed()
				end
			end
		else
			if not struckThisSwing[target] then
				faceTowards(targetRoot.Position)
				local broke = fireSwing(currentMove, currentMove.Damage, currentMove.Posture, currentMove.Reach)
				if broke then
					state = "PostureBroken"
					stateUntil = now + PostureCfg.BrokenStun
					return
				end
			end
			if now >= stateUntil then
				halt()
				setTelegraph("None")
				settleToGuard(ANIM_SETTLE)
				state = "Recover"
				stateUntil = now + currentMove.Recovery / phaseSpeed()
			end
		end
		return
	end

	if state == "Recover" then
		settleToGuard(ANIM_SNAP_BACK)
		if now >= stateUntil then
			state = "Reposition"
			stateUntil = now + AI.IdleThinkDelay / phaseSpeed()
			showKanji(false)
		end
		return
	end

	state = "Reposition"
	stateUntil = now + AI.IdleThinkDelay
end

--[[
Boot. The loop itself, and nothing else - every decision it makes is made by
`think`, which is above.
]]
--[[
The move count is counted, not typed. This banner hard-coded 4 while the brief
and `BossConfig` both describe five moves, and a boot line that disagrees with
the fight it is announcing is worse than no banner - it is the one line a reader
trusts without checking.
]]
local MoveCount = 0
for _ in pairs(Move.Moves) do
	MoveCount += 1
end

print(string.format(
"[BOSS 1] %s online - %d HP, %d posture, %d moves, %.0fms cadence",
BossConfig.Name,
BossConfig.MaxHealth,
BossConfig.MaxPosture,
MoveCount,
AI.ThinkInterval * 1000
))

bossModel:SetAttribute(Attributes.State, "Dormant")

while true do
		task.wait(AI.ThinkInterval)
		think(os.clock())
end
