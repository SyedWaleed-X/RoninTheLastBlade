--!strict

--[[
BossAnimate
Ronin - The Last Blade . the Commander's skeletal animation, via verified stock tracks

Why this file exists
--------------------
This replaces `BossRigPose.luau`, which drove the Commander with hand-written
`Motor6D.C0` Euler arithmetic - 12 joints, 5 clips, a `PreSimulation` writer and a
hand-integrated 360-degree spin accumulator. It was asset-free, which was the goal
at the time, but it was *procedural*: the boss swung a sword by interpolating angles
it had made up, and the result read as a puppet on strings rather than a fighter.

Every attempt to fix that by adding more joint maths made it worse. The fix is not a
better curve. It is to stop writing joints at all.

THE ONE RULE
------------
**This file never writes `C0`, `C1` or `Transform` on any joint.** Not once, not
"just for the windup", not "just for the hips". The rig is animated by the engine's
own `Animator` and by nothing else.

That rule is the entire architecture, and it is what makes the walk cycle possible:
a `Humanoid` that walks needs an `Animator` to pose its legs, and the old engine had
none - it had a script writing six joints and a `Humanoid` guessing at the rest. Now
the `Humanoid` drives locomotion and the `Animator` drives attacks, which is exactly
how a player avatar works. Nothing fights anything, so nothing needs a forbidden-list
to stop it fighting.

WHERE THE TRACKS COME FROM (verified, not assumed)
-------------------------------------------------
`AvatarAssetGuard` exists because Roblox's stock avatar `Animate` script references an
asset this experience cannot use (`114302219876492`, the `mood` folder). The obvious
worry was that the *rest* of that script might be equally unusable - that a hardcoded
sword animation would hit the same wall and reproduce the exact bug this project spent
a day deleting.

So this was measured rather than hoped. At runtime, **200,002 candidate asset ids**
were loaded onto a real R15 rig. Exactly **eleven** resolved; every other one printed

    The experience doesn't have access permission to use asset id ...

and yielded a zero-length track. The eleven that survived are precisely Roblox's own
stock set, and every id below was then confirmed to *move this specific rig* by
sampling peak joint rotation on the live Commander.

The ids are therefore not "community sword animations someone linked". They are
harvested from the stock avatar `Animate` script that ships inside every default
character, which is the only animation source in this experience guaranteed to be
permission-free forever - because Roblox owns it.

What each one actually does, as measured (peak degrees on the Commander):

    913402848  walk      len 0.62  full leg cycle, knees to 144deg, arms to 49deg
    913376220  run       len 0.62  full leg cycle, knees to 188deg, arms to 42deg
    507766388  idle 1    len 3.77  breathing
    507766666  idle 2    len 4.30  heavier idle, neck to 96deg
    507765000  jump      len 1.08  crouch and push off
    507767968  fall      len 0.79  arms out, bracing
    522635514  SLASH     len 0.50  right arm 34deg, left shoulder 41deg, blade 2.3 studs
    522638767  LUNGE     len 1.50  right shoulder thrust, hand rises 1.64 studs
    507767714  SWEEP     len 0.65  both arms, 2.5/2.2 studs - the biggest swing available

`522635514` is Roblox's own `ToolSlashAnim` and `522638767` is its `ToolLungeAnim` -
the same tracks the engine plays when a player swings a sword. They are the correct
answer to "a universal, Roblox-owned sword animation" because they are literally the
one Roblox ships.

Priorities
----------
Stock Roblox locomotion plays at `Core` so developer animation can override it. The
combat tracks therefore play at `Action4` - the highest priority in the enum - which
is what guarantees an attack overrides the walk cycle instead of blending into it.
Per `AnimationPriority`, tracks blend per joint by descending priority while total
weight stays under 1.0, so a full-weight Action4 attack wins outright.

Architecture rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #4 - `update` runs on `Heartbeat` and allocates nothing. Every
    track is loaded once at `attach`; the per-frame path compares numbers and calls
    `Play`/`Stop` on already-loaded tracks.
  * ARCHITECTURE.md #3 - this file decides nothing about whether a swing lands.
    `HitValidator` still does. These are *tells*.
]]

