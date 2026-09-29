--!strict

--[[
	GuardSparks
	Ronin — The Last Blade · guard-clash impact (Day 6 · Part 2/2)

	Two katana meeting is the single most important piece of feedback in a game about
	blocking, and this is the effect that carries it. When `HitValidator` resolves a
	frontal block it has decided, authoritatively, that no damage was dealt - but a
	defender who takes zero damage with no visible reaction cannot tell that from being
	ignored, and an attacker cannot tell a block from a miss. The spark is what turns
	a server-side subtraction into something a player can read.

	Who decides what, and who draws it
	------------------------------------
	The **server** decides *that* a clash happened and *where*. It cannot decide what
	that looks like, and it should not try: this module runs on every client, so the
	same block renders for the attacker, the defender and everyone watching. That
	division is the whole reason the effect lives here and not in `HitValidator` -
	a ParticleEmitter created on the server would be one simulation replicated, rather
	than one effect each client renders at its own frame rate.

	Payload validation (ARCHITECTURE.md #2)
	----------------------------------------
	Exactly one field crosses the wire: a Vector3. It is checked for its type and for
	being a finite, in-world position before anything is parented, because a position
	is about to be written into a CFrame and a malformed one is an error rather than a
	bad-looking spark. Nothing off this remote is ever used as anything but a point.

	Why the burst is pooled rather than created per clash
	-----------------------------------------------------
	`Instance.new` per clash would allocate a Part, an Attachment and an emitter on
	every block, and a guard-heavy fight is exactly the situation that produces many
	clashes in a short window. One reusable emitter is parented to a single invisible
	part under the character and simply moved: `Emit` is then a method call on an
	emitter that already exists, which is the difference between a combat effect and
	a garbage-collection event.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. This module draws a burst the server
	    already decided on; it cannot make a hit land, block, or break.
	  * ARCHITECTURE.md #4 - no per-frame path. The emitter is idle (Rate 0) between
	    bursts and is woken by `Emit` for a few hundredths of a second.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
	Burst shape.

	WHITE -> YELLOW -> ORANGE -> RED is the standard read for struck metal: the
	white-hot core is the contact, the orange body is the shower, and the dark red
	tail is cooling debris. `LightEmission = 1` is what makes them genuinely *bright*
	- without it these are coloured dots on a dark scene, and with it they read as
	heat.

	`Speed` and `SpreadAngle` together make the burst go *out* from the contact in a
	cone rather than falling straight down, which is what sells the force of the
	collision: a clash throws sparks away from the impact, not toward the floor.
]]
local SPARK_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 235)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 231, 138)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 146, 26)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 32, 0)),
})

local SPARK_SIZE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.45),
	NumberSequenceKeypoint.new(0.4, 0.3),
	NumberSequenceKeypoint.new(1, 0),
})

--[[
	How long the sparks live, and how long the emitter is kept alive after the last
	burst.

	The emitter is only retired on a timeout, never mid-burst, so a second clash while
	the first burst's sparks are still in the air re-uses the same emitter and simply
	adds to the shower. Destroying it per clash would cut the first burst off halfway
	through its fade - which is the exact frame the eye reads as the impact.
]]
local SPARK_LIFETIME = NumberRange.new(0.08, 0.26)
local SPARK_COUNT = 14
local EMITTER_LIFETIME = 1.2

local sparkHost: Part? = nil
local sparkEmitter: ParticleEmitter? = nil

--[[
	Bumped on every burst. A retire timer only destroys the emitter if the stamp it
	was scheduled with is still the current one, so a flurry of blocks keeps one
	emitter alive across all of them rather than letting the first clash's cleanup
	destroy the emitter the second is about to use.

	A counter rather than an `Enabled` toggle because the emitter's `Enabled` never
	changes: `Rate = 0` already keeps it silent, and `Emit` is the wake-up.
]]
local sparkGeneration = 0

--[[
	Builds the single reusable emitter, parented to an invisible anchored part under
	the character.

	Anchored and non-colliding so it can never be pushed by, or push, a body. `CanQuery`
	off is not optional: the part sits in Workspace, and a spark the blade's raycast
	could strike would be a phantom self-hit reported to the server as a real contact.
	An emitter parented to the character needs no per-frame position write, because it
	*is* on the character - which is also why it is parented to the character rather
	than to a free-floating part this module had to move by hand.
]]
local function ensureEmitter(): ParticleEmitter?
	local existing = sparkEmitter
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end

	local host = Instance.new("Part")
	host.Name = "RoninSparkHost"
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanTouch = false
	host.CanQuery = false
	host.CastShadow = false
	host.Parent = character

	local attachment = Instance.new("Attachment")
	attachment.Name = "RoninSparkOrigin"
	attachment.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RoninGuardSparks"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = SPARK_COLOR
	emitter.Size = SPARK_SIZE
	emitter.Lifetime = SPARK_LIFETIME
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Speed = NumberRange.new(9, 20)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Acceleration = Vector3.new(0, -34, 0)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rate = 0
	emitter.Enabled = true
	emitter.ZOffset = 0.5
	emitter.Parent = attachment

	sparkHost = host
	sparkEmitter = emitter

	-- A respawn or a death destroys the host and takes the emitter with it, so the
	-- module has to forget rather than hand out a dead emitter next time.
	host.Destroying:Connect(function()
		sparkHost = nil
		sparkEmitter = nil
	end)

	return emitter
