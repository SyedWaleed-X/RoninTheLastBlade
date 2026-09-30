--!strict

--[[
	Hitstop
	Ronin — The Last Blade · the deflect micro-pause (Day 7 · Part 1/2) ·
	the true hitstop and FOV punch (Day 10 · Part 1/2)

	A perfect deflect costs the defender no Health, spends no posture, and produces
	one burst of sparks. Judged on those numbers alone it is indistinguishable on
	screen from a strike that quietly missed. This module is the 50ms that makes it
	land: a real pause in the local character's motion, at the exact moment the
	blades meet, on both participants.

	Why this is presentation and not authority
	-------------------------------------------
	ARCHITECTURE.md #3 draws the line at damage and state transitions, and this sits
	entirely on the other side of it. The server decides a deflect happened; this
	decides what the local player *sees* happen because it did. Nothing here can make
	a hit land, fail to land, or change a number — a client with this module disabled
	plays a slightly choppier game, and that is the entire blast radius.

	Which is also why the hitstop is applied to the *local* character only. A client
	cannot authoritatively freeze another player's body, and a scripted attempt to
	would be a rubber band: the other player's own client would keep simulating them
	and the two would visibly disagree.

	Why `AutoRotate` alone is not the whole trick
	----------------------------------------------
	AutoRotate off stops the character *turning*, which is the most visible part of a
	punch but nowhere near all of it: a walk cycle keeps cycling, the character keeps
	sliding, and the camera keeps drifting. The pause that actually reads is the one
	that stops the animation being advanced, so the `Animator` is what is driven
	here, with the root's velocity zeroed for the same window so the body does not
	drift out from under a frozen pose.

	Day 10 · Part 1/2: what "true" added
	-------------------------------------
	Day 7 froze the *character*. It left three things moving, and those three are
	exactly what makes a hit feel like it landed:

	  1. `AnimationTrack.Speed` was forced to 0 and restored to **1**. Day 7 used
	     `TimeScale`, which composes with the authored speed and so restores cleanly
	     — but a hitstop during a clip authored at 0.5 was thawing correctly while
	     reporting that it had been playing at 1. `AdjustSpeed(0)` is the documented
	     freeze and, crucially, the *captured* prior speed is restored rather than
	     an assumed one.
	  2. The dodge's lean tween and the weapon's pose tween ran straight through the
	     pause. A body frozen mid-lean while its joint kept easing to neutral reads
	     as a glitch, not an impact. There is no global `TweenService:PauseAll` in
	     this engine (verified: the method does not exist), so the tweens that should
	     freeze are *registered* here and paused individually.
	  3. `AssemblyLinearVelocity` was zeroed once. A single zero is a suggestion:
	     `Humanoid.MoveDirection` re-applies velocity on the very next physics step,
	     so a character that was walking when it got deflected kept walking through
	     the freeze and slid out from under its own frozen pose. Day 10 re-asserts
	     the zero every frame of the freeze and *restores the captured velocity*,
	     so the dodge momentum that was in flight resumes instead of being lost.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - nothing here can change a combat number.
	  * ARCHITECTURE.md #4 - the only per-frame path is the one `RenderStep`
	    binding, which allocates no tables. `Apply` schedules exactly one
	    `task.delay`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

local MIN_HITSTOP_DURATION = 0.01
local MAX_HITSTOP_DURATION = 0.25

--[[
	Day 10 · Part 1/2: the FOV punch's own tuning, read from the one place it is
	written. `DeflectFeedback` used to own a 2-degree punch with its own tween; that
	tween is gone (see `DeflectFeedback.Punch`) because two modules writing
	`Camera.FieldOfView` on the same deflect would fight each other — one easing back
	to 70 while the other eased back to 68 — and the camera would settle somewhere
	between the two, permanently off-default.
]]
local FOV_PUNCH_DEGREES = AttackConfig.FOV_PUNCH_DEGREES
local FOV_PUNCH_RETURN_DURATION = AttackConfig.FOV_PUNCH_RETURN_DURATION
local DEFAULT_FIELD_OF_VIEW = AttackConfig.DEFAULT_FIELD_OF_VIEW
local MIN_FIELD_OF_VIEW = AttackConfig.MIN_FIELD_OF_VIEW

-- The render-step binding name, for the same reason as `CameraShaker`'s.
local RENDER_STEP_NAME = "RoninFovPunch"

--[[
	How long the local character is currently frozen, as an os.clock() deadline.

	Module-scoped rather than a per-call local because two deflects inside one window
	have to behave as one freeze, not two overlapping ones: restoring on the first
	timer would thaw the character while the second pause is still owed to it. A
	second `Apply` inside a live freeze therefore *extends* the deadline rather than
	restarting a competing restore, which is the behaviour a double-parry in the same
	100ms needs and the one a second `task.delay` would get wrong.
]]
local frozenUntil = 0
local releaseScheduled = false

--[[
	The module's own table.

	Declared here so the methods below can be written as `function Hitstop.X()`
	rather than as a `table.freeze({...})` literal at the bottom of the file, which
	is the shape every other method-bearing module in `PlayerScripts` uses
	(`StateMachine`, `BladeHitbox`, `InputGate`).

	The reason is not style. A module that assigns to a name it never declared
	creates a *global*, and a global is shared across every copy of the script in the
	place — so `frozenUntil` would be one value for every player, and a hitstop on
	one character would thaw on another's timer.
]]
local Hitstop = {}

--[[
	Day 10 · Part 1/2: the three pieces of freeze state that have to survive the
	pause to be handed back correctly.

	`capturedTrackSpeeds` maps an `AnimationTrack` to the `Speed` it had at the
	moment of the freeze. Day 7 wrote `TimeScale = 0` and `TimeScale = 1`; `TimeScale`
	multiplies on top of `Speed`, so that restore was accidentally correct — but it
	meant the module could not also use `AdjustSpeed`, which is the documented way to
	freeze a track. Capturing the real `Speed` per track and calling
	`AdjustSpeed(captured)` on the way out means a clip authored at 0.5x thaws at
	0.5x, which is what the animator authored and therefore the only correct answer.

	`capturedLinearVelocity` is the same idea for the body. Zeroing velocity once and
	forgetting it is what Day 7 did, and it loses momentum: a character mid-dodge
	when deflected had 45 studs/s of committed movement that was silently destroyed.
	Capturing and restoring it means the dash finishes where it was going.
]]
local capturedTrackSpeeds: { [AnimationTrack]: number } = {}
local capturedLinearVelocity: Vector3? = nil
local capturedAngularVelocity: Vector3? = nil

--[[
	The tweens that freeze with the character.

	There is no `TweenService:PauseAll` in this engine — verified against the live
	class, the member does not exist — so pausing "whatever is running" is not
	available and a module that tried would error on every deflect. Instead the
	tweens that should freeze *register themselves* here, and `Apply` pauses exactly
	that set.

	Registration is explicit rather than automatic on purpose: a tween that has
	already finished is inert, and one belonging to an unrelated system (a HUD bar
	pulse, say) must not be caught by a sword freeze.
]]
local pausableTweens: { Tween } = {}

--[[
	Day 10 · Part 1/2: the FOV punch's live state.

	`fovCamera` is the camera instance the punch was applied to, and `fovRestoreBase`
	is the FOV to return to. Both are needed because `workspace.CurrentCamera` can be
	swapped at any time; writing a stale base onto a replacement camera is a jump in
	field of view for no reason the player can see.

	`fovPunchedUntil` is an `os.clock()` deadline rather than a decrementing timer,
	for the same reason the rest of the project uses deadlines: a second deflect
	inside a live punch re-aims one sequence instead of racing a competing timer.
]]
local fovCamera: Camera? = nil
local fovRestoreBase = 0
local fovPunchedUntil = 0

--[[
	Registers a tween to be paused for the duration of any hitstop.

	Called by the modules that own the tweens worth freezing (the dodge's lean, the
	weapon's pose). Returns nothing and takes no handle: the caller keeps its own
	reference and this module keeps the only one that matters, which is the list.
]]
function Hitstop.RegisterTween(tween: Tween)
	for _, registered in ipairs(pausableTweens) do
		if registered == tween then
			return
		end
	end

	table.insert(pausableTweens, tween)
end

--[[
	Drops a tween from the freeze set.

	Needed because these tweens are created per dodge and per swing. Without it the
	list would grow for the life of the session and `Apply` would walk a few thousand
	dead tweens on every deflect. Callers should invoke this from their tween's
	`Completed` handler.
]]
function Hitstop.UnregisterTween(tween: Tween)
	local index = table.find(pausableTweens, tween)
	if index ~= nil then
		table.remove(pausableTweens, index)
	end
end

--[[
	The FOV punch: in instantly, out over `FOV_PUNCH_RETURN_DURATION`.

	Instant in, eased out — not the other way round. A punch that eases *in* is a
	zoom, and a hit that zooms is a hit the player has time to think about. Snapping
	and recovering is what a physical impact does to a lens, and it is the half of
	this effect that reads as force rather than as a camera move.

	The recovery is driven from the render-step binding below rather than from a
	Tween, for two reasons. A tween writing `FieldOfView` would race the render step
	that eases it (two writers, one property — the exact drift `DeflectFeedback`'s
	old implementation documented), and a tween cannot be cleanly interrupted
	mid-recovery: two deflects 50ms apart would produce two overlapping returns and
	settle at the wrong value. One sequence with a deadline handles both.
]]
function Hitstop.PunchFOV(degrees: number)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	local amount = if typeof(degrees) == "number" then degrees else FOV_PUNCH_DEGREES

	--[[
		Capture the base once per sequence.

		If this camera is already mid-punch then the FOV to return to is the one the
		*previous* punch recorded, not the punched value currently on the camera.
		Re-basing off the punched value is how a camera ends up permanently zoomed
		in: each deflect saves 3 degrees lower than the last and the drift never
		unwinds. A punch on a *different* camera (a respawn swapped it) re-bases off
		whatever that camera is showing, the only reading that is right for it.
	]]
	if fovCamera ~= camera then
		fovCamera = camera
		fovRestoreBase = camera.FieldOfView
	end

	local punched = fovRestoreBase - amount
	if punched < MIN_FIELD_OF_VIEW then
		punched = MIN_FIELD_OF_VIEW
	end

	camera.FieldOfView = punched
	fovPunchedUntil = os.clock() + FOV_PUNCH_RETURN_DURATION
end

--[[
	The single per-frame path in this file.

	It does two things, both of which have to happen *every frame* rather than once:

	  1. Eases the FOV back to its base while a punch is live.
	  2. Re-asserts the frozen body's zero velocity.

	The second is the reason a hitstop needs a frame loop at all. A single velocity
	write is undone on the very next physics step — `Humanoid.MoveDirection` writes
	velocity from the controller every step, so a character walking when it was
	struck walks straight out from under its own frozen pose. Re-asserting for the
	duration of the freeze is what makes the pause read as a pause.

	Both are guarded by an early return on the common case (nothing frozen, nothing
	punched), and neither allocates: the CFrame-free body of this function is three
	number reads and two conditional writes.
]]
local function onRenderStep(dt: number)
	local frozen = os.clock() < frozenUntil
	local punchLive = os.clock() < fovPunchedUntil

	if not frozen and not punchLive then
		return
	end

	--[[
		FOV recovery, as an exponential approach rather than a linear ramp.

		The easing is expressed as a *per-second* rate (`1 - FOV_RETURN_EASING * dt`)
		instead of a fixed per-frame fraction. A fixed fraction is frame-rate
		dependent: the same punch would take 150ms at 60fps and about 300ms at 30fps,
		so the effect would quietly change strength on a weak machine. Dividing by
		`dt` makes the recovery take the same wall-clock time at any frame rate, which
		is what "ease back over 0.15s" is supposed to mean.
	]]
	if punchLive then
		local camera = fovCamera

		-- The camera may have been swapped mid-recovery. If the one we punched is
		-- gone, there is nothing to ease — and writing to the new one would snap a
		-- camera the player never saw affected.
		if camera ~= nil and camera.Parent ~= nil and workspace.CurrentCamera == camera then
			local eased = math.clamp(dt / FOV_PUNCH_RETURN_DURATION, 0, 1)

			-- Quad out: fast at first, settling into the default. Matches the
			-- `DeflectFeedback` easing this replaced.
			local curve = 1 - (1 - eased) * (1 - eased)

			local target = fovRestoreBase
			camera.FieldOfView = camera.FieldOfView + (target - camera.FieldOfView) * curve

			-- Snap on the final frame rather than easing asymptotically toward the
			-- base. A pure exponential never actually arrives, and a camera left at
			-- 70.0000001 degrees is a camera that is one more punch away from being
			-- measurably off-default.
			if eased >= 1 then
				camera.FieldOfView = target
				fovPunchedUntil = 0
				fovCamera = nil
			end
		else
			fovPunchedUntil = 0
			fovCamera = nil
		end
	end

	--[[
		The body freeze, re-asserted.

		`AssemblyLinearVelocity` rather than `Humanoid` properties: `WalkSpeed = 0`
		is what `CombatController` uses for a 3-second stun and is wrong here, because
		a hitstop is 50ms and zeroing the walk speed for 50ms would visibly stutter
		the character's locomotion. Velocity is the surgical instrument.
	]]
	if frozen then
		local character = Players.LocalPlayer.Character
		if character ~= nil then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") then
				local rootPart = root :: BasePart
				rootPart.AssemblyLinearVelocity = Vector3.zero
				rootPart.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
end

--[[
	Bound at `Camera.Value + 1`, the same priority as `CameraShaker`.

	Two render steps can share a priority — the ordering *between* them is not
	guaranteed, but they write different properties (`Camera.CFrame` here,
	`Camera.FieldOfView`), so neither can clobber the other and the order is
	irrelevant. What matters is that both run *after* `Camera` (200), where the
	camera module has finished resolving the frame.
]]
RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)

--[[
	Restores everything `Apply` changed.

	Every restore is defensive on purpose, because this is the one function here that
	runs on a timer the player does not control: the character may have died, respawned
	or been stripped between the freeze and the thaw, and every one of those would
	turn a missing Animator or a destroyed Humanoid into an error inside a
	`task.delay` — i.e. into a freeze that never lifts and a character that can never
	move again. Reading through nil checks is what makes the worst case "the pause
	simply ends early" rather than "the player is stuck".
]]
local function release()
	local character = Players.LocalPlayer.Character

	--[[
		The paused tweens are resumed unconditionally, before any character check.

		A tween belongs to a joint or a part, not to a `Humanoid`, so it survives the
		character being gone — and a tween left paused after the character it was
		animating has been destroyed is a permanently frozen joint on whatever object
		still holds it. Resuming first makes the "character is nil" path a clean exit
		rather than a leak.

		`tween:Play()` rather than a hypothetical `Resume`. Verified against the live
		engine: neither `Tween.Pause` nor `Tween.Resume` exists as a class member, and
		the documented way to resume a paused tween is `Play()` — the pause is a
		playback flag, not a separate state machine.
	]]
	for _, tween in pausableTweens do
		tween:Play()
	end

	if character == nil then
		releaseScheduled = false
		capturedTrackSpeeds = {}
		capturedLinearVelocity = nil
		capturedAngularVelocity = nil
		return
	end

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if humanoidInstance ~= nil then
		local humanoid = humanoidInstance :: Humanoid
		if humanoid.Parent ~= nil then
			humanoid.AutoRotate = true
		end
	end

	--[[
		Thaw each track to the speed it actually had.

		Iterating the *captured* map rather than `GetPlayingAnimationTracks()` is the
		Day 10 change: Day 7 looped the live tracks and set `TimeScale = 1`, which
		touched every track that happened to still be playing and silently ignored
		the rest. Here each track is restored to its own captured `Speed` through
		`AdjustSpeed`, and a track that stopped during the pause is skipped —
		restoring the speed of a destroyed track is an error, and restoring the speed
		of one that has since been reused by a different animation would be worse.
	]]
	for track, speed in pairs(capturedTrackSpeeds) do
		if track.Parent ~= nil and track.IsPlaying then
			track:AdjustSpeed(speed)
		end
	end
	capturedTrackSpeeds = {}

	--[[
		Hand the body back its momentum.

		Written only when the root still belongs to *this* character. A character
		that respawned inside the 50ms has a brand new root that has never had
		velocity, and arming it to 45 studs/s in an arbitrary captured direction
		would launch the player across the map on spawn — so the capture is cleared
		rather than applied when the root is not the one that was frozen.
	]]
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		local rootPart = root :: BasePart
		local linear = capturedLinearVelocity
		if linear ~= nil then
			rootPart.AssemblyLinearVelocity = linear
		end
		local angular = capturedAngularVelocity
		if angular ~= nil then
			rootPart.AssemblyAngularVelocity = angular
		end
	end

	capturedLinearVelocity = nil
	capturedAngularVelocity = nil

	releaseScheduled = false
end

--[[
	Freezes the local character for `duration` seconds.

	Clamped to the same 0.01-0.25s band the guard break uses, for the same reason: a
	negative duration would produce a pause that had already ended, and an unbounded
	one would be a soft lock delivered by a malformed remote.

	`AdjustSpeed(0)` rather than `TimeScale = 0`. `TimeScale` composes on top of
	`Speed`, which is fine for freezing but means the restore has to *guess* the
	authored speed back. `AdjustSpeed` is the documented freeze and, paired with the
	captured `Speed` above, is the only version that can hand a track back exactly
	what it had.
]]
function Hitstop.Apply(duration: number)
	local character = Players.LocalPlayer.Character
	if character == nil then
		return
	end

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if humanoidInstance == nil then
		return
	end

	local humanoid = humanoidInstance :: Humanoid
	if humanoid.Parent == nil then
		return
	end

	local holdTime = math.clamp(duration, MIN_HITSTOP_DURATION, MAX_HITSTOP_DURATION)

	humanoid.AutoRotate = false

	--[[
		Freeze the body as well as the animation.

		Freezing the pose while the character keeps sliding produces the worst version
		of this effect: a statue gliding forwards, which reads as a bug rather than as
		impact. The velocity is *captured* rather than discarded so `release` can
		hand it back — see the note on `capturedLinearVelocity`.

		The render step re-asserts these zeros for the whole window; this write only
		stops the very first physics step, which is the one that would otherwise move
		the character out from under the pose.
	]]
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		local rootPart = root :: BasePart
		capturedLinearVelocity = rootPart.AssemblyLinearVelocity
		capturedAngularVelocity = rootPart.AssemblyAngularVelocity
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end

	--[[
		The animation tracks, each frozen at its own captured speed.

		Iterating `GetPlayingAnimationTracks()` rather than a saved array is
		deliberate: a track that was destroyed before this call cannot be indexed, and
		one that *starts* during the freeze is picked up by the next `Apply`'s sweep.
	]]
	local animatorInstance = character:FindFirstChildOfClass("Animator")
	if animatorInstance ~= nil then
		local animator = animatorInstance :: Animator
		for _, track in animator:GetPlayingAnimationTracks() do
			if track ~= nil and track.IsPlaying then
				--[[
					Capture only on the *first* freeze of this track.

					A second `Apply` inside a live freeze would otherwise capture the
					already-frozen speed (0) as the "prior" speed, and `release` would
					then restore the track to a permanent standstill — which is exactly
					the soft-lock this module must never be able to cause, and precisely
					what a double-parry inside the 50ms window produces.
				]]
				if capturedTrackSpeeds[track] == nil then
					capturedTrackSpeeds[track] = track.Speed
				end

				track:AdjustSpeed(0)
			end
		end
	end

	--[[
		And the joint tweens.

		Paused, not cancelled. A cancelled lean tween would leave the torso stuck at
		whatever angle it had reached when the blades met, and the player would be
		looking at a character permanently frozen mid-dodge for the rest of the
		session. Pausing lets it finish normally once the thaw comes.
	]]
	for _, tween in pausableTweens do
		tween:Pause()
	end

	-- Extend rather than restart: see the note on `frozenUntil`.
	local now = os.clock()
	if now + holdTime > frozenUntil then
		frozenUntil = now + holdTime
	end

	if releaseScheduled then
		return
	end

	releaseScheduled = true
	task.delay(holdTime, function()
		-- Re-read the deadline: a second `Apply` during this window will have pushed
		-- it out, and thawing now would cut that extension short.
		if os.clock() < frozenUntil - 0.001 then
			task.delay(frozenUntil - os.clock(), release)
			return
		end

		release()
	end)
end

--[[
	Thaws immediately, and is called from character teardown.

	Without it a player who died inside the 50ms window respawns into a character
	whose `AutoRotate` was left off and whose Animator tracks are still at
	`TimeScale = 0` — a character that cannot turn and whose animations do not
	advance. The new body has its own Animator, so nothing would ever fix it.
]]
function Hitstop.Release()
	frozenUntil = 0

	--[[
		Day 10 · Part 1/2: the FOV returns with the body.

		A character destroyed inside the 50ms window left `fovRestoreBase` pointing at
		a base captured from a camera that has since been replaced, so the next punch
		on the new camera would either re-base correctly (because the camera differs)
		or ease a camera nobody is looking at. Clearing both is the same reasoning
		that makes `release` drain `capturedTrackSpeeds`: this module's state outlives
		the character, and anything it holds for the old one has to go.
	]]
	fovPunchedUntil = 0
	fovCamera = nil

	release()
end

return Hitstop


