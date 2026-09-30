--!strict

--[[
	SparringDummy
	Ronin — The Last Blade · the training opponent (Day 7 · Part 2/2)

	Everything built so far has needed a *second* blade to mean anything. The parry
	window, the posture pool, the guard cone, the deflect's posture reflection and
	the clash sparks are all rules about a collision between two people, and until
	now the only way to test any of them was to find a real second player willing to
	swing on cue. This script is that second player: it finds the rig standing in the
	place, puts a katana in its hand, and attacks anybody who comes within ten studs,
	on a 2.5-second cadence, forever.

	What it is for
	--------------
	A sparring partner, and specifically a *defensive* drill. Its swing is the light
	chain's opener - the same `COMBO_CHAIN[1]` frame data the player's first hit uses,
	read from the same frozen table - so the thing it teaches is a real thing: 10
	Health if you eat it, 15 posture if you block it, and if you *deflect* it the
	dummy pays `PARRY_REFLECT_POSTURE` and its attack is cancelled outright. Four
	clean deflects break its guard. It is a posture-war opponent that never gets
	tired, which is exactly what a posture-war mechanic needs to be learnable.

	The wire contract, and why this script speaks it
	------------------------------------------------
	The single most important design decision here is that the dummy does **not**
	invent its own feedback. When it resolves a strike it fires the same remotes, with
	the same payload shapes, that `HitValidator` fires when a player lands one:

	  * `GuardClashEvent`   (all clients, Vector3) the blocked case's sparks
	  * `GuardBreakEvent`   (defender only)        the broken-guard stun
	  * `ParryResultEvent`  (defender only)        the deflect's HUD line
	  * `DeflectClashEvent` (all clients, Vector3) the deflect's white-hot burst

	What follows from that is the whole reason to do it this way: a deflect against
	the dummy runs the *same client code* as a deflect against a player - the hitstop,
	the clang, the FOV punch, the sparks, the HUD flash - with no dummy-specific
	branch anywhere on the client. The dummy is a second *attacker*, not a second
	combat system.

	It also reads the defender's state the same way `HitValidator` does: the
	server-written `RoninBlocking` and `RoninParryUntil` attributes on the defender's
	own character, and the shared `GUARD_FRONT_DOT_THRESHOLD` for the frontal cone.
	No remote arrives here at all - a dummy cannot be spoofed, because there is no
	message to forge.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #2 - there are no remotes arriving here, so there is nothing
	    off the wire to validate; the one payload the dummy *sends* is a Vector3 it
	    computed itself.
	  * ARCHITECTURE.md #3 - the server remains the sole authority. This is that
	    authority deciding, on the dummy's behalf, exactly what a client's claim would
	    have been worth.
	  * ARCHITECTURE.md #4 - the attack loop is a 2.5s timer, not a per-frame path.
	    The only per-frame work is what `TweenService` does to two joints, and the
	    tween owns that, not this script.
]]

--[[
	Why the resolution rules are written here rather than called out of HitValidator
	--------------------------------------------------------------------------------
	`HitValidator` is a `Script`, not a `ModuleScript`, so `require` cannot load it -
	and the honest question is therefore "what must not drift?". The answer is the
	*contract*, and every part of it is already shared:

	  * frame data, damage and posture numbers - `AttackConfig.COMBO_CHAIN`
	  * the posture pool's attribute names and ceiling - `AttackConfig`
	  * the guard cone and the parry ladder - `AttackConfig`
	  * the parry deadline attribute - `AttackConfig.PARRY_STATE_ATTRIBUTE`
	  * the live state itself - the attributes on the defender's character

	What is duplicated is the arithmetic that reads and writes those values - about
	twenty lines of clamping and comparisons - and it is duplicated *deliberately*,
	because the alternative (turning a verified, thousand-line authority script into
	a module mid-milestone so a training dummy can borrow six of its functions)
	trades a stable file for a refactor nobody asked for. The risk duplication
	creates is a *rule* drifting, and a rule here is a number or a name - both of
	which live in `AttackConfig`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
	The dummy's frame data.

	Deliberately the *player's* opener rather than a bespoke stat block. A training
	opponent whose numbers are its own teaches nothing transferable - the whole point
	of standing in front of it is that the 10 Health, the 15 posture and the 0.15s
	windup you learn to read are the same ones the first hit of a real player's chain
	brings. One index into the frozen table, so a rebalance of the chain rebalances
	the dummy in the same edit.
]]
local OPENING_HIT_INDEX = 1

--[[
	The frame data itself, read once.

	`AttackConfig.COMBO_CHAIN` is frozen and guaranteed to carry all three hits, so
	the opener is fetched at load rather than on every attack: one index into a frozen
	table per session instead of one per swing, and a config that somehow lost its
	first entry would fail loudly here rather than mid-swing.
]]
type AttackData = AttackConfig.AttackData

local OPENING_ATTACK: AttackData = AttackConfig.COMBO_CHAIN[OPENING_HIT_INDEX]

local PARRY_REFLECT_POSTURE = AttackConfig.PARRY_REFLECT_POSTURE
local PARRY_STATE_ATTRIBUTE = AttackConfig.PARRY_STATE_ATTRIBUTE
local GUARD_STATE_ATTRIBUTE = AttackConfig.GUARD_STATE_ATTRIBUTE
local GUARD_FRONT_DOT_THRESHOLD = AttackConfig.GUARD_FRONT_DOT_THRESHOLD
local POSTURE_ATTRIBUTE = AttackConfig.POSTURE_ATTRIBUTE
local MAX_POSTURE_ATTRIBUTE = AttackConfig.MAX_POSTURE_ATTRIBUTE
local MAX_POSTURE = AttackConfig.MAX_POSTURE
local GUARD_BREAK_STUN_DURATION = AttackConfig.GUARD_BREAK_STUN_DURATION

--[[
	Day 10 · Part 2/2: the dodge's i-frame flag, read from the same shared source
	`HitValidator` writes it to.

	Read as a constant here for exactly the reason the other four are: the
	attribute *name* is the contract. This file deliberately re-implements the
	defender-side rules rather than requiring the validator (see the header), and
	the only thing that duplication is allowed to share is a number or a string.
	A dodge that read a hardcoded "RoninInvulnerable" while the validator read
	`AttackConfig` would break silently the day the name changed - and it would
	break in the worst possible direction, since a mismatched i-frame check is a
	cheat, not a crash.
]]
local INVULNERABLE_ATTRIBUTE = AttackConfig.INVULNERABLE_ATTRIBUTE