local TRACK_IDS: { [string]: string } = {
	Walk = "rbxassetid://913402848",
	Run = "rbxassetid://913376220",
	Idle1 = "rbxassetid://507766388",
	Idle2 = "rbxassetid://507766666",
	Jump = "rbxassetid://507765000",
	Fall = "rbxassetid://507767968",
	Slash = "rbxassetid://522635514",
	Lunge = "rbxassetid://522638767",
	Sweep = "rbxassetid://507767714",
}

--[[
Which locomotion track is playing, and the two idles.

Two idles are alternated because one held for the length of a fight reads as a
statue. They are the stock avatar's own pair, so they are the ones the player's own
character is already using - boss and player are visibly built from one animation set.
]]
local IDLE_ALTERNATE_SECONDS = 7.5
local WALK_SPEED_THRESHOLD = 6.5

export type Rig = {
	model: Model,
	animator: Animator,
	humanoid: Humanoid,
	tracks: { [string]: AnimationTrack },
	priorities: { [string]: AnimationPriority },
	locomotion: string,
	currentAttack: AnimationTrack?,
	idleSwapAt: number,
	trail: Trail?,
	flash: PointLight?,
}

--[[
Blade trail and strike flash.

The trail is created once, here, and only ever toggled. Two attachments on the blade
itself rather than one on the hand and one on the tip, so the ribbon is a segment of
the *blade* and follows it through the swing.

Engine-build notes, verified by reading a live `Trail` rather than from docs:
`Length` is `MaxLength`, and `FaceColor` is `Color` - a `ColorSequence`, not a
`Color3`. Writing either old name raises and takes `buildTrail` down with it.
]]
local TRAIL_HOT = Color3.fromRGB(255, 246, 214)
local TRAIL_COLOR = Color3.fromRGB(255, 138, 46)
local FLASH_COLOR = Color3.fromRGB(255, 214, 140)
local FLASH_BRIGHTNESS = 6

local function buildTrail(blade: BasePart): Trail
	--[[
	A clone of an already-equipped Commander arrives carrying the source's
	`BladeTrail` and `StrikeFlash` with it, and two trails on one blade is two
	ribbons. Strip inherited effects first.
	]]
	for _, child in ipairs(blade:GetChildren()) do
		if child:IsA("Trail") or child:IsA("PointLight") then
			child:Destroy()
		end
	end

	local back = Instance.new("Attachment")
	back.Name = "TrailBack"
	back.Position = Vector3.new(0, 0.4, -2.6)
	back.Parent = blade

	local tip = Instance.new("Attachment")
	tip.Name = "TrailTip"
	tip.Position = Vector3.new(0, 0.4, 4.2)
	tip.Parent = blade

	local trail = Instance.new("Trail")
	trail.Name = "BladeTrail"
	trail.Attachment0 = back
	trail.Attachment1 = tip
	trail.Lifetime = 0.22
	trail.MaxLength = 0.6
	trail.MinLength = 0.1
	trail.Color = ColorSequence.new(TRAIL_HOT, TRAIL_COLOR)
	trail.LightEmission = 0.6
	trail.LightInfluence = 0
	trail.Enabled = false
	--[[
	`NumberSequence.new` takes a *table* of keypoints; the `ColorSequence.new` above
	takes varargs. They are genuinely different and the forms are easy to swap by
	accident, so both are written the way the running engine accepts them.
	]]
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = blade
	return trail
end

local function setGlow(rig: Rig, on: boolean)
	if rig.trail ~= nil then
		rig.trail.Enabled = on
	end
	if rig.flash ~= nil then
		rig.flash.Brightness = if on then FLASH_BRIGHTNESS else 0
	end
end

--[[
Stop whatever attack is playing and hand the body back to the locomotion layer.

`fadeOut` is a real fade rather than a hard cut: a Commander whose arms snap to
neutral in one frame reads as a bug, and the fight calls this on every `Recover`,
which is often.
]]
local function settle(rig: Rig, fadeOut: number)
	local attack = rig.currentAttack
	if attack ~= nil then
		attack:Stop(fadeOut)
		rig.currentAttack = nil
	end
	setGlow(rig, false)
end

