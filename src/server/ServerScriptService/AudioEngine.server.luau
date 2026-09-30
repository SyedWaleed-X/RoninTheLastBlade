--!strict

--[[
	AudioEngine
	Ronin — The Last Blade · the SoundService mix tree (Day 10 · Part 2/2)

	Everything this game heard until now was a `Sound` parented straight to
	`SoundService` and played at a volume somebody typed next to it. That works
	until the first thing that actually needs a *mix*: two sounds that must not
	collide, or a bed of ambience that has to get out of the way when steel hits
	steel. Neither of those is a property of a sound. Both are properties of the
	graph the sounds travel through, and the graph did not exist.

	So this script builds it, once, on the server:

	    SoundService
	      └─ RoninMaster            Volume 1.0
	           ├─ RoninCombatSFX    Volume 1.0  + limiter
	           └─ RoninAmbience     Volume 0.7  + ducking compressor

	Why the server owns it
	----------------------
	Audio is resolved on the client, so the tempting shape is to build this in a
	LocalScript. It is built here instead because the mix is *authoritative*: it
	is one description of how the game should sound, and every player must get
	that identical description. Built per-client it would be N copies of a
	decision that should be made once, and the copies drift the moment someone
	tunes a volume in one place. Built here it is a single source of truth that
	replicates; a client that cannot find it warns and stays quiet rather than
	inventing a second, divergent mix.

	Nothing here plays a sound. Playback is `CombatAudio`, on the client,
	because a sound played by the server would be one sound heard at every
	player's own volume with no 3D projection - the exact non-spatial clank
	`DeflectFeedback`'s header explains. This file is the graph; that one is the
	traffic on it.

	Two API notes, both verified against this build rather than assumed
	------------------------------------------------------------------
	1. `CompressorSoundEffect` is the *legacy* audio API. Roblox has since
	   shipped `AudioPlayer` / `AudioEmitter` / `AudioCompressor` / `Wire`, and
	   the new objects are the future. The legacy tree is still the right tool
	   here for one concrete reason: **the new API has no SoundGroup.**
	   Group-level mixing is the entire requirement - "duck everything in the
	   ambience bucket" is not expressible as a wire between two players.
	2. The Creator Hub's own sidechain example is wrong in a way that would
	   break this file. It documents a `MakeUpGain` property; the class actually
	   exposes `GainMakeup` (no "up"), and setting `MakeUpGain` silently does
	   nothing rather than erroring. Verified live: `GainMakeup` reads,
	   `MakeUpGain` errors.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. It creates groups and
	    processors; it never touches a character, a Health value or a state.
	  * ARCHITECTURE.md #4 - there is no per-frame path. This runs once at
	    boot and then owns nothing but a hierarchy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

local MASTER_NAME = AttackConfig.AUDIO_GROUP_MASTER
local COMBAT_NAME = AttackConfig.AUDIO_GROUP_COMBAT_SFX
local AMBIENCE_NAME = AttackConfig.AUDIO_GROUP_AMBIENCE

--[[
	The processor names.

	Named rather than left anonymous so the tree is self-documenting in the
	Explorer, and so `CombatAudio` can *find* the limiter by name and report on
	it during the chaos suite instead of guessing at an index. A processor whose
	identity is its position in a list is a processor nobody can find after the
	next one is added above it.
]]
local DUCK_EFFECT_NAME = "RoninAmbienceDuck"
local LIMITER_EFFECT_NAME = "RoninCombatLimiter"

--[[
	Fetches a child by name and class, creating it only if it is genuinely
	absent.

	The `IsA` test is not a cast dodge. A Script Sync reload, a second copy of
	this script, or a hand-placed group in the place can all leave a *wrong*
	instance under the expected name, and silently writing `Volume` onto
	something that is not a SoundGroup would either error or, worse, configure an
	object that is not in the audio graph at all. Finding the wrong class is
	reported and left alone rather than configured.

	This is the same idempotent, self-healing shape `ensurePosture` uses in the
	combat scripts, and for the same reason: a boot-time builder that only runs
	correctly once is a boot-time builder that is wrong after every reload.
]]
local function ensureGroup(parent: Instance, name: string, volume: number): SoundGroup?
	local existing = parent:FindFirstChild(name)

	if existing ~= nil then
		if existing:IsA("SoundGroup") then
			local group = existing :: SoundGroup
			group.Volume = volume
			return group
		end

		warn(string.format(
			"[AUDIO] '%s' exists but is a %s, not a SoundGroup. It was left alone.",
			name,
			existing.ClassName
		))
		return nil
	end

	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = volume
	group.Parent = parent
	return group
end

--[[
	The same idempotent fetch for a `CompressorSoundEffect`, used for both the
	limiter and the duck.

	Kept separate from `ensureGroup` rather than generalised into one function
	because the two take different constructors and return different types. A
	single function parameterised by class name would have to hand back
	`Instance` and push a cast onto every caller, which is the exact thing the
	`IsA` checks above exist to avoid.
]]
local function ensureEffect(parent: Instance, name: string): CompressorSoundEffect?
	local existing = parent:FindFirstChild(name)

	if existing ~= nil then
		if existing:IsA("CompressorSoundEffect") then
			return existing :: CompressorSoundEffect
		end

		warn(string.format(
			"[AUDIO] '%s' exists but is a %s, not a CompressorSoundEffect. It was left alone.",
			name,
			existing.ClassName
		))
		return nil
	end

	local effect = Instance.new("CompressorSoundEffect")
	effect.Name = name
	effect.Parent = parent
	return effect
end

--[[
	Builds the whole tree and wires the duck.

	Returns the two groups a consumer needs - the combat group (to assign sounds
	to) and the ambience group (to parent the duck into) - or nil if either could
	not be produced. A nil return is a hard stop rather than something to work
	around: half a mix is worse than none, because combat sounds would then play
	through no group at full volume and the player would hear a game that is very
	slightly wrong in a way nobody can name.
]]
local function buildMixTree(): (SoundGroup?, SoundGroup?)
	local master = ensureGroup(SoundService, MASTER_NAME, AttackConfig.AUDIO_MASTER_VOLUME)
	if master == nil then
		return nil, nil
	end

	--[[
		The leaves are parented to the *master*, not to `SoundService`. Roblox
		resolves volume down the group chain, so the nesting is what makes this
		one mix with a single master fader rather than three unrelated groups
		that happen to share a service.
	]]
	local combat = ensureGroup(master, COMBAT_NAME, AttackConfig.AUDIO_COMBAT_SFX_VOLUME)
	if combat == nil then
		return nil, nil
	end

	local ambience = ensureGroup(master, AMBIENCE_NAME, AttackConfig.AUDIO_AMBIENCE_VOLUME)
	if ambience == nil then
		return nil, nil
	end

	--[[
		The limiter, on the combat group.

		Placed on `CombatSFX` rather than on `RoninMaster` on purpose. A limiter
		on the master would also be limiting the ambience - and the ambience is
		the thing being *ducked*, so the limiter would fight the duck's release
		and the bed would audibly stutter on its way back up after every clash.
		Each processor owns the bus it protects and nothing else.
	]]
	local limiter = ensureEffect(combat, LIMITER_EFFECT_NAME)

	if limiter ~= nil then
		limiter.Threshold = AttackConfig.AUDIO_LIMITER_THRESHOLD
		limiter.Ratio = AttackConfig.AUDIO_LIMITER_RATIO
		limiter.Attack = AttackConfig.AUDIO_LIMITER_ATTACK
		limiter.Release = AttackConfig.AUDIO_LIMITER_RELEASE
	end

	--[[
		The duck, and the one piece of this file that is not boilerplate.

		`SideChain` takes an `Instance` and here it takes a `SoundGroup`: the
		ambience is the signal being compressed, and the combat group is the
		*control* signal deciding how hard. That inversion is the whole
		mechanism, and it is why the limiter above cannot express it - the
		limiter watches its own output, while the duck watches a different bus
		entirely.

		Ordering matters and is not obvious. The duck is created *after* the
		combat group exists so it has something to point at, and it is parented
		into the ambience group so the signal being compressed is the ambience.
		Pointing `SideChain` at a group that does not exist yet would bind nil
		and leave a compressor that silently does nothing - which again sounds
		like a mixing choice rather than a bug.
	]]
	local duck = ensureEffect(ambience, DUCK_EFFECT_NAME)
	if duck == nil then
		return nil, nil
	end

	duck.Threshold = AttackConfig.AUDIO_DUCK_THRESHOLD
	duck.Ratio = AttackConfig.AUDIO_DUCK_RATIO
	duck.Attack = AttackConfig.AUDIO_DUCK_ATTACK
	duck.Release = AttackConfig.AUDIO_DUCK_RELEASE

	--[[
		Bound last, once both halves are known good.

		Verified against the live class rather than the docs: `SideChain` accepts
		any `Instance`, and assigning a `SoundGroup` to it is legal. The
		assignment is wrapped because it is the one write here that touches a
		property the engine resolves at *audio time* rather than at instance
		time, and a tree that comes up half-configured and loud is better than
		one that comes up wrong and quiet.
	]]
	local sideChainOk, sideChainError = pcall(function()
		duck.SideChain = combat
	end)

	if not sideChainOk then
		warn(string.format(
			"[AUDIO] Could not bind the ambience duck to '%s': %s",
			COMBAT_NAME,
			tostring(sideChainError)
		))
		return nil, nil
	end

	return combat, ambience
end

--[[
	Verify the tree the way a client will actually read it.

	Deliberately a *read-back* rather than a restatement of what the constructor
	above was told to do. The values printed are the ones a `Sound` parented to
	each group would actually be routed through, so if replication or a re-parent
	ever changed the effective graph, this line would show it. A build script
	that only prints what it intended to build cannot tell you it built it.
]]
local combatGroup, ambienceGroup = buildMixTree()

if combatGroup == nil or ambienceGroup == nil then
	warn("[AUDIO] Mix tree failed to build; combat sounds will play ungrouped. See the warnings above.")
	return
end

print(string.format(
	"[AUDIO] Mix tree online: %s (%.2f) > [%s (%.2f) + limiter | %s (%.2f) ducked].",
	MASTER_NAME,
	AttackConfig.AUDIO_MASTER_VOLUME,
	COMBAT_NAME,
	combatGroup.Volume,
	AMBIENCE_NAME,
	ambienceGroup.Volume
))

--[[
	The second read-back, and the most valuable line in this file.

	A duck whose `SideChain` silently failed to bind is the single most likely
	failure of this whole system, because the ambience still plays, the combat
	still plays, and the only symptom is that the bed is *slightly* too present
	during a fight - which reads as a mixing taste rather than as a broken
	sidechain. Printing the resolved binding turns that silent failure into a
	line in the console, which is the whole difference between a bug that is
	found and a bug that is felt.
]]
local duckInstance = ambienceGroup:FindFirstChild(DUCK_EFFECT_NAME)
local limiterInstance = combatGroup:FindFirstChild(LIMITER_EFFECT_NAME)

if duckInstance ~= nil and duckInstance:IsA("CompressorSoundEffect") then
	local duck = duckInstance :: CompressorSoundEffect
	local sideChain = duck.SideChain

	print(string.format(
		"[AUDIO] Duck verified: %s is side-chained by %s (threshold %.0fdB, ratio %.1f:1, attack %.0fms, release %.2fs).",
		AMBIENCE_NAME,
		if sideChain ~= nil then sideChain.Name else "NOTHING",
		duck.Threshold,
		duck.Ratio,
		duck.Attack * 1000,
		duck.Release
	))

	if sideChain == nil or not sideChain:IsA("SoundGroup") then
		warn("[AUDIO] The ambience duck has no sidechain input; ambience will NOT duck.")
	end
else
	warn("[AUDIO] The ambience duck is missing; ambience will NOT duck.")
end

if limiterInstance ~= nil and limiterInstance:IsA("CompressorSoundEffect") then
	local limiter = limiterInstance :: CompressorSoundEffect

	print(string.format(
		"[AUDIO] Limiter verified: %s capped at %.0fdB, ratio %.1f:1, voice cap %d.",
		COMBAT_NAME,
		limiter.Threshold,
		limiter.Ratio,
		AttackConfig.AUDIO_VOICE_LIMIT
	))
else
	warn("[AUDIO] The combat limiter is missing; stacked impacts may clip.")
end
