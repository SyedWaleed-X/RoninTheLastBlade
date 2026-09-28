--!strict

--[[
	CombatController
	Ronin — The Last Blade · local character lifecycle binder

	Keeps exactly one combat state machine alive per character:
	  * CharacterAdded           -> build a fresh StateMachine("Idle"), publish it to
	                                CombatStateBus and log every transition it makes.
	  * Humanoid.Died / CharacterRemoving -> detach the listener, neutralise the
	                                machine and release the reference so nothing
	                                outlives the character.

	Per docs/ARCHITECTURE.md #3 this controller is local prediction and presentation
	only: the server remains the sole authority for damage and state transitions.

	This file is a LocalScript (Script Sync suffix `.local.luau`). StarterPlayerScripts
	is already a per-player container, so a Script carrying a non-legacy RunContext in it
	starts twice per client (Studio warns about exactly that combination); a local script
	runs once, which is what a single-machine-per-character contract needs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StateMachine = require(ReplicatedStorage:WaitForChild("StateMachine") :: ModuleScript)

-- Client-local bridge: publishes the bound machine to observers (the debug HUD) and to
-- the keyboard/chaos harness. Every client script shares the one bus in PlayerScripts.
local CombatStateBus = require(script.Parent:WaitForChild("CombatStateBus") :: ModuleScript)
local InputBuffer = require(script.Parent:WaitForChild("InputBuffer") :: ModuleScript)

local localPlayer = Players.LocalPlayer

-- Teardown of the character that is currently bound; nil while no character is bound.
local activeTeardown: (() -> ())? = nil

--[[
	Binds a single character lifetime to a single state machine. The teardown it
	returns is idempotent so that Died and CharacterRemoving can both drive it
	without double cleanup.
]]
local function bindCharacter(character: Model): () -> ()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	local machine = StateMachine.new("Idle")

	-- Publish immediately so client observers mirror the machine from its first
	-- transition onwards.
	CombatStateBus.Bind(machine)

	local lastTransitionClock = machine.LastTransitionTime
	local disconnectStateChanged: (() -> ())? = nil
	local diedConnection: RBXScriptConnection? = nil
	local isBound = true

	--[[
		Logs `[COMBAT] State changed: <from> -> <to> (dt: <time>)`. `dt` is the
		interval in seconds since the previous transition, read from the machine's own
		LastTransitionTime so the value is not skewed by the machine's deferred
		(task.spawn) listener dispatch.

		Also drives the action consumption loop (Day 3):
		  - Idle: consumes buffered action and dispatches transition (LightAttack -> Windup, Guard -> Blocking).
		  - Stunned: clears input buffer to prevent actions queued during/before hitstun.
		  - Recovery: keeps listening, allowing new inputs to fill the buffer.
	]]
	local function onStateChanged(fromState: string, toState: string)
		local transitionClock = machine.LastTransitionTime
		local dt = transitionClock - lastTransitionClock
		lastTransitionClock = transitionClock

		print(string.format("[COMBAT] State changed: %s -> %s (dt: %.3f)", fromState, toState, dt))

		if toState == "Idle" then
			local action, latencyDelta = InputBuffer.Consume()
			if action then
				CombatStateBus.RecordConsumed(action, latencyDelta or 0)

				if action == "LightAttack" then
					machine:SetState("Windup")
				elseif action == "Guard" then
					machine:SetState("Blocking")
				end
			end
		elseif toState == "Stunned" then
			-- Immediately flush queued actions: no attacks after hitstun
			InputBuffer.Clear()
		elseif toState == "Recovery" then
			-- Keep listening, allowing new inputs to fill the buffer
		end
	end

	disconnectStateChanged = machine:OnStateChanged(onStateChanged)

	--[[
		Retires the binding: stop listening, return the machine to Idle and drop every
		reference this closure holds.
	]]
	local function teardown()
		if not isBound then
			return
		end
		isBound = false

		-- 1) Stop receiving transitions from a character that is going away.
		local connection = diedConnection
		diedConnection = nil
		if connection then
			connection:Disconnect()
		end

		local disconnect = disconnectStateChanged
		disconnectStateChanged = nil
		if disconnect then
			disconnect()
		end

		-- Stop feeding client observers before the machine is retired.
		CombatStateBus.Release(machine)

		-- Clear buffered inputs on death/respawn
		InputBuffer.Clear()

		-- 2) Neutralise the machine. Disposal is not a combat transition, so a
		--    table-legal move goes through SetState; dying mid-strike (Active -> Idle)
		--    is the one case the table forbids, and there we reset the fields directly
		--    rather than log a rejection for a machine that is about to be discarded.
		if machine.CurrentState ~= "Idle" then
			if not machine:SetState("Idle") then
				machine.PreviousState = machine.CurrentState
				machine.CurrentState = "Idle"
				machine.LastTransitionTime = os.clock()
			end
		end

		-- 3) Release the caller's reference. With the listener disconnected and this
		--    closure dropped, nothing keeps the machine (or the character) alive.
		if activeTeardown == teardown then
			activeTeardown = nil
		end
	end

	diedConnection = humanoid.Died:Connect(teardown)

	return teardown
end

local function detachActiveBinding()
	local teardown = activeTeardown
	if teardown then
		activeTeardown = nil
		teardown()
	end
end

local function onCharacterAdded(character: Model)
	-- A respawn can arrive while the previous binding is still live.
	detachActiveBinding()
	activeTeardown = bindCharacter(character)
end

local function onCharacterRemoving(_character: Model)
	detachActiveBinding()
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)
localPlayer.CharacterRemoving:Connect(onCharacterRemoving)

-- The local player may already be alive by the time this script starts.
local existingCharacter = localPlayer.Character
if existingCharacter then
	onCharacterAdded(existingCharacter)
end
