--!strict

--[[
	CombatAudio
	Ronin — The Last Blade · the 4-part combat sound palette (Day 10 · Part 2/2)

	`AudioEngine` builds the graph. This file is the traffic on it: four cues,
	played in 3D at the position the impact actually happened.

	    Deflect       two blades meeting      high metallic ring
	    Block         a guard absorbing mass  dull, almost no top end
	    Slash         the blade connecting     a fast cut
	    PostureBreak  the guard failing       one heavy rupture

	Why this is a client module at all
	-----------------------------------
	Because a sound the *server* plays is not spatial. A `Sound` created on the
	server is heard by every client at the same relative volume with no rolloff
	and no panning, because the server has no idea where each player's camera is.
	The whole reason to place a clash sound at the contact point is so a duel
	heard from across the arena arrives as a detail while a duel at arm's length
	arrives as a wall - and that requires a listener, which only exists on the
	client. `DeflectFeedback`'s header reaches the same conclusion from the other
	direction.

	So the split is: the server owns *what the mix is*, the client owns *where
	the sounds are heard from*. Neither half is redundant and neither can do the
	other's job.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. It draws no sparks, moves no
	    joint and reads no combat state; it is told a cue and a position.
	  * ARCHITECTURE.md #4 - no per-frame path. `PlayCue` runs on a combat
	    remote, and there is no `Heartbeat` connection anywhere in this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
The bus, for the two cues this module triggers itself.

Required here rather than passed in, and the dependency is one-way:
`CombatStateBus` requires `InputBuffer` and knows nothing about audio, so
this cannot cycle. `CombatController` requires both this module and the bus
and sees one instance of each either way, because `require` caches.

Subscribing at module scope rather than per-character is deliberate:
`SubscribeHits` publishes into a list that outlives a respawn, and the slash
cue has no per-character state of its own to rebind. Subscribing once is
therefore correct rather than merely convenient, and it avoids the
double-subscribe a per-spawn subscription would produce across respawns.
]]
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)

type CombatCue = AttackConfig.CombatCue
type CombatSoundCue = AttackConfig.CombatSoundCue
type CombatSoundPalette = { [CombatCue]: CombatSoundCue }

local CombatAudio = {}

--[[
	The palette, read once.

	`AttackConfig` is a ModuleScript already required by other PlayerScripts, so
	this resolves on the first line of this file. The `:: ModuleScript` cast is
	the same one every other module in the project uses to tell `--!strict` that
	the child is a module rather than an untyped `Instance`.
]]
local PALETTE: CombatSoundPalette = AttackConfig.COMBAT_SOUND_PALETTE

--[[
	One playable voice: a `Sound` and the invisible host part that gives it a
	position in the world.

	The host is a real `Part` rather than the `Sound` being parented to an
	existing character part because a clash belongs to a *place*, not to a body.
	Parenting to the attacker's torso would drag the sound along with them as the
	stagger tween reels them backwards, and the sound would appear to slide out
	of the point where the steel actually met.
]]
type Voice = {
	Sound: Sound,
	Host: Part,
	Busy: boolean,
	StartedAt: number,
	Cue: CombatCue,
}

--[[
	The pool, per cue, keyed by cue name.

	Pooled *per cue* rather than shared, and that is the load-bearing decision.
	`DeflectFeedback` pools a single `Sound` and restarts it, which is right
	there because a deflect is one sound and restarting it is the desired
	behaviour - a second clash should cut the first. That trick does not
	generalise here:

	  * There are four cues of different lengths. Sharing one pool means a
	    posture rupture is cancelled by a slash 0.29s later, and the rupture is
	    the most important sound in the game.
	  * Position is per-voice. One host part cannot be moved to a second impact
	    while it is still ringing, so two clashes at different places inside the
	    same 1.3s tail would collapse into one sound at one place.

	Built lazily on a cue's first play rather than all four up front: a session
	that never breaks a guard should not pay for a posture-rupture `Sound` it
	will never hear.
]]
local pools: { [CombatCue]: { Voice } } = {}

--[[
	The resolved combat group, and whether the failure was already reported.

	`nil` here is a *sticky* lookup rather than a retry-per-play: the group is
	built once on the server at boot, so if it was missing on the first clash it
	will still be missing on the hundredth, and re-running `FindFirstChild` on
	every impact forever buys nothing but repeated work in the hot path.
]]
local combatGroup: SoundGroup? = nil
local warnedMissingGroup = false

