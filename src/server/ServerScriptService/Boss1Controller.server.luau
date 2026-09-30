--!strict

--[[
Boss1Controller
Ronin - The Last Blade . Boss 1: THE CORRUPTED COMMANDER

The fight. Five moves, a posture economy, two phases, and the arena lifecycle
	that brackets them.

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

local state: BossState = "Dormant"
local stateUntil = 0
local currentMove = Move.Moves.TripleFlurry
local stepIndex = 0
local phase = 1
local engaged = false
local lastPostureHit = 0
local struckThisSwing: { [Model]: boolean } = {}
local deflectFlashUntil = 0
local respawnAt = 0
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
Handles by name, not by attribute.

An attribute holding an Instance reads back as an `InstanceHandle`, not the
Instance, so the first version of this line - `GetAttribute("RoninBoss")` -
returned a handle that has no `FindFirstChild` and took the whole fight down at
line 122. Names are the contract now; `Arena1Builder` documents the four of them
where it publishes them.
]]
local bossModel = arenaFolder:WaitForChild("TheCorruptedCommander") :: Model
local gateLeft = arenaFolder:WaitForChild("GateLeafLeft") :: BasePart
local gateRight = arenaFolder:WaitForChild("GateLeafRight") :: BasePart
local grade = Lighting:WaitForChild("ARENA_Burn_Grade") :: ColorCorrectionEffect

local bossRig = bossModel:FindFirstChild("Rig") :: Model
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
Walk toward a point, closing at most `speed` studs.

Returns true when close enough to matter. The `Near` band is deliberately
generous: the boss should stop *short* of the player rather than walk into their
guard, because every move it has is answered at reach and the reach numbers in
`BossConfig` already assume some distance.
]]
local function stepTowards(target: Vector3, speed: number, near: number): boolean
	local to = target - bossRoot.Position
	local flat = Vector3.new(to.X, 0, to.Z)
	local distance = flat.Magnitude
	if distance <= near then
	return true
	end
	bossHumanoid.WalkSpeed = speed
	bossHumanoid:Move(flat.Unit, false)
	return false
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
Poses.

A boss with no animation track is not a limitation here, it is the point: every
	telegraph this fight needs is a *hold*, and a hold is what a Motor6D does better
	than an animation. An overhead Cleave windup is 750ms of the exact same frame; a
750ms blend curve would spend most of it arriving and leave 200ms to read.

The angles are applied as `C0 * rotation` rather than as absolute rotations, so
	the rig's own rest pose is preserved underneath and nothing has to know what the
	template's authored C0 values were. That is what makes a pose table portable to
	the next boss.

`Priority = 2` on the joints we drive, because the stock `Animate` LocalScript
writes at the default priority and would otherwise overwrite the pose on the very
next frame. The template's `Animate` was stripped at build time, but the priority
is set anyway so the rig behaves if a replacement animation is added later.
]]
type MotorName = "Root" | "Waist" | "Neck" | "RightShoulder" | "LeftShoulder" | "RightElbow" | "LeftElbow"
type PoseAngles = { [MotorName]: Vector3 }

local JOINTS: { MotorName } = { "Root", "Waist", "Neck", "RightShoulder", "LeftShoulder", "RightElbow", "LeftElbow" }

--[[
The joint table.

Resolved by *descendant* search rather than by direct child, and that is the
whole reason this block exists in this shape.

A stock R15 rig does not parent its Motor6Ds to the Model. `Root` lives in
`LowerTorso`, `Waist` in `UpperTorso`, `Neck` in `Head`, and each shoulder and
elbow in its own limb. A `FindFirstChild` on the Model therefore finds
*nothing* - and because that failure is a silent nil rather than an error,
every pose in this file degrades to a no-op. The Commander would stand in its
rest pose through a 750ms Cleave windup while the player is told to read a
telegraph that does not exist. The bug would not look like a bug.

So the joints are resolved once, by name, across the whole rig, into a table
this file indexes for the rest of the fight: one search at load, zero searches
per pose, and a rig that re-parents its own joints cannot silently break it.

`Priority = 2` is set here rather than at each call site for the same reason
the rest of the pose system is table-driven - it is the one property every
joint in this list needs and the only place it can be forgotten.
]]
local joints: { [string]: Motor6D } = {}

