--!strict

--[[
	WeaponVisuals
	Ronin — The Last Blade · client katana rig (Day 6 · Part 1/2)

	Clones the authored katana out of `ReplicatedStorage.KatanaModel` onto the local
	character, welds it into the right hand, and publishes the handles the rest of the
	client needs so the hitbox has something real to sweep.

	What gets built, on every character spawn:

	    RightHand
	      └─ RoninKatanaGrip      Motor6D, Part0 = RightHand, Part1 = the blade
	           └─ Handle (clone)  the real katana mesh, authored along +Y
	                ├─ BladeBase  Attachment at the guard, just behind the cutting edge
	                └─ BladeTip   Attachment at the point
	    Character
	      └─ RoninKatanaTrail     Trail across BladeBase -> BladeTip, off by default

	Why a Trail rather than a Beam
	------------------------------
	A Beam is a static line between two attachments; a Trail follows the attachments
	as they move, so it is the only one of the two that can show a swing arc. It
	ships disabled: the rig sits in the hand all day, and a permanent ribbon on an
	unswinging katana is visual noise. `SetTrailEnabled` turns it on for the length of
	the Active window, which is exactly when the blade is meant to be drawing an arc.

	Day 6 · Part 1/2 reskins that arc: tapered, glowing and face-on to the camera
	rather than a flat white ribbon. The gradient setup is documented at the
	construction site below, where each of the three sequences is set.

	Why the blade is no longer animated by this script
	--------------------------------------------------
	Day 5 · Part 1/2 drove the swing by writing the grip Motor6D's `C0` every frame,
	because the rigs in this place had no Motor6D joints at all - every joint was an
	AnimationConstraint - and the arm physically could not move. That constraint is
	gone: the rigs now carry standard Motor6D shoulders (verified live: 15 joints
	including `RightUpperArm.RightShoulder`), so the arm animates for real.

	So the shoulder is the driver now, and a second scripted rotation on the grip
	would not add to it - it would fight it. Two drivers on one sword is how you get a
	blade that detaches visually from the arm that is holding it, which is exactly the
	failure this module used to be forced into. The blade is now rigidly welded to the
	hand and rides the arm, which is the requirement stated plainly: the blade follows
	the arm because it *is* attached to it.

	Why a Motor6D for the grip rather than a WeldConstraint
	---------------------------------------------------------
	The joint has to express a fixed offset: the katana's origin sits 1.5 studs ahead
	of and slightly below the palm, tipped ~82 degrees so the blade lies along the
	hand's forward axis instead of standing out of the top of the fist. A WeldConstraint
	can only lock two parts together in whatever relative position they happen to be
	in, and cannot rotate the sword into the palm. `C0` is that fixed offset, and
	nothing writes to it - the swing lives in the shoulder, one joint up.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - the blade is presentation only. It carries no damage, and
	    the client never decides a hit; it only draws where the blade is.
	  * ARCHITECTURE.md #4 - there is no per-frame path in this file at all. The rig is
	    built once per spawn and then only read from.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

type BladeRig = CombatStateBus.BladeRig
type GuardPoseHandle = CombatStateBus.GuardPoseHandle

local localPlayer = Players.LocalPlayer

--[[
	Names. Everything this script creates carries the `Ronin` prefix so a stray blade
	from a previous spawn is recognisable in the hierarchy dump, and so nothing here
	can collide with an avatar's own parts.
]]
local BLADE_NAME = "RoninKatana"
local GRIP_NAME = "RoninKatanaGrip"
local TRAIL_NAME = "RoninKatanaTrail"

-- The two attachment names are contract, not decoration: BladeHitbox names them, and
-- they are the names the day brief specifies.
local BASE_ATTACHMENT_NAME = "BladeBase"
local TIP_ATTACHMENT_NAME = "BladeTip"

--[[
	R15 hands are named "RightHand"; R6 calls the same limb "Right Arm". Both are
	checked so the proxy survives an avatar-type change without a second code path.
]]
local HAND_NAMES = { "RightHand", "Right Arm" }

--[[
	ReplicatedStorage.KatanaModel

	The template is a real, authored katana - a MeshPart from the Creator Store, cleaned
	of the Tool that shipped it (scripts, sounds, sparkles, lights, a TouchTransmitter)
	and rescaled to a believable size. WeaponVisuals never builds geometry: it clones
	that template per spawn, so the sword in the player's hands is the same asset a
	designer can open and inspect, rather than a coloured box that happens to be
	blade-shaped.
]]
local KATANA_MODEL_NAME = "KatanaModel"
local KATANA_BLADE_NAME = "Handle"

--[[
	Where the blade's two sweep attachments sit along the katana's local Y axis.

	These are measured, not chosen. The template mesh was sampled in a live playtest by
	running an OverlapParams query down its length, which gave:

	    y = -2.00 .. +1.96   the full length of the mesh (3.96 studs)
	    y = -0.81            a 0.45-stud bulge, against 0.21-0.30 everywhere else

	That bulge is the tsuba - the guard between the wrapped handle and the blade - so
	the hilt runs from -2.00 up to about -0.81 and the cutting edge runs from there to
	the point at +1.96. `BladeBase` therefore sits just behind the guard and `BladeTip`
	just short of the point, which is the span a swung katana actually sweeps. Putting
	`BladeBase` at the very end of the mesh instead would sweep the wrapped handle,
	which cannot cut and would make the hitbox reach a stud further than the sword does.
]]
local BLADE_BASE_OFFSET = Vector3.new(0, -0.85, 0)
local BLADE_TIP_OFFSET = Vector3.new(0, 1.9, 0)

--[[
	Where the blade sits relative to the hand.

	The hand's axes are near world-aligned while the arm hangs (measured: Up ~(0,1,0),
	Look ~(0,0.12,-0.99) in root space), so a hand-space offset reads as a
	character-space offset. The katana mesh is authored along +Y with the hilt at -Y,
	and `REST_POSE` tips that axis from vertical to near-horizontal so the sword lies
	along the hand's forward axis instead of standing out of the top of the fist.

	`GRIP_TRANSLATION` is how far along that axis the mesh's *centre* is pushed, and
	1.5 is derived from the measured mesh rather than picked: the handle runs from
	y = -2.00 up to the guard at y = -0.81, so its middle sits about 1.4 studs below
	the mesh origin. Placing the origin 1.5 studs ahead of the palm therefore lands the
	middle of the wrapped handle in the fist, with the tsuba just in front of the
	thumb and the point ~3.4 studs out - the reach the distance validator's 14-stud
	ceiling is sized to allow.
]]
local GRIP_TRANSLATION = Vector3.new(0, 0, -1.5)
local REST_POSE = CFrame.Angles(math.rad(-82), 0, 0)

-- The rig currently published to the bus, and the character it belongs to.
local activeRig: BladeRig? = nil
local activeCharacter: Model? = nil

--[[
	Day 6 · Part 2/2 — the Sekiro guard stance.

	The guard is two shoulders and a pair of feet, and all three are driven from one
	blend value so they can never disagree about whether the character is guarding.

	Why the pose is *deltas on the captured rest C0*
	-----------------------------------------------
	Exactly the reason `ARM_POSES` in AttackController is: a hardcoded absolute C0
	would put the arm somewhere anatomically strange on any rig that is not the one
	the numbers were tuned on. Composing onto the captured rest makes each number mean
	"rotate from where this arm happens to hang", which is portable across avatars.

	The angles below were measured on the live R15 rig rather than guessed, by
	sweeping each axis and reading the resulting hand position in the character's own
	frame (+X right, +Y up, -Z forward):

	    RightShoulder  X+55 Y+25 Z-45
	        hand  ( 0.09, -0.22, -1.28)   in front of the sternum, elbows in
	        tip   (-0.32,  1.02, -2.01)   raised, angled across the face
	    LeftShoulder   X+50 Y-30 Z+50
	        hand  (-0.07, -0.37, -1.09)   0.85 studs from the right hand, on the hilt

	That 0.85-stud gap is the number that makes this a two-handed guard rather than
	one arm waving a sword: the left hand lands on the hilt the right hand is holding,
	which is the Sekiro silhouette. The blade tip sitting above and across the sternum
	is the second half of it - the guard is only legible if something is visibly
	between the attacker and the face.

	Z drives the sweep across the body on both arms (negative on the right, positive
	on the left, mirroring each other), which is what carries the hands inward to
	meet in the middle. X lifts and angles, Y fine-tunes the blade's roll.
]]
local GUARD_RIGHT_POSE = CFrame.Angles(math.rad(55), math.rad(25), math.rad(-45))
local GUARD_LEFT_POSE = CFrame.Angles(math.rad(50), math.rad(-30), math.rad(50))

--[[
	The guard snaps up fast and settles back slowly.

	Raising is 0.14s - about a seventh of a second, roughly nine frames - because a
	guard that takes visibly longer than that to arrive is a guard that arrives after
	the blade does. Releasing is slower on purpose: a character that snaps its arms
	down the instant a button is released reads as flinching rather than as choosing a
	new stance, and the 0.18s return is what makes releasing feel like a decision.
]]
local GUARD_RAISE_DURATION = 0.14
local GUARD_RELEASE_DURATION = 0.18

--[[
	One blend value, 0 = rest and 1 = full guard, drives both shoulders.

	A single scalar rather than two independent tweens is the whole point: with one
	value there is no frame on which the left arm is up and the right arm is down, so
	the pose cannot be caught half-formed. Both joints are written from the same
	`applyGuardBlend`, so they are always the same blend.
]]
local guardBlend: NumberValue? = nil
local guardRightShoulder: Motor6D? = nil
local guardLeftShoulder: Motor6D? = nil
local guardRightRest: CFrame? = nil
local guardLeftRest: CFrame? = nil
local guardTween: Tween? = nil
local guardWriteConnection: RBXScriptConnection? = nil
local guardHumanoid: Humanoid? = nil
local guardRestWalkSpeed: number? = nil
local guardIsRaised = false
local guardBlendValue = 0

--[[
	Day 7 · Part 1/2 — the locomotion bleed lock.

	This is the one per-frame write in the whole module that is NOT the guard pose,
	and it exists because of a specific, reproducible failure: walking with the guard
	up swings the arms.

	The cause is that a guard pose written into `C0` is an *additive* offset, not a
	replacement. `C0` says where the shoulder joint sits relative to the torso, and
	every frame the default `Animate` script blends its own locomotion track on top by
	writing `Transform`. A walk cycle's shoulder track swings the arm through
	roughly 20 degrees, and that swing is applied to the guarded arm just as happily
	as to a free one — so the character walks with its guard, and the sword arm
	pumps up and down with every step. The legs walk (their tracks are untouched) and
	the upper body does not hold still, which is the "rock-solid guard stance" the
	guard was supposed to be and is not.

	The fix is to cancel the animation's contribution rather than fight it with a
	bigger `C0` offset. While the guard blend is live, both shoulders' `Transform` is
	forced to `CFrame.identity`, which is exactly "the animation contributes
	nothing", leaving the joint sitting at precisely the `C0` this module composed.
	The legs are deliberately *not* touched, so the character keeps walking normally
	and only the upper body locks — which is the whole intent of the feature.

	Why `PreSimulation` and not `PreAnimation`
	------------------------------------------
	The brief suggested `PreAnimation`, and it is the intuitive choice, but it does
	not work: the engine runs the animation step *after* `PreAnimation` fires, so the
	Animator overwrites whatever this wrote in the same frame and the lock is
	invisible. The Motor6D docs are explicit that `Transform` "can be set manually
	using RunService.PreSimulation", and that is the point in the frame where the
	animation has finished and the simulation has not — the last moment at which a
	manual transform is still the one the physics step will read. Written there, the
	guard holds; written in `PreAnimation`, it does not.

	Both shoulders are written and neither is skipped, for the same reason both are
	written in `applyGuardBlend`: there is no frame on which one arm is locked and the
	other is not.
]]
local locomotionLockConnection: RBXScriptConnection? = nil

local function setGuardBlendValue(value: number)
	guardBlendValue = value
end

--[[
	Installs the per-frame lock. Called only while a guard blend exists, and removed
	by `releaseGuardPose` the moment the blend lands on 0 — a connection that outlived
	the guard would keep writing `Transform` on a character that is no longer
	guarding, which is the exact bug this code exists to fix.

	The threshold is `> 0.01` rather than `> 0` so the lock survives the whole
	release tween and lifts only once the arms are genuinely down. Gating on
	`guardBlend` being non-nil is not enough on its own: the blend object outlives
	the instant value write in the tweened path, so between "release requested" and
	"blend reached 0" the connection is live with a blend approaching zero.
]]
local function startLocomotionLock()
	if locomotionLockConnection ~= nil then
		return
	end

	locomotionLockConnection = RunService.PreSimulation:Connect(function()
		if guardBlendValue <= 0.01 then
			return
		end

		local right = guardRightShoulder
		local left = guardLeftShoulder

		if right ~= nil and right.Parent ~= nil then
			right.Transform = CFrame.identity
		end

		if left ~= nil and left.Parent ~= nil then
			left.Transform = CFrame.identity
		end
	end)
end

local function stopLocomotionLock()
	local connection = locomotionLockConnection
	locomotionLockConnection = nil

	if connection ~= nil then
		connection:Disconnect()
	end
end


-- Reported once, for the same reason as `warnedNoShoulder` in AttackController: a rig
-- without Motor6D shoulders is a supported case, and a line per guard press would be
-- noise that hides a real one.
local warnedNoGuardShoulders = false

--[[
	Applies the guard pose at a given blend.

	Interpolates each shoulder between its captured rest C0 and the rest composed with
	its guard delta, rather than between two absolute frames. Both shoulders are
	written here and nowhere else, which is what makes them structurally incapable of
	disagreeing.

	Both joints are parent-checked because this is reachable from a deferred tween
	callback: a character that died or respawned mid-guard leaves the Motor6D behind
	with a dead parent, and writing C0 to it would be an error rather than a no-op.
]]
local function applyGuardBlend(blend: number)
	local right = guardRightShoulder
	local left = guardLeftShoulder
	local rightRest = guardRightRest
	local leftRest = guardLeftRest

	if right == nil or left == nil or rightRest == nil or leftRest == nil then
		return
	end

	if right.Parent ~= nil then
		right.C0 = rightRest:Lerp(rightRest * GUARD_RIGHT_POSE, blend)
	end

	if left.Parent ~= nil then
		left.C0 = leftRest:Lerp(leftRest * GUARD_LEFT_POSE, blend)
	end

	--[[
		Day 7 · Part 1/2: mirror the blend into the locomotion lock.

		`applyGuardBlend` is the one place the blend is written, so recording it here
		is what keeps the lock and the pose from ever disagreeing — the lock reads the
		same scalar the arms are actually being drawn at, rather than a second copy of
		it that a future edit could fail to update.
	]]
	setGuardBlendValue(blend)
end

--[[
	Drops the guard's write path and puts the arms back.

	`instant` skips the tween entirely and parks both shoulders at rest on the spot.
	That path exists for one caller: `AttackController` needs the right shoulder to be
	*at* rest the instant it captures `shoulder.C0` as the base for a swing's arm
	pose, and a tween in flight would hand it a half-raised arm to compose the slash
	on top of. Tearing the pose down first and swinging second is the only order in
	which the captured rest is the real rest.

	Idempotent, and safe to call when no guard was ever raised. It still parks both
	shoulders on rest in that case, so a caller that is relying on "the arms are down
	when this returns" is never lied to, whether or not there was a blend to tear down.
]]
local function releaseGuardPose(instant: boolean)
	local value = guardBlend
	local tween = guardTween

	guardTween = nil

	-- Cancelled unconditionally: a raise still in flight would otherwise keep pushing
	-- the blend towards 1 while the release is pulling it towards 0, and whichever tween
	-- happened to write last would win.
	if tween ~= nil then
		tween:Cancel()
	end

	if instant then
		--[[
			Park the arms, then tear the write path down - in that order.

			The ordering is the entire point of this branch. `applyGuardBlend(0)` has to
			run while the connection is still capable of writing, because a caller
			waiting on this function needs the joints to actually be at rest the instant
			it returns, not "about to be" rest. Disconnecting first and writing after
			would leave the arms frozen wherever the last raise frame left them, which
			is exactly the bug this branch exists to prevent.
		]]
		applyGuardBlend(0)

		if guardWriteConnection ~= nil then
			guardWriteConnection:Disconnect()
			guardWriteConnection = nil
		end

		if value ~= nil then
			value:Destroy()
		end

		-- Day 7 · Part 1/2: the lock comes down with the blend. On the instant path
		-- the blend is already 0, so holding the lock one frame longer would be
		-- invisible — but it is removed here anyway so all three exits below share
		-- one teardown and none can forget it.
		stopLocomotionLock()

		guardBlend = nil
	elseif value ~= nil then
		--[[
			Smooth return. The write connection deliberately STAYS live for the
			duration - it is what turns the blend coming down from 1 into the arms
			coming down with it - and is dropped only once the blend has landed on 0.

			That is the reason this branch does not share the disconnect above: cutting
			the connection before the tween runs is what would freeze the pose, because a
			NumberValue animating with nobody reading it moves nothing.
		]]
		local returnTween = TweenService:Create(value, TweenInfo.new(
			GUARD_RELEASE_DURATION,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut
		), { Value = 0 })

		guardTween = returnTween
		returnTween.Completed:Once(function()
			-- Only tear down if this tween is still the current one; a re-raise during
			-- the return owns the blend now and this callback is stale.
			if guardTween ~= returnTween then
				return
			end

			guardTween = nil

			if guardWriteConnection ~= nil then
				guardWriteConnection:Disconnect()
				guardWriteConnection = nil
			end

			returnTween:Destroy()
			value:Destroy()

			-- Day 7 · Part 1/2: released only here, once the blend has actually
			-- landed on 0. Dropping it when the release was *requested* would let the
			-- walk cycle take the arms back mid-tween, and the guard would visibly
			-- "let go" a fifth of a second before the arms finished coming down.
			stopLocomotionLock()

			guardBlend = nil
		end)

		returnTween:Play()
	else
		-- No live blend: nothing was raised, or an earlier release already finished.
		-- Still park the arms, so a caller's "release before I read the C0" promise
		-- holds even when there was nothing to tear down.
		applyGuardBlend(0)

		if guardWriteConnection ~= nil then
			guardWriteConnection:Disconnect()
			guardWriteConnection = nil
		end

		-- Day 7 · Part 1/2: third teardown, same reason — see the first one.
		stopLocomotionLock()
	end

	-- Footwork returns with the arms. Guarding at 9 studs a second is a stance, not
	-- a sentence; leaving the character walking at half speed after the guard is down
	-- would read as a bug the player experiences as "my character is slow for no
	-- reason".
	local humanoid = guardHumanoid
	local restSpeed = guardRestWalkSpeed
	if humanoid ~= nil and restSpeed ~= nil and humanoid.Parent ~= nil then
		humanoid.WalkSpeed = restSpeed
	end

	guardIsRaised = false
end

--[[
	Raises the guard: arms to the two-handed pose, feet to defensive footwork.

	Guards on `guardIsRaised` rather than on the state transition alone, so a
	re-published `Blocking` (the debug harness forcing a state, a listener running
	twice) cannot stack a second blend value on top of a live one and leave the arms
	driven by an orphan tween forever.

	Refuses when there is no rig to pose. A character with no Motor6D shoulders is a
	supported case (R6 has none), not an error.
]]
local function raiseGuardPose()
	if guardIsRaised then
		return
	end

	local right = guardRightShoulder
	local left = guardLeftShoulder
	local rightRest = guardRightRest
	local leftRest = guardLeftRest

	if right == nil or left == nil or rightRest == nil or leftRest == nil then
		return
	end

	guardIsRaised = true

	-- Defensive footwork, from the shared config so the number lives in exactly one
	-- place. The rest speed is captured rather than hardcoded to 16 so a character
	-- that was already moving at some other speed gets that speed back.
	local humanoid = guardHumanoid
	if humanoid ~= nil and humanoid.Parent ~= nil then
		if guardRestWalkSpeed == nil then
			guardRestWalkSpeed = humanoid.WalkSpeed
		end

		humanoid.WalkSpeed = AttackConfig.GUARD_WALK_SPEED
	end

	local value = Instance.new("NumberValue")
	value.Name = "RoninGuardBlend"
	value.Value = 0
	value.Parent = left

	-- Any tween still holding the *previous* blend is cancelled before a new value
	-- takes over. A release caught halfway down owns a value this raise is about to
	-- orphan, and its Completed callback would then tear down the fresh blend's
	-- connection - dropping the guard a frame after it went up.
	if guardTween ~= nil then
		guardTween:Cancel()
		guardTween = nil
	end

	if guardWriteConnection ~= nil then
		guardWriteConnection:Disconnect()
		guardWriteConnection = nil
	end

	guardBlend = value

	-- The one per-frame write in the guard, and it allocates nothing: the
	-- changed-signal callback is handed the blend directly.
	guardWriteConnection = value:GetPropertyChangedSignal("Value"):Connect(function()
		applyGuardBlend(value.Value)
	end)

	local raiseTween = TweenService:Create(value, TweenInfo.new(
		GUARD_RAISE_DURATION,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	), { Value = 1 })

	guardTween = raiseTween
	raiseTween:Play()

	--[[
		Day 7 · Part 1/2: arm the locomotion lock with the raise.

		Installed *after* `Play()` rather than before, so the blend's first write and
		the lock's first write are the same frame the arms start moving. The lock
		reads `guardBlendValue`, which is already 0 at this point and climbs with the
		tween, so it engages the instant the blend passes the threshold rather than
		snapping on at full strength and popping.
	]]
	startLocomotionLock()
end

--[[
	Finds the character's right hand, R15 or R6. Split find and cast so the nil test
	comes first and the cast narrows a value the checker already knows is present,
	rather than leaning on a cast of a possibly-nil Instance.
]]
local function findHand(character: Model): BasePart?
	for _, handName in ipairs(HAND_NAMES) do
		local candidate = character:FindFirstChild(handName)
		if candidate ~= nil and candidate:IsA("BasePart") then
			return candidate :: BasePart
		end
	end

	return nil
end

--[[
	Builds the katana rig for a character and publishes it on the bus.

	Everything created is parented into the character, so a respawn destroys the whole
	rig for free: there is no cleanup pass that could miss an instance, and no
	window in which a stale blade is still parented to a dead model. The only thing
	that has to be actively cleared is the bus reference, which is why the callers
	below always clear it.

	Failures are loud on purpose. A missing template or a renamed handle means the
	sword is not in the player's hand, and that is precisely the kind of failure the
	client cannot notice on its own - the hitbox would simply never find a rig and
	warn about something else entirely.
]]
local function equip(character: Model)
	-- R15 assembles the body asynchronously, so the hand is not necessarily there on
	-- the CharacterAdded edge. The timeout is a failure path, not a wait: a rig that
	-- never produced a hand is reported and skipped rather than parked forever.
	local hand = findHand(character)
	if hand == nil then
		character:WaitForChild(HAND_NAMES[1], 10)
		hand = findHand(character)
	end

	if hand == nil then
		warn("[WEAPON] No right hand on the character; the katana was not equipped.")
		return
	end

	-- The template is waited on rather than read directly: ReplicatedStorage is
	-- replicated independently of StarterPlayerScripts, so on a cold join the script
	-- can be ready before the model has streamed in.
	local template = ReplicatedStorage:WaitForChild(KATANA_MODEL_NAME, 10)
	if template == nil then
		warn(string.format(
			"[WEAPON] ReplicatedStorage.%s is missing; the katana was not equipped.",
			KATANA_MODEL_NAME
		))
		return
	end

	local bladeTemplate = template:FindFirstChild(KATANA_BLADE_NAME)
	if bladeTemplate == nil or not bladeTemplate:IsA("BasePart") then
		warn(string.format(
			"[WEAPON] %s has no %s part; the katana was not equipped.",
			KATANA_MODEL_NAME,
			KATANA_BLADE_NAME
		))
		return
	end

	local blade = bladeTemplate:Clone() :: BasePart
	blade.Name = BLADE_NAME
	blade.Anchored = false
	-- Non-colliding and massless so the sword never shoves the character around or
	-- trips physics - the Motor6D drags it. CanQuery stays on so a future server-side
	-- pass can trace another player's blade.
	blade.CanCollide = false
	blade.CanTouch = false
	blade.CanQuery = true
	blade.Massless = true
	blade.CFrame = hand.CFrame * CFrame.new(GRIP_TRANSLATION) * REST_POSE
	blade.Parent = character

	-- The grip is parented to the blade, so the joint dies with the part it moves.
	local grip = Instance.new("Motor6D") :: Motor6D
	grip.Name = GRIP_NAME
	grip.Part0 = hand
	grip.Part1 = blade
	grip.C0 = CFrame.new(GRIP_TRANSLATION) * REST_POSE
	grip.C1 = CFrame.new()
	grip.Parent = blade

	-- The two sweep endpoints, at the guard and the point. Their asymmetry is the
	-- point: a raycast between them covers the whole cutting edge, while a single
	-- midpoint would cover none of it.
	local bladeBase = Instance.new("Attachment") :: Attachment
	bladeBase.Name = BASE_ATTACHMENT_NAME
	bladeBase.Position = BLADE_BASE_OFFSET
	bladeBase.Parent = blade

	local bladeTip = Instance.new("Attachment") :: Attachment
	bladeTip.Name = TIP_ATTACHMENT_NAME
	bladeTip.Position = BLADE_TIP_OFFSET
	bladeTip.Parent = blade

	--[[
		Day 6 · Part 1/2: the swing arc.

		This was a flat, evenly-lit ribbon: `ColorSequence.new(a, b)` and nothing
		else, so the whole polygon was one soft smear with a hard cut at both ends.
		Three properties are what separate a glowing edge from a sheet of tissue
		paper, and all three are read along the *history* of the trail, not along its
		width:

		  * `WidthScale` is what makes it a blade arc rather than a slab. It runs
		    1.0 at Attachment1 (BladeTip) down to 0.0 at Attachment0 (BladeBase), so
		    the ribbon is at its widest where the point is drawing and closes to
		    nothing at the guard. That is the shape of a katana edge in motion: the
		    tip leads, the hilt trails off.
		  * `Transparency` runs 0.1 at the tip to 1.0 at the tail, so the arc is
		    nearly opaque where it is fresh and has fully dissolved by the time it
		    is oldest. Tying opacity to age is what sells speed - a trail whose tail
		    stays visible reads as a solid object following the sword, not as
		    motion blur.
		  * `LightEmission` at 0.8 makes the ribbon glow rather than shade: the
		    colour contributes almost nothing to the final pixel, so the arc keeps
		    its brightness in an unlit night map instead of vanishing into it.

		`FaceCamera` keeps the ribbon edge-on to the viewer, so the arc reads as a
		crisp line of light rather than a billboard that flares as the blade turns.
		The mid keypoints are deliberate: an arc with only two stops has a visible
		seam where the gradient rate changes, and the extra stops put the falloff
		where the eye expects it - a long bright leading edge and a short fade.

		`Lifetime` is 0.12s, matching the shortest Active window in the chain. A
		trail that outlived its own swing would still be drawing after the blade had
		recovered, which is the same "two drivers" mistake in a different place.
	]]
	local trail = Instance.new("Trail") :: Trail
	trail.Name = TRAIL_NAME
	trail.Attachment0 = bladeBase
	trail.Attachment1 = bladeTip
	trail.Lifetime = 0.12
	trail.MinLength = 0.05
	trail.LightEmission = 0.8
	trail.FaceCamera = true

	-- White-hot at the point, cooling to steel blue along the arc.
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(38, 58, 112)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(96, 150, 224)),
		ColorSequenceKeypoint.new(0.72, Color3.fromRGB(186, 226, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})

	-- Nearly opaque at the point, gone by the oldest segment.
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.55),
		NumberSequenceKeypoint.new(0.7, 0.18),
		NumberSequenceKeypoint.new(1, 0.1),
	})

	-- Widest at the point, closed to nothing at the guard.
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.28, 0.3),
		NumberSequenceKeypoint.new(0.75, 0.78),
		NumberSequenceKeypoint.new(1, 1),
	})

	trail.Enabled = false
	trail.Parent = character

	activeCharacter = character

	--[[
		Day 6 · Part 2/2: capture the guard's rest pose.

		The rest C0s are read once here, on this character's own rig, and every guard
		pose is composed onto them. `AttackController` reads the right shoulder's C0
		the same way when it starts a swing, so both systems measure the rig the same
		way and agree on what "at rest" means.

		Both shoulders are required. A half-raised guard - sword arm up, support arm
		hanging at the player's side - is worse than no guard animation at all, so a rig
		missing either joint gets no guard pose rather than a broken one. Reported once,
		not per press.
	]]
	local rightUpperArm = character:FindFirstChild("RightUpperArm")
	local leftUpperArm = character:FindFirstChild("LeftUpperArm")
	local rightJoint = if rightUpperArm then rightUpperArm:FindFirstChild("RightShoulder") else nil
	local leftJoint = if leftUpperArm then leftUpperArm:FindFirstChild("LeftShoulder") else nil

	if rightJoint and rightJoint:IsA("Motor6D") and leftJoint and leftJoint:IsA("Motor6D") then
		guardRightShoulder = rightJoint
		guardLeftShoulder = leftJoint
		guardRightRest = rightJoint.C0
		guardLeftRest = leftJoint.C0
		guardRestWalkSpeed = nil
	else
		guardRightShoulder = nil
		guardLeftShoulder = nil
		guardRightRest = nil
		guardLeftRest = nil

		if not warnedNoGuardShoulders then
			warnedNoGuardShoulders = true
			print("[GUARD] No Motor6D shoulders on this character; the guard pose is disabled.")
		end
	end

	guardHumanoid = nil
	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if humanoidInstance then
		guardHumanoid = humanoidInstance
	end

	activeRig = {
		Character = character,
		Hand = hand,
		Blade = blade,
		Base = bladeBase,
		Tip = bladeTip,
		Trail = trail,
		SetTrailEnabled = function(enabled: boolean)
			if trail.Parent then
				trail.Enabled = enabled
			end
		end,
		StartSwing = function(_hitIndex: number, _windup: number, _active: number, _recovery: number)
			-- The shoulder is the swing driver now (see the header), so the blade needs
			-- no per-frame pose of its own - a second driver on the same sword is what
			-- made the blade look detached in Part 1/2. The method stays on the seam so
			-- the swing driver can still express "a swing starts here" in one place, and
			-- the body is deliberately empty rather than deleted: `StopSwing` below is the
			-- matching no-op, and a seam whose halves can be deleted independently is a
			-- seam that eventually is.
		end,
		StopSwing = function()
			-- Nothing to release: the blade is welded and the arm owns the recovery.
		end,
	}

	CombatStateBus.SetBladeRig(activeRig)

	--[[
		Day 6 · Part 2/2: publish the guard as a second seam.

		`CombatController` observes every state transition from every source, so it is
		the one place that knows a `Blocking` began or ended - the same one-observer
		rule that already governs the server-facing guard flag in Part 1/2. Registering
		the pose here rather than having WeaponVisuals subscribe to transitions itself
		keeps a single observer, and keeps this module free of any knowledge of *why*
		the guard came up (hold, debug reset, or a future parry).
	]]
	local guardHandle: GuardPoseHandle = {
		Raise = raiseGuardPose,
		Release = releaseGuardPose,
		IsRaised = function(): boolean
			return guardIsRaised
		end,
	}

	CombatStateBus.SetGuardPose(guardHandle)

	print("[WEAPON] Katana equipped: cloned mesh, grip weld, BladeBase/BladeTip and tapered glow trail.")