end

--[[
	Draws one clash burst at a world position.

	Rejects before touching the emitter. A NaN, an infinity or a position hundreds of
	thousands of studs out is not something to hand to `CFrame.new`, and this remote is
	the one place in the project where a malformed value can arrive unasked for. The
	`x ~= x` form is the NaN test: NaN is the only value that is not equal to itself.
]]
local function isUsablePosition(position: Vector3): boolean
	if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z then
		warn("[SPARK] Ignored a clash at a non-finite position.")
		return false
	end

	if math.abs(position.X) > 100000 or math.abs(position.Y) > 100000 or math.abs(position.Z) > 100000 then
		warn("[SPARK] Ignored a clash at an out-of-world position.")
		return false
	end

	return true
end

local function emitSparks(position: Vector3)
	if not isUsablePosition(position) then
		return
	end

	local emitter = ensureEmitter()
	local host = sparkHost
	if emitter == nil or host == nil then
		return
	end

	-- `CFrame.new` is a world frame, and assigning it to the host places the emitter
	-- exactly at the clash point regardless of which character the host is riding.
	host.CFrame = CFrame.new(position)

	sparkGeneration += 1
	local myGeneration = sparkGeneration

	-- `Rate = 0` keeps the emitter silent between clashes; `Emit` is the wake-up, and
	-- it fires a one-shot burst rather than opening a stream.
	emitter:Emit(SPARK_COUNT)

	task.delay(EMITTER_LIFETIME, function()
		-- Retire only if no later clash re-armed the emitter in the meantime. Without
		-- the stamp check, three blocks in half a second would leave two of the three
		-- bursts emitting into a destroyed emitter.
		if myGeneration ~= sparkGeneration then
			return
		end

		local currentHost = sparkHost
		if currentHost == nil then
			return
		end

		currentHost:Destroy()
	end)
end

--[[
	Day 7 · Part 1/2 — the deflect burst.

	A separate emitter rather than a brighter setting on the clash one, for one
	reason: a block and a deflect are the two most important events in a defensive
	exchange and they must never look alike. A block is "that was absorbed"; a
	deflect is "that was beaten" and it costs the attacker 25 posture. If they shared
	a burst, the single moment a player is rewarded for perfect timing would render
	identically to the moment they merely held a button.

	Three properties separate them, and each one is doing a specific job:

	  * `LightEmission = 1` on a *bluer, whiter* ramp, so the core reads as
	    over-exposed steel rather than as orange fire. The block's ramp is
	    yellow-to-red because a block is a collision; a deflect is a locked blade
	    turned aside, and the cold white core is what says "precision".
	  * `Speed 18-34` against the block's `9-20` — roughly double, which is what
	    makes the shower *fast*. A slow shower reads as debris settling; a fast one
	    reads as force.
	  * `DEFLECT_SPARK_COUNT 26` against `14`, and a longer lifetime, so the burst is
	    roughly twice as much stuff hanging in the air for twice as long. Combined
	    with the 50ms hitstop, that is a screen that stops and then fills with light.

	The pool is separate for the same reason the emitter is: a deflect that reused
	the block's pooled emitter would cancel and re-point a burst that is still
	visible, so a block and a deflect in the same 200ms would show one burst of the
	wrong colour rather than two of the right ones.
]]
local DEFLECT_SPARK_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(214, 240, 255)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(120, 190, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 90, 200)),
})

local DEFLECT_SPARK_SIZE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.7),
	NumberSequenceKeypoint.new(0.4, 0.42),
	NumberSequenceKeypoint.new(1, 0),
})

local DEFLECT_SPARK_LIFETIME = NumberRange.new(0.12, 0.38)
local DEFLECT_SPARK_COUNT = 26

local deflectHost: Part? = nil
local deflectEmitter: ParticleEmitter? = nil
local deflectGeneration = 0