--[[
	Dummy tuning.

	None of these are shared contract values - they are the cadence and the manners
	of a training partner, and they live here for the same reason `GuardSparks` keeps
	its particle numbers: nothing outside this script can disagree with them, so
	filing them in `AttackConfig` would put them under a heading that does not
	describe them.

	`TELEGRAPH_DURATION` is the one number that is a *design* statement rather than a
	taste: it is the red warning, and it is deliberately longer than any frame-data
	windup. The chain's opener winds up for 0.15s because it is meant to be hard to
	see; the dummy's telegraph is 0.55s because a sparring partner that cannot be
	read is a damage fountain rather than a drill. 0.55s is also comfortably longer
	than the 133ms parry window, so a player who waits for the red flash and *then*
	presses block is inside the window rather than chasing it.
]]
local AGGRO_RADIUS = 10
local ATTACK_INTERVAL = 2.5
local TELEGRAPH_DURATION = 0.55
local STAGGER_DURATION = 0.45
local STRIKE_RETURN_DURATION = 0.18

--[[
	The rig, by name.

	"TrainingDummy" first because that is the name the brief asks for, "Rig" second
	because that is what is actually standing in this place (an R15 mannequin with a
	`Humanoid`, an `Animator` and AnimationConstraint joints - verified live, not
	assumed). Both are tried, so the script works in a place where somebody has
	renamed the rig properly *and* in this one, without an edit.
]]
local DUMMY_NAMES = { "TrainingDummy", "Rig" }

--[[
	The katana proxy.

	Same asset, same grip offsets, same joint name as the client's `WeaponVisuals`
	builds, and that is not decoration: a player looking at the dummy should see the
	sword they are holding, angled into the hand the way theirs is. The offsets are
	the client's measured values (`GRIP_TRANSLATION` pushes the mesh's centre 1.5
	studs ahead of the palm so the wrapped handle sits in the fist, `REST_POSE` tips
	the mesh's +Y blade axis to near-horizontal along the hand's forward axis).

	The grip is a `Motor6D` for the same reason it is one on the player's rig: the
	offset has to *rotate* the mesh into the palm, and a WeldConstraint cannot.
]]
local KATANA_MODEL_NAME = "KatanaModel"
local KATANA_BLADE_NAME = "Handle"
local BLADE_NAME = "RoninKatana"
local GRIP_NAME = "RoninKatanaGrip"
local GRIP_TRANSLATION = Vector3.new(0, 0, -1.5)
local REST_POSE = CFrame.Angles(math.rad(-82), 0, 0)

--[[
	The swing, as deltas on each joint's own rest `Transform`.

	Deltas rather than absolute frames for the same reason `ARM_POSES` in
	`AttackController` and `GUARD_RIGHT_POSE` in `WeaponVisuals` are deltas: an
	absolute `Transform` puts the arm somewhere anatomically strange on any rig whose
	attachments are not the ones the numbers were tuned on. Composed onto rest, each
	number means "rotate from where this arm hangs".

	Three joints, one cut: the waist twists into the windup (which is what makes it
	read as a committed overhead rather than a raised hand), the shoulder carries the
	arm, and the elbow decides whether the blade is cocked or extended.

	Values are tuned against the live rig by capture, not by guesswork - see the
	playtest note in the docs' active context.
]]
local WINDUP_WAIST = CFrame.Angles(0, math.rad(22), 0)
local STRIKE_WAIST = CFrame.Angles(0, math.rad(-18), 0)
local WINDUP_SHOULDER = CFrame.Angles(math.rad(-85), math.rad(10), math.rad(12))
local STRIKE_SHOULDER = CFrame.Angles(math.rad(78), math.rad(-8), math.rad(-26))
local WINDUP_ELBOW = CFrame.Angles(math.rad(-62), 0, 0)
local STRIKE_ELBOW = CFrame.Angles(math.rad(-12), 0, 0)

-- The deflect recoil: a short backward lean of the whole upper body, and an arm
-- that drops out of the swing rather than finishing it.
local STAGGER_WAIST = CFrame.Angles(math.rad(-16), 0, math.rad(6))
local STAGGER_ELBOW = CFrame.Angles(math.rad(-30), 0, 0)

--[[
	The telegraph, which is the whole of the dummy's readability.

	A `Highlight` (fill + outline) on the rig plus a red-hot blade. `Highlight` rather
	than tinting the body parts: it renders the silhouette the engine already has, it
	is one instance for the whole model, and it is impossible to confuse with lighting
	or a material change - the player has to be able to answer "is it winding up?" at
	a glance from across the arena, and a red outline is that answer.
]]
local TELEGRAPH_FILL = Color3.fromRGB(255, 42, 32)
local TELEGRAPH_OUTLINE = Color3.fromRGB(255, 120, 40)
local TELEGRAPH_BLADE_COLOR = Color3.fromRGB(255, 70, 50)
local HIGHLIGHT_NAME = "RoninDummyTelegraph"

--[[
	The four remotes this script fires, created-or-reused exactly as `HitValidator`
	does with the same `ensureRemote` rule: Script Sync can re-run a server script
	without clearing ReplicatedStorage, and `Instance.new` on a taken name is a hard
	error that would take this script down on a hot reload.

	They are *found*, not created, in practice - `HitValidator` runs first and owns
	them - but a place where the validator was disabled would otherwise leave the
	dummy silently unable to spark or stun, which is the kind of failure that looks
	like the dummy is broken rather than like a remote is missing.
]]
local function ensureRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local guardClashEvent = ensureRemote(AttackConfig.REMOTE_GUARD_CLASH_EVENT)
local guardBreakEvent = ensureRemote(AttackConfig.REMOTE_GUARD_BREAK_EVENT)
local parryResultEvent = ensureRemote(AttackConfig.REMOTE_PARRY_RESULT_EVENT)
local deflectClashEvent = ensureRemote(AttackConfig.REMOTE_DEFLECT_CLASH_EVENT)

--[[
	Root-part lookup.

	`Humanoid.RootPart` first because it is the field the engine maintains, with the
	`HumanoidRootPart` child as the fallback for a rig whose Humanoid has not bound a
	root yet. `HitValidator` does the same lookup for the same reason: a hit needs a
	position, and a position needs a part that exists.
]]
local function findRoot(model: Model): BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.RootPart ~= nil then
		return humanoid.RootPart
	end

	local fallback = model:FindFirstChild("HumanoidRootPart")
	if fallback ~= nil and fallback:IsA("BasePart") then
		return fallback
	end

	return nil