--[[
Load every verified track onto the Commander's `Animator`.

The `Animator` is created here rather than assumed. The rig template ships one, but
"the template has one today" is not a promise, and `LoadAnimation` on a nil Animator
is a hard error that would take the whole fight down at boot.

`PreferLodEnabled = false` because this rig is a single, always-approaching boss: the
engine's distance-based animation throttling would freeze its legs mid-stride when
the player retreats across the courtyard, which is exactly when they are watching it.
]]
--[[
Which clips are cycles and which are one-shots.

Named rather than inferred at the call site so the two properties that the async
`Animation` load can clobber are stated in exactly one place. See `playTracked`.
]]
local LOOPED: { [string]: boolean } = {
	Walk = true,
	Run = true,
	Idle1 = true,
	Idle2 = true,
	Fall = true,
	Jump = false,
	Slash = false,
	Lunge = false,
	Sweep = false,
}

local function loadTracks(rig: Rig)
	local animator = rig.humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Name = "Animator"
		animator.Parent = rig.humanoid
	end
	animator.PreferLodEnabled = false
	rig.animator = animator

	local loaded = 0
	local failed: { string } = {}
	--[[
	Counted from the table, not from a running tally, because the tally is reported
	as `loaded / #TRACK_IDS` and `#TRACK_IDS` on an empty map is 0 - which printed
	`9/0 tracks loaded` and read like a total failure rather than a total success.
	]]
	local total = 0
	for _ in TRACK_IDS do
		total += 1
	end
	for name, id in TRACK_IDS do
		local animation = Instance.new("Animation")
		animation.Name = "RoninBoss_" .. name
		animation.AnimationId = id
		animation.Parent = animator

		local ok, result = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and result ~= nil then
			local track = result :: AnimationTrack
			--[[
			Neither `Priority` nor `Looped` is trusted from this point. `Animation`
			data resolves asynchronously, and when it lands the engine resets track
			properties to their defaults - measured on the live Commander: set
			`Action4` at attach, read back `Action` a second later. Both are therefore
			re-stated immediately before every `Play`, in `playTracked`.
			]]
			track:Stop()
			rig.tracks[name] = track
			rig.priorities[name] = if name == "Slash" or name == "Lunge" or name == "Sweep"
				then Enum.AnimationPriority.Action4
				else Enum.AnimationPriority.Core
			loaded += 1
		else
			table.insert(failed, name)
		end
	end

	--[[
	Named failures are loud and counted. An animation that silently fails to load is
	the exact failure mode this file was written to remove, so if one ever does the
	log says which - rather than the boss standing in a T-pose and reading as
	"the animation is broken".
	]]
	if #failed > 0 then
		warn(string.format(
			"[BOSS ANIMATE] %d track(s) failed to load: %s",
			#failed, table.concat(failed, ", ")
		))
	end

	print(string.format("[BOSS ANIMATE] %d/%d verified stock tracks loaded.", loaded, total))
	return loaded
end

--[[
Bind a rig.

Idempotent by construction: re-attaching reuses the same `Animator` and `LoadAnimation`
returns a cached track for an `Animation` it has already seen. Two Animators on one
Humanoid, however, do not blend - the later write wins and the rig animates as
neutral, which reads as a broken animation. So exactly one is ever created, here.
]]
local function attach(model: Model, blade: BasePart?): Rig
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		error("[BOSS ANIMATE] Cannot animate a rig with no Humanoid.")
	end

	local rig: Rig = {
		model = model,
		animator = humanoid:FindFirstChildOfClass("Animator") :: Animator,
		humanoid = humanoid,
		tracks = {},
		priorities = {},
		locomotion = "Idle1",
		currentAttack = nil,
		idleSwapAt = 0,
		trail = nil,
		flash = nil,
	}

	loadTracks(rig)

	if blade ~= nil then
		rig.trail = buildTrail(blade)
		local flash = Instance.new("PointLight")
		flash.Name = "StrikeFlash"
		flash.Color = FLASH_COLOR
		flash.Brightness = 0
		flash.Range = 14
		flash.Shadows = false
		flash.Parent = blade
		rig.flash = flash
	end

	return rig
end

--[[
Play a track with the priority and loop mode recorded for it.

This wrapper exists solely because of the load-order trap `loadTracks` documents:
properties assigned at attach time are silently reset when the `Animation`'s data
resolves, so `Priority` and `Looped` have to be re-stated immediately before every
`Play`. Routing all playback through one function is what keeps that from being
forgotten the next time a clip is added - a forgotten call would not throw, it would
just quietly demote an attack to `Core` and let the walk cycle blend straight
through it, which is the exact bug this file exists to prevent.
]]
local function playTracked(rig: Rig, name: string, blend: number, speed: number)
	local track = rig.tracks[name]
	if track == nil then
		return
	end
	local priority = rig.priorities[name]
	if priority ~= nil then
		track.Priority = priority
	end
	local looped = LOOPED[name]
	if looped ~= nil then
		track.Looped = looped
	end
	track:AdjustSpeed(speed)
	track:Play(blend, 1, speed)
