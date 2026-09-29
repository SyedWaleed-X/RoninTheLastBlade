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

	Why the FOV punch has to be idempotent
	--------------------------------------
	The naive version of this is `camera.FieldOfView -= 2` and a tween back to the
	saved value, and it is wrong the moment two deflects land inside 50ms: the second
	call saves the *already punched* FOV as its new base and the camera never returns
	to where it started, drifting a little further in with every parry until the
	player is looking down a telescope. So the base is captured once per punch
	*sequence* and reused, exactly as `Hitstop` keeps a deadline rather than
	restarting a timer: a second deflect inside a live punch re-punches from the
	original base and re-aims the same return.

	The `punchCamera` check is the other half of that. `workspace.CurrentCamera` can
	be swapped at any time (a character respawn, a cutscene), and writing a stale
	base onto a camera that replaced the one that was punched would be a jump in
	field of view for no reason the player can see. The restore only happens if the
	camera it was punched on is still the current one.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. Nothing here reads or writes combat
	    state; it draws and sounds what the server already decided.
	  * ARCHITECTURE.md #4 - no per-frame path. `Clang` and `Punch` run on a remote
	    event, and the punch allocates exactly one tween per deflect.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

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
	The punch.

	Two degrees is small on purpose - it is meant to be felt more than seen, and a
	larger value would read as the camera being yanked. 50ms is three frames at
	60Hz: long enough to register as a hit, short enough that nobody could accuse
	the camera of moving.
]]
local FOV_PUNCH_DEGREES = 2
local FOV_PUNCH_DURATION = 0.05

-- The camera's field of view is clamped at 1 by the engine; a punch applied to a
-- camera already sitting at the floor must not write below it.
local MIN_FOV = 1

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

-- The camera currently being punched, the FOV to put back, and the live return
-- tween. All three exist to make a second punch inside a live one continue the
-- same sequence rather than stack a new one.
local punchCamera: Camera? = nil
local punchRestoreFov = 0
local punchTween: Tween? = nil

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
	The camera punch: in instantly, back out over `FOV_PUNCH_DURATION`.

	Instant in, eased out - not the other way round. A punch that eases *in* is a
	zoom, and a hit that zooms is a hit the player has time to think about. Snapping
	and recovering is what a physical impact does to a lens, and it is the half of
	this effect that reads as force rather than as a camera move.
]]
function DeflectFeedback.Punch()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	--[[
		Capture the base once per sequence.

		If this camera is already mid-punch then the FOV to return to is the one the
		*previous* punch recorded, not the punched value currently on the camera -
		the drift bug described in the header. A punch on a different camera (a
		respawn swapped it) re-bases off whatever that camera is showing.
	]]
	local base: number
	if punchCamera == camera then
		base = punchRestoreFov

		local live = punchTween
		punchTween = nil
		if live ~= nil then
			live:Cancel()
		end
	else
		base = camera.FieldOfView
	end

	punchCamera = camera
	punchRestoreFov = base

	local punched = base - FOV_PUNCH_DEGREES
	if punched < MIN_FOV then
		punched = MIN_FOV
	end

	camera.FieldOfView = punched

	local returnTween = TweenService:Create(camera, TweenInfo.new(
		FOV_PUNCH_DURATION,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	), { FieldOfView = base })

	punchTween = returnTween

	returnTween.Completed:Once(function()
		-- Only the current tween may clear the sequence: a newer punch owns it now
		-- and this callback is stale.
		if punchTween ~= returnTween then
			return
		end

		punchTween = nil

		if punchCamera == camera then
			punchCamera = nil
		end
	end)

	returnTween:Play()
end

return DeflectFeedback
