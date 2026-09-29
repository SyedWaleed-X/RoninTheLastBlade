--!strict

--[[
	Hitstop
	Ronin — The Last Blade · the deflect micro-pause (Day 7 · Part 1/2)

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
	and the two would visibly disagree. The server tells each side about its own
	deflect, and each side freezes itself. Both participants get the pause because
	both clients receive an event, not because either one reached across.

	Why `AutoRotate` alone is not the whole trick
	----------------------------------------------
	AutoRotate off stops the character *turning*, which is the most visible part of a
	punch but nowhere near all of it: a walk cycle keeps cycling, the character keeps
	sliding, and the camera keeps drifting. The pause that actually reads is the one
	that stops the animation being advanced, so the `Animator` is what is driven
	here, with the root's velocity zeroed for the same window so the body does not
	drift out from under a frozen pose.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #4 - no per-frame path. `Apply` is called on a remote event
	    and schedules exactly one `task.delay`; there is no Heartbeat loop here, and
	    the restore is a single pass over the Animator's playing tracks.
]]

local Players = game:GetService("Players")

local MIN_HITSTOP_DURATION = 0.01
local MAX_HITSTOP_DURATION = 0.25

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
	if character == nil then
		releaseScheduled = false
		return
	end

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if humanoidInstance ~= nil then
		local humanoid = humanoidInstance :: Humanoid
		if humanoid.Parent ~= nil then
			humanoid.AutoRotate = true
		end
	end

	-- Advance any animation still running back to real time. Tracks that finished
	-- during the freeze are gone from this list already, which is why the loop is
	-- over *playing* tracks rather than over a saved array: a track destroyed
	-- mid-pause cannot be restored and must not be indexed.
	local animatorInstance = character:FindFirstChildOfClass("Animator")
	if animatorInstance ~= nil then
		local animator = animatorInstance :: Animator
		for _, track in animator:GetPlayingAnimationTracks() do
			if track ~= nil then
				track.TimeScale = 1
			end
		end
	end

	releaseScheduled = false
end

--[[
	Freezes the local character for `duration` seconds.

	Clamped to the same 0.01-0.25s band the guard break uses, for the same reason: a
	negative duration would produce a pause that had already ended, and an unbounded
	one would be a soft lock delivered by a malformed remote.

	`TimeScale` rather than `Speed`: it scales the track's own playback rate without
	overwriting the authored speed a clip was configured with, so a track that played
	at 0.5 is still playing at 0.5 after the thaw. Setting `Speed` and restoring it to
	1 would silently double the speed of any slow-motion clip in the place.
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
		Zero the body as well as the animation. Freezing the pose while the character
		keeps sliding produces the worst version of this effect: a statue gliding
		forwards, which reads as a bug rather than as impact.
	]]
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		local rootPart = root :: BasePart
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end

	local animatorInstance = character:FindFirstChildOfClass("Animator")
	if animatorInstance ~= nil then
		local animator = animatorInstance :: Animator
		for _, track in animator:GetPlayingAnimationTracks() do
			if track ~= nil then
				track.TimeScale = 0
			end
		end
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
	release()
end

return Hitstop