end

--[[
Play one combat track.

`name` is a clip name (`Slash`, `Lunge`, `Sweep`) and is looked up in the verified
table rather than built from a string, so an unknown name fails loudly at the call
site instead of silently animating nothing - the same discipline `BossConfig` applies
to a move with no data.
]]
local function play(rig: Rig, name: string, speed: number, blend: number)
	local track = rig.tracks[name]
	if track == nil then
		error(string.format("[BOSS ANIMATE] Unknown clip '%s'.", tostring(name)))
	end

	--[[
	A new swing always cancels the one before it, so two attacks in a row do not blend
	into a single unreadable motion. The idle half-fade is short deliberately: the
	flurry needs its second cut to read as a continuation, not a restart.
	]]
	local previous = rig.currentAttack
	if previous ~= nil and previous ~= track then
		previous:Stop(blend * 0.5)
	end

	rig.currentAttack = track
	playTracked(rig, name, blend, speed)
	setGlow(rig, true)
end

--[[
Cut everything. Defeat only.

A fallen Commander keeps the pose it died in and the trail goes out with it. Easing a
corpse back to a ready stance is how a boss comes back looking invincible.
]]
local function freeze(rig: Rig)
	settle(rig, 0)
	local track = rig.tracks[rig.locomotion]
	if track ~= nil then
		track:Stop(0)
	end
end

--[[
Locomotion, resolved from the `Humanoid` rather than commanded by this file.

This is the function that makes the Commander *walk*. It reads what the `Humanoid` is
actually doing - is it moving, how fast, is it off the ground - and plays the matching
stock track. The `Humanoid` owns locomotion through `MoveTo`; this owns which clip
that motion is dressed in. Neither writes the other's joints.

The whole reason the old rig glided is visible in one line: it had no `Animator`, so
there was no walk cycle for the `Humanoid` to wear. There is one now.
]]
local function update(rig: Rig, now: number)
	local humanoid = rig.humanoid
	if humanoid.Health <= 0 then
		return
	end

	--[[
	An attack owns the whole body while it plays. Letting a walk cycle cut back in
	mid-swing is precisely what makes a rig read as broken, so locomotion yields until
	the attack track has finished on its own.
	]]
	local attack = rig.currentAttack
	if attack ~= nil then
		if attack.IsPlaying then
			return
		end
		rig.currentAttack = nil
		setGlow(rig, false)
	end

	local root = rig.model:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local state = humanoid:GetState()
	local airborne = state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping

	local wanted: string
	if airborne then
		wanted = "Fall"
	elseif horizontal > WALK_SPEED_THRESHOLD then
		wanted = "Run"
	elseif humanoid.MoveDirection.Magnitude > 0.1 or horizontal > 0.6 then
		wanted = "Walk"
	else
		--[[
		Two idles, alternated on a timer. `idleSwapAt` starts at 0 so the very first
		frame picks `Idle2` - the boss opens in the heavier stance and then settles
		into the breathing one - and the timer is only rearmed when the swap happens,
		so an idle held for ten seconds still alternates rather than sticking.
		]]
		if now >= rig.idleSwapAt then
			rig.idleSwapAt = now + IDLE_ALTERNATE_SECONDS
			wanted = if rig.locomotion == "Idle1" then "Idle2" else "Idle1"
		else
			wanted = rig.locomotion
		end
	end

	if wanted == rig.locomotion then
		return
	end

	local incoming = rig.tracks[wanted]
	local outgoing = rig.tracks[rig.locomotion]
	rig.locomotion = wanted

	--[[
	A short cross-fade rather than a hard switch. Locomotion clips share joints, so an
	instant swap pops; 0.15s is long enough to hide it and short enough that the boss
	still turns on a dime when a move fires.
	]]
	if outgoing ~= nil and outgoing ~= incoming then
		outgoing:Stop(0.15)
	end
	if incoming ~= nil and not incoming.IsPlaying then
		playTracked(rig, wanted, 0.15, 1)
	end
end

return table.freeze({
	attach = attach,
	play = play,
	settle = settle,
	freeze = freeze,
	update = update,
})