--[[
	Finds `RoninCombatSFX` by walking the same path `AudioEngine` built it.

	Walked rather than found by a flat `FindFirstChild` over `SoundService`
	precisely because the tree is *nested*: `CombatSFX` is a child of
	`RoninMaster`, so a flat search would miss it and report the mix as missing
	on a tree that is perfectly healthy. The failure mode of getting this lookup
	wrong is "no audio, and no warning that explains why".
]]
local function resolveCombatGroup(): SoundGroup?
	if combatGroup ~= nil then
		return combatGroup
	end

	local master = SoundService:FindFirstChild(AttackConfig.AUDIO_GROUP_MASTER)
	if master == nil then
		return nil
	end

	local group = master:FindFirstChild(AttackConfig.AUDIO_GROUP_COMBAT_SFX)
	if group == nil or not group:IsA("SoundGroup") then
		return nil
	end

	combatGroup = group :: SoundGroup
	return combatGroup
end

--[[
	A position is usable if it is finite.

	Tested on `Magnitude` rather than per-axis because a NaN on any axis
	propagates into the magnitude, and an infinite position would ask the engine
	to place a part somewhere it has to make room for. Combat positions arrive
	off remotes and off geometry; `GuardSparks` refuses the same class of value
	for the same reason in its `isUsablePosition`.
]]
local function isUsablePosition(position: Vector3): boolean
	local magnitude = position.Magnitude
	return magnitude == magnitude and magnitude < math.huge
end