end

--[[
	Finds the rig to drive. Both configured names are tried, and a model only counts
	if it has a `Humanoid` - a part named "Rig" is a part named "Rig", not an
	opponent.
]]
local function findDummy(): Model?
	for _, name in ipairs(DUMMY_NAMES) do
		local candidate = workspace:FindFirstChild(name)
		if candidate ~= nil and candidate:IsA("Model") then
			if candidate:FindFirstChildOfClass("Humanoid") ~= nil then
				return candidate
			end
		end
	end

	return nil
end

--[[
	Finds a joint by the limb that owns it.

	The second argument is the *joint* name and the first is the part the joint is
	parented to, which is the same "a joint is named after the limb it moves and
	lives on that limb" rule `WeaponVisuals` relies on: `RightShoulder` on
	`RightUpperArm`, `RightElbow` on `RightLowerArm`, `Waist` on `UpperTorso`.

	Both joint classes are accepted. This place's rigs are AnimationConstraints and a
	player's avatar is Motor6Ds, and the script has no business caring which: they
	expose the same `Transform` and are driven identically.
]]
local function findLimbJoint(model: Model, limbName: string, jointName: string): Instance?
	local limb = model:FindFirstChild(limbName)
	if limb == nil then
		return nil
	end

	local joint = limb:FindFirstChild(jointName)
	if joint == nil then
		return nil
	end

	if joint:IsA("Motor6D") or joint:IsA("AnimationConstraint") then
		return joint
	end

	return nil
end

--[[
	Writes a `Transform`, whichever joint class it is.

	The class check is not a cast dodge - it is the documented difference between the
	two: `AnimationConstraint` deliberately fails `IsA("Motor6D")`, so a single
	branch that assumed Motor6D would silently animate nothing on this place's rigs.
	Both classes carry `Transform: CFrame` and both are read by the engine the same
	way, so the two branches below are intentionally identical in effect.
]]
local function writeJointTransform(joint: Instance?, pose: CFrame)
	if joint == nil or joint.Parent == nil then
		return
	end

	if joint:IsA("Motor6D") then
		joint.Transform = pose
	elseif joint:IsA("AnimationConstraint") then
		joint.Transform = pose
	end
end

--[[
	The defender-side rules.

	These five functions are the ones `HitValidator` also implements, and they are
	implemented in exactly the same shape here: same sources (the character's own
	server-written attributes), same constants (all from `AttackConfig`), same
	clamping. See the header for why they are not *shared* code.

	They are also the reason the dummy can fight a player and a player can fight a
	player without the two systems knowing about each other: posture, guard state and
	the parry deadline are properties of a *character*, not of whoever punched it.
]]

--[[
	Seeds and reads a posture pool, repairing a character that lost its attributes.

	Idempotent and self-healing, exactly as the validator's copy is: a fresh rig, a
	stripped dummy or a character that spawned before this script started all get a
	pool on first touch instead of being treated as infinitely durable or already
	broken.
]]
local function ensurePosture(model: Model): (number, number)
	if model:GetAttribute(MAX_POSTURE_ATTRIBUTE) == nil then
		model:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
	end

	if model:GetAttribute(POSTURE_ATTRIBUTE) == nil then
		model:SetAttribute(POSTURE_ATTRIBUTE, 0)
	end

	local current = model:GetAttribute(POSTURE_ATTRIBUTE)
	local maximum = model:GetAttribute(MAX_POSTURE_ATTRIBUTE)

	-- `GetAttribute` returns `any`; a stripping script can leave a string here, and
	-- adding a string to a number would take the strike path down.
	if typeof(current) ~= "number" then
		model:SetAttribute(POSTURE_ATTRIBUTE, 0)
		current = 0
	end

	if typeof(maximum) ~= "number" or maximum <= 0 then
		model:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
		maximum = MAX_POSTURE
	end

	return current, maximum
end

local function spendPosture(model: Model, amount: number): (number, number, boolean)
	local current, maximum = ensurePosture(model)

	local nextPosture = current + math.max(amount, 0)
	if nextPosture > maximum then
		nextPosture = maximum
	end

	model:SetAttribute(POSTURE_ATTRIBUTE, nextPosture)

	return nextPosture, maximum, nextPosture >= maximum
end

--[[
	The width of an open parry window on a character, in seconds, or 0.

	A read of the server's own deadline attribute rather than a stored flag: it is
	written by `HitValidator` when the client claims a block press, so this is the
	authority asking itself a question it already answered.
]]
local function readParryWindow(model: Model): number
	local deadline = model:GetAttribute(PARRY_STATE_ATTRIBUTE)
	if typeof(deadline) ~= "number" then
		return 0
	end

	local remaining = deadline - os.clock()
	if remaining <= 0 then
		return 0
	end

	-- Never report a window wider than the ladder's best rung, whatever the
	-- attribute says - the same clamp the validator applies, for the same reason.
	if remaining > AttackConfig.PARRY_BASE_WINDOW then
		return AttackConfig.PARRY_BASE_WINDOW
	end

	return remaining
end

local function closeParryWindow(model: Model)
	model:SetAttribute(PARRY_STATE_ATTRIBUTE, 0)
end