end

--[[
	Drops the published rig. Called for a character that is leaving, and for the
	character that is leaving when a new one arrives before it, so a fast respawn
	cannot leave the bus pointing at a destroyed character.
]]
local function unequip()
	--[[
		Day 6 · Part 2/2: retire the guard before the character does.

		Torn down `instant` rather than tweened, because the joints this pose writes are
		about to be destroyed along with the character - a 0.18s tween toward a rig that
		no longer exists is 0.18s of the new character's shoulders being written by the
		old character's guard. The `Parent` checks in `applyGuardBlend` make that
		harmless, but not doing it at all is better than making it harmless.
	]]
	releaseGuardPose(true)

	--[[
		Day 7 · Part 1/2: the locomotion lock is a connection rather than an instance,
		so nothing destroying the character takes it with it. `releaseGuardPose(true)`
		already disconnects it, and this is the second line of defence for the case
		where it somehow outlived that: a live `PreSimulation` connection holding
		references to a dead character's Motor6Ds is exactly the kind of thing that
		survives a respawn and writes into a torn-down rig forever.
	]]
	stopLocomotionLock()

	activeRig = nil
	activeCharacter = nil
	CombatStateBus.SetBladeRig(nil)
	CombatStateBus.SetGuardPose(nil)
end

local function onCharacterAdded(character: Model)
	-- A respawn can arrive while the previous rig is still live. The published rig
	-- is the record of "the bus is currently pointing at a character", so it is what
	-- this checks rather than a separate boolean that could disagree with it.
	if activeRig ~= nil then
		unequip()
	end

	equip(character)
end

local function onCharacterRemoving(character: Model)
	-- Only the character that owns the current rig may retire it; CharacterRemoving
	-- also fires for characters this binding has already moved on from.
	if activeCharacter ~= character then
		return
	end

	unequip()
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)
localPlayer.CharacterRemoving:Connect(onCharacterRemoving)

-- The local player may already be alive by the time this script starts.
local existingCharacter = localPlayer.Character
if existingCharacter then
	onCharacterAdded(existingCharacter)
end