--[[
	No `Priority` is written to any of these joints. The property was removed from
	`Motor6D` by the Avatar Joint Upgrade and raises on assignment, and it only
	ever existed to out-rank the stock `Animate` LocalScript - which this rig does
	not have, because `Arena1Builder` authors the Commander from scratch and
	never parents one. The pose table below is the only writer of these joints.
]]
for _, name in JOINTS do
	for _, descendant in ipairs(bossRig:GetDescendants()) do
		if descendant:IsA("Motor6D") and descendant.Name == name then
			joints[name] = descendant
			break
		end
	end
end

--[[
A rig that is missing a joint the pose table names would make the telegraph
for that move quietly weaker, so it is a printed warning rather than a silent
skip. This is build-time diagnosis: the arena is authored, not discovered.
]]
for _, name in JOINTS do
	if joints[name] == nil then
		warn(string.format("[BOSS] CorruptedCommander had no %s Motor6D - its poses will be partial", name))
	end
end

local restC0: { [string]: CFrame } = {}
for name, joint in pairs(joints) do
	restC0[name] = joint.C0
end

local function setPose(name: string, angles: PoseAngles, duration: number)
	local tweens: { Tween } = {}
	for _, jointName in JOINTS do
		local joint = joints[jointName]
		local base = restC0[jointName]
		if joint ~= nil and base ~= nil then
			local euler = angles[jointName]
			local target = base
			if euler ~= nil then
				target = base * CFrame.Angles(euler.X * DEG, euler.Y * DEG, euler.Z * DEG)
			end
				tweens[#tweens + 1] = TweenService:Create(
				joint,
				TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ C0 = target }
			)
	end
	end
	for _, tween in ipairs(tweens) do
			tween:Play()
	end
end

--[[
The pose table. Degrees, applied in each joint's own local frame; see above for
why they are relative.

`Sweep` is the one that matters most, because it is the only move whose telegraph
is the *pose itself*: the body drops, both arms go out and low, and the blade
ends up where a player's ankles are. A player reading the pose knows what height
	the attack will be at before the kanji finishes flashing, which is the difference
between reacting to the attack and reacting to the idea of it.
]]
local POSES: { [string]: PoseAngles } = {
Idle = {},
Guard = {
RightShoulder = Vector3.new(-38, 0, -18),
LeftShoulder = Vector3.new(-30, 0, 18),
RightElbow = Vector3.new(18, 0, 0),
LeftElbow = Vector3.new(22, 0, 0),
},
--[[ Blade held high overhead. The 750ms Cleave is readable from across the arena
because of this frame, and from directly behind the boss because the shoulders
and elbows are set as well as the waist. ]]
Overhead = {
Root = Vector3.new(-8, 0, 0),
Waist = Vector3.new(-12, 0, 0),
RightShoulder = Vector3.new(-152, 0, -14),
LeftShoulder = Vector3.new(-128, 0, 14),
RightElbow = Vector3.new(26, 0, 0),
LeftElbow = Vector3.new(30, 0, 0),
},
Thrust = {
Root = Vector3.new(6, 0, 0),
Waist = Vector3.new(8, 0, 0),
RightShoulder = Vector3.new(-88, 0, -8),
LeftShoulder = Vector3.new(18, 0, 24),
RightElbow = Vector3.new(4, 0, 0),
},
Sweep = {
Root = Vector3.new(14, 0, 0),
Waist = Vector3.new(26, 0, 0),
RightShoulder = Vector3.new(-18, 0, -52),
LeftShoulder = Vector3.new(-16, 0, 52),
RightElbow = Vector3.new(14, 0, 0),
LeftElbow = Vector3.new(14, 0, 0),
},
Lunge = {
Root = Vector3.new(14, 0, 0),
Waist = Vector3.new(16, 0, 0),
RightShoulder = Vector3.new(-104, 0, -10),
LeftShoulder = Vector3.new(72, 0, 26),
RightElbow = Vector3.new(6, 0, 0),
},
Broken = {
Root = Vector3.new(22, 0, 0),
Waist = Vector3.new(30, 0, 0),
Neck = Vector3.new(24, 0, 0),
RightShoulder = Vector3.new(22, 0, -46),
LeftShoulder = Vector3.new(22, 0, 46),
},
}
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
	setPose("Broken", POSES.Broken, 0.18)
	setTelegraph("White")
	deflectFlashUntil = 0
	halt()
	print(string.format("[BOSS] GUARD BROKEN - %s is open for %.1fs", BossConfig.DisplayName, PostureCfg.BrokenStun))
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