--[[
	Builds the deflect's reusable emitter. Structurally identical to `ensureEmitter`
	above, including the `CanQuery = false` part (a spark host in Workspace that the
	blade's raycast could strike would be a phantom self-hit reported to the server as
	a real contact) and the `Destroying` forget, so a respawn cannot hand back a dead
	emitter.
]]
local function ensureDeflectEmitter(): ParticleEmitter?
	local existing = deflectEmitter
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end

	local host = Instance.new("Part")
	host.Name = "RoninDeflectSparkHost"
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanTouch = false
	host.CanQuery = false
	host.CastShadow = false
	host.Parent = character

	local attachment = Instance.new("Attachment")
	attachment.Name = "RoninDeflectOrigin"
	attachment.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "RoninDeflectSparks"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = DEFLECT_SPARK_COLOR
	emitter.Size = DEFLECT_SPARK_SIZE
	emitter.Lifetime = DEFLECT_SPARK_LIFETIME
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Speed = NumberRange.new(18, 34)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -20, 0)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rate = 0
	emitter.Enabled = true
	emitter.ZOffset = 0.5
	emitter.Parent = attachment

	deflectHost = host
	deflectEmitter = emitter

	host.Destroying:Connect(function()
		deflectHost = nil
		deflectEmitter = nil
	end)

	return emitter
end

--[[
	Draws the deflect burst at a world position.

	Structurally the same as `emitSparks` above — pooled host, generation-stamped
	retire, one-shot `Emit` — and deliberately not a call into it: the two effects
	have separate pools, separate counts and separate colours, so sharing a body
	would mean threading five parameters through a function whose whole virtue is
	that it has none.
]]
local function emitDeflectSparks(position: Vector3)
	if not isUsablePosition(position) then
		return
	end

	local emitter = ensureDeflectEmitter()
	local host = deflectHost
	if emitter == nil or host == nil then
		return
	end

	host.CFrame = CFrame.new(position)

	deflectGeneration += 1
	local myGeneration = deflectGeneration

	emitter:Emit(DEFLECT_SPARK_COUNT)

	task.delay(EMITTER_LIFETIME, function()
		-- Retire only if no later deflect re-armed the emitter, for the same reason
		-- the clash pool does: two deflects inside one burst's lifetime should add to
		-- the shower rather than have the first one cut off mid-fade.
		if myGeneration ~= deflectGeneration then
			return
		end

		local currentHost = deflectHost
		if currentHost == nil then
			return
		end

		currentHost:Destroy()
	end)
end



--[[
	Wire-up.

	The remotes are looked up with `FindFirstChild` rather than `WaitForChild` because
	a client can start before the server has finished running `HitValidator`, and this
	effect is the only reason for this script to exist. A hard wait would make a purely
	cosmetic module the thing that stalls; `GuardBreakEvent` in CombatController - which
	does decide something - is the one worth waiting on.
]]
local clashEvent = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_GUARD_CLASH_EVENT)
local deflectEvent = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_DEFLECT_CLASH_EVENT)
local isSubscribed = false
local isDeflectSubscribed = false

if clashEvent == nil or not clashEvent:IsA("RemoteEvent") then
	print("[SPARK] GuardClashEvent not found; guard-clash sparks are disabled.")
else
	clashEvent.OnClientEvent:Connect(function(position: any)
		if typeof(position) ~= "Vector3" then
			return
		end

		emitSparks(position)
	end)

	isSubscribed = true
	print("[SPARK] Guard-clash sparks online.")
end

--[[
	The deflect subscription, kept independent of the block's above rather than
	sharing its handler. A place that has one remote and not the other should still
	get whichever effect it can, and a shared handler would mean the burst drawn
	depended on which remote happened to arrive first.
]]
if deflectEvent == nil or not deflectEvent:IsA("RemoteEvent") then
	print("[SPARK] DeflectClashEvent not found; deflect sparks are disabled.")
else
	deflectEvent.OnClientEvent:Connect(function(position: any)
		if typeof(position) ~= "Vector3" then
			return
		end

		emitDeflectSparks(position)
	end)

	isDeflectSubscribed = true
	print("[SPARK] Deflect sparks online (white-hot, 2x speed, 26 particles).")
end


--[[
	A single frozen record, exported because `--!strict` requires every module to
	return exactly one value - and because a module that can only be reached by
	waiting for the server is a module that cannot be tested.

	`EmitAt` is the whole effect, callable directly, so a playtest can spawn a burst
	without having to make a real block land first: it is how the spark was tuned
	against a stationary character, and it is how it can be re-checked after a
	texture or colour edit without standing up a second player. It runs the same
	validation the remote does, so a test cannot reach a path a live event could not.
]]
local GuardSparks = table.freeze({
	EmitAt = emitSparks,
	EmitDeflectAt = emitDeflectSparks,
	IsSubscribed = isSubscribed,
	IsDeflectSubscribed = isDeflectSubscribed,
})

return GuardSparks
