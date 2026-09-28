--!strict

--[[
	AttackController
	Ronin — The Last Blade · 3-hit light-attack chain driver (Day 4 · Part 1/2)

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

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)
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

return AttackController
