--!strict

--[[
	DodgeController
	Ronin — The Last Blade · camera-relative step-dodge (Day 9 · Parts 1/2 + 2/2)

	The [Q] handler, and the only thing in the project that asks for
	invulnerability.

	What one dodge is
	----------------
	    0.000s  Dodging. I-frames open. Body pushed at DODGE_SPEED, torso
	            pitched into the dash. 10 posture spent.
	    0.060s  The lean lands (sharp in, Back/Out - a slip has to register
	            as a reaction, not a slide).
	    0.200s  I-frames close. The push is released. The lean is HELD.
	    0.350s  Lean unwinds, back to Idle. Posture begins recovering.

	Direction is camera-relative, and the reason it is *free* is that
	`Humanoid.MoveDirection` already is. The default control module builds that
	vector in camera space, so "W" means "away from the camera" and nothing here
	has to reconstruct it. The two candidate sources are:

	  * moving  -> `MoveDirection.Unit`, flattened to the ground plane.
	  * neutral -> the negated, flattened camera forward vector: a backstep.

	The backstep case is the interesting one. A dodge with no direction input has
	to pick *something*, and "backwards relative to where you are looking" is the
	only choice that is almost always what the player meant: they are being
	pressed, they pressed no key, and the threat is in front of them because that
	is where threats are.

	Why the input path is a bus registration, not a second binding
	-----------------------------------------------------------------
	`InputBinder` already owns the [Q] binding and is the single sink for every
	combat intent (the binder decides *when to ask*, never *whether it is
	allowed*). Binding Q again here would give one keypress two independent
	consumers that race. So this script registers an executor on the bus - the
	same seam `AttackController` uses for the light attack - and the binder's
	existing `Dodge` action is what routes here.

	Why a LinearVelocity and not AssemblyLinearVelocity
	-------------------------------------------------
	Setting `AssemblyLinearVelocity` once is an *impulse*: it hands the body a
	velocity and lets the Humanoid's own locomotion fight it straight back down
	to WalkSpeed, which is why it reads as a nudge. A `LinearVelocity` constraint
	holds a *target* velocity for exactly as long as it exists and stops the
	instant it is destroyed. The distinction matters because the safety and the
	movement have to end at the same moment, and only a constraint whose lifetime
	this file controls can guarantee that.

	The force ceiling is the part that is easy to get wrong and expensive to get
	wrong: `MaxAxesForce` is what stops a dodge into a wall from launching the
	character, and its Y entry being zero is what leaves gravity in charge. The
	full reasoning lives with the constant in `AttackConfig`.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #2 - the outbound message is schema-shaped.
	  * ARCHITECTURE.md #3 - this file *asks*. The server decides whether the
	    i-frames are real, from its own clock; the client's copy of that is
	    prediction, and it feeds the HUD and nothing else.
	  * ARCHITECTURE.md #4 - nothing here runs per frame. A dodge is two
	    `task.delay` closures and a three-instance trail.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[[
	Day 9 · Part 1/2.

	`Debris` owns the ghost trail's lifetime rather than the tween's `Completed`
	callback, for one specific reason: a dodge can be cut short. A character hit
	into `Stunned` one frame into a dodge still has three ghosts in the world, and
	waiting on a tween that nobody is watching to clear them would leave them
	hanging there. `Debris:AddItem` is a hard deadline that no interruption can
	outlive, and it is the same mechanism the rest of the engine uses for exactly
	this kind of throwaway visual.
]]
local Debris = game:GetService("Debris")

local CombatTypes = require(ReplicatedStorage:WaitForChild("CombatTypes") :: ModuleScript)
local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

type CombatState = CombatTypes.CombatState

local DODGE_IFRAME_DURATION = AttackConfig.DODGE_IFRAME_DURATION
local DODGE_TOTAL_DURATION = AttackConfig.DODGE_TOTAL_DURATION
local DODGE_RECOVERY_DURATION = AttackConfig.DODGE_RECOVERY_DURATION
local DODGE_SPEED = AttackConfig.DODGE_SPEED
local DODGE_MAX_AXES_FORCE = AttackConfig.DODGE_MAX_AXES_FORCE
local DODGE_MOVE_DEADZONE = AttackConfig.DODGE_MOVE_DEADZONE
local DODGE_LEAN_JOINT = AttackConfig.DODGE_LEAN_JOINT
local DODGE_LEAN_FORWARD_DEG = AttackConfig.DODGE_LEAN_FORWARD_DEG
local DODGE_LEAN_BACKWARD_DEG = AttackConfig.DODGE_LEAN_BACKWARD_DEG
local DODGE_LEAN_BANK_DEG = AttackConfig.DODGE_LEAN_BANK_DEG
local DODGE_LEAN_TORSO_DROP = AttackConfig.DODGE_LEAN_TORSO_DROP
local DODGE_LEAN_TWEEN_IN = AttackConfig.DODGE_LEAN_TWEEN_IN
local DODGE_LEAN_RETURN_DURATION = AttackConfig.DODGE_LEAN_RETURN_DURATION
local POSTURE_ATTRIBUTE = AttackConfig.POSTURE_ATTRIBUTE
local DODGE_POSTURE_LOCKOUT = AttackConfig.DODGE_POSTURE_LOCKOUT
local DODGE_POSTURE_COST = AttackConfig.DODGE_POSTURE_COST
local DODGE_SPAM_WINDOW = AttackConfig.DODGE_SPAM_WINDOW
local DODGE_SPAM_COST_STEP = AttackConfig.DODGE_SPAM_COST_STEP
local DODGE_SPAM_MAX_CHAIN = AttackConfig.DODGE_SPAM_MAX_CHAIN

local localPlayer = Players.LocalPlayer

--[[
	The dodge's physical half, and the only physics this file owns.

	Both handles are module scope rather than locals of `TryDodge` for the same
	reason `AttackController` keeps its lunge handles at module scope: the exit
	paths out of a dodge - the i-frame timer, the total-duration timer, and
	teardown - run in three different threads, and a local captured as an upvalue
	would be copied into each closure. Only the closure that created it would ever
	be able to see the constraint it needs to destroy, so a second dodge would
	stack a second push on top of a first one nobody can reach.
]]
local dodgeConstraint: LinearVelocity? = nil
local dodgeAttachment: Attachment? = nil

--[[
	Monotonic token identifying the dodge that owns those handles.

	`StateMachine` dispatches its listeners through `task.spawn`, and a dodge's
	two timers are independent `task.delay` closures, so the threads interleave: a
	release belonging to dodge N can land *after* dodge N+1 has already begun. The
	token makes a stale timer a no-op instead of a character whose dodge was
	cancelled by a dodge that had not started yet. This is the same argument as
	`stunGeneration` in `CombatController`, for the same reason.
]]
local dodgeGeneration = 0

--[[
	Releases the push and forgets the dodge that owned it.

	Idempotent, and safe to call when no dodge is running: every exit path calls
	it, including the ones taken when a dodge never started. The handles are taken
	out of the module *first* and only then destroyed, so a re-entrant call during
	teardown cannot find a half-released push.
]]
local function stopDodge()
	local constraint = dodgeConstraint
	local attachment = dodgeAttachment

	dodgeConstraint = nil
	dodgeAttachment = nil

	if constraint then
		constraint:Destroy()
	end

	if attachment then
		attachment:Destroy()
	end
end

--[[
	Resolves the local character's root part, or nil.

	Find-and-cast is split from the nil test for the reason it is split everywhere
	else in this project: the nil test has to run before the cast narrows a value
	the type checker already knows is present.
]]
local function findRootPart(character: Model): BasePart?
	local instance = character:FindFirstChild("HumanoidRootPart")
	if instance == nil or not instance:IsA("BasePart") then
		return nil
	end

	return instance :: BasePart
end

--[[
	Flattens a direction onto the ground plane and normalises it.

	Both the `MoveDirection` path and the camera path need this, and both need it
	to be *safe* on a short input: `Vector3.Unit` on a near-zero vector is
	documented as unreliable and returns the zero vector, which would produce a
	dodge with a `VectorVelocity` of (0, 0, 0) - a dodge that opens its i-frames,
	costs 350ms of vulnerability, and moves the character nowhere. The magnitude
	test turns that silent failure into a fallback.

	The Y component is dropped rather than preserved because a dodge that climbs
	or launches is not a step. It also means the push is exactly horizontal,
	which is the only shape the zero-Y force ceiling in `DODGE_MAX_AXES_FORCE` is
	written to permit.
]]
local function flattenAndUnit(direction: Vector3): Vector3?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.001 then
		return nil
	end

	return flat.Unit
end

--[[
	Resolves which way the dodge goes.

	`MoveDirection` is read first and only because it is already camera-relative;
	if it were rebuilt here from the camera and the raw keys, the dodge would drift
	from the walk on any input scheme that is not WASD, and "dodge where I am
	walking" would quietly become "dodge north".

	Returns the direction and a short name for the trace and the HUD.

	The two fallbacks on the camera path are both real. `Workspace.CurrentCamera`
	is nil for a frame between a camera being destroyed and its replacement
	existing, and a camera pointed straight down yields a zero horizontal vector
	before flattening. Both cases fall through to the character's own facing,
	which is always a valid answer: it is the direction the player last *chose* to
	be looking.
]]
local function resolveDodgeDirection(character: Model, humanoid: Humanoid): (Vector3?, string)
	if humanoid.MoveDirection.Magnitude > DODGE_MOVE_DEADZONE then
		local flat = flattenAndUnit(humanoid.MoveDirection)
		if flat then
			return flat, "MOVE"
		end
	end

	local camera = workspace.CurrentCamera
	if camera ~= nil then
		local backstep = flattenAndUnit(-camera.CFrame.LookVector)
		if backstep then
			return backstep, "BACKSTEP"
		end
	end

	local rootPart = findRootPart(character)
	if rootPart then
		local facing = flattenAndUnit(-rootPart.CFrame.LookVector)
		if facing then
			return facing, "FACING"
		end
	end

	return nil, "NONE"
end

--[[
	Day 9 · Part 2/2 · the procedural dash lean.

	What this section is for
	------------------------
	A `LinearVelocity` moves a character without touching its *pose*. The root is
	sliding at 45 studs/s while the legs are still running their ordinary cycle, so
	the dodge reads as a skate: the body is dragged out from under itself and
	nothing in the silhouette says "evasion". The lean is the fix, and the reason it
	is procedural rather than an animation is that an AnimationTrack would need an
	asset, an `AnimationController`, priority arbitration against whatever idle is
	already playing, and a fade-out landing in the same 350ms window this whole
	move lives in. Rotating one joint costs two tweens and no new instances.

	The joint
	---------
	`LowerTorso.Root` - the R15 Motor6D joining `HumanoidRootPart` to the torso.
	That is the correct one and it is not interchangeable with the alternatives:
	rotating `LowerTorso.RootJoint` pivots the *whole body including the legs*,
	which reads as the character toppling sideways rather than stepping, and
	tilting the neck reads as a flinch.

	`C0` and not `Transform`
	------------------------
	`Motor6D.Transform` is the property the `Animator` writes, and the engine
	applies it as a batch in a parallel job after `PreSimulation`. `C0` is the
	immediate, non-Animator path. A dodging character very much *has* an Animator
	driving that same joint (the default `Animate` LocalScript is running the idle
	and walk cycles), so a `Transform` overlay would be overwritten by the next
	animation event before it was ever applied, and a `C0` overlay is the one of
	the two that survives. Verified against the current engine reference: `C0` is
	not deprecated - the docs recommend `Transform` *for animating rigged models*,
	which is not what a 200ms procedural overlay is.

	The neutral pose
	----------------
	`leanNeutralC0` is captured once per *joint instance*, not once per dodge. A
	dodge that re-read `joint.C0` at the start of every cast would capture whatever
	the previous dodge's release tween happened to be passing through, and a second
	dodge landing mid-release would therefore store a half-unwound pose as "neutral"
	and tween back to it forever after. Caching per joint makes the return target a
	property of the character rather than of the move.

	Everything here is generation-stamped for the same reason `dodgeConstraint` is:
	`StateMachine` dispatches listeners through `task.spawn` and the release runs
	from three different threads, so a release belonging to dodge N can land after
	dodge N+1 has begun. A stale release would snap the torso upright underneath a
	dodge that is still in flight.
]]
local leanJoint: Motor6D? = nil
local leanNeutralC0: CFrame? = nil
local leanTween: Tween? = nil

--[[
	Resolves the torso joint, or nil when the rig does not have one.

	Returns nil rather than erroring for a stripped custom rig, a mannequin, or an
	R6 character (which has `Torso.RootJoint` and no `LowerTorso` at all). Every
	caller treats nil as "dodge without a lean", because the lean is a presentation
	layer over a move that is already fully functional without it. A missing joint
	must never be the reason a dodge fails to cast.
]]
local function findLeanJoint(character: Model): Motor6D?
	local lowerTorso = character:FindFirstChild("LowerTorso")
	if lowerTorso == nil or not lowerTorso:IsA("BasePart") then
		return nil
	end

	local joint = lowerTorso:FindFirstChild(DODGE_LEAN_JOINT)
	if joint == nil or not joint:IsA("Motor6D") then
		return nil
	end

	return joint :: Motor6D
end

--[[
	Snaps the torso back and forgets the lean entirely.

	The hard reset, used by teardown and by a new dodge casting over a live lean.
	`C0` is assigned directly rather than through a zero-length tween: a tween would
	still be scheduled against a character on its way out of the world, and the
	point of this path is that nothing is left running.
]]
local function cancelDodgeLean()
	local tween = leanTween
	local joint = leanJoint
	local neutral = leanNeutralC0

	leanTween = nil
	leanJoint = nil
	leanNeutralC0 = nil

	if tween then
		tween:Cancel()
	end

	-- `Parent` rather than nil-checking the joint: a joint on a character that has
	-- already left the workspace is still a live object, and writing to it is
	-- wasted work against a model nobody will ever see again.
	if joint ~= nil and neutral ~= nil and joint.Parent ~= nil then
		joint.C0 = neutral
	end
end

--[[
	Unwinds the lean over `duration`, landing exactly on the captured neutral.

	Idempotent and generation-guarded, so the 350ms timer and `onStateChanged` can
	both call it: whichever runs first starts the unwind, and the second finds a
	zeroed handle and returns. Cancelling the in-flight tween before starting the
	return is what stops the two tweens fighting over the same `C0` for the length
	of the return.
]]
local function releaseDodgeLean(myGeneration: number, duration: number)
	if myGeneration ~= dodgeGeneration then
		return
	end

	local joint = leanJoint
	local neutral = leanNeutralC0
	if joint == nil or neutral == nil then
		return
	end

	local previous = leanTween
	leanTween = nil
	if previous then
		previous:Cancel()
	end

	if joint.Parent == nil then
		leanJoint = nil
		leanNeutralC0 = nil
		return
	end

	local tween = TweenService:Create(
		joint,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ C0 = neutral }
	)
	leanTween = tween
	tween:Play()
end

--[[
	Pitches and banks the torso along `direction`.

	The direction is decomposed in the *root part's* local frame rather than in
	world axes, which is what makes the lean follow the character: `C0` is
	expressed relative to `HumanoidRootPart`, and the root turns with the body, so a
	lean computed in world space would be leaning "north" while the character faces
	east. `VectorToObjectSpace` gives the direction in the frame the rotation is
	actually applied in, and the dodge direction is already flattened to the ground
	plane by `resolveDodgeDirection`.

	Both rotations are `-amount * angle` for the same reason, and it is worth being
	explicit because it is the part that is easy to get backwards:

	  * Pitch rotates about the local X axis. A *positive* angle about +X swings
	    the character's facing (-Z) upward, so a forward lean needs a *negative*
	    angle. One sign therefore serves both cases: forward (`forwardAmount > 0`)
	    leans the torso down into the slip, and backward (`forwardAmount < 0`) leans
	    it up and away into the retreat.
	  * Bank rotates about the local Z axis. A positive angle about +Z tips the up
	    vector toward -X, which is the character's *left*, so banking into a
	    rightward slide is negative for the same reason.

	The dip is a translation on top of the rotation, scaled by the forward component
	so it only happens on a forward slip: rotation alone about a joint sitting at
	the waist pivots the upper body in place, which reads as a mannequin falling
	sideways. Dropping the shoulder line while it turns is what makes it read as
	weight moving.

	Only the dominant axis is used. A diagonal dodge picks whichever component is
	larger, because a 25-degree pitch *and* a 20-degree bank applied together is a
	32-degree compound twist that no longer looks like a dash in any direction - it
	looks like the character was dropped.
]]
local function applyDodgeLean(rootPart: BasePart, direction: Vector3)
	local character = localPlayer.Character
	if character == nil then
		return
	end

	local joint = findLeanJoint(character)
	if joint == nil then
		return
	end

	-- A lean may still be unwinding from a previous dodge; take the wheel before
	-- capturing a neutral that is currently in motion.
	local previous = leanTween
	leanTween = nil
	if previous then
		previous:Cancel()
	end

	if leanJoint ~= joint or leanNeutralC0 == nil then
		leanJoint = joint
		leanNeutralC0 = joint.C0
	end
	local neutral = leanNeutralC0 :: CFrame

	local localRaw = rootPart.CFrame:VectorToObjectSpace(direction)
	local localFlat = Vector3.new(localRaw.X, 0, localRaw.Z)
	local magnitude = localFlat.Magnitude

	local forwardAmount = 0
	local rightAmount = 0
	if magnitude > 0.001 then
		forwardAmount = math.clamp(-localFlat.Z / magnitude, -1, 1)
		rightAmount = math.clamp(localFlat.X / magnitude, -1, 1)
	end

	local pitch = 0
	local bank = 0
	local drop = 0

	if math.abs(rightAmount) > math.abs(forwardAmount) then
		bank = -rightAmount * math.rad(DODGE_LEAN_BANK_DEG)
	else
		-- Forward and backward use different angles on purpose. A forward dodge is
		-- a committed slip and carries the whole body; a backstep is a defensive
		-- retreat that keeps the sword side up. Pitching a backstep as hard as a
		-- forward slip reads as diving away from the threat.
		local forwardDegrees = 0
		if forwardAmount > 0 then
			forwardDegrees = DODGE_LEAN_FORWARD_DEG
		else
			forwardDegrees = DODGE_LEAN_BACKWARD_DEG
		end

		pitch = -forwardAmount * math.rad(forwardDegrees)
		drop = DODGE_LEAN_TORSO_DROP * forwardAmount
	end

	--[[
		The lean tween itself. `Back` / `Out` because the *overshoot* is the point:
		a real slip pulls the torso slightly past its committed angle and settles
		back into it, and a plain `Quad` cannot express that. It is the one place
		in this file where overshoot is wanted rather than something to be tuned
		out.
	]]
	local tween = TweenService:Create(
		joint,
		TweenInfo.new(DODGE_LEAN_TWEEN_IN, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ C0 = neutral * CFrame.Angles(pitch, 0, bank) * CFrame.new(0, -drop, 0) }
	)
	leanTween = tween
	tween:Play()
end

--[[
	Day 9 · Part 2/2 · the dodge's cost in posture.

	Why the dodge cannot stay free
	------------------------------
	Every other verb in the combat vocabulary already spends posture: a block does,
	a deflect does, and a whiffed guard has to climb back out of the red. The dodge
	was the one move that cost nothing, which made it strictly better than every
	other answer to the same problem - press Q on reaction, skip the whole economy
	- and a strictly dominant option deletes the decisions the rest of the design
	is built on.

	10 posture against a 100-point pool with 16/sec of healthy regen and a 1.2s
	recovery grace means one deliberate dodge is about 0.6s of standing still to
	repay. Small enough that a correct read still comes out ahead, large enough
	that dodging *every* swing does not: at Hit 1's 0.27s cadence that is ~37/sec of
	spend against 16/sec of regen, and the pool empties.

	The spam penalty
	----------------
	The base cost already makes panic-rolling lose, slowly. These make it lose
	*fast*, and in a way the player can read: each dodge inside `DODGE_SPAM_WINDOW`
	of the last costs `DODGE_SPAM_COST_STEP` more than the one before it
	(10 -> 15 -> 20 -> 25), so a HUD shows the price of the press rising and a
	player who spaces their evasions a beat apart is visibly charged the flat rate
	instead. A flat increment rather than a multiplier is what keeps that legible.

	Authoritative-ness, stated honestly
	------------------------------------
	ARCHITECTURE.md #3 keeps the server authoritative for damage and state
	transitions; this is a *cost the client charges itself*, written onto its own
	copy of the `RoninPosture` attribute. Because that attribute replicated down
	from the server, a client write changes only the local copy and never travels
	up - so this cannot be used to gain anything, and a cheater who edits the value
	locally simply dodges for free against their own HUD, which is a cosmetic cheat
	and not a combat one. What the local write *does* buy is honesty for everyone
	playing normally: the gauge drops the instant the dodge is thrown rather than
	one network hop later, so the cost is legible at the moment it is paid. That is
	why this is a prediction written to the client's own copy rather than a server
	round-trip.
]]
local lastDodgePostureAt: number? = nil
local dodgePostureChain = 0

--[[
	Whether the pool is too broken to dodge out of, and by how much.

	Returns the current posture alongside the verdict so the refusal trace can
	print the reading the rule actually compared against - a refusal with no number
	in it is indistinguishable from a cooldown.
]]
local function isDodgePostureLocked(character: Model): (boolean, number)
	local current = character:GetAttribute(POSTURE_ATTRIBUTE)
	if typeof(current) ~= "number" then
		-- Never written. A character with no posture attribute has not been
		-- registered by the server yet, so there is nothing to be spent and
		-- nothing to be locked out of.
		return false, 0
	end

	return current >= DODGE_POSTURE_LOCKOUT, current
end

--[[
	Charges the dodge and returns the cost that was applied.

	Called only once the move has been accepted, so a refused dodge - illegal edge,
	no character, no room to stand - never advances the chain counter. That
	ordering is the difference between "I dodged three times quickly" and "I
	pressed Q three times while stunned", and only the first should be punished.
]]
local function spendDodgePosture(character: Model, now: number): number
	if lastDodgePostureAt ~= nil and (now - lastDodgePostureAt) < DODGE_SPAM_WINDOW then
		dodgePostureChain = math.min(dodgePostureChain + 1, DODGE_SPAM_MAX_CHAIN)
	else
		dodgePostureChain = 0
	end
	lastDodgePostureAt = now

	local cost = DODGE_POSTURE_COST + dodgePostureChain * DODGE_SPAM_COST_STEP

	local current = character:GetAttribute(POSTURE_ATTRIBUTE)
	if typeof(current) == "number" then
		-- Clamped at zero so a chain of dodges taken against an already-spent pool
		-- cannot drive the local reading negative, which the gauge would render as
		-- a bar wider than its track.
		character:SetAttribute(POSTURE_ATTRIBUTE, math.max(0, current - cost))
	end

	return cost
end

--[[
	The dash trail.

	Deliberately not a `Trail` and deliberately not a character clone. A Trail
	would need two attachments on moving body parts plus a texture, and it draws a
	*ribbon* - which reads as a swipe, not as a step. Cloning the character three
	times per dodge is 40+ instances of churn for a 200ms effect.

	Three flat quads laid along the path instead: three `Part`s, none of which can
	be collided with, touched or hit by a raycast, so the trail cannot perturb
	the very hit-detection the dodge exists to escape. Anchored, so the owner's
	own write is enough for every client to see it - the dodge reads correctly to
	an opponent with no second remote and no server involvement.

	`Debris` owns the lifetime rather than the tween's `Completed`, so a dodge cut
	short by a stun still clears its trail immediately instead of hanging in the
	world for the rest of the tween.
]]
local GHOST_COUNT = 3
local GHOST_LIFETIME = 0.22
local GHOST_SPACING = 0.6
local GHOST_HEIGHT = 1.0
local GHOST_COLOR = Color3.fromRGB(150, 210, 255)

local function spawnDashGhosts(origin: Vector3, direction: Vector3)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	-- Read once per dodge rather than per ghost: the quads are billboarded to a
	-- single camera pose, and a dodge lasts 350ms, so a rotating camera over the
	-- life of the trail is not a case worth per-ghost maths.
	local lookVector = camera.CFrame.LookVector

	for index = 1, GHOST_COUNT do
		-- Laid *behind* the origin along the travel direction, so the trail is
		-- left behind the character rather than stretched out in front of them.
		local centre = origin + direction * (-(index - 1) * GHOST_SPACING) + Vector3.new(0, GHOST_HEIGHT, 0)

		local ghost = Instance.new("Part")
		ghost.Name = "DodgeGhost"
		ghost.Anchored = true
		ghost.CanCollide = false
		ghost.CanTouch = false
		ghost.CanQuery = false
		ghost.CastShadow = false
		ghost.Material = Enum.Material.ForceField
		ghost.Color = GHOST_COLOR
		ghost.Transparency = 0.55
		ghost.Size = Vector3.new(2.2, 3.4, 0.1)
		ghost.CFrame = CFrame.lookAt(centre, centre + lookVector)
		ghost.Parent = workspace

		local tween = TweenService:Create(
			ghost,
			TweenInfo.new(GHOST_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Transparency = 1 }
		)
		tween:Play()

		Debris:AddItem(ghost, GHOST_LIFETIME)
	end
end

--[[
	Tells the server a dodge has started.

	The payload is the dodge's *direction*, carried so the trace and the HUD can
	name it - it decides nothing. The server does not take it on trust for anything
	that matters: the i-frames it opens are timed from its own `os.clock()` and
	its own `DODGE_IFRAME_DURATION`, so a client asking for five seconds of
	invulnerability gets the same 200ms everybody else gets.

	The handle is resolved lazily and cached. `HitValidator` creates every remote
	inside its own body, and ServerScriptService runs children in an order that is
	not stable across runs, so a lookup performed while this LocalScript starts is
	a race against a remote that may not exist yet - the same trap `PostureChaos`
	fell into on Day 8. A missing remote is reported once and then silently
	tolerated, because the dodge still plays locally; only the server-side
	i-frames are lost.
]]
local dodgeEvent: RemoteEvent? = nil
local warnedNoDodgeRemote = false

local function declareDodge(direction: Vector3)
	if dodgeEvent == nil then
		local instance = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_DODGE_EVENT)
		if instance ~= nil and instance:IsA("RemoteEvent") then
			dodgeEvent = instance :: RemoteEvent
		else
			if not warnedNoDodgeRemote then
				warnedNoDodgeRemote = true
				warn(string.format(
					"[SERVER] %s is not present; the dodge has no server-side i-frames.",
					AttackConfig.REMOTE_DODGE_EVENT
				))
			end
			return
		end
	end

	dodgeEvent:FireServer(direction)
