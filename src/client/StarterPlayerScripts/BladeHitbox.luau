--!strict

--[[
	BladeHitbox
	Ronin — The Last Blade · swept-raycast blade hitbox (Day 5 · Part 1/2)

	Resolves "did the blade touch anything" during the Active window, using the two
	attachments WeaponVisuals put on the katana. This is the first thing in the
	project that turns a state into an outcome: until now Active was a state and a
	lunge, and nothing that happened inside it could ever be wrong.

	Why swept rays rather than a static volume
	-----------------------------------------
	The Active windows are 120ms, 120ms and 180ms - six to eleven frames at 60fps -
	and a katana tip travels several studs per frame while it sweeps. A part-overlap
	test run once per frame would therefore miss a body that only ever existed
	between two sampled positions, which is most of the bodies a swing is supposed
	to connect with.

	So each frame the blade is treated as the volume it swept rather than the volume
	it occupies, and four rays are cast across it: both attachment tracks
	(previous base -> current base, previous tip -> current tip) and both diagonals
	(previous base -> current tip, previous tip -> current base). The first two cover
	a blade translating without rotating, the two diagonals cover a blade pivoting
	in the hand - which is what every pose in the chain's swing table actually does -
	and together they close the quad the blade enclosed between the two frames.

	One contact per target per swing
	--------------------------------
	`hitTargets` is a per-swing set keyed by target model, so a body inside the arc
	for the whole 180ms of Hit 3 is struck once, on the frame it entered. A raw
	per-frame raycast would hit it six times and report a six-hit combo.

	Contract
	--------
	  Start(frameData)  opens the Active window for one hit. Refuses without a rig.
	  Stop()            closes the window. Idempotent, safe from every exit path.
	  IsActive()        whether the window is currently open.

	What a contact is worth
	-----------------------
	Nothing, on its own. This module finds contacts; the server decides what they are
	worth. As of Day 5 · Part 2/2 a contact is reported over `RegisterHitEvent` as a
	*candidate* - target model and hit index, with no damage value attached - and
	`HitValidator` re-derives the damage from its own copy of the frame data before it
	touches a Humanoid. Everything below therefore still holds: the local trace and the
	red beam are prediction and debugging, and there is no path from a raycast here to
	a number of Health.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - this is local prediction and a trace. It reports a
	    contact and publishes it; it never applies damage or a state change. The
	    server stays the sole authority for both, over the validated RemoteEvent
	    described above.
	  * ARCHITECTURE.md #4 - the per-frame path allocates nothing. The RaycastParams
	    and its filter list are built once per swing, the four segments reuse
	    module-scope Vector3s, and `hitTargets` is cleared with table.clear rather
	    than reallocated. The only allocations in a swing are the contact records
	    and debug beams, at most one per target per swing.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

type AttackData = AttackConfig.AttackData
type BladeRig = CombatStateBus.BladeRig

--[[
	A blade that has not moved has no swept volume, and a zero-length raycast is a
	wasted query returning nil on every frame of a swing that never got going.
	1/64th of a stud is below the precision of the engine's own motion, so anything
	bigger than this is real motion worth tracing.
]]
local MIN_SWEEP_DISTANCE = 0.015625

--[[
	Reported once, for the same reason AttackController reports a missing state remote:
	the server script owns both, so their absence is a startup-order problem to notice
	once rather than a line to repeat on every contact.
]]
local warnedNoHitRemote = false

--[[
	Debug beam. Anchored, Neon and non-interactive: it exists to be seen for 0.4s at
	the point of contact, and must not collide with, be touched by, or be traceable
	by anything - including the next swing's own raycasts.
]]
local DEBUG_BEAM_LIFETIME = 0.4
local DEBUG_BEAM_SIZE = Vector3.new(0.22, 0.22, 1.8)
local DEBUG_BEAM_COLOR = Color3.fromRGB(255, 64, 64)
local DEBUG_FOLDER_NAME = "RoninHitboxDebug"

--[[
	Live window state. Module scope for the same reason AttackController and
	WeaponVisuals keep their handles there: Stop is reached from three different
	exit paths (the normal end of Active, an interruption, and a superseding swing)
	and all of them must close the same window.
]]
local sweepConnection: RBXScriptConnection? = nil
local activeRig: BladeRig? = nil
local activeHitIndex: number = 0
local activeDamage: number = 0
local activePoiseDamage: number = 0

-- One contact per target model, for the length of the current swing.
local hitTargets: { [Model]: boolean } = {}

--[[
	Previous frame's world positions of the two attachments. These are the other
	corner of the swept quad, and are the whole reason this is a swept test.

	`WorldPosition`, never `Position`: an Attachment's `Position` is its offset from
	its parent part, so BladeBase and BladeTip would read a constant (0, -1.8, 0) and
	(0, 1.8, 0) no matter where the character stood, and every ray would have been
	cast a few studs from the world origin. Measured in a live playtest, which is how
	it was caught.
]]
local previousBase: Vector3 = Vector3.zero
local previousTip: Vector3 = Vector3.zero

--[[
	Reused across every frame of a swing. `FilterDescendantsInstances` is a
	copy-on-set property, so it is written once per Start rather than once per frame.
]]
local rayParams: RaycastParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- Scratch values for the current frame, read once and reused by all four rays.
local currentBase: Vector3 = Vector3.zero
local currentTip: Vector3 = Vector3.zero
local sweepDirection: Vector3 = Vector3.zero

-- Folder for the contact beams, created on the first hit and reused after that.
local debugFolder: Folder? = nil

--[[
	Declared before the functions below so `sweepFrame` can call back into `Stop`:
	the frame callback closes over this upvalue, and a teardown that runs after a
	death mid-swing has to reach the same public entry point every other exit path
	uses.
]]
local BladeHitbox = {}

--[[
	Draws the red contact beam at the point of contact.

	Oriented along the ray that hit and grown from the contact point forward along
	that ray, so the mark sits *on* the impact rather than starting beside it.
	Removed by Debris rather than by a timer of our own, so a swing that resolves
	early cannot leave a beam stuck to a moving character.
]]
local function drawContactBeam(position: Vector3, direction: Vector3)
	local folder = debugFolder
	if folder == nil or folder.Parent == nil then
		folder = Instance.new("Folder") :: Folder
		folder.Name = DEBUG_FOLDER_NAME
		folder.Parent = Workspace
		debugFolder = folder
	end

	local beam = Instance.new("Part") :: Part
	beam.Name = "BladeContact"
	beam.Size = DEBUG_BEAM_SIZE
	beam.Color = DEBUG_BEAM_COLOR
	beam.Material = Enum.Material.Neon
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanTouch = false
	-- CanQuery off so the beam is invisible to the very raycasts that produced it:
	-- a marker left in the world must not become the next swing's first "target".
	beam.CanQuery = false
	beam.CFrame = CFrame.lookAt(position, position + direction) * CFrame.new(0, 0, -DEBUG_BEAM_SIZE.Z / 2)
	beam.Parent = folder

	Debris:AddItem(beam, DEBUG_BEAM_LIFETIME)
end

--[[
	Resolves one raycast result into a strike, or into nothing.

	The order of these tests is the whole policy of the module:

	  1. the struck part must belong to a Model (a part with no model ancestor is
	     scenery that happens to be in the way);
	  2. that model must not be the attacker's own character - the character is in
	     the RaycastParams filter, so this is a belt-and-braces check that also
	     covers a swing opened against a rig that is already being torn down;
	  3. the model must not already be in `hitTargets` - one strike per swing;
	  4. the model must actually have a Humanoid. A part with no Humanoid behind it
	     is a prop: swinging through a crate is not a hit.

	Note that (3) comes *before* (4) deliberately. Marking a prop as struck would
	silently swallow a real target that shares its model, and a prop can never be a
	legitimate strike, so the set is only ever written for models that are.
]]
local function resolveHit(instance: BasePart, position: Vector3, direction: Vector3, distance: number)
	local rig = activeRig
	if rig == nil then
		return
	end

	local targetModel = instance:FindFirstAncestorOfClass("Model")
	if targetModel == nil or targetModel == rig.Character then
		return
	end

	if hitTargets[targetModel] then
		return
	end

	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if targetHumanoid == nil then
		return
	end

	hitTargets[targetModel] = true

	drawContactBeam(position, direction)

	--[[
		Day 5 · Part 2/2: ask the server to resolve this contact.

		The payload is the target model and the hit index, and nothing else. `Damage`
		and `PoiseDamage` are deliberately *not* sent: the server reads both back out
		of its own `AttackConfig`, so a client that reports 9999 damage gets the frame
		data's number instead. The record published to the bus just below still carries
		them, because that record is for local consumers (the debug HUD) rather than for
		the wire.

		A missing remote is reported once. It means the server script has not run, and
		the swing still resolves locally - the player sees the beam and the trace, the
		Health simply does not move.
	]]
	local hitEvent = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_HIT_EVENT)
	if hitEvent ~= nil and hitEvent:IsA("RemoteEvent") then
		(hitEvent :: RemoteEvent):FireServer(targetModel, activeHitIndex)
	elseif not warnedNoHitRemote then
		warnedNoHitRemote = true
		warn(string.format(
			"[SERVER] %s is not present; the hit was detected but the server never heard it.",
			AttackConfig.REMOTE_HIT_EVENT
		))
	end

	print(string.format("[HIT DETECTED] Struck: %s on Hit #%d", targetModel.Name, activeHitIndex))

	CombatStateBus.FireHit({
		TargetModel = targetModel,
		TargetHumanoid = targetHumanoid,
		HitIndex = activeHitIndex,
		Damage = activeDamage,
		PoiseDamage = activePoiseDamage,
		Position = position,
		Distance = distance,
	})
end

--[[
	Casts one segment of the swept quad and resolves whatever it found. `from` and
	`to` are already-computed world positions, passed in rather than computed here so
	that the four callers share the two position reads.
]]
local function castSegment(from: Vector3, to: Vector3)
	sweepDirection = to - from

	if sweepDirection.Magnitude < MIN_SWEEP_DISTANCE then
		return
	end

	local result = Workspace:Raycast(from, sweepDirection, rayParams)
	if result == nil then
		return
	end

	local hitInstance = result.Instance
	if hitInstance == nil or not hitInstance:IsA("BasePart") then
		return
	end

	-- `RaycastResult` has no Direction of its own; the ray's direction is the one
	-- this function already asked with. Normalising it here rather than inside
	-- resolveHit keeps it off the per-frame path - this line only runs on a frame
	-- where a ray actually connected with something.
	resolveHit(hitInstance :: BasePart, result.Position, sweepDirection.Unit, result.Distance)
end


--[[
	One frame of the Active window: read where the blade is now, sweep the quad it
	came from onto the quad it is at, then make the current positions the previous
	ones.

	The rig is re-validated before the attachment positions are read: a character
	destroyed mid-swing (a death during Active is a legal outcome, COMBAT_SPEC §2)
	leaves a rig whose attachments are no longer parented, and reading Position off a
	destroyed instance throws.
]]
local function sweepFrame()
	local rig = activeRig
	if rig == nil then
		return
	end

	if rig.Blade.Parent == nil then
		BladeHitbox.Stop()
		return
	end

	currentBase = rig.Base.WorldPosition
	currentTip = rig.Tip.WorldPosition

	-- Two tracks of the swept quad: the blade translating without rotating.
	castSegment(previousBase, currentBase)
	castSegment(previousTip, currentTip)

	-- Two diagonals: the blade pivoting in the hand, which is what every pose in
	-- the swing table does. Without these, a rotating blade sweeps a volume that
	-- neither track ever crosses.
	castSegment(previousBase, currentTip)
	castSegment(previousTip, currentBase)

	previousBase = currentBase
	previousTip = currentTip
end

--[[
	Opens the Active window for one hit of the chain.

	Seeds the previous positions from where the blade is *now* rather than from zero,
	so the first frame of the window sweeps from the pose the windup left the blade
	in. That first segment matters most - it is the frame the blade arrives on the
	target in, and a first frame seeded at the origin would trace a 3,000-stud ray
	instead of a 3.8-stud one.

	Refuses loudly when there is no rig, because a swing whose Active window
	quietly does nothing is precisely the failure the previous four days could not
	detect.
]]
function BladeHitbox.Start(frameData: AttackData)
	BladeHitbox.Stop()

	local rig = CombatStateBus.GetBladeRig()
	if rig == nil then
		warn("[HITBOX] Start ignored: no blade rig is published (is WeaponVisuals running?).")
		return
	end

	if rig.Blade.Parent == nil then
		warn("[HITBOX] Start ignored: the published rig belongs to a character that is gone.")
		return
	end

	-- table.clear rather than a fresh table: the set is the same size every swing,
	-- and reallocating it per swing is the one allocation a hitbox can least afford
	-- to make inside an active window.
	table.clear(hitTargets)

	-- The attacker's whole character, blade included, is excluded from every ray.
	rayParams.FilterDescendantsInstances = { rig.Character }

	activeRig = rig
	activeHitIndex = frameData.HitIndex
	activeDamage = frameData.Damage
	activePoiseDamage = frameData.PoiseDamage

	previousBase = rig.Base.WorldPosition
	previousTip = rig.Tip.WorldPosition
	currentBase = previousBase
	currentTip = previousTip

	-- The trail is lit for exactly the window where the blade is meant to be drawing
	-- an arc, and only for that window.
	rig.SetTrailEnabled(true)

	sweepConnection = RunService.RenderStepped:Connect(sweepFrame)

	print(string.format(
		"[HITBOX] Active on Hit #%d (Dmg: %d, Poise: %d) for %.0f ms",
		frameData.HitIndex,
		frameData.Damage,
		frameData.PoiseDamage,
		frameData.ActiveDuration * 1000
	))
end

--[[
	Closes the window. Idempotent, and called from every exit out of Active: the
	normal transition into Recovery, an interruption reaching breakChain, and the
	start of the next swing.

	The connection is cleared before it is disconnected so a re-entrant call during
	teardown cannot find a half-released window, and the rig is released before the
	trail is put out so a destroyed character's trail is never written to.
]]
function BladeHitbox.Stop()
	local connection = sweepConnection
	sweepConnection = nil

	if connection then
		connection:Disconnect()
	end

	local rig = activeRig
	activeRig = nil

	if rig ~= nil then
		rig.SetTrailEnabled(false)
	end
end

--[[
	Whether the window is currently open. Exposed so a caller can assert the wiring
	rather than infer it, and so the debug HUD can render the state honestly.
]]
function BladeHitbox.IsActive(): boolean
	return sweepConnection ~= nil
end

return BladeHitbox
