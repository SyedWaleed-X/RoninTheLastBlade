--!strict

--[[
	DeflectFeedback
	Ronin — The Last Blade · the deflect's clang and camera punch (Day 7 · Part 2/2)

	`Hitstop` is the *pause* a perfect deflect produces; this is everything else it
	produces. Two effects, one call site each:

	    Clang()   a crisp, pitched-up metal clash, once per deflect
	    Punch()   a 2-degree FOV punch-in that eases back over 50ms

	Why a module rather than two lines inside `Hitstop`
	---------------------------------------------------
	Because they are not the same kind of thing, and the project's modules are named
	for what they are. `Hitstop` freezes a body — it writes `AutoRotate`, zeroes
	velocity and stops `AnimationTrack`s, and its entire risk surface is leaving a
	character frozen. Sound and camera are the opposite: they touch no character
	state at all, they cannot strand anything, and they are the parts a designer is
	most likely to want to retune. Burying them in a module whose header promises a
	micro-pause would make the one file that can soft-lock a character also the file
	that owns a volume slider.

	Being its own module also gives the punch one place to be idempotent, which is
	the only genuinely tricky part of it (see `Punch`).

	Why the clang is played from a pooled Sound
	-------------------------------------------
	A deflect is the most repeatable event in the game: four of them break a guard,
	so a fight produces a stream of them, and `Instance.new("Sound")` per deflect is
	one instance plus one network-light asset lookup per parry for an effect that
	lasts under a second. One `Sound` is created on first use and re-started
	thereafter; `TimePosition = 0` is what makes a second deflect cut a still-ringing
	first one rather than layering two copies of the same transient on top of each
	other, which is what a clash should sound like.

	The asset is a Creator Store sound effect (Pro Sound Effects' "Sword Impact 202")
	because it is the closest thing to the sound this game needs - a sword striking
	metal, recorded - and because it is free, licensed for use on the platform, and
	verifiable by ID. `CLANG_PLAYBACK_SPEED` pitches it up: Sekiro's deflect is a
	*tight* ring, not a heavy thud, and the same recording at 1.2x reads as a
	lighter, higher clash without needing a second asset.

	Where the FOV punch went on Day 10
	----------------------------------
	This module used to own the punch outright. It does not any more: `Hitstop` is
	the single writer of `Camera.FieldOfView`, and `Punch` below is a delegation.

	The reason is the argument that used to live here, which is still true and is now
	the reason for the move rather than an implementation detail. The naive version
	of this effect is `camera.FieldOfView -= 2` and a tween back to the saved value,
	and it is wrong the moment two deflects land inside 50ms: the second call saves
	the *already punched* FOV as its new base and the camera never returns to where it
	started, drifting further in with every parry until the player is looking down a
	telescope. Solving that once per module is not a solution — it is the same rule
	restated, waiting for one module to forget it. A camera property with one owner
	cannot drift at all, so the camera moved.

	`Clang` stayed here because a `Sound` is not a camera: nothing else in the
	project plays a clash, and there is no second writer to protect against.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. Nothing here reads or writes combat
	    state; it draws and sounds what the server already decided.
	  * ARCHITECTURE.md #4 - no per-frame path. `Clang` and `Punch` run on a remote
	    event; the punch itself is a delegated call into `Hitstop`'s existing render
	    step and allocates nothing here.
]]

local SoundService = game:GetService("SoundService")

--[[
	Day 10 · Part 1/2: required for its `PunchFOV` side effect.

	Same reasoning as every other require in `PlayerScripts` — a ModuleScript does
	not run until something requires it, and `CombatController` requires both modules
	so they observe the same instance. The dependency is one-way (`DeflectFeedback`
	reads `Hitstop`, `Hitstop` knows nothing of the deflect), so it cannot cycle.
]]
local Hitstop = require(script.Parent:WaitForChild("Hitstop") :: ModuleScript)

--[[
	The clash asset and its mix.

	`rbxassetid://9119747138` is "Sword Impact 202 (SFX)" from Pro Sound Effects,
	verified present and free through the Creator Store before it was hardcoded.
	Volume is deliberately below 1: this sound plays on top of the clash sparks, the
	hitstop and the HUD flash, and a deflect that is *loudest* is a deflect that
	makes the rest of the mix inaudible in the one moment the player is listening
	hardest.
]]
local CLANG_SOUND_ID = "rbxassetid://9119747138"
local CLANG_VOLUME = 0.65
local CLANG_PLAYBACK_SPEED = 1.2

--[[
	The punch's tuning, retired to Day 10 · Part 1/2.

	Two degrees over 50ms were the original values. Both now live in `AttackConfig`
	as `FOV_PUNCH_DEGREES` (3) and `FOV_PUNCH_RETURN_DURATION` (0.15) and are read
	by `Hitstop`, so the camera's numbers are set in exactly one place.

	Three degrees rather than two because the punch now shares its recovery with a
	render step that also has to survive a camera swap mid-punch, and a slightly
	larger instant is what stays legible against a shake that is simultaneously
	ramping down. 150ms rather than 50ms because it now outlasts the 50ms hitstop
	on purpose — the snap has to be inside the freeze or it is missed entirely, and
	the ease back has to outlast it or the punch reads as cut off rather than
	recovered from.
]]

--[[
	The module's own table.

	Declared here so the methods below can be written as `function DeflectFeedback.X()`
	rather than as a frozen literal at the bottom, which is the shape every other
	method-bearing module in `PlayerScripts` uses (`Hitstop`, `ParryWindow`,
	`StateMachine`). See `Hitstop`'s note on why: a module that assigns to a name it
	never declared creates a global, and a global is shared by every copy of the
	script in the place.
]]
local DeflectFeedback = {}

-- The pool. Nil until the first deflect, because a session that never parries
-- should not pay for a Sound instance either.
local clangSound: Sound? = nil


--[[
	Creates the clash sound once, on first use.

	Parented to `SoundService` rather than to the character: this is the *player's*
	clash, not a world event. A Sound parented to a part would be attenuated and
	panned by where that part happens to be, and a deflect that sounds quieter
	because the camera is looking away is exactly the feedback that must not scale
	with the camera.
]]
local function ensureClangSound(): Sound
	local existing = clangSound
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local sound = Instance.new("Sound")
	sound.Name = "RoninDeflectClang"
	sound.SoundId = CLANG_SOUND_ID
	sound.Volume = CLANG_VOLUME
	sound.PlaybackSpeed = CLANG_PLAYBACK_SPEED
	sound.Parent = SoundService

	clangSound = sound
	return sound
end

--[[
	Plays the clash.

	Called on the defender's own deflect and on the attacker's, because both of them
	heard the same two blades meet. It is *not* called from the broadcast
	`DeflectClashEvent` that draws the sparks: a bystander watching two other people
	duel should see the burst, but a point-blank clang for a clash on the far side of
	the map would be noise, and `SoundService` has no positional story for an event
	that happened to somebody else.
]]
function DeflectFeedback.Clang()
	local sound = ensureClangSound()

	-- Restart rather than layer: a second deflect inside the tail of the first is a
	-- second impact, not a chorus.
	sound.TimePosition = 0
	sound:Play()
end

--[[
	The camera punch: in instantly, back out over the shared recovery.

	Day 10 · Part 1/2: this is now a one-line delegation to `Hitstop.PunchFOV`, which
	owns `Camera.FieldOfView` outright. The whole idempotency argument this function's
	header used to make - capture the base once per sequence so a second deflect
	inside a live punch cannot re-base off the already-punched value - is now
	enforced in one place rather than being re-derived per module.

	The method is kept rather than deleted so the call site in `CombatController` still
	reads "a deflect happened, do its feedback", and so the split stays legible:
	`DeflectFeedback` is the deflect's *feedback list*, `Hitstop` owns the camera and
	the freeze. The sound is still played here because nothing else touches it.
]]
function DeflectFeedback.Punch()
	Hitstop.PunchFOV()
end

return DeflectFeedback