end

--[[
	Applies the horizontal push.

	Split out of `TryDodge` so the state transition, the physics, the network
	declaration and the timers can each be read on their own. It creates its own
	attachment rather than reusing the rig's `RootAttachment`: the standard rigs
	do have one, but a *destroyed* one (or a stripped custom rig that never had
	one) would otherwise make the dodge un-castable, and the attachment is three
	lines of code to make unconditional. Owning it also means `stopDodge` can
	guarantee the character is left exactly as it was found.

	`RelativeTo = World` is load-bearing next to the force ceiling. The default
	is the attachment's own frame, and this attachment rides the root - which
	turns. A dodge that curved around with the body mid-dash would not be a dash
	in any direction the player asked for.

	`MaxAxesForce` is inert unless limits are enabled *and* per-axis *and* the
	mode is Vector. All three are stated explicitly rather than trusted to a
	default, because a silent change to any one of them puts the character back
	under an unbounded force and the wall-fling comes straight back.
]]
local function applyDodgePush(rootPart: BasePart, direction: Vector3)
	stopDodge()

	local attachment = Instance.new("Attachment")
	attachment.Name = "DodgeAttachment"
	attachment.Parent = rootPart

	local constraint = Instance.new("LinearVelocity")
	constraint.Name = "RoninDodgePush"
	constraint.Attachment0 = attachment
	constraint.RelativeTo = Enum.ActuatorRelativeTo.World
	constraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	constraint.ForceLimitsEnabled = true
	constraint.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	constraint.MaxAxesForce = DODGE_MAX_AXES_FORCE
	constraint.VectorVelocity = direction * DODGE_SPEED

	-- Parented last, so the constraint never simulates for even one step against
	-- a half-configured target velocity.
	constraint.Parent = rootPart

	dodgeConstraint = constraint
	dodgeAttachment = attachment