--[[
	Forces a guard down and tells the defender's client to stagger.

	Three things, in the order the validator does them: clear the server's guard flag
	so a stunned character cannot keep absorbing strikes, close any parry window so a
	window cannot outlive the state it belongs to, and reset the pool. The stun itself
	is *carried* to the client rather than applied here - the state machine is
	client-side (ARCHITECTURE.md #3), so a server that wrote `Stunned` locally would
	be writing to a machine that does not exist on this side of the wire.

	An NPC defender is a legitimate nil from `GetPlayerFromCharacter`: the pool still
	resets and the stun simply has no local machine to reach.
]]
local function breakGuard(model: Model)
	model:SetAttribute(GUARD_STATE_ATTRIBUTE, false)
	closeParryWindow(model)
	ensurePosture(model)
	model:SetAttribute(POSTURE_ATTRIBUTE, 0)

	local player = Players:GetPlayerFromCharacter(model)
	if player ~= nil then
		guardBreakEvent:FireClient(player, model, GUARD_BREAK_STUN_DURATION)
	end
end

--[[
	Whether a defender's guard covers this strike, and the facing dot that decided it.

	The guard is a *frontal* cone: the defender's `LookVector` dotted against the
	direction from the defender to the attacker, tested against the shared threshold.
	That is the whole counter-play to holding block - walk round the sword arm and the
	guard stops existing - and it is checked here rather than in the client for the
	same reason `HitValidator` checks it there: the attribute is server-written, and
	the geometry is measured on the server.
]]
local function resolveGuard(
	defenderModel: Model,
	defenderRoot: BasePart,
	attackerRoot: BasePart
): (boolean, number)
	if defenderModel:GetAttribute(GUARD_STATE_ATTRIBUTE) ~= true then
		return false, 0
	end

	local offset = attackerRoot.Position - defenderRoot.Position
	local magnitude = offset.Magnitude

	-- Roots effectively coincident: no direction to test. Treated as frontal, which
	-- is the only reading that cannot be turned into an exploit by standing inside
	-- somebody.
	if magnitude < 0.001 then
		return true, 1
	end

	local dotProduct = defenderRoot.CFrame.LookVector:Dot(offset.Unit)

	return dotProduct >= GUARD_FRONT_DOT_THRESHOLD, dotProduct
end

--[[
	Forces a guard down and tells the defender's client to stagger.

	Three things, in the order the validator does them: clear the server's guard flag
	so a stunned character cannot keep absorbing strikes, close any parry window so a
	window cannot outlive the state it belongs to, and reset the pool. The stun itself
	is *carried* to the client rather than applied here - the state machine is
	client-side (ARCHITECTURE.md #3), so a server that wrote `Stunned` locally would
	be writing to a machine that does not exist on this side of the wire.
]]
--[[
	The live rig record, and the handles the swing needs.

	One table per equipped dummy rather than six module-level locals, because these
	values are only meaningful together - a shoulder joint without the rig it belongs
	to is a reference to a dead part, and keeping them in one record means `unequip`
	is one assignment instead of six and cannot forget one.

	`BladeStyle` is captured at equip so the telegraph can be *undone*: a red-hot
	blade has to become a steel blade again, and the only honest way to restore a
	mesh's appearance is to have recorded what it was.
]]
type DummyBladeStyle = {
	TextureId: string,
	Material: Enum.Material,
	Color: Color3,
}

type DummyRig = {
	Model: Model,
	Blade: BasePart?,
	BladeStyle: DummyBladeStyle?,
	Highlight: Highlight,
	Waist: Instance?,
	RightShoulder: Instance?,
	RightElbow: Instance?,
}

-- The equipped dummy, or nil when there is nothing in the place to drive.
local activeRig: DummyRig? = nil

--[[
	The swing epoch.

	Every scheduled step of a swing carries the value this held when the swing began,
	and every step bails if it has changed. That is what makes a deflect's
	cancellation instant and total: the deflect bumps the epoch, and the pending
	"strike now" and "recover now" timers for the cancelled swing become no-ops
	without any of them having to know that a deflect is why. The same token guards
	the tween chain, so a cancelled swing cannot finish its animation over a stagger.
]]
local swingToken = 0

-- The tweens currently driving this dummy's joints. Cleared on every phase change
-- so two phases can never write the same joint.
local liveTweens: { Tween } = {}

local function cancelTweens()
	for index = #liveTweens, 1, -1 do
		local tween = liveTweens[index]
		liveTweens[index] = nil
		if tween ~= nil then
			tween:Cancel()
		end
	end
end

--[[
	Drives one joint towards one pose.

	`Transform` on both joint classes is a plain CFrame property, which is what makes
	a TweenService tween of it legitimate rather than a hack: the engine applies the
	value to the parts on its own schedule (as a batch after `PreSimulation` for an
	`AnimationConstraint`), so the tween only has to write the value.
]]
local function tweenJoint(
	joint: Instance?,
	pose: CFrame,
	duration: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection
)
	if joint == nil or joint.Parent == nil then
		return
	end

	local tween = TweenService:Create(joint, TweenInfo.new(duration, style, direction), {
		Transform = pose,
	})

	table.insert(liveTweens, tween)
	tween:Play()
end

--[[
	Moves the dummy to a whole-body pose: waist, sword shoulder, elbow.

	All three joints are written on every call, including the ones that are not
	changing, for the same reason `applyGuardBlend` writes both shoulders: a phase
	transition where one joint is left behind is the frame a pose looks broken on.
]]
local function poseSwing(
	rig: DummyRig,
	waistPose: CFrame,
	shoulderPose: CFrame,
	elbowPose: CFrame,
	duration: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection
)
	cancelTweens()

	tweenJoint(rig.Waist, waistPose, duration, style, direction)
	tweenJoint(rig.RightShoulder, shoulderPose, duration, style, direction)
	tweenJoint(rig.RightElbow, elbowPose, duration, style, direction)
end

--[[
	The telegraph: the rig's silhouette and its blade go red.

	`Enabled` rather than a fade. A warning that fades in is a warning that is half
	delivered for half its length, and the whole point of this effect is that a player
	can answer "yes, it is winding up" in one glance. The blade loses its texture for
	the duration, because a mesh's texture is what hides a colour change on a MeshPart
	- without that, the "blade goes red-hot" tell is invisible on any textured sword,
	which is every sword this project has.
]]
--[[
	Builds the katana proxy into the dummy's hand.

	The blade is presentational and load-bearing at once: it is what the player
	actually reads as "the dummy is armed", and its position at the strike moment is
	what the contact point for the sparks is measured from. It carries no damage -
	the strike is resolved from geometry on the server, not from a blade sweep - which
	is the same division the player's own katana has (`WeaponVisuals` header).
]]
local function equipKatana(model: Model, hand: BasePart): (BasePart?, DummyBladeStyle?)
	-- Re-running the script must not leave two katanas in the hand. The old one is
	-- destroyed rather than reused because the grip has to be re-seated against the
	-- hand's *current* CFrame, and a stale grip would hold the sword where the hand
	-- used to be.
	local previous = model:FindFirstChild(BLADE_NAME)
	if previous ~= nil then
		previous:Destroy()
	end

	local template = ReplicatedStorage:FindFirstChild(KATANA_MODEL_NAME)
	if template == nil or not template:IsA("Model") then
		warn(string.format("[DUMMY] ReplicatedStorage.%s is missing; the dummy stays unarmed.", KATANA_MODEL_NAME))
		return nil, nil
	end

	local bladeTemplate = template:FindFirstChild(KATANA_BLADE_NAME)
	if bladeTemplate == nil or not bladeTemplate:IsA("BasePart") then
		warn(string.format("[DUMMY] %s has no %s part; the dummy stays unarmed.", KATANA_MODEL_NAME, KATANA_BLADE_NAME))
		return nil, nil
	end

	local blade = bladeTemplate:Clone() :: BasePart
	blade.Name = BLADE_NAME
	blade.Anchored = false
	blade.CanCollide = false
	blade.CanTouch = false
	-- `CanQuery` off, unlike the player's blade: the server raycasts line of sight
	-- between the two fighters, and a sword that blocks its own owner's line of
	-- sight would make the dummy's strikes fail to resolve for no visible reason.
	blade.CanQuery = false
	blade.Massless = true
	blade.CFrame = hand.CFrame * CFrame.new(GRIP_TRANSLATION) * REST_POSE
	blade.Parent = model

	local grip = Instance.new("Motor6D")
	grip.Name = GRIP_NAME
	grip.Part0 = hand
	grip.Part1 = blade
	grip.C0 = CFrame.new(GRIP_TRANSLATION) * REST_POSE
	grip.C1 = CFrame.new()
	grip.Parent = blade

	--[[
		Record what the blade looked like, so the telegraph can put it back.

		Read *after* the clone is parented, because the template's own values are the
		ones that matter and the clone is a faithful copy of them - capturing them
		from the clone rather than from `bladeTemplate` keeps this correct if the
		template is ever revised in place.
	]]
	local style: DummyBladeStyle = {
		TextureId = blade.TextureID,
		Material = blade.Material,
		Color = blade.Color,
	}

	return blade, style
end

--[[
	The telegraph's highlight, created once per rig.

	`FillTransparency` is left at its default and `Enabled` does the switching: a
	highlight that is disabled costs nothing to render, and a warning that has to be
	*un-hidden* rather than switched on is one more state to get out of sync.
]]
local function ensureHighlight(model: Model): Highlight
	local existing = model:FindFirstChild(HIGHLIGHT_NAME)
	if existing ~= nil and existing:IsA("Highlight") then
		return existing
	end

	local highlight = Instance.new("Highlight") :: Highlight
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = model
	highlight.FillColor = TELEGRAPH_FILL
	highlight.OutlineColor = TELEGRAPH_OUTLINE
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = model

	return highlight
end

--[[
	The telegraph: the rig's silhouette and its blade go red.

	`Enabled` rather than a fade. A warning that fades in is a warning that is half
	delivered for half its length, and the whole point of this effect is that a player
	can answer "yes, it is winding up" in one glance.

	The blade also loses its texture for the duration, because a mesh's texture is
	what hides a colour change on a `MeshPart` - without that, the "blade goes
	red-hot" tell is invisible on any textured sword, which is every sword this
	project has. Restoring it is why `BladeStyle` exists.
]]
local function setTelegraph(rigHandle: DummyRig, active: boolean)
	rigHandle.Highlight.Enabled = active

	local blade = rigHandle.Blade
	local style = rigHandle.BladeStyle
	if blade == nil or style == nil then
		return
	end

	if active then
		blade.TextureID = ""
		blade.Material = Enum.Material.Neon
		blade.Color = TELEGRAPH_BLADE_COLOR
	else
		blade.TextureID = style.TextureId
		blade.Material = style.Material
		blade.Color = style.Color
	end
end

--[[
	Line-of-sight parameters, reused across resolutions.

	`FilterType.Exclude` with the two fighters named, exactly as the validator does:
	the ray may not be stopped by the attacker's own sword or the defender's own body
	parts. Rebuilt per shot rather than per frame, so this is one table write per
	strike (ARCHITECTURE.md #4).
]]
local LOS_PARAMS = RaycastParams.new()
LOS_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
LOS_PARAMS.IgnoreWater = true

--[[
	The nearest living player character inside the aggro radius.

	Nearest rather than first-found, so a dummy in a busy place attacks the person who
	walked up to it rather than whichever player happens to sit earliest in the player
	list - which is a difference the player standing next to it can see.

	Selection ignores facing, and the dummy squares up in `faceTarget` afterwards.
	That is a deliberate choice about what a sparring partner *is*: an opponent that
	refuses to engage because you approached from the wrong side is a broken prop, not
	a duel. The facing rules that matter - the frontal guard cone - are the
	*defender's*, and they are untouched by what the dummy does with its own body.
]]
local function findTarget(rigHandle: DummyRig): Model?
	local dummyRoot = findRoot(rigHandle.Model)
	if dummyRoot == nil then
		return nil
	end

	local nearest: Model? = nil
	local nearestDistance = AGGRO_RADIUS

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil and character ~= rigHandle.Model then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local targetRoot = findRoot(character)

			if humanoid ~= nil and targetRoot ~= nil and humanoid.Health > 0 then
				local distance = (targetRoot.Position - dummyRoot.Position).Magnitude
				if distance <= nearestDistance then
					nearest = character
					nearestDistance = distance
				end
			end
		end
	end

	return nearest
end

--[[
	Turns the dummy to face a target, about the vertical axis only.

	Yaw only *and* at the pivot's existing height, so the rig cannot be dragged off
	the floor or tipped by its own turn: the rotation is `CFrame.lookAt` between the
	pivot position and the target's ground projection, which cannot introduce any
	change in Y. The legs keep standing where they were standing.
]]
local function faceTarget(rigHandle: DummyRig, targetRoot: BasePart)
	local model = rigHandle.Model

	local pivot = model:GetPivot()
	local origin = pivot.Position
	local targetPosition = targetRoot.Position
	local flattened = Vector3.new(targetPosition.X, origin.Y, targetPosition.Z)

	-- Standing exactly on top of the dummy leaves no direction to face.
	if (flattened - origin).Magnitude < 0.05 then
		return
	end

	model:PivotTo(CFrame.lookAt(origin, flattened, Vector3.yAxis))
end

--[[
	The deflect's recoil.

	The dummy is knocked out of its swing and leans back for `duration`, then returns
	to rest. This is the visible half of "the attack was cancelled": a swing that
	simply stopped mid-arc would read as a script error, whereas a body that is
	shoved backwards reads as *being beaten*, which is the feedback a player who
	landed a perfect parry has earned.

	Two joints are driven, not one: the waist takes the lean (the whole upper body,
	which is what makes it a stagger rather than a shrug) and the elbow drops the arm
	out of the cut. The shoulder is returned to rest at the same time so the arm and
	the body agree about which way they are going.

	The recovery is epoch-guarded, so a reel that is still resolving when the next
	attack begins cannot drive the joints back to rest in the middle of that attack's
	windup.
]]
local function stagger(rigHandle: DummyRig, duration: number)
	cancelTweens()

	local myToken = swingToken

	tweenJoint(rigHandle.Waist, STAGGER_WAIST, 0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenJoint(rigHandle.RightShoulder, CFrame.identity, 0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenJoint(rigHandle.RightElbow, STAGGER_ELBOW, 0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	task.delay(duration, function()
		if swingToken ~= myToken then
			return
		end

		local current = activeRig
		if current ~= rigHandle then
			return
		end

		poseSwing(
			current,
			CFrame.identity,
			CFrame.identity,
			CFrame.identity,
			STRIKE_RETURN_DURATION,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut
		)
	end)
end

--[[
	Resolves one dummy strike against one defender.

	Called from the *middle* of the Active window rather than when the swing starts,
	and everything it checks is re-checked at that moment rather than cached from the
	windup. That is what makes the telegraph a real warning instead of theatre: a
	player who backs out of the ten-stud radius, or steps behind cover, during the
	0.7s between the red flash and the blade arriving has genuinely dodged the attack,
	because the strike is measured against where things *are*, not where they were.

	The three outcomes, in the order the policy requires them:

	  1. **Deflected** (the defender's own parry window is live, and the guard is
	     frontal). The defender pays nothing - no Health, no posture - and the dummy
	     pays `PARRY_REFLECT_POSTURE`, loses its swing and reels. This branch is
	     *inside* the block branch and ahead of the posture spend, exactly as it is in
	     `HitValidator`: a parry is strictly better than a block, and anything spent on
	     the defender here would be read by the player as "I parried and still lost
	     ground".
	  2. **Blocked**. Zero Health, `PoiseDamage` off the frame data onto the
	     defender's pool - 15, the same number a player's opener costs - and an empty
	     pool breaks the guard and stuns.
	  3. **Unguarded**. Full `Damage` (10) through `TakeDamage`. The server applies it;
	     nothing here is derived from a client claim, because there is no client
	     claim: this is the authority attacking in its own process.
]]
local function resolveStrike(rigHandle: DummyRig, target: Model, token: number, data: AttackData)
	-- The swing this resolution belongs to may have been cancelled - by a deflect
	-- that landed on an earlier strike, or by a teardown - in the frame between the
	-- timer being scheduled and it firing.
	if swingToken ~= token then
		return
	end

	if activeRig ~= rigHandle then
		return
	end

	local dummyModel = rigHandle.Model
	local dummyRoot = findRoot(dummyModel)
	local targetRoot = findRoot(target)
	local targetHumanoid = target:FindFirstChildOfClass("Humanoid")

	if dummyRoot == nil or targetRoot == nil or targetHumanoid == nil or targetHumanoid.Health <= 0 then
		return
	end

	-- 1. Still in range? This is the dodge window the telegraph buys.
	local distance = (targetRoot.Position - dummyRoot.Position).Magnitude
	if distance > AGGRO_RADIUS then
		print(string.format(
			"[DUMMY] Strike missed: %s was %.1f studs away (radius %d).",
			target.Name,
			distance,
			AGGRO_RADIUS
		))
		return
	end

	-- 2. Line of sight, the same rule and the same parameter object as the validator.
	local toTarget = targetRoot.Position - dummyRoot.Position
	if toTarget.Magnitude > 0.001 then
		LOS_PARAMS.FilterDescendantsInstances = { dummyModel, target }

		if workspace:Raycast(dummyRoot.Position, toTarget, LOS_PARAMS) ~= nil then
			print(string.format("[DUMMY] Strike missed: no line of sight to %s.", target.Name))
			return
		end
	end

	-- Contact point, midpoint-and-lift, the same coarse approximation the validator
	-- uses for its bursts so the two spark sources cannot read as coming from
	-- different parts of the world.
	local contactPoint = (dummyRoot.Position + targetRoot.Position) * 0.5 + Vector3.new(0, 1.2, 0)

	--[[
		Day 10 · Part 2/2: the dodge, resolved.

		This is the bug this check fixes, and it is worth stating plainly because
		the symptom ("I dodged perfectly and still took damage") pointed at the
		dodge rather than at its absence here. `HitValidator` has honoured
		`RoninInvulnerable` since Day 9, so a *player's* katana already slides
		straight through an i-framed defender - but the dummy is a second,
		independent authority that resolves its own strikes, and it never read
		the attribute. The rule existed; this file just never asked. Two
		authorities resolving the same rule is exactly the duplication the
		SparringDummy header warns about, and this is the one place it cost a
		real mechanic.

		Placement is the whole design decision, and it is deliberately the same
		one `HitValidator` makes:

		  * **After the swing is proven real.** A cancelled swing is not an
		    evaded swing; the player was never touched, so claiming they evaded it
		    would be a lie printed into the console.
		  * **After range and line-of-sight.** Those two checks are what the
		    0.7s telegraph buys the player - backing out of the ten studs or
		    stepping behind cover genuinely misses the strike, and that is a
		    *miss*, a different event from an *evasion*. Both return cleanly;
		    they just tell the truth differently.
		  * **Before the guard, and before the parry.** Invulnerability is a
		    stronger claim than a block: a block still takes posture damage and
		    can still be broken, whereas i-frames take nothing at all.
		    Consulting the guard first would let a defender whose button is
		    still down from before the dodge absorb posture inside a window in
		    which they should be untouchable - and the trace would read
		    "Blocked" on a move the player experienced as untouchable. A player
		    who sees "Blocked" believes they were hit; a player who sees
		    "EVADED" knows they were not.

		Zero Health, zero posture, and the `return` is the guarantee - the same
		shape as the block path's "no `TakeDamage` on this path, ever".

		The attribute read is a plain `== true` rather than a truthiness test for
		the same reason `readParryWindow` is explicitly typed: `GetAttribute`
		returns `any`, and a stripping script that left a string here must
		produce "vulnerable", not a type error inside the hit path.
	]]
	if target:GetAttribute(INVULNERABLE_ATTRIBUTE) == true then
		print(string.format(
			"[DUMMY EVADED] %s i-framed through the dummy's katana strike!",
			target.Name
		))
		return
	end

	local isBlocked, dotProduct = resolveGuard(target, targetRoot, dummyRoot)

	if isBlocked then
		--[[
			The deflect read, inside the frontal branch and ahead of the posture
			spend. The window comes from the attribute `HitValidator` wrote when the
			player's client claimed the press, so this is the server checking a
			deadline it set itself - a client cannot widen it, and a client that never
			pressed has none.
		]]
		local parryWindow = readParryWindow(target)

		if parryWindow > 0 then
			-- 1. The defender pays nothing. The window is spent by the parry itself.
			closeParryWindow(target)

			-- 2. Reflect onto the dummy, through the ordinary posture path.
			local posture, maxPosture, isBroken = spendPosture(dummyModel, PARRY_REFLECT_POSTURE)

			-- 3. Cancel the swing, server-side, and reel. The epoch bump is what
			--    makes the cancellation total: every pending step of this attack
			--    becomes a no-op, including the recovery pose that would otherwise
			--    drive the joints back to rest over the stagger.
			swingToken += 1
			setTelegraph(rigHandle, false)
			stagger(rigHandle, STAGGER_DURATION)

			-- 4. The burst everyone sees, exactly as the validator broadcasts its own.
			deflectClashEvent:FireAllClients(contactPoint)

			-- 5. The defender's own client: HUD line, hitstop, clang and camera punch.
			local defenderPlayer = Players:GetPlayerFromCharacter(target)
			if defenderPlayer ~= nil then
				parryResultEvent:FireClient(
					defenderPlayer,
					target,
					parryWindow,
					PARRY_REFLECT_POSTURE,
					dummyModel.Name
				)
			end

			print(string.format(
				"[DUMMY DEFLECT] %s parried the dummy! Reflected %d posture (dummy %d/%d, dot %.3f, window %dms).",
				target.Name,
				PARRY_REFLECT_POSTURE,
				posture,
				maxPosture,
				dotProduct,
				math.floor(parryWindow * 1000)
			))

			if isBroken then
				--[[
					The dummy's own guard shatters: four clean deflects is the whole
					pool. Its pool resets and it reels for the shared guard-break
					duration rather than the short one, which is the visible
					consequence the player has been working towards.
				]]
				ensurePosture(dummyModel)
				dummyModel:SetAttribute(POSTURE_ATTRIBUTE, 0)
				stagger(rigHandle, GUARD_BREAK_STUN_DURATION)

				print(string.format("[DUMMY BREAK] %s broke the dummy's guard!", target.Name))
			end

			return
		end

		--[[
			The block: zero Health, posture instead.

			`PoiseDamage` off the same frame data the damage came from, which is why a
			heavier attack is both harder to eat and more expensive to block - one
			number, two readings of the same design intent.
		]]
		guardClashEvent:FireAllClients(contactPoint)

		local posture, maxPosture, isBroken = spendPosture(target, data.PoiseDamage)

		print(string.format(
			"[DUMMY] Blocked by %s! Posture: %d/%d (Dot: %.3f, +%d)",
			target.Name,
			posture,
			maxPosture,
			dotProduct,
			data.PoiseDamage
		))

		if isBroken then
			breakGuard(target)

			print(string.format("[DUMMY BREAK] %s's guard shattered!", target.Name))
		end

		return
	end

	--[[
		3. Unguarded: full damage, applied here, on the server.

		Both unguarded variants take the damage, because COMBAT_SPEC is explicit that
		a guard converts a *frontal* hit - a flank or rear hit is full damage, and
		that is the entire reason circling behind a guard works. The trace is split
		because "hit somebody guarding from the wrong angle" and "hit somebody not
		guarding" are different events, and only the first proves the guard system is
		still running.
	]]
	local isGuarding = target:GetAttribute(GUARD_STATE_ATTRIBUTE) == true

	if isGuarding then
		print(string.format("[DUMMY] Guard bypassed - backstab landed on %s (Dot: %.3f).", target.Name, dotProduct))
	else
		print(string.format("[DUMMY HIT CONFIRMED] The dummy struck %s for %d HP.", target.Name, data.Damage))
	end

	targetHumanoid:TakeDamage(data.Damage)
end

--[[
	One attack, start to finish, on the opener's frame data.

	The timeline, and why each step is where it is:

	    t = 0.00   telegraph on; the dummy squares up and starts to cock the blade
	    t = 0.55   the telegraph's cock is complete (`TELEGRAPH_DURATION`)
	    t = 0.70   the frame data's windup has committed the blade to the cut
	    t = 0.76   the strike resolves, mid-Active
	    t = 0.82   the Active window closes
	    t = 1.02   recovery complete, arms back at rest
	    t = 2.50   the next attack begins

	The 0.55s telegraph is the *read*; the frame data's windup after it is the
	*commit*. A player who reacts to the red flash and presses block has a window
	that is still open when the blade arrives roughly a fifth of a second later -
	which is the entire point of a dummy that can be learned from.

	`false` means "nothing to attack", not "the attack failed": the loop treats the
	two the same way, and logging a miss for an empty arena every 2.5 seconds would
	be noise on top of an idle prop.
]]
local function attackOnce(rigHandle: DummyRig, data: AttackData): boolean
	local target = findTarget(rigHandle)
	if target == nil then
		return false
	end

	local targetRoot = findRoot(target)
	if targetRoot == nil then
		return false
	end

	faceTarget(rigHandle, targetRoot)

	-- Claim the swing. From here until this epoch changes, this attack owns the
	-- dummy's joints and its pending timers.
	swingToken += 1
	local myToken = swingToken

	local telegraphDuration = TELEGRAPH_DURATION
	local windupDuration = data.WindupDuration
	local activeDuration = data.ActiveDuration
	local recoveryDuration = data.RecoveryDuration

	--[[
		1. The warning, and the first half of the cock.

		The blade rises to a *shallow* cock for the length of the telegraph rather
		than straight to the full windup. That leaves the frame data's windup
		something real to do - the final commit - instead of a phase that animates
		nothing, and it puts the visible motion where the player's attention already
		is: the red flash.
	]]
	setTelegraph(rigHandle, true)
	poseSwing(
		rigHandle,
		WINDUP_WAIST:Lerp(CFrame.identity, 0.45),
		WINDUP_SHOULDER:Lerp(CFrame.identity, 0.45),
		WINDUP_ELBOW:Lerp(CFrame.identity, 0.45),
		telegraphDuration,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)

	--[[
		2. The commit, then the cut.

		Two nested timers rather than one, because the phases have different jobs:
		the windup *positions* the blade (and is the window COMBAT_SPEC §2.2 lets a
		parry interrupt), while the Active window is where the blade is live. Every
		step re-checks the epoch, so a deflect that lands at any point in the next
		second cancels every remaining one of them.
	]]
	task.delay(telegraphDuration, function()
		if swingToken ~= myToken or activeRig ~= rigHandle then
			return
		end

		poseSwing(
			rigHandle,
			WINDUP_WAIST,
			WINDUP_SHOULDER,
			WINDUP_ELBOW,
			windupDuration,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		)

		task.delay(windupDuration, function()
			if swingToken ~= myToken or activeRig ~= rigHandle then
				return
			end

			-- The red goes out as the blade falls: the warning is over and the
			-- strike has begun, and that transition is itself something to read.
			setTelegraph(rigHandle, false)

			poseSwing(
				rigHandle,
				STRIKE_WAIST,
				STRIKE_SHOULDER,
				STRIKE_ELBOW,
				activeDuration,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			)

			-- Resolution lands in the middle of the Active window: early enough
			-- that the blade is visibly moving when it connects, late enough that a
			-- player who read the windup has been given the whole window to answer.
			task.delay(activeDuration * 0.5, function()
				resolveStrike(rigHandle, target, myToken, data)
			end)

			-- Recovery: the follow-through COMBAT_SPEC §1 describes, where the
			-- dummy is committed and a counter has its opening.
			task.delay(activeDuration, function()
				if swingToken ~= myToken or activeRig ~= rigHandle then
					return
				end

				poseSwing(
					rigHandle,
					CFrame.identity,
					CFrame.identity,
					CFrame.identity,
					recoveryDuration,
					Enum.EasingStyle.Sine,
					Enum.EasingDirection.InOut
				)
			end)
		end)
	end)

	return true
end

--[[
	Finds the rig, arms it, and records the handles the swing needs.

	Returns whether a dummy is ready to fight. A place with no rig, or a rig with no
	`RightHand`, is a supported state rather than an error - this script has to be
	safe to drop into any place - so both paths report and return false, and the
	attack loop keeps retrying in case a rig appears later.

	The dummy gets a posture pool of its own (`RoninPosture` / `RoninMaxPosture`, the
	same attributes a player's character carries) because that pool is what the
	deflect reflection spends. It is seeded here rather than on first deflect so the
	first forced read of it cannot be the one that creates it.
]]
local function setupRig(): boolean
	local dummy = findDummy()
	if dummy == nil then
		print("[DUMMY] No rig named TrainingDummy (or Rig) with a Humanoid in Workspace; the sparring dummy is inactive.")
		return false
	end

	local hand = dummy:FindFirstChild("RightHand")
	if hand == nil or not hand:IsA("BasePart") then
		warn("[DUMMY] The rig has no RightHand; the dummy cannot be armed and will not attack.")
		return false
	end

	local blade, bladeStyle = equipKatana(dummy, hand)
	local highlight = ensureHighlight(dummy)

	ensurePosture(dummy)
	dummy:SetAttribute(POSTURE_ATTRIBUTE, 0)

	local record: DummyRig = {
		Model = dummy,
		Blade = blade,
		BladeStyle = bladeStyle,
		Highlight = highlight,
		Waist = findLimbJoint(dummy, "UpperTorso", "Waist"),
		RightShoulder = findLimbJoint(dummy, "RightUpperArm", "RightShoulder"),
		RightElbow = findLimbJoint(dummy, "RightLowerArm", "RightElbow"),
	}

	--[[
		Park the arm at rest before the first attack.

		A rig can be re-armed while it is still wearing a pose: a Script Sync hot
		reload during a swing, or a place that reloads this script mid-session. A
		snap rather than a tween, because there is no meaningful transition from "the
		pose a previous copy of this script left behind" - and because the first
		telegraph must not start from a half-cocked arm it would then have to
		overcorrect from.
	]]
	writeJointTransform(record.Waist, CFrame.identity)
	writeJointTransform(record.RightShoulder, CFrame.identity)
	writeJointTransform(record.RightElbow, CFrame.identity)

	activeRig = record

	-- A fresh rig starts with no swing in flight, so any timer still pending from a
	-- previous rig is retired by this bump.
	swingToken += 1

	print(string.format(
		"[DUMMY] Sparring dummy online: %s armed, attacking every %.1fs within %d studs (hit %d: %d HP / %d posture).",
		dummy.Name,
		ATTACK_INTERVAL,
		AGGRO_RADIUS,
		OPENING_ATTACK.HitIndex,
		OPENING_ATTACK.Damage,
		OPENING_ATTACK.PoiseDamage
	))

	if blade == nil then
		print("[DUMMY] The dummy is unarmed but will still swing: the strike is resolved from geometry, not from the blade.")
	end

	return true
end

--[[
	The attack loop.

	One timer per attack, and deliberately not a Heartbeat connection: the dummy has
	nothing to do between swings, and a per-frame check for "is anybody in range"
	would burn a frame-by-frame pass over the player list to answer a question whose
	answer cannot change the outcome for another 2.5 seconds (ARCHITECTURE.md #4).

	Discovery is retried on every tick when there is no rig, so a script that starts
	before the place finishes loading - or a place where the rig is added later - ends
	up armed without a reload. When the rig is *destroyed*, the record is dropped and
	the joints along with it, rather than being held by a loop that would keep writing
	to parts that no longer exist.
]]
local function runAttackLoop()
	while true do
		task.wait(ATTACK_INTERVAL)

		local rigHandle = activeRig

		if rigHandle == nil then
			setupRig()
		elseif rigHandle.Model.Parent == nil then
			cancelTweens()
			activeRig = nil
			print("[DUMMY] The rig was removed; waiting for one to reappear.")
		else
			local humanoid = rigHandle.Model:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health > 0 then
				attackOnce(rigHandle, OPENING_ATTACK)
			end
		end
	end
end

setupRig()

task.spawn(runAttackLoop)

