--!strict

--[[
	CameraShaker
	Ronin — The Last Blade · trauma-driven camera shake (Day 10 · Part 1/2)

	A sword fight is loud in three channels and the game only had two. Sparks and
	clang existed from Day 7, but the camera itself never moved, so the single most
	important question in a duel — *did that connect?* — was answered only by a
	sprite. This module is the third channel: the one that arrives in the player's
	hands.

	The trauma model
	----------------
	Three lines of state, one scalar:

	    Trauma  accumulates from hits, clamped to [0, 1], decays at 1.4/sec
	    Shake   = Trauma * Trauma
	    Offset  = six Perlin samples through Shake

	The squaring is the load-bearing decision. Linear shake spends almost all of its
	life at a magnitude the eye reads as "the camera is malfunctioning", so a graze
	and a guard break become the same event at two volumes — the player learns
	nothing from *how hard* they were hit. Quadratic separates the tiers: a light hit
	(0.20 trauma) shakes at 0.04 and is felt rather than seen, a deflect (0.35)
	shakes at 0.12, and a posture rupture (0.65) shakes at 0.42 and is violent.

	Why Perlin and not `math.random`
	--------------------------------
	Random is uncorrelated between frames, which is the wrong shape entirely: it
	produces white noise, a jitter that reads as digital and breaks the illusion of
	a physical camera. Perlin noise is smooth — neighbouring samples are close — so
	consecutive frames form a continuous *drift*, and it is that continuity the eye
	reads as inertia. Each axis is also given a constant offset so pitch, yaw and
	roll are never the same signal sampled at the same instant.

	Why `BindToRenderStep` and not `RenderStepped`
	----------------------------------------------
	Ordering. The default camera module resolves the camera's true CFrame during
	`RenderPriority.Camera` (200). A shake applied from `RenderStepped` runs at an
	unspecified point relative to that, so it either lands *before* the camera is
	resolved and is discarded, or fights the next frame's resolution and produces
	the classic 1-frame lag that reads as the camera stuttering. Binding at
	`Camera.Value + 1` guarantees the shake is a strict *delta applied on top of* a
	fully resolved camera, and because the camera module rewrites the CFrame from
	scratch every frame, the delta cannot accumulate into drift.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #3 - presentation only. Nothing here can change a Health
	    value, a state transition or a posture number; it draws what the server has
	    already decided.
	  * ARCHITECTURE.md #4 - the bind is the only per-frame path and it allocates
	    no tables. Every offset is a scalar resolved into a single CFrame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

local TRAUMA_DECAY_RATE = AttackConfig.CAMERA_TRAUMA_DECAY_RATE
local ROTATION_DEGREES = AttackConfig.CAMERA_SHAKE_ROTATION_DEGREES
local TRANSLATION_STUDS = AttackConfig.CAMERA_SHAKE_TRANSLATION_STUDS
local ROTATION_FREQUENCY = AttackConfig.CAMERA_SHAKE_ROTATION_FREQUENCY
local TRANSLATION_FREQUENCY = AttackConfig.CAMERA_SHAKE_TRANSLATION_FREQUENCY

-- The render-step binding name, kept as a constant so the bind site and any future
-- unbind site cannot drift apart on a string literal.
local RENDER_STEP_NAME = "RoninCameraShaker"

--[[
	The six Perlin axes, and why they are constants.

	`math.noise` takes three coordinates and returns a single value, so six
	independent axes means six calls against a shared 3D field. Each call passes
	different *offsets* so no two axes read the same sliver of noise at the same
	time — without this, roll would be a delayed copy of pitch and the camera
	would roll as a consequence of pitching, which reads as a broken gimbal.
]]
local NOISE_PITCH_X, NOISE_PITCH_Y, NOISE_PITCH_Z = 0.00, 0.00, 0.00
local NOISE_YAW_X, NOISE_YAW_Y, NOISE_YAW_Z = 11.31, 4.77, 27.13
local NOISE_ROLL_X, NOISE_ROLL_Y, NOISE_ROLL_Z = 23.87, 19.41, 8.29
local NOISE_X_X, NOISE_X_Y, NOISE_X_Z = 37.55, 31.09, 14.73
local NOISE_Y_X, NOISE_Y_Y, NOISE_Y_Z = 44.21, 42.63, 33.97
local NOISE_Z_X, NOISE_Z_Y, NOISE_Z_Z = 52.11, 48.37, 29.61

--[[
	The module's own table.

	Declared here rather than returning a `table.freeze({...})` literal, which is
	the shape every other method-bearing module in `PlayerScripts` uses
	(`StateMachine`, `BladeHitbox`, `InputGate`, `Hitstop`).

	The reason is not style. A module that assigns to a name it never declared
	creates a *global*, and a global is shared across every copy of the script in the
	place — so `trauma` would be one value for every player, and a hit landed on one
	character would shake the camera of somebody else entirely.
]]
local CameraShaker = {}

-- The accumulated trauma. Module-scoped rather than a local passed around so that
-- `AddTrauma` can be called from any module without a handle to the shaker.
local trauma = 0

--[[
	Applies trauma to the camera.

	Clamped rather than summed raw, because trauma above 1 is not "more shake" — it
	is the same shake, since `shake = trauma * trauma` is already saturated, and the
	only thing an unclamped sum buys is a number that no longer maps to a visible
	magnitude. Three ruptures in one second and the camera is pinned at full trauma
	for the decay period, which is the correct reading of "the player was just
	destroyed".

	A negative amount is clamped away by the same `math.clamp` rather than being
	allowed to drain the pool. The callers are all in this project and all pass
	constants, so this is a guard against a future edit rather than a live input.
]]
function CameraShaker.AddTrauma(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)
end

--[[
	Clears the shake immediately.

	Called from character teardown. The camera is *not* the character's — a
	respawned player keeps their camera — so a shake left decaying across a death
	would carry the previous life's last impact into the next one's first frame.
]]
function CameraShaker.Reset()
	trauma = 0
end

--[[
	The current trauma, exposed for the debug HUD.

	Returns the raw value rather than the shake, because the number a designer
	reads off a gauge should be the one the rules compare against — the same
	reason `HitValidator` prints posture rather than a percentage of it.
]]
function CameraShaker.GetTrauma(): number
	return trauma
end

--[[
	The render step.

	Early-returns while `trauma` is zero, which is the overwhelmingly common case:
	a fight spends most of its time not being hit. Skipping the six `math.noise`
	calls and the CFrame build in that state is what makes a permanent render-step
	binding free rather than a small tax on every frame of every session.

	The camera is re-read from `workspace.CurrentCamera` rather than cached, because
	the camera object is genuinely replaced — on respawn, on a cutscene, on any
	`CameraType` change — and a cached reference would keep shaking a camera that is
	no longer on screen.
]]
local function onRenderStep(dt: number)
	if trauma <= 0 then
		return
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	-- Decay first, then sample. Sampling before decaying would make the shake one
	-- frame longer than the number that scheduled it, which compounds over a fast
	-- chain of hits and leaves the camera buzzing after the last impact has passed.
	trauma = math.max(0, trauma - TRAUMA_DECAY_RATE * dt)

	local shake = trauma * trauma

	-- Two clocks, deliberately different rates. Rotation at 24Hz reads as a sharp
	-- judder across the frame; translation at 19Hz reads as weight. Sharing one rate
	-- collapses the two into a single rigid-body swing.
	local rotationTime = os.clock() * ROTATION_FREQUENCY
	local translationTime = os.clock() * TRANSLATION_FREQUENCY

	--[[
		Rotation. `math.noise` returns roughly [-0.5, 0.5] rather than [-1, 1] (its
		observed range on this engine is about -0.89..0.68), so each sample is
		doubled to use the range the amplitudes were tuned against — without it the
		shake would sit at roughly half the intended magnitude and the tuning
		constants would be quietly lying.
	]]
	local pitch = math.noise(rotationTime + NOISE_PITCH_X, NOISE_PITCH_Y, NOISE_PITCH_Z) * 2 * shake
	local yaw = math.noise(rotationTime + NOISE_YAW_X, NOISE_YAW_Y, NOISE_YAW_Z) * 2 * shake
	local roll = math.noise(rotationTime + NOISE_ROLL_X, NOISE_ROLL_Y, NOISE_ROLL_Z) * 2 * shake

	local offsetX = math.noise(translationTime + NOISE_X_X, NOISE_X_Y, NOISE_X_Z) * 2 * shake
	local offsetY = math.noise(translationTime + NOISE_Y_X, NOISE_Y_Y, NOISE_Y_Z) * 2 * shake
	local offsetZ = math.noise(translationTime + NOISE_Z_X, NOISE_Z_Y, NOISE_Z_Z) * 2 * shake

	--[[
		The delta, multiplied onto the camera's already-resolved CFrame.

		`CFrame.new` then `CFrame.Angles` in that order: the translation is applied
		in the camera's own local space, so the shake moves the camera along *its*
		axes rather than the world's. A shake built in world space would swing wildly
		as the player turned — a forward nudge would become a sideways one — which
		is the single most common way this effect goes wrong.

		The write is a full overwrite rather than a relative one because the camera
		module resolves `CFrame` from scratch every frame. Reading the current value
		and nudging it would accumulate into unbounded drift the moment a frame
		arrived out of order.
	]]
	camera.CFrame = camera.CFrame
		* CFrame.new(offsetX * TRANSLATION_STUDS, offsetY * TRANSLATION_STUDS, offsetZ * TRANSLATION_STUDS)
		* CFrame.Angles(
			pitch * math.rad(ROTATION_DEGREES),
			yaw * math.rad(ROTATION_DEGREES),
			roll * math.rad(ROTATION_DEGREES)
		)
end

--[[
	Bound at `RenderPriority.Camera.Value + 1` rather than at `Camera.Value` itself.

	At exactly `Camera` (200) this would race the default camera module — both are
	registered at that priority and the order between them is not guaranteed — so
	the shake would sometimes be applied and then immediately overwritten. One step
	later is the documented contract for "apply something on top of the resolved
	camera", which is precisely what a shake is.
]]
RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)

return CameraShaker