end

--[[
	Runs one dodge, end to end.

	Returns whether a dodge actually started. It does not start when no machine
	is bound, when no character is loaded, when the state table refuses the move,
	when a dodge is already in flight, or when no direction can be resolved - and
	each of those is a distinct, reportable outcome rather than a silent one.

	The legality question belongs to `ALLOWED_TRANSITIONS`, not to this script.
	`CanRequestState` is asked first only to keep the console readable, for the
	same reason `InputBinder` does the same before raising a guard.
]]
local function TryDodge(): boolean
	local machine = CombatStateBus.GetActiveMachine()
	if machine == nil then
		print("[DODGE] Ignored: no state machine bound.")
		return false
	end

	if machine.CurrentState == "Dodging" then
		-- Checked here as well as in `ALLOWED_TRANSITIONS`. The table is the
		-- authority; this exists so a player mashing Q through a dodge gets a
		-- quiet no-op rather than a `[FSM] Rejected transition` warning on every
		-- press.
		print("[DODGE] Ignored: a dodge is already in flight.")
		return false
	end

	local character = localPlayer.Character
	if character == nil then
		print("[DODGE] Ignored: no local character.")
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		print("[DODGE] Ignored: no living Humanoid.")
		return false
	end

	local direction, source = resolveDodgeDirection(character, humanoid)
	if direction == nil then
		print("[DODGE] Ignored: no usable dodge direction.")
		return false
	end

	--[[
		Day 9 · Part 2/2: the posture lockout.

		Placed *before* the transition table is consulted rather than after it, so
		a spent player gets the specific reason ("posture is at 96") instead of a
		generic illegal-edge trace that would be identical to a dodge thrown in
		the wrong state. The two are different failures with different remedies, and
		the console is the only place a player can tell them apart.

		It is also placed before `RequestState`, which matters: a refusal that had
		already flipped the machine into `Dodging` would have to hand the state
		back, and every one of those paths is a chance to leave the player stuck
		in a state they never earned.
	]]
	local locked, currentPosture = isDodgePostureLocked(character)
	if locked then
		print(string.format(
			"[DODGE] Refused: posture is at %d/%d - too broken to dodge (lockout %d).",
			currentPosture,
			AttackConfig.MAX_POSTURE,
			DODGE_POSTURE_LOCKOUT
		))
		return false
	end

	if not CombatStateBus.CanRequestState("Dodging") then
		print(string.format(
			"[DODGE] Refused: %s -> Dodging is not a legal edge at %.3f",
			tostring(machine.CurrentState),
			os.clock()
		))
		return false
	end

	local originState: CombatState = machine.CurrentState

	if not CombatStateBus.RequestState("Dodging") then
		return false
	end

	-- Claim the dodge before anything that could fail, so neither timer below can
	-- ever be orphaned by a later one.
	dodgeGeneration += 1
	local myGeneration = dodgeGeneration

	local rootPart = findRootPart(character)
	if rootPart == nil then
		-- The machine is already in Dodging, so it has to be handed back rather
		-- than abandoned. This is a rig fault, not a gameplay one.
		warn("[DODGE] HumanoidRootPart is missing; the dodge resolved immediately.")
		CombatStateBus.RequestState("Idle")
		return false
	end

	applyDodgePush(rootPart, direction)
	applyDodgeLean(rootPart, direction)
	declareDodge(direction)
	spawnDashGhosts(rootPart.Position, direction)

	--[[
		Charged only now, on the accepted path.

		Every earlier exit is a dodge that did not happen - no machine, no
		character, no direction, an illegal edge, a spent pool. None of them may
		advance the spam chain, or a player who is being stunned and mashing Q
		would arrive at their one legitimate dodge already carrying a 25-posture
		penalty for presses the game refused to act on.

		This is the only line in the file that spends a resource, and it runs
		before the timers are armed so a charge can never be applied to a dodge
		whose setup then fails.
	]]
	local now = os.clock()
	local postureCost = spendDodgePosture(character, now)

	CombatStateBus.SetDodgeTelemetry({
		Phase = "IFrames",
		EndsAt = os.clock() + DODGE_IFRAME_DURATION,
		Direction = direction,
		Speed = DODGE_SPEED,
		Origin = originState,
	})

	print(string.format(
		"[DODGE] %s -> Dodging (%s, %.1f studs/s, i-frames %dms, total %dms, posture -%d)",
		originState,
		source,
		DODGE_SPEED,
		DODGE_IFRAME_DURATION * 1000,
		DODGE_TOTAL_DURATION * 1000,
		postureCost
	))

	--[[
		Day 9 · Part 2/2: the lean unwinds at the *end* of the move, not at the end
		of the i-frames.

		Releasing at 200ms would stand the character back up for the entire
		vulnerable recovery tail - the one stretch of the dodge where they can
		actually be hit - and a torso that has already straightened reads as a
		player who is safe again at the exact moment they are not. Holding the
		lean across the tail and releasing it alongside the transition to Idle is
		what makes the vulnerable half of the move *look* vulnerable.

		`DODGE_LEAN_RETURN_DURATION` is short on purpose, and the release starts
		here so it finishes just as the state resolves. Generation-guarded like
		every other exit in this file, because `onStateChanged` may have already
		unwound this same lean if the dodge was cut short.
	]]

	--[[
		0.200s - the i-frames close and the push is released.

		The body keeps whatever momentum the constraint had already given it and
		coasts down under ordinary friction, which is what makes a dodge read as a
		step that settles rather than a snap that stops dead.

		Invulnerability is *not* ended here. This script never owned it: the server
		opened the window from its own clock and closes it from its own clock, and
		a client that ended it on its own schedule would simply be able to claim
		i-frames for longer than the server honours. The two durations being equal
		is a property of the shared config, not a coincidence of two timers.
	]]
	task.delay(DODGE_IFRAME_DURATION, function()
		if myGeneration ~= dodgeGeneration then
			return
		end

		stopDodge()

		-- Only re-published if the machine is still in this dodge. A character
		-- that was stunned on the very frame its i-frames closed is in `Stunned`,
		-- and telling the HUD "Recovery" about a dodge that no longer exists would
		-- show a vulnerability window for a move that has already been cancelled.
		if CombatStateBus.GetCurrentState() == "Dodging" then
			CombatStateBus.SetDodgeTelemetry({
				Phase = "Recovery",
				EndsAt = os.clock() + DODGE_RECOVERY_DURATION,
				Direction = direction,
				Speed = DODGE_SPEED,
				Origin = originState,
			})
		else
			CombatStateBus.ClearDodgeTelemetry()
		end

		print(string.format(
			"[DODGE] I-frames closed at %dms; %dms of recovery remain.",
			DODGE_IFRAME_DURATION * 1000,
			DODGE_RECOVERY_DURATION * 1000
		))
	end)

	--[[
		0.350s - the state ends.

		The machine is re-read first and only handed back to Idle if it is *still*
		in `Dodging`. A character hit into `Stunned`, parried, or debug-reset
		during the recovery tail keeps the state it legitimately reached; yanking it
		out of a stun here would hand a staggered player a free escape from their
		own stagger. This is the Day 8 stale-release bug avoided by construction
		rather than by a generation counter.
	]]
	task.delay(DODGE_TOTAL_DURATION, function()
		if myGeneration ~= dodgeGeneration then
			return
		end

		stopDodge()
		releaseDodgeLean(myGeneration, DODGE_LEAN_RETURN_DURATION)
		CombatStateBus.ClearDodgeTelemetry()

		if CombatStateBus.GetCurrentState() == "Dodging" then
			CombatStateBus.RequestState("Idle")
		end

		print(string.format("[DODGE] Dodging -> Idle at %dms.", DODGE_TOTAL_DURATION * 1000))
	end)

	return true