--[[
	Builds one voice for a cue: an invisible anchored host plus its `Sound`.

	The host's flags are the full "invisible and inert" set - anchored (it must
	not fall), `CanCollide`/`CanTouch`/`CanQuery` all false (it must not be hit,
	touched, or found by a hitbox sweep) and transparent. `CanQuery = false` is
	the one that actually matters for correctness: a queryable part sitting in
	the world is a target that `BladeHitbox`'s spatial sweep could select, and a
	sound host that a katana can hit is a bug that would show up as phantom
	blade contacts during exactly the fast exchanges this system exists to sell.
]]
local function createVoice(cue: CombatCue, entry: CombatSoundCue, index: number): Voice
	local host = Instance.new("Part")
	host.Name = string.format("RoninAudioHost_%s_%d", cue, index)
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanTouch = false
	host.CanQuery = false
	host.CastShadow = false

	local sound = Instance.new("Sound")
	sound.Name = string.format("RoninCombat_%s_%d", cue, index)
	sound.SoundId = entry.Id
	sound.Volume = entry.Volume
	sound.PlaybackSpeed = entry.PlaybackSpeed
	sound.Looped = false

	--[[
		`InverseTapered` rather than the default. Verified against the live
		enum on this build, whose members are `Inverse`, `Linear`,
		`LinearSquare` and `InverseTapered` - the name is `InverseTapered` with a
		"ed", and the value is 3. The default curve drops off linearly, which
		makes a mid-distance clash sound quieter than a distant one on a steep
		enough gradient; the tapered curve keeps a point-blank impact dominant
		over a neighbouring one, which is the only relationship that matters in
		a duel.
		]]
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = AttackConfig.AUDIO_MIN_DISTANCE
	sound.RollOffMaxDistance = AttackConfig.AUDIO_MAX_DISTANCE

	--[[
		Assigned before `Parent`, and to the resolved group rather than to
		`SoundService`. Assigning after parenting would play the first moments of
		the sound outside the mix - unducked and unlimitered - which is exactly
		the kind of first-frame artefact that gets blamed on the mix rather than
		on the ordering.
	]]
	local group = resolveCombatGroup()
	if group ~= nil then
		sound.SoundGroup = group
	elseif not warnedMissingGroup then
		warnedMissingGroup = true
		warn("[AUDIO] RoninCombatSFX was not found; combat sounds will play ungrouped and will NOT be limited or ducked. Is AudioEngine running?")
	end

	host.Parent = workspace
	sound.Parent = host

	local voice: Voice = {
		Sound = sound,
		Host = host,
		Busy = false,
		StartedAt = 0,
		Cue = cue,
	}

	--[[
		The completion signal, subscribed once here at construction.

		`Ended` is the engine's own signal for "this sample finished", so the
		busy flag tracks real playback state with no per-frame bookkeeping at
		all (ARCHITECTURE.md #4). Deciding it by elapsed wall-clock instead would
		drift against `PlaybackSpeed` - a 1.2x-pitched deflect finishes about 17%
		earlier than its nominal length says it will.
	]]
	sound.Ended:Connect(function()
		voice.Busy = false
	end)

	return voice
end

--[[
	Claims a voice from a cue's pool, stealing the oldest if the pool is full.

	Stealing rather than dropping is the decision that matters. Dropping the
	twenty-first impact would be audible as a *gap* in a fast chain - the player
	would hear a rhythm with a hole in it and read the hole as a dropped frame.
	Stealing means the oldest ring is cut off by the newest impact, which is what
	a real mix does anyway: the most recent clash is the one the player is
	reading, and the stale tail underneath it was never carrying information.
]]
local function claimVoice(cue: CombatCue, entry: CombatSoundCue): Voice?
	local pool = pools[cue]

	if pool == nil then
		pool = {}
		pools[cue] = pool
	end

	for index = 1, #pool do
		local voice = pool[index]
		if voice ~= nil and not voice.Busy then
			return voice
		end
	end

	if #pool < AttackConfig.AUDIO_VOICE_LIMIT then
		local voice = createVoice(cue, entry, #pool + 1)
		table.insert(pool, voice)
		return voice
	end

	--[[
		Full: steal the oldest voice in this cue's pool. Scoped to the cue
		deliberately - a slash must never steal a ringing posture rupture, since
		the rupture is the sound that tells the player their guard just failed
		and cutting it for a 0.29s cut would erase the most important signal in
		the game.
	]]
	local oldest: Voice? = nil

	for index = 1, #pool do
		local voice = pool[index]
		if voice ~= nil then
			if oldest == nil or voice.StartedAt < oldest.StartedAt then
				oldest = voice
			end
		end
	end

	return oldest
end

--[[
	How many cues this client has been asked to play, ever.

	Never reset. The chaos suite compares it across its twenty impacts to prove
	each one actually reached the pool rather than being short-circuited by a bad
	position or an unknown cue - a suite that only checked "no error was
	printed" would pass just as happily on twenty silent no-ops.

	Declared before `PlayCue` rather than after it purely so the reader meets the
	state before the function that mutates it.
]]
CombatAudio.PlayCount = 0

--[[
	Plays one cue at one position.

	The single public entry point, and everything the palette needs to be correct
	is decided here rather than at the call sites:

	  * an unusable position plays nothing rather than throwing - a combat
	    remote is not a trusted source of geometry, and one bad Vector3 must not
	    take the deflect's sparks and hitstop down with it;
	  * an unknown cue name plays nothing and says so, rather than indexing a
	    frozen table with nil and erroring inside a hit path;
	  * the voice is positioned *before* `Play`, because a sound that starts at
	    the origin and is teleported to the impact afterwards plays its first
	    milliseconds in the wrong place - and on a 0.29s slash that is a quarter
	    of the sound in the wrong place.
]]
function CombatAudio.PlayCue(cue: CombatCue, position: Vector3)
	if not isUsablePosition(position) then
		return
	end

	local entry = PALETTE[cue]
	if entry == nil then
		warn(string.format("[AUDIO] Unknown combat cue '%s'; nothing played.", tostring(cue)))
		return
	end

	local voice = claimVoice(cue, entry)
	if voice == nil then
		return
	end

	--[[
		A host destroyed by a teardown mid-clash leaves a voice that can never be
		positioned again. Bailing here keeps the pool from filling with dead
		entries until every later impact steals a corpse and goes silent.
	]]
	local host = voice.Host
	local sound = voice.Sound

	if host.Parent == nil or sound.Parent == nil then
		return
	end

	host.CFrame = CFrame.new(position)

	voice.Busy = true
	voice.StartedAt = os.clock()
	CombatAudio.PlayCount += 1

	sound.TimePosition = 0
	sound:Play()
end

--[[
	Live voice occupancy: how many are sounding, and how many exist.

	Two numbers rather than one because the chaos suite asserts on the
	difference. `playing` proves the cap is being honoured under load (it must
	never exceed the limit) and `total` proves the pool actually grew to serve
	the burst rather than silently dropping impacts the whole way through.
]]
function CombatAudio:GetVoiceStats(): (number, number)
	local playing = 0
	local total = 0

	for _, pool in pairs(pools) do
		for index = 1, #pool do
			local voice = pool[index]
			if voice ~= nil then
				total += 1
				if voice.Sound.IsPlaying then
					playing += 1
				end
			end
		end
	end

	return playing, total
end

--[[
	Telemetry for the chaos suite.

	Reads the *live* graph rather than restating the config, which is the whole
	point: a suite that asserted `AttackConfig.AUDIO_LIMITER_RATIO == 20` would
	pass on a client where the tree never replicated and no limiter existed at
	all. These values come off the actual `SoundGroup` and `CompressorSoundEffect`
	objects, so `LimiterPresent = false` on a client that failed to receive the
	mix is a real, catchable failure.
]]
function CombatAudio:GetMixDiagnostics(): { [string]: unknown }
	local master = SoundService:FindFirstChild(AttackConfig.AUDIO_GROUP_MASTER)
	local combat = resolveCombatGroup()

	local ambiencePresent = false
	local duckSideChainPresent = false
	local limiterPresent = false
	local limiterThreshold = 0

	if master ~= nil then
		local ambience = master:FindFirstChild(AttackConfig.AUDIO_GROUP_AMBIENCE)
		ambiencePresent = ambience ~= nil

		--[[
			The duck is verified through *its own* `SideChain` read rather than
			through the presence of the compressor. A duck that exists but failed
			to bind its sidechain is the failure this whole system is most likely
			to produce and the one a presence check would sail straight past: the
			ambience plays, the combat plays, and nothing is ducked.
		]]
		if ambience ~= nil then
			local duck = ambience:FindFirstChild("RoninAmbienceDuck")
			if duck ~= nil and duck:IsA("CompressorSoundEffect") then
				duckSideChainPresent = duck.SideChain ~= nil
			end
		end

		local limiter = combat and combat:FindFirstChild("RoninCombatLimiter") or nil
		if limiter ~= nil and limiter:IsA("CompressorSoundEffect") then
			limiterPresent = true
			limiterThreshold = limiter.Threshold
		end
	end

	return {
		MasterPresent = master ~= nil,
		CombatGroupPresent = combat ~= nil,
		AmbienceGroupPresent = ambiencePresent,
		DuckSideChainPresent = duckSideChainPresent,
		LimiterPresent = limiterPresent,
		LimiterThreshold = limiterThreshold,
		VoiceLimit = AttackConfig.AUDIO_VOICE_LIMIT,
	}
end

--[[
	Two of the four cues are triggered from inside this module, and it is worth
	saying why only two.

	`Block` arrives on `GuardClashEvent`, which the server broadcasts to *every*
	client with a `Vector3`, and `Slash` arrives on the local blade-hit seam.
	Both are things that happened somewhere in the world and are the same event
	for everyone who can hear them, so neither needs to know anything about the
	local character - and a module that already owns the palette should own the
	triggers it can own without inventing a dependency.

	`Deflect` and `PostureBreak` are the other two, and they are deliberately
	NOT triggered here. Those two are *asymmetric*: only the defender hears the
	deflect as a reward and only the defender's guard can rupture, and the
	deflect is also what ignites the trail. That asymmetry is a combat rule, and
	`CombatController` is where combat rules are observed - so those two cues are
	played from its two remote handlers, which already own the asymmetry for the
	FOV punch and the camera trauma.

	Splitting the palette across two files is the cost of that decision, and it
	is the right trade: the alternative is a second combat observer inside this
	module purely to re-derive "am I the defender", which would be the exact
	two-writers problem Day 10 spent its first half fixing.
]]
local function subscribeToWorldCues()
	local clashEvent = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_GUARD_CLASH_EVENT)

	if clashEvent == nil or not clashEvent:IsA("RemoteEvent") then
		print("[AUDIO] GuardClashEvent not found; the block cue is disabled.")
	else
		clashEvent.OnClientEvent:Connect(function(position: any)
			--[[
				Type-checked rather than cast. This is a broadcast remote, and
				`CombatAudio.PlayCue` accepts a `Vector3`; if a non-Vector3 ever
				arrived, passing it straight through would reach the magnitude
				arithmetic inside `isUsablePosition` and produce a NaN position
				rather than a clean refusal (ARCHITECTURE.md #2).
			]]
			if typeof(position) ~= "Vector3" then
				return
			end

			CombatAudio.PlayCue("Block", position)
		end)
	end

	--[[
		The slash, off the local blade-hit seam.

		`BladeHitbox` publishes this record the instant its sweep touches a
		target, carrying the contact `Position` directly - which is exactly the
		point a cut happened, and better than any root-part approximation.
	]]
	local unsubscribe = CombatStateBus.SubscribeHits(function(event: CombatStateBus.BladeHitEvent)
		CombatAudio.PlayCue("Slash", event.Position)
	end)

	return unsubscribe
end

--[[
	Wires the world cues up at load.

	Unconditional, and deliberately not wrapped in an availability guard. This
	module is reached only through `require`, so by the time this line runs
	the bus is a resident module and there is nothing to wait for. Neither
	cue trigger needs a spawned character either: `GuardClashEvent` is a
	broadcast, and `SubscribeHits` publishes into a list that is valid before
	a character exists. Guarding on `GetActiveMachine()` would have suppressed
	both cues for the whole of the first spawn, which is exactly when the
	player is learning what a block sounds like.

	The handle is retained rather than discarded so the subscription is
	visibly owned and can be released if a teardown is ever added. It stays
	nil: these listeners live as long as this module, which lives as long as
	the client.
]]
local worldUnsubscribe: (() -> ())? = subscribeToWorldCues()

return CombatAudio
