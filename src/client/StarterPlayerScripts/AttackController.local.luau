--!strict

--[[
	AttackController
	Ronin — The Last Blade · 3-hit light-attack chain driver (Day 5 · Part 1/2)

	Plays one swing of the light-attack chain and owns the two pieces of state that
	make a chain a chain:

	  * which hit the character is on (CurrentComboIndex), and
	  * when the last swing finished (LastAttackEndTime), which decides whether the
	    next press continues the chain or restarts it at Hit 1.

	Frame data comes from the frozen `AttackConfig.COMBO_CHAIN` table, so this module
	holds no timings of its own: tuning the chain is a config edit, not a code edit.

	How a swing is driven
	---------------------
	`ExecuteLightAttack` requests the Windup transition and then hands the machine
	over to three chained `task.delay` hardware timers, one per phase, each reading
	its duration from the frame data of the hit being played:

	    Windup  --WindupDuration-->  Active  --ActiveDuration-->  Recovery
	    Recovery  --RecoveryDuration-->  Idle

	The timers are chained rather than scheduled as three deadlines from the swing's
	start: a phase is "how long the character spends in that state", so the total
	swing time is the sum of the three durations. (Scheduling Recovery as a deadline
	from the start would make Hit 1's recovery negative - 0.20s of recovery against
	0.27s of windup+active.)

	Interruption
	------------
	COMBAT_SPEC §2 makes Stunned override everything and lets a parry cancel the
	startup, so a swing the player never gets to finish is a normal outcome rather
	than an exceptional one. Every timer therefore re-checks that the machine is
	still in the state that timer was supposed to leave it in; if it is not (a stun, a
	parry cancel, a feint, a respawn that bound a new machine, the debug harness
	forcing a reset) the chain breaks, the combo resets to Hit 1, and the machine is
	left exactly where the interrupting system put it. A `swingId` token guards the
	same case when a new swing starts while an older chain is still pending.

	Chain carry
	-----------
	A follow-up press is normally made while the character is still busy, but the
	200ms InputBuffer tolerance is spent from the moment of the press, so on the longer
	recoveries (Hit 3 recovers for 350ms) a press made early in Recovery would expire
	before the character became actionable, and the chain would silently drop. The
	swing therefore watches the buffer while it is in flight and, if a follow-up press
	was buffered at any point, hands that intent to the chain when it resolves.

	The watch is one Peek per frame, which InputBuffer documents as allocation free
	(ARCHITECTURE.md #4): it reuses the live entry and never builds a table. It lives
	only for the length of a swing and is disconnected on every exit path.

	Root motion
----------
`LungeSpeed` is not a cosmetic number: from Day 4 · Part 2/2 each swing physically
commits the character forward for the length of the Active window. It is applied as a
real `LinearVelocity` constraint on `HumanoidRootPart` rather than a scripted CFrame
move, so the physics engine stays the owner of the body's motion - the push still
collides, still slides along walls and still obeys gravity, instead of the client
teleporting a character through geometry.

The direction is sampled once, at the moment Active begins, and paired with
`Humanoid.AutoRotate = false` for the same window. Together those are the whole of
"commitment": a swing that could be steered while the blade was live would make the
root motion meaningless, because the lunge would be re-aimed by the mouse underneath
it. COMBAT_SPEC §1 already calls Active the action-locked, cannot-turn state - the
constraint is what makes that promise true in the physics engine as well.

`MaxAxesForce` is `Vector3.new(100000, 0, 100000)`: full authority on the two
horizontal axes and a hard zero on Y, so the constraint contributes no vertical force
at all and gravity keeps pulling the character down mid-lunge. That value is honoured
only because `ForceLimitsEnabled` is switched on in PerAxis mode - the engine ignores
`MaxAxesForce` outright under the default magnitude mode, which is the sort of default
that silently turns a lunge into an unconstrained fling.

The constraint, its attachment and the rotation lock are all released by one idempotent
`stopLunge`, called from every exit out of the Active window: the normal transition
into Recovery, an interruption (COMBAT_SPEC §2 - a stun or parry cut, reaching
`breakChain`), and the start of the next swing. A `LinearVelocity` left attached to a
live character would fling it across the map for the rest of the session, so this is
deliberately not left to the happy path alone.

Blade and hitbox (Day 5 · Part 1/2)
-----------------------------------
Active now has something to do. Three seams hang off the two phase edges that
already existed:

  * `startSlash` fires at the top of the swing, in Windup, and asks the blade proxy
    (WeaponVisuals) to run the arc for the hit being played. It also plays an
    authored AnimationTrack when one is configured in `SLASH_CLIP_IDS`; that table
    ships empty, and the reason it cannot simply be filled in with a guessed asset
    id is written out beside it.
  * `BladeHitbox.Start` fires on the frame the machine enters Active and
    `BladeHitbox.Stop` on the frame it leaves, both immediately adjacent to the
    lunge calls above. That placement is the point: the hitbox window and the
    Active state are the same window, not two windows that happen to agree today
    and drift the first time someone retimes the chain.
  * `breakChain` releases both, so an interrupted swing cannot leave a live sweep
    or a frozen blade behind.

What none of this does is apply damage. The hitbox reports a contact, draws a beam
and publishes a record; the server remains the only thing allowed to turn that into
a Health or a posture change (ARCHITECTURE.md #3).

Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - this is local prediction only. Nothing here applies
	    damage; it reads frame data, drives the local state machine and prints a
	    trace. The server stays the sole authority for damage and transitions.
	  * ARCHITECTURE.md #4 - nothing here allocates per frame. The only allocations are
	    the three task.delay closures of a swing, and the follow-up watch, which is a
	    single allocation-free InputBuffer.Peek() per frame and lives no longer than
	    the swing it watches.

	This file is a LocalScript (Script Sync suffix `.local.luau`), which is why the
	consumption loop in CombatController reaches it through CombatStateBus instead of
	`require` - see the registration at the bottom of this file.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
local BladeHitbox = require(script.Parent:WaitForChild("BladeHitbox") :: ModuleScript)
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)

type AttackData = AttackConfig.AttackData

-- Frozen frame data, indexed by the current combo index. Read-only by construction.
local COMBO_CHAIN = AttackConfig.COMBO_CHAIN
local COMBO_RESET_TIMEOUT = AttackConfig.COMBO_RESET_TIMEOUT

--[[
	Length of the chain, counted from the frozen frame data rather than written down
	here. It is the divisor in the wrap arithmetic below, the divisor in the chain
	timeout check, and the "/ 3" the HUD renders - three things that must not disagree
	after someone tunes the chain to four hits in AttackConfig.
]]
local COMBO_LENGTH = 0
for _ in pairs(COMBO_CHAIN) do
	COMBO_LENGTH += 1
end

--[[
	Sentinel for "no swing has resolved yet". -math.huge guarantees the difference
	against it is +inf, so the very first attack of a session takes the same "chain
	timed out" path as a real timeout and starts at Hit 1.
]]
local NO_COMPLETED_SWING = -math.huge

--[[
	Chain state.
	  CurrentComboIndex  - the hit the character is on, or the hit the next press will
	                       play while it sits in Idle. Starts at Hit 1.
	  LastAttackEndTime  - os.clock() reading of the last swing's final transition.
	                       The chain survives a gap shorter than COMBO_RESET_TIMEOUT.
	  swingId            - monotonic token identifying the chain that owns the pending
	                       timers, so a newer swing can orphan an older one.
]]
local CurrentComboIndex: number = 1
local LastAttackEndTime: number = NO_COMPLETED_SWING
local swingId: number = 0

--[[
	The follow-up watch of the swing that is currently in flight, if any, and whether
	a follow-up press was buffered while it ran. Both are held at module scope rather
	than as locals of ExecuteLightAttack for two reasons: every exit path of the chain
	- completion, interruption, and being superseded by a newer swing - can then stop
	and reset the watch from one place, and the Heartbeat callback and the Recovery
	timer must observe the *same* flag. A local would be copied into the callback as
	an upvalue, so the timer would keep reading the value the callback started with.
]]
local activeWatch: RBXScriptConnection? = nil
local followUpBuffered = false

--[[
	Root motion of the swing that is currently in flight, and the rotation lock that
	goes with it. Held at module scope for the same reason as the follow-up watch: the
	Active timer, the Recovery timer and breakChain are three different exits out of
	the same window and all of them have to reach the *same* handles, including the
	ones that run long after ExecuteLightAttack has returned. A local would be copied
	into each closure as its own upvalue and the constraint would be unreleasable from
	the paths that did not create it.

	All three are nil whenever no swing holds the character locked, which is also the
	state `stopLunge` treats as "nothing to release".
]]
local lungeConstraint: LinearVelocity? = nil
local lungeAttachment: Attachment? = nil
local lungeHumanoid: Humanoid? = nil

--[[
	Per-axis force ceiling for the lunge, in the space named by RelativeTo (World).
	X and Z are effectively unlimited for a character of this mass, so the push
	reaches the requested speed within the Active window instead of easing into it; Y
	is pinned to zero, meaning the constraint adds no vertical force whatsoever and
	gravity keeps its full authority on the character mid-lunge.
]]
local LUNGE_MAX_AXES_FORCE = Vector3.new(100000, 0, 100000)

--[[
	Day 5 · Part 2/2: the authored-clip hook, and why it is now genuinely optional.

	Two different systems are called "the swing", and keeping them apart is the whole
	point of this block:

	  * the *scripted* arm swing, driven by `startArmSlash` on the right shoulder's
	    Motor6D. It is live today, it is frame-accurate, and the welded blade follows
	    the arm it is holding.
	  * an authored *arm* animation, played as a real AnimationTrack on the
	    character's Animator. `SLASH_CLIP_IDS` is its seam.

	Why the second one is a seam and not the driver
	-----------------------------------------------
	Measured on this place's own rigs, in a live playtest on Day 5 · Part 1/2:

	  * the characters had no Motor6D joints at all - every joint on a character was
	    an AnimationConstraint, and a scripted `Transform` on one of those is blended
	    away by the locomotion track;
	  * the standard R15 clips therefore did not bind. Loaded at Action4 on the
	    character's own Animator, rbxassetid://507766666 (idle), 507777826 (walk) and
	    522635514 (toolslash) all loaded, all reported a length, and all moved the
	    hand by 0.04 / 0.06 / 0.13 studs. 522635514 is the standard tool slash and is
	    already referenced by this place's own Animate script, so the id was never the
	    problem - the rig was;
	  * `AnimationTrack.Weight` is read-only, so the locomotion track cannot be faded
	    out to make room for an authored one;
	  * `Animator:LoadKeyframeSequence` does not exist, so a clip cannot be built at
	    runtime either.

	AvatarJointUpgrade has since been set to Disabled in StarterPlayer, which restores
	standard Motor6D joints - confirmed live, 15 of them including
	`RightUpperArm.RightShoulder`. So the obstruction above is gone and a clip *could*
	bind now. It is still left empty on purpose:

	Two drivers on one shoulder is exactly the bug Part 1/2 was built around, in its
	mirror image. `startArmSlash` writes `C0` every frame of a swing; an
	`AnimationTrack` writes the same joint's `Transform` every frame it plays. Script
	fills in the table before anyone has verified a clip actually binds, the swing
	looks authored and is a silent no-op, and that is the hardest kind of bug to see
	from a playtest. The table stays as the seam, and the scripted swing carries the
	weapon on its own until someone tests a real clip against the restored rig.
]]
local SLASH_CLIP_IDS: { [number]: string } = {
	[1] = "",
	[2] = "",
	[3] = "",
}

--[[
	Reported once, not once per swing. A rig without a RightShoulder is a supported
	case (R6 has no such joint), and a line in the console on every attack would bury
	anything worth reading.
]]
local warnedNoShoulder = false

--[[
	Reported once, for the same reason as `warnedNoShoulder`: the server script owns
	the remote, and its absence is a startup-order problem to notice once, not a line
	to repeat on every attack.
]]
local warnedNoStateRemote = false

--[[
	Action4 outranks the default Idle and Movement tracks the Animate script plays,
	so a clip at this priority owns the joints it animates for as long as it runs.
	Action4 is also the fastest of the Action tiers, which matches a 120ms window.
]]
local SLASH_CLIP_PRIORITY = Enum.AnimationPriority.Action4

--[[
	Weight ramp of a clip, in seconds. Small on purpose: the default 0.1s ramp would
	spend most of a 120ms Active window before the clip reached full influence.
]]
local SLASH_CLIP_BLEND = 0.05

--[[
	Loaded tracks keyed by hit index, the Animator they were loaded against, and the
	one currently playing. Module scope for the reason the lunge handles are: the
	swing that loads a clip, the swing that supersedes it, and an interruption
	arriving mid-swing all have to be talking about the same Animator, or a cached
	track would be played on a character that no longer exists.
]]
local slashTracks: { [number]: AnimationTrack } = {}
local slashAnimator: Animator? = nil
local activeSlashTrack: AnimationTrack? = nil

-- One-time note, so a session with no clips does not print it on every swing.
local warnedNoClip = false

--[[
	Resolves the AnimationTrack for a hit, loading and caching it on first use.

	Returns nil - quietly, because a missing clip is a normal state of this project
	- when no id is configured, when there is no character, or when the character
	has no Animator. The cache is keyed by hit index alone, so it is cleared
	whenever the Animator it was loaded against changes: a track is bound to its
	Animator and is meaningless on a respawned character.
]]
local function resolveSlashTrack(hitIndex: number): AnimationTrack?
	local cached = slashTracks[hitIndex]
	if cached ~= nil then
		return cached
	end

	local clipId = SLASH_CLIP_IDS[hitIndex]
	if clipId == nil or clipId == "" then
		return nil
	end

	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		return nil
	end

	if slashAnimator ~= animator then
		table.clear(slashTracks)
		slashAnimator = animator
	end

	local animation = Instance.new("Animation") :: Animation
	animation.Name = string.format("RoninSlash_%d", hitIndex)
	animation.AnimationId = clipId
	animation.Parent = character

	-- LoadAnimation throws on a malformed Animation, and a bad asset id is a
	-- configuration mistake rather than a reason to take the whole swing down.
	local ok, result = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)

	if not ok or result == nil then
		warn(string.format("[SLASH] Clip for Hit #%d could not be loaded: %s", hitIndex, tostring(result)))
		return nil
	end

	local track = result :: AnimationTrack
	track.Priority = SLASH_CLIP_PRIORITY
	track.Looped = false
	slashTracks[hitIndex] = track

	return track
end

--[[
	Arm swing poses, in the shoulder's own rest frame, indexed by the 1-based hit.

	Each entry is the two extremes of one slash: the arm is tweened to `Wind` across the
	windup window and then to `Strike` across the Active window, which are the same two
	durations the frame data defines. The arc is therefore frame-accurate by
	construction - retiming the chain in AttackConfig retimes the swing with it.

	These are *deltas* on the shoulder's captured rest C0 rather than absolute frames,
	and that is deliberate. C0 depends on the avatar (an R15 default shoulder and a
	custom one sit in different places), so a hardcoded absolute pose would put the arm
	somewhere strange on any rig that is not the one it was tuned on. Composing onto
	the rest pose makes the numbers mean "rotate the arm 80 degrees from where it
	happens to hang", which is portable.

	Why the shoulder and not the blade
	----------------------------------
	Part 1/2 drove the swing on the grip joint, because these characters had no Motor6D
	joints and the arm genuinely could not move. AvatarJointUpgrade is now disabled in
	StarterPlayer, so the rigs carry standard Motor6D shoulders (verified in a live
	playtest: 15 joints, including `RightUpperArm.RightShoulder`) and the arm can be
	posed for real. A swing that moves the arm and drags a welded sword with it is
	what a katana swing is; a sword that pivots in a static fist is not, and it is also
	how you end up with a blade that visually slides out of the hand.

	The blade is welded to the hand by WeaponVisuals and carries no rotation of its own,
	so these numbers are the only thing that moves the sword. Exactly one driver per
	joint is the whole reason the two cannot fight each other.

	How the axes were found
	-----------------------
	Measured, not guessed - and the first guess was wrong, which is the reason the
	measurement is written down. Reading the hand's displacement in the character's own
	frame (+X right, +Y up, -Z forward) for a single 30-40 degree rotation of each axis
	from rest:

	    Z +30   delta (+0.69, +0.49, -0.05)   raises the arm up and out to the right
	    Z -30   delta (-0.84, -0.08, +0.05)   sweeps the arm across the body to the left
	    X +40   delta (-0.05, +0.58, -0.90)   lifts the hand up and forward
	    X -40   delta (+0.06, +0.14, +1.06)   pulls the hand back behind the body
	    Y +/-30 delta (∓0.28, ~0.00, ∓0.23)   small: twist about the arm's own axis

	So Z is the axis that carries a blade *sideways* and X is the one that carries it
	up and over. The first attempt at this table had them the wrong way round, which
	produced a swing that wound the arm out to the left and then "struck" by lifting
	it - the mirror image of a katana cut. The 90/120/150/180 sweep below is what
	established the usable range on this rig: the arm can be raised from hanging
	(0) through horizontal (90) to straight up (180), and slightly past 180 starts to
	come back down the far side.
]]
local ARM_POSES: { [number]: { Wind: CFrame, Strike: CFrame } } = {
	-- Hit 1: horizontal right-to-left. Cocks out to the right at shoulder height, then
	-- slices across the chest. Pure Z: the two extremes are the same axis, which is
	-- what makes the arc read as one continuous sweep rather than a lift-and-drop.
	[1] = {
		Wind = CFrame.Angles(0, 0, math.rad(55)),
		Strike = CFrame.Angles(0, 0, math.rad(-75)),
	},
	-- Hit 2: rising reverse cut, the mirror of Hit 1 and deliberately higher. Cocks
	-- up over the right shoulder and cuts back down across the body, so the two read
	-- as different blows even though both cross right to left. The X on the wind pulls
	-- the hand back behind the head, which is what loads the cut.
	[2] = {
		Wind = CFrame.Angles(math.rad(-30), 0, math.rad(105)),
		Strike = CFrame.Angles(math.rad(15), 0, math.rad(-60)),
	},
	-- Hit 3: heavy committed overhead. The chain's finisher, and the only hit that
	-- leaves the character frame entirely. Cocks at Z 140 - arm well up, blade drawn
	-- back over the shoulder - and drives through to Z 215, which carries the tip past
	-- the character's centreline and down the far side.
	--
	-- This uses Z alone, for the same reason Hit 1 does. X was tried here first and is
	-- wrong: X raises the arm *forward*, so an X-driven "overhead" put the tip above
	-- the hand at every angle from 45 to 130 degrees (measured: tip-relative-to-hand
	-- stayed between +2.3 and +3.3 studs, i.e. blade pointing up on a downward cut).
	-- The overhead lives entirely on Z, which is also the axis that carries the blade
	-- sideways, so the finisher and the two horizontal cuts are the same motion at
	-- three different weights.
	[3] = {
		Wind = CFrame.Angles(0, 0, math.rad(140)),
		Strike = CFrame.Angles(0, 0, math.rad(215)),
	},
}

--[[
	Live arm-swing state. Module scope for the reason `stopLunge` documents for the
	lunge handles: the shoulder, the tweened value and the connection that writes them
	are all reached from three different exits out of a swing (natural end,
	interruption, supersession), including ones that run long after this function has
	returned.
]]
local armShoulder: Motor6D? = nil
local armRestC0: CFrame? = nil
local armTweenValue: CFrameValue? = nil
local armTween: Tween? = nil
local armWriteConnection: RBXScriptConnection? = nil

--[[
	Finds `RightUpperArm.RightShoulder` on the local character, or nil.

	Returns nil on any rig that does not have it - an R6 character has no
	RightShoulder joint at all - which is a normal case rather than an error. The caller
	reports it once and carries on with the rest of the swing intact.
]]
local function findShoulderJoint(): Motor6D?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end

	local upperArm = character:FindFirstChild("RightUpperArm")
	if upperArm == nil then
		return nil
	end

	local joint = upperArm:FindFirstChild("RightShoulder")
	if joint == nil or not joint:IsA("Motor6D") then
		return nil
	end

	return joint :: Motor6D
end

--[[
	Puts the arm back where it started and releases the swing's write path.

	Idempotent, and called from every exit out of a swing. The handles are taken out of
	the module before anything is torn down, so a re-entrant call during teardown cannot
	find a half-released swing. The joint is parent-checked for the same reason
	`stopLunge` checks the Humanoid: the usual reason to be mid-swing when this last
	runs is that the character died or respawned.

	The leftover offset is eased away rather than zeroed. Snapping C0 back to rest on
	the frame a swing is cancelled is the one way to make a scripted swing read as
	broken, because the eye sees a discontinuity instead of a follow-through - and this
	path is the *interrupted* one, where a visible snap is most jarring.
]]
local function stopArmSwing()
	local value = armTweenValue
	local tween = armTween
	local connection = armWriteConnection
	local shoulder = armShoulder
	local restC0 = armRestC0

	armTweenValue = nil
	armTween = nil
	armWriteConnection = nil
	armShoulder = nil
	armRestC0 = nil

	if tween ~= nil then
		tween:Cancel()
	end

	if connection ~= nil then
		connection:Disconnect()
	end

	if value ~= nil then
		value:Destroy()
	end

	if shoulder ~= nil and restC0 ~= nil and shoulder.Parent ~= nil then
		-- Only when the swing is still displaced. Easing an already-resting arm does
		-- nothing visible, and skipping it keeps the common path free of a tween.
		if shoulder.C0 ~= restC0 then
			-- 0.25 is a fixed, very short blend rather than a tween: this has to
			-- complete even though the swing is over and nobody is tracking it any
			-- more, and a tween owned by a released handle is the thing that leaks.
			shoulder.C0 = shoulder.C0:Lerp(restC0, 0.25)
		end
	end
end

--[[
	Drives one slash on the right shoulder.

	Called at the top of the swing rather than when Active begins, because Windup is
	where a katana is supposed to be travelling - a blade that only moved during Active
	would not be a swing, it would be a blade teleporting onto a target.

	The three phases are three chained TweenService tweens rather than a hand-rolled
	per-frame blend: TweenService owns the timing, so retiming the chain retimes the
	arm with it, and the arm still returns to rest if every timer is interrupted. Each
	phase re-checks that it still owns `value` before starting the next, so a swing
	that was superseded or cancelled mid-flight cannot resume a stale phase over the
	shoulder of the swing that replaced it.

	Durations are floored at a small positive value: a zero-duration tween is a no-op
	that would silently drop a phase, and a frame data value of zero should freeze the
	arm rather than delete the windup.
]]
local function startArmSlash(currentData: AttackData)
	-- Release first, so this is a single unconditional entry point rather than a
	-- function that is only correct if its caller cleaned up. A new swing superseding
	-- an old one would otherwise leave two tweens writing the same C0.
	stopArmSwing()

	--[[
		Day 6 · Part 2/2: drop any live guard pose *before* the rest C0 is read below.

		`restC0 = shoulder.C0` is the frame every arm pose in this swing is composed
		onto, so whatever the shoulder happens to be wearing at this instant becomes the
		swing's definition of "at rest". Attacking out of a guard puts the shoulder
		exactly halfway through a 0.18s tween, and capturing that would make every
		swing in the chain start from a half-raised, permanently-offset arm - and would
		return the arm to *that* on recovery, so the character never stood straight
		again.

		`Release(true)` is instant precisely for this call site: it parks both shoulders
		on their captured rest frames on the spot, and the tween the player *should* see
		- the arms coming down - is played by the transition observer in
		CombatController, which ran this same transition a moment earlier. Here the
		pose only has to be out of the way, and out of the way means now.

		Ordering is the whole fix: pose down, then read the rest.
	]]
	local guardPose = CombatStateBus.GetGuardPose()
	if guardPose ~= nil then
		guardPose.Release(true)
	end

	local shoulder = findShoulderJoint()
	if shoulder == nil then
		if not warnedNoShoulder then
			warnedNoShoulder = true
			print("[ARM] No RightShoulder joint on this character; the arm cannot swing.")
		end
		return
	end

	local poses = ARM_POSES[currentData.HitIndex]
	if poses == nil then
		warn(string.format(
			"[ARM] No arm pose for hit index %d; the arm did not swing.",
			currentData.HitIndex
		))
		return
	end

	local restC0 = shoulder.C0
	local value = Instance.new("CFrameValue")
	value.Name = "RoninArmSwing"
	value.Value = restC0
	value.Parent = shoulder

	armShoulder = shoulder
	armRestC0 = restC0
	armTweenValue = value

	-- The one per-frame write in the whole swing, and it allocates nothing: the
	-- changed-signal callback is handed the tweened value directly.
	armWriteConnection = value:GetPropertyChangedSignal("Value"):Connect(function()
		shoulder.C0 = value.Value
	end)

	local windup = math.max(currentData.WindupDuration, 0.01)
	local active = math.max(currentData.ActiveDuration, 0.01)
	local recovery = math.max(currentData.RecoveryDuration, 0.01)

	-- Windup eases *in* (slow to start, accelerating into the strike) and Active eases
	-- *out* (fastest at the moment of contact, decelerating through it). That pairing
	-- is what gives a slash its snap: the blade is slowest while the player can still
	-- cancel it, and fastest on the frame it can hurt somebody.
	local function chain(pose: CFrame, duration: number, style: Enum.EasingStyle, direction: Enum.EasingDirection)
		local tween = TweenService:Create(value, TweenInfo.new(duration, style, direction), {
			Value = pose,
		})
		armTween = tween
		tween:Play()
	end

	chain(restC0 * poses.Wind, windup, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(windup, function()
		if armTweenValue ~= value then
			return
		end

		chain(restC0 * poses.Strike, active, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end)
	task.delay(windup + active, function()
		if armTweenValue ~= value then
			return
		end

		chain(restC0, recovery, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	end)
	task.delay(windup + active + recovery, function()
		if armTweenValue == value then
			stopArmSwing()
		end
	end)
end

--[[
	Starts the swing for one hit: the arm always, the blade rig if one is published,
	and an authored arm clip when one is configured.

	Called at the top of the swing rather than when Active begins, because Windup is
	where a katana is supposed to be travelling. A blade that only moved during Active
	would not be a swing, it would be a blade teleporting onto a target.
]]
local function startSlash(currentData: AttackData)
	-- The arm first. It is the only thing that actually moves the weapon now, so it
	-- runs before the rig and the clip are consulted - if either of them decides to
	-- do nothing, the swing still has a visible arc.
	startArmSlash(currentData)

	local rig = CombatStateBus.GetBladeRig()
	if rig ~= nil then
		rig.StartSwing(
			currentData.HitIndex,
			currentData.WindupDuration,
			currentData.ActiveDuration,
			currentData.RecoveryDuration
		)
	end

	local track = resolveSlashTrack(currentData.HitIndex)
	if track ~= nil then
		activeSlashTrack = track
		track:Play(0, SLASH_CLIP_BLEND)
		return
	end

	if not warnedNoClip then
		warnedNoClip = true
		print("[SLASH] No authored clip for this chain; the scripted arm swing carries it on its own.")
	end
end

--[[
	Releases the swing. Idempotent, and called from every exit out of a swing for the
	same reason `stopLunge` is: an AnimationTrack left running past the end of its swing
	would keep overriding the locomotion animation with a stale pose, and a tween left
	running would keep writing C0 over a rest pose the Animator owns.
]]
local function stopSlash()
	-- Before the rig and the track, so the arm is parked first and nothing downstream
	-- can be left holding a swing that is still moving.
	stopArmSwing()

	local rig = CombatStateBus.GetBladeRig()
	if rig ~= nil then
		rig.StopSwing()
	end

	local track = activeSlashTrack
	activeSlashTrack = nil

	if track ~= nil and track.IsPlaying then
		track:Stop(0)
	end
end

local AttackController = {}



--[[
	Ends the follow-up watch. Deliberately does *not* clear `followUpBuffered`: the
	Recovery timer stops the watch and then hands the follow-up off, so clearing the
	flag here would erase the very thing the hand-off is about to read. The flag is
	re-initialised by startWatch, and only a swing that called startWatch can ever
	hand a follow-up off, so no stale value is reachable.
]]
local function stopWatch()
	local connection = activeWatch
	activeWatch = nil

	if connection then
		connection:Disconnect()
	end
end

--[[
	Releases the lunge and hands turning back to the player.

	Idempotent and safe to call from every exit out of the Active window, including
	paths where nothing was ever started. The handles are taken out of the module
	first and only then destroyed, so a re-entrant call during the teardown cannot
	find a half-released lunge. The constraint goes before its attachment because the
	constraint is the thing referencing it.

	The Humanoid is parent-checked because the usual reason to be standing in Active
	when this runs for the last time is that the character died or respawned, and
	writing a property to a destroyed instance is work thrown away.
]]
local function stopLunge()
	local constraint = lungeConstraint
	local attachment = lungeAttachment
	local humanoid = lungeHumanoid

	lungeConstraint = nil
	lungeAttachment = nil
	lungeHumanoid = nil

	if constraint then
		constraint:Destroy()
	end

	if attachment then
		attachment:Destroy()
	end

	-- COMBAT_SPEC §1 turn-locks Active and only Active. Restoring true is what makes
	-- Recovery the first state in which the player can steer again.
	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = true
	end
end

--[[
	Commits the swing forward and locks the facing, for the length of Active.

	The direction is read from HumanoidRootPart once, right here: the lunge goes where
	the character was pointing at the instant the blade went live and stays there. That
	is the point of a committed attack - re-reading the facing every frame would let
	the mouse steer the root motion underneath the animation.

	AutoRotate is switched off for the same window, which is what stops the player from
	turning mid-strike. Its previous value is not captured: nothing else in this
	system ever writes AutoRotate, and the lock is owned outright by the swing for as
	long as the swing is in flight, so `true` is the correct value to hand back rather
	than a remembered one that could itself be stale.
]]
local function startLunge(currentData: AttackData)
	-- A swing may only be superseded from Idle, where no lunge can be live, but
	-- releasing first keeps this a single unconditional entry point rather than a
	-- function that is correct only if its caller checked something.
	stopLunge()

	local character = Players.LocalPlayer.Character
	if character == nil then
		warn("[ATTACK] Lunge skipped: the local character is gone.")
		return
	end

	-- Split find and cast: the nil test comes first so the cast below narrows a
	-- value the checker already knows is present, rather than leaning on a cast of a
	-- possibly-nil Instance.
	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	if rootPartInstance == nil then
		warn("[ATTACK] Lunge skipped: HumanoidRootPart is missing.")
		return
	end

	local rootPart = rootPartInstance :: BasePart

	local attachment = Instance.new("Attachment")
	attachment.Name = "AttackLungeAttachment"
	attachment.Parent = rootPart

	local constraint = Instance.new("LinearVelocity")
	constraint.Name = "AttackLunge"
	constraint.Attachment0 = attachment

	-- World space, so the target below is a world direction rather than one expressed
	-- in the character's local frame. This is the engine default; it is stated
	-- explicitly because both it and the axis order that MaxAxesForce is written
	-- against depend on it.
	constraint.RelativeTo = Enum.ActuatorRelativeTo.World
	constraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector

	-- MaxAxesForce is inert unless force limits are enabled and per-axis. Left at the
	-- defaults the constraint applies an unbounded magnitude-mode force and the
	-- horizontal-only limit below would be silently ignored.
	constraint.ForceLimitsEnabled = true
	constraint.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	constraint.MaxAxesForce = LUNGE_MAX_AXES_FORCE

	constraint.VectorVelocity = rootPart.CFrame.LookVector * currentData.LungeSpeed

	-- Parented last, so the constraint never simulates for even one step against a
	-- half-configured target velocity.
	constraint.Parent = rootPart

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		lungeHumanoid = humanoid
		humanoid.AutoRotate = false
	end

	lungeAttachment = attachment
	lungeConstraint = constraint

	print(string.format(
		"[ATTACK] Root motion committed: %.1f studs/s for %.0f ms",
		currentData.LungeSpeed,
		currentData.ActiveDuration * 1000
	))
end

--[[
	Tells the server this swing has entered Active, so it will accept a hit candidate
	from this player for the next `ActiveDuration`.

	Day 5 · Part 2/2. This is the one place the client is *allowed* to assert anything
	to the server about combat, and the assertion is deliberately the smallest possible
	one: "I am swinging hit N now". It carries no damage, no position and no target,
	so the most an exploiter can do with it is open a window that is the real swing's
	length - and the server measures that from its own copy of the frame data.

	It is fired from the same place, on the same frame, as `BladeHitbox.Start` below.
	Those two must not be allowed to drift: a window that opened before the blade went
	live would accept hits outside it, and one that opened after would reject the first
	frame of a real swing. Same line of code, same frame, one window.
]]
local function declareActiveWindow(currentData: AttackData)
	local remote = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_ATTACK_STATE_EVENT)
	if remote == nil or not remote:IsA("RemoteEvent") then
		-- The validator creates the remote when it starts. Its absence means the
		-- server script has not run, and firing into nothing is silently ignored, so
		-- this is reported once rather than on every swing.
		if not warnedNoStateRemote then
			warnedNoStateRemote = true
			warn(string.format(
				"[SERVER] %s is not present; the server cannot see this swing.",
				AttackConfig.REMOTE_ATTACK_STATE_EVENT
			))
		end
		return
	end

	(remote :: RemoteEvent):FireServer(currentData.HitIndex)
end

--[[
	Breaks the chain of a swing that never reached its end.

	Called from a timer whose machine is no longer in the state that timer expected,
	so the swing was interrupted (COMBAT_SPEC §2). Forcing the end time back to the
	sentinel guarantees the next press restarts at Hit 1 rather than resuming a chain
	the player never completed.
]]
local function breakChain()
	stopWatch()

	-- A swing cut short during Active (COMBAT_SPEC §2: a stun interrupts anything)
	-- still has to hand the character back. Without this the LinearVelocity would keep
	-- driving a body nobody is watching, for the rest of the session.
	stopLunge()

	-- Day 5 · Part 1/2: the two things the Active window owns are released on the
	-- same path. An interrupted swing that left the blade mid-arc, or left the sweep
	-- live, would keep tracing against a world the player is no longer attacking.
	BladeHitbox.Stop()
	stopSlash()

	LastAttackEndTime = NO_COMPLETED_SWING
	CurrentComboIndex = 1
	CombatStateBus.SetComboState(CurrentComboIndex, COMBO_LENGTH)
end

--[[
	Starts the follow-up watch for a swing in flight: from here until the swing
	resolves, any LightAttack sitting in the buffer counts as a queued follow-up.
]]
local function startWatch()
	stopWatch()

	followUpBuffered = InputBuffer.Peek() == "LightAttack"
	activeWatch = RunService.Heartbeat:Connect(function()
		if InputBuffer.Peek() == "LightAttack" then
			followUpBuffered = true
		end
	end)
end

--[[
	Hands a buffered follow-up to the chain once the swing resolves, so the Idle
	handler spends it as a fresh intent rather than letting a 200ms tolerance that
	started while the character was busy decide the chain's fate.

	A press that is still queued is re-stamped, and one that has already expired is
	re-queued - it is the same press the player made during the swing. A *different*
	action sitting in the buffer is left alone: it is the player's newer intent, and
	Day 3's rule is that the latest press wins.
]]
local function handOffFollowUp()
	if not followUpBuffered then
		return
	end

	local pending = InputBuffer.Peek()
	if pending == nil or pending == "LightAttack" then
		InputBuffer.Push("LightAttack")
	end
end

--[[
	Runs one swing of the light attack chain: Windup -> Active -> Recovery -> Idle,
	on the frame data of CurrentComboIndex, and closes the chain bookkeeping when the
	swing resolves.

	Returns whether a swing was actually started. A swing does not start when there is
	no bound character, when the frame data for the index is missing, or when the state
	machine's own rules refuse the Windup request (e.g. the press was spent on a
	machine that is no longer Idle) - the machine's transition table is the authority
	there, and burning a chain index on a refused swing would desync the HUD from the
	frame data.
]]
function AttackController.ExecuteLightAttack(): boolean
	-- Chain reset: a gap longer than the reset window (or a session that has not
	-- swung yet) drops the chain back to the opener.
	if (os.clock() - LastAttackEndTime) > COMBO_RESET_TIMEOUT then
		CurrentComboIndex = 1
	end

	local currentData: AttackData? = COMBO_CHAIN[CurrentComboIndex]
	if not currentData then
		warn(string.format("[ATTACK] No frame data for hit index %d; swing ignored.", CurrentComboIndex))
		return false
	end

	if not CombatStateBus.RequestState("Windup") then
		warn(string.format("[ATTACK] Windup request rejected; Hit #%d not started.", currentData.HitIndex))
		return false
	end

	-- Claim the chain: every timer below carries this token and bails when a newer
	-- swing has taken over, so a forced reset mid-swing leaves no orphan timers.
	swingId += 1
	local mySwingId = swingId

	-- Watch the buffer for a follow-up press until this swing resolves.
	startWatch()

	-- Day 5 · Part 1/2: the blade starts travelling now, in Windup, not in Active.
	-- A katana swing is the whole arc; the Active window is only the part of it that
	-- can hurt somebody.
	startSlash(currentData)

	-- Publish the hit that is now in flight so the HUD shows the swing being played
	-- rather than the hit that will follow it.
	CombatStateBus.SetComboState(CurrentComboIndex, COMBO_LENGTH)

	print(string.format(
		"[ATTACK] Executed Hit #%d (Dmg: %d, Poise: %d)",
		currentData.HitIndex,
		currentData.Damage,
		currentData.PoiseDamage
	))

	-- Windup -> Active ---------------------------------------------------------
	task.delay(currentData.WindupDuration, function()
		if mySwingId ~= swingId then
			return
		end

		local machine = CombatStateBus.GetActiveMachine()
		if machine == nil or machine.CurrentState ~= "Windup" then
			breakChain()
			return
		end

		if not CombatStateBus.RequestState("Active") then
			-- Windup -> Active is unconditional in the transition table, so this is
			-- unreachable in practice; it is checked anyway because the lunge below
			-- must only ever exist for a window the machine actually entered.
			breakChain()
			return
		end

		-- The commitment: from here until the Active window closes, the character is
		-- pushed forward and cannot turn.
		startLunge(currentData)

		-- Day 5 · Part 1/2: the blade goes live. The sweep is opened on the same
		-- frame the state machine enters Active, and closed before Recovery is
		-- requested below, so "the hitbox is live" and "the state is Active" are one
		-- window rather than two that can drift apart.
		BladeHitbox.Start(currentData)

		-- Day 5 · Part 2/2: and the server is told, on the same frame, so the window
		-- it will accept a hit candidate in is the same window the blade is actually
		-- live in. One frame of slack either way would be a hole, so these two calls
		-- are deliberately adjacent rather than folded into one helper.
		declareActiveWindow(currentData)

		-- Active -> Recovery ---------------------------------------------------
		task.delay(currentData.ActiveDuration, function()
			if mySwingId ~= swingId then
				return
			end

			local activeMachine = CombatStateBus.GetActiveMachine()
			if activeMachine == nil or activeMachine.CurrentState ~= "Active" then
				breakChain()
				return
			end

			-- Active is over the moment the strike lands. The push and the turn lock are
			-- dropped *before* the transition is requested, so Recovery is the first
			-- state in which the player can steer again rather than one frame after it.
			stopLunge()

			-- Day 5 · Part 1/2: and so is the blade. The sweep is closed on the same
			-- frame, for the same reason - Recovery must be the first state in which
			-- the player is no longer being hit by their own swing.
			BladeHitbox.Stop()

			CombatStateBus.RequestState("Recovery")

			-- Recovery -> Idle ---------------------------------------------------
			task.delay(currentData.RecoveryDuration, function()
				if mySwingId ~= swingId then
					return
				end

				local recoveryMachine = CombatStateBus.GetActiveMachine()
				if recoveryMachine == nil or recoveryMachine.CurrentState ~= "Recovery" then
					breakChain()
					return
				end

				-- Close the chain *before* handing the machine back to Idle. The Idle
				-- handler that spends the follow-up is dispatched through task.spawn
				-- and reads CurrentComboIndex, so the advance must already be visible
				-- before the transition is requested.
				stopWatch()

				-- Day 5 · Part 1/2: the swing is fully resolved here - the blade is
				-- already home, but releasing it at the end of the *swing* rather than
				-- the end of Active is what keeps a long recovery (Hit 3 is 350ms)
				-- from freezing the proxy in a strike pose.
				stopSlash()

				LastAttackEndTime = os.clock()
				CurrentComboIndex = (CurrentComboIndex % COMBO_LENGTH) + 1
				CombatStateBus.SetComboState(CurrentComboIndex, COMBO_LENGTH)

				handOffFollowUp()

				CombatStateBus.RequestState("Idle")
			end)
		end)
	end)

	return true
end

--[[
	Publish this driver to the bus so CombatController's consumption loop can spend a
	queued LightAttack into a real swing. Registration happens as this module is
	required, so the order in which the client scripts start does not matter.
]]
CombatStateBus.SetLightAttackExecutor(function(): boolean
	return AttackController.ExecuteLightAttack()
end)

--[[
	Day 7 · Part 1/2: the inbound half of the chain seam.

	The server resolves a perfect deflect and drops this attacker's Active window, so
	no further hit from the swing in flight can be billed (that half is server-side and
	lives in `HitValidator`). This handler is the *client* half: it drops the chain
	index the player would otherwise see, so the next press starts at Hit 1 instead of
	continuing a three-hit combination whose third beat was just answered with a
	deflect.

	`breakChain` rather than a bare `CurrentComboIndex = 1` on purpose. A reset that
	only moved the index would leave everything the swing in flight owns still live —
	the lunge constraint, the open hitbox sweep, the slash pose, and the follow-up
	watch — and the attacker's body would keep lunging into a parry that has already
	stopped them. `breakChain` is the existing "the swing is over, hand the character
	back" path, and reusing it means a deflect and a stun and a respawn all release
	the swing through exactly one function.

	`breakChain` also resets `CurrentComboIndex` to 1 and republishes it, so this is a
	single call rather than a set-and-forget that could drift from what the HUD shows.
]]
CombatStateBus.SetComboResetHandler(function()
	breakChain()
end)

return AttackController