end

--[[
	Teardown.

	Called for every character. A dodge that is in flight when the character dies
	must not survive it: the closure holding the constraint is aimed at a model
	that is being destroyed, and leaving it running would push a corpse for the
	remainder of the window and leave a lit HUD row behind with no dodge attached
	to it.

	Bumping the generation is what actually neutralises the two pending timers.
	`stopDodge` releases the physics, but a `task.delay` that has not fired yet
	would otherwise wake up afterwards, find a stale handle and - worse - take the
	`Dodging -> Idle` branch against whatever machine the *new* character has
	bound. This is exactly the argument for `stunGeneration` in CombatController.
]]
local function teardown()
	dodgeGeneration += 1
	stopDodge()
	--[[
		A hard reset rather than a tween, unlike the 350ms path.

		The character this was leaning is being destroyed. A `DODGE_LEAN_RETURN_DURATION`
		tween scheduled against it would be driving a joint on a model that is on its
		way out of the world, and if the player respawns inside that window the
		tween would still be running against a `leanJoint` handle pointing at the old
		body. Writing `C0` once and dropping the handles leaves nothing alive to
		misbehave.
	]]
	cancelDodgeLean()
	CombatStateBus.ClearDodgeTelemetry()
end

--[[
	Cancels a dodge the instant the machine leaves `Dodging` for any reason other
	than this file's own total-duration timer.

	Without this, a character hit into `Stunned` on the frame after a dodge would
	keep being pushed by a `LinearVelocity` for the remainder of the window - a
	staggered body rocketing away from the hit that staggered it, which is both a
	visual bug and a way to eat a stagger for free. The guard below is what makes
	the subscription safe to have at all: it is not "cancel on any transition",
	which would fire on the dodge's own `Dodging -> Idle` and race the timer that
	owns that edge.
]]
local function onStateChanged(fromState: CombatState, toState: CombatState)
	if fromState == "Dodging" and toState ~= "Dodging" then
		-- Idempotent, so it is safe that the total-duration timer will also reach
		-- this: whichever gets there first releases the push, and the other's
		-- generation check makes the second call a no-op.
		stopDodge()

		--[[
			Day 9 · Part 2/2: the lean has to unwind here too, and this is the path
			that actually matters for it.

			The 350ms timer only runs when the dodge resolves on its own clock. A
			character hit into `Stunned` on the frame after a dodge never reaches
			it, so without this the torso would be left pitched 25 degrees forward
			through the whole stagger - a knocked-down character lying at an angle
			that no animation agrees with, holding the pose until the next dodge
			overwrote it or the character despawned.

			Passed `dodgeGeneration` rather than a captured token because this runs
			from the *transition*, not from a dodge's own timer: it is reacting to
			whatever is current, and the call is already a no-op when there is no
			live lean to unwind.
		]]
		releaseDodgeLean(dodgeGeneration, DODGE_LEAN_RETURN_DURATION)
	end
end

CombatStateBus.Subscribe(onStateChanged)

localPlayer.CharacterAdded:Connect(teardown)
localPlayer.CharacterRemoving:Connect(teardown)

-- The character already in the world when this script started needs the same
-- teardown hookup as one that arrives later, or a respawn during a session would
-- be the one path with no listener attached. `teardown` is a no-op on a character
-- that has not dodged, so calling it here costs nothing.
local existingCharacter = localPlayer.Character
if existingCharacter ~= nil then
	teardown()
end

--[[
	Registers the dodge driver, exactly as `SetLightAttackExecutor` registers the
	swing driver (AttackController). Both are LocalScripts and so cannot be
	`require`d by `CombatController`; the bus is the only seam that reaches them.

	Registered *last*, after every function it names is in scope. Registering here
	rather than at the top of the file is what makes that a compile-time fact
	instead of a forward declaration.

	Registering twice is harmless and idempotent, last registration wins, so a
	re-run of this script does not leave the bus pointing at a dead closure.
]]
CombatStateBus.SetDodgeExecutor(TryDodge)

print("[CLIENT] DodgeController online: [Q] throws a 360-degree step-dodge with 200ms of server-checked i-frames.")