The forward cone is `Reach + 2` deep and ±60 degrees wide. A sphere reach would
let a swing catch somebody the boss was visibly facing away from, which is the
single most reliable way to make a boss feel unfair.
]]
local ANGLE_LIMIT = 60

local function fireSwing(move: BossMoveData, damage: number, posture: number, reach: number): boolean
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

local function isPerilous(move: BossMoveData): boolean
	return move.Unblockable
end

local function rollMove(target: Model): BossMoveData
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
local function beginMove(move: BossMoveData)
	currentMove = move
	stepIndex = 0
	state = "Telegraph"
		table.clear(struckThisSwing)

	local steps = move.Steps
	local windup = if steps ~= nil then steps[1].Windup else move.Windup
	stateUntil = os.clock() + windup / phaseSpeed()

	lastMoveId = move.Id
	lastWasPerilous = isPerilous(move)

	if move.MustJump or move.Unblockable then
		setTelegraph("Red")
		showKanji(true)
		playChime()
		setPose("Sweep", POSES.Sweep, math.min(windup * 0.7, 0.3))
	elseif move.Id == "DragonCleave" then
		setTelegraph("Amber")
		showKanji(false)
		setPose("Overhead", POSES.Overhead, math.min(windup * 0.6, 0.35))
	else
		setTelegraph("Amber")
		showKanji(false)
		setPose("Guard", POSES.Guard, 0.14)
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
	setPose("Broken", POSES.Broken, 0.6)
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
	setPose("Idle", POSES.Idle, 0.4)
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
	engaged = false
	state = "Dormant"
	bossModel:SetAttribute(Attributes.Engaged, false)
	openGate()
	stopMusic()
	grade.Enabled = false
	showKanji(false)
	setTelegraph("None")
	setPose("Idle", POSES.Idle, 0.4)
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

The leash rule: more than `RetreatTriggerDistance` (15) studs and the boss stops
being an attacker and becomes a nuisance for 0.32s. It dashes backwards, holds,
	then covers 30 studs in a straight line.

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
	stateUntil = os.clock() + Move.RetreatDuration / phaseSpeed()
	bossHumanoid.WalkSpeed = Move.RetreatSpeed
	print(string.format("[BOSS] Shadow Retreat - %.0f studs out", (root.Position - bossRoot.Position).Magnitude))
end

local function beginLunge(target: Model)
	state = "Lunge"
	setPose("Lunge", POSES.Lunge, 0.14)
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
			setPose("Idle", POSES.Idle, 0.3)
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
			setPose("Idle", POSES.Idle, 0.2)
			state = "Recover"
			stateUntil = now + Move.ShadowRetreat.Recovery / phaseSpeed()
	end
	return
	end

	if state == "Reposition" then
		setPose("Guard", POSES.Guard, 0.2)
	stepTowards(targetRoot.Position, AI.RepositionSpeed, 10)
		faceTowards(targetRoot.Position)
	if now >= stateUntil then
			halt()
			-- The leash rule, before the roulette: a boss that has to *choose* to
			-- retreat can choose not to, and a kiting player would then have no answer
			-- at all.
			if distance > Move.RetreatTriggerDistance then
				beginRetreat(target)
			else
				beginMove(rollMove(target))
			end
	end
	return
	end

	if state == "Telegraph" then
		faceTowards(targetRoot.Position)
	local steps = currentMove.Steps
	if steps ~= nil then
			setPose("Thrust", POSES.Thrust, 0.12)
	elseif currentMove.Id == "DragonCleave" then
			setPose("Overhead", POSES.Overhead, 0.1)
	else
			setPose("Thrust", POSES.Thrust, 0.1)
	end
	if now >= stateUntil then
			state = "Strike"
			local active = if steps ~= nil then steps[1].Active else currentMove.Active
			stateUntil = now + active / phaseSpeed()
			stepIndex = 1
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
					local next = steps[stepIndex]
					state = "Telegraph"
					stateUntil = now + next.Windup / phaseSpeed()
						table.clear(struckThisSwing)
					setPose("Thrust", POSES.Thrust, 0.1)
				else
					halt()
					setPose("Idle", POSES.Idle, 0.2)
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
				setPose("Idle", POSES.Idle, 0.24)
				state = "Recover"
				stateUntil = now + currentMove.Recovery / phaseSpeed()
			end
	end
	return
	end

	if state == "Recover" then
		setPose("Idle", POSES.Idle, 0.2)
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
