--!strict

--[[
PostureChaos
Ronin -- The Last Blade · Day 8 posture-rupture chaos suite (Day 8 · Part 2/2)

Verification harness, not a gameplay system. Nothing here is required by anything
else in the project; it exists so the [Y] key on the client has something honest
to talk to.

Why this is a *server* script at all
-----------------------------------
The two Day 8 invariants the [Y] suite has to prove are both about the server's
decisions, and a client cannot observe them. Writing `RoninPosture` from the
client changes only that client's copy of the model -- it never replicates back,
and the client is not the party that decides a rupture (ARCHITECTURE.md #3). A
"test" run from the client against client-written attributes would assert that a
number the test itself just wrote round-trips, which is true of every engine and
proves nothing about the game.

So the client sends `REMOTE_CHAOS_EVENT` and this script performs each test
against the real production paths -- the real `PostureEngine` heartbeat, the real
poise spend, the real `Humanoid` death -- and reports back. The client-side half
of the suite (the freeze is enforced, the listeners are gone) stays on the client,
where it belongs, and the two halves are reported together as one verdict.

The one thing this deliberately does *not* do is reach into another script's
internals. It cannot call `PostureEngine.rupturePosture` or
`HitValidator.spendPosture` even though both exist: they are file-locals, and
Day 8 · Part 1/2 already learned the cost of a server script depending on another
server script's *load order*. Every test here is expressed in terms of the same
attributes the rest of the game reads, which is both simpler and a stronger test
-- it goes through the production code rather than around it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
Every tuning value is read from `AttackConfig` rather than written here, for the
same reason `PostureEngine` does it: a threshold that exists in two files is a
threshold that will exist in two files *differently* after the first tune, and the
resulting failure is a test that quietly stops testing the thing.
]]
local POSTURE_ATTRIBUTE = AttackConfig.POSTURE_ATTRIBUTE
local MAX_POSTURE_ATTRIBUTE = AttackConfig.MAX_POSTURE_ATTRIBUTE
local POSTURE_BROKEN_ATTRIBUTE = AttackConfig.POSTURE_BROKEN_ATTRIBUTE
local MAX_POSTURE = AttackConfig.MAX_POSTURE

--[[
How long the suite waits for the server to *observe* a write.

`PostureEngine` runs on `RunService.Heartbeat`, so a posture change is not read
until the next frame. 2.0s is comfortably more than one frame on any machine and
still short enough that the whole suite stays inside a single fight's attention
span. Polling a deadline rather than sleeping a fixed time is what makes the waits
below *fast when the value lands early* -- the client sees the rupture the frame it
happens, not one polling interval later.
]]
local OBSERVE_TIMEOUT = 2.0
local OBSERVE_STEP = 0.02

--[[
Day 8 chaos: the 99.9% edge.

99.9% of a 100 pool is 99.9, and the hit that takes it over the line is 0.2% of a
pool -- so the test sets posture to 99.9 and applies a hit worth 0.2, which is
100.1 and must clamp to 100. The point is not the arithmetic, it is that the break
is driven by the *value crossing the threshold* and not by the size of the hit: a
0.2% nick breaking a guard is what proves the rule is "full pool breaks
immediately" (Day 8 · Part 1/2 invariant 3) rather than "a big enough hit breaks
it".
]]
local EDGE_POSTURE = MAX_POSTURE * 0.999
local EDGE_POISE = MAX_POSTURE * 0.002

--[[
Result shape returned to the client. Kept as a plain array of records rather than
a single boolean so the client can print *which* invariant failed -- a suite that
reports only "failed" sends the reader back to the console to work out which half
of the game broke.
]]
export type ChaosResult = {
Name: string,
Passed: boolean,
Detail: string,
}

local function result(name: string, passed: boolean, detail: string): ChaosResult
return { Name = name, Passed = passed, Detail = detail }
end

--[[
Polls `predicate` until it returns true or the timeout expires. Returns whether it
was satisfied. This is the only waiting primitive in the file, and it exists
because the alternative -- `task.wait(OBSERVE_TIMEOUT)` and hope -- makes every
assertion below a race that passes on a fast machine and fails on a slow one.
]]
local function waitFor(predicate: () -> boolean, timeout: number): boolean
local deadline = os.clock() + timeout
while os.clock() < deadline do
if predicate() then
return true
end
task.wait(OBSERVE_STEP)
end

return predicate()
end

--[[
Reads a numeric attribute defensively.

`RoninPosture` is server-written, so a `nil` here means the character has not been
picked up by `PostureEngine` yet (a character spawned in the same frame the suite
started). Returning the fallback keeps the caller's arithmetic total instead of
erroring three lines later on a nil comparison.
]]
local function numberAttribute(character: Model, name: string, fallback: number): number
local value = character:GetAttribute(name)
if typeof(value) == "number" then
return value
end

return fallback
end
--[[
Test (a) -- Posture Edge Test.

Sets the pool to 99.9% and applies a 0.2% poise hit, then asserts the rupture
fires, that the flag goes true, and -- the assertion that would actually catch a
regression -- that the flag went true *before* the recovery grace could have
expired on its own.

That last part is the interesting one. `POSTURE_HIT_RECOVERY_DELAY` is 1.2s, so an
implementation that merely let the pool sit at 100 and waited for the grace to
lapse would also end up "broken", just 1.2 seconds later and for entirely the wrong
reason. Measuring the latency between the hit and the flag, and requiring it to be
well inside the grace, is what separates "the rule fired" from "the timer fired".
]]
local function runPostureEdgeTest(character: Model, humanoid: Humanoid): ChaosResult
local name = "Posture Edge (99.9% + 0.2% poise)"

-- Start from a known-clean character. A player who was already kneeling when they
-- pressed [Y] would otherwise be measuring their previous rupture.
character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, false)
character:SetAttribute(POSTURE_ATTRIBUTE, EDGE_POSTURE)
humanoid.WalkSpeed = AttackConfig.DEFAULT_WALK_SPEED

-- The edge must be observed before the hit lands, or the test would be measuring a
-- hit against a pool the engine has not accepted yet.
local primed = waitFor(function()
return math.abs(numberAttribute(character, POSTURE_ATTRIBUTE, -1) - EDGE_POSTURE) < 0.001
and character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) ~= true
end, OBSERVE_TIMEOUT)

if not primed then
return result(name, false, string.format(
"could not prime the pool to %.1f/%d (read back %s)",
EDGE_POSTURE,
MAX_POSTURE,
tostring(character:GetAttribute(POSTURE_ATTRIBUTE))
))
end

--[[
The 0.2% poise hit. In a real exchange this is `data.PoiseDamage` from the frame
data, applied by `HitValidator.spendPosture`; from the server the same arithmetic
is a clamped addition against the pool, which is precisely what that function
does with its argument.

`RoninLastPostureHitTime` is stamped on the same instant, deliberately. It is
what starts the 1.2s recovery grace, and a test that hit the pool without
starting the grace would be measuring a case the game never produces -- in real
combat every poise hit is also a grace stamp, by construction (Day 8 · Part 1/2
invariant 2). Setting it here keeps the test faithful to the real path.
]]
local hitAt = os.clock()
character:SetAttribute(POSTURE_ATTRIBUTE, math.min(EDGE_POSTURE + EDGE_POISE, MAX_POSTURE))
character:SetAttribute(AttackConfig.POSTURE_LAST_HIT_ATTRIBUTE, hitAt)

local broke = waitFor(function()
return character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) == true
end, OBSERVE_TIMEOUT)

if not broke then
return result(name, false, string.format(
"no rupture at %d/%d after a %.2f%% hit (broken=%s, posture=%s)",
MAX_POSTURE,
MAX_POSTURE,
EDGE_POISE / MAX_POSTURE * 100,
tostring(character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE)),
tostring(character:GetAttribute(POSTURE_ATTRIBUTE))
))
end

local latency = os.clock() - hitAt

-- The grace it must beat is 1.2s. Half of it is the threshold: comfortably inside
-- the window the rule has to beat, and loose enough that one dropped frame on a
-- loaded server cannot fail the test.
local graceDeadline = AttackConfig.POSTURE_HIT_RECOVERY_DELAY * 0.5
if latency >= graceDeadline then
return result(name, false, string.format(
"rupture took %.3fs, which is not the value-driven break (grace is %.1fs)",
latency,
AttackConfig.POSTURE_HIT_RECOVERY_DELAY
))
end

-- The pool must be left pinned at full, not drained: a rupture that zeroed posture
-- on the way in would let a character stand up at 0% and be driven back to full in
-- a single exchange, which is the bug Day 8 P1/2 fixed.
local pinned = math.abs(numberAttribute(character, POSTURE_ATTRIBUTE, -1) - MAX_POSTURE) < 0.001
if not pinned then
return result(name, false, string.format(
"pool is %s during the rupture, expected %d pinned",
tostring(character:GetAttribute(POSTURE_ATTRIBUTE)),
MAX_POSTURE
))
end

return result(name, true, string.format(
"broke in %.3fs (grace %.1fs), pool pinned at %d, walk=%.0f",
latency,
AttackConfig.POSTURE_HIT_RECOVERY_DELAY,
MAX_POSTURE,
humanoid.WalkSpeed
))
end
--[[
Test (b) -- Death Override Test.

Kills the character *while* it is kneeling, and asserts two separate things that
fail independently:

  1. The server's own bookkeeping survives. The dead model must be dropped and the
     deferred 3.0s release must not fire against a corpse or, worse, leave
     `RoninPostureBroken` set on whatever comes next. This is Day 8 P1/2
     invariant 7, and it is the half only the server can see.

  2. The client tears down. The client's own `Died` handler retires the machine,
     disconnects the state listener and drops the freeze capture. The client
     asserts that half against its real bound machine and reports it over the same
     wire; see `CombatDebugUI`.

The death itself is `humanoid.Health = 0`, which is the same thing a landed hit
does -- not a `Destroy()` on the model, because destroying it would skip the
`Died` event that the teardown this test exists to verify is wired to.

`Players.RespawnTime` is deliberately left alone. The engine's normal respawn is
part of what has to work here, and shortening it for the test would mean the test
never ran the code path a real death runs.
]]
local function runDeathOverrideTest(player: Player, character: Model, humanoid: Humanoid): ChaosResult
local name = "Death Override (HP 0 during rupture)"

-- Put the character into a live rupture first, so the death lands *during* one.
character:SetAttribute(POSTURE_ATTRIBUTE, MAX_POSTURE)
local broke = waitFor(function()
return character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) == true
end, OBSERVE_TIMEOUT)

if not broke then
return result(name, false, "could not enter a rupture to die inside of")
end

local wasWalking = humanoid.WalkSpeed
local expectedMaxPosture = numberAttribute(character, MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)

-- Kill it. `Died` fires on the next frame; everything below is waiting for the
-- engine's own teardown rather than asserting against a timer.
humanoid.Health = 0

local sawDeath = waitFor(function()
		return humanoid.Health <= 0
	end, OBSERVE_TIMEOUT)

if not sawDeath then
return result(name, false, string.format(
"character did not die (health=%s)",
tostring(humanoid.Health)
))
end

--[[
The dead body is deliberately NOT asserted on here. It is still flagged broken at
this instant, and that is correct: `PostureEngine`'s 3.0s release has not fired
yet - the console shows `[POSTURE RECOVERED]` *after* this test returns - and
that release is explicitly written to tolerate a body that has since died, by
re-reading the broken flag and the model's parent before touching anything.

What must not happen is the corruption reaching the *next* life, which is what the
respawn checks below actually test. Asserting on the corpse's flag is asserting
that a deferred timer has already run, which is a test of the clock rather than of
the override - and it failed on a correct run for exactly that reason.
]]

-- Wait for the replacement and check it is genuinely clean. This is the part that
-- catches a *leak into the next life* rather than a crash in the current one,
-- which is the harder failure to notice by eye.
local respawned = waitFor(function()
local nextCharacter = player.Character
return nextCharacter ~= nil and nextCharacter ~= character
end, 15)

if not respawned then
return result(name, false, "character never respawned after the death")
end

local nextCharacter = player.Character
if nextCharacter == nil then
return result(name, false, "player.Character was nil after respawn")
end

if nextCharacter:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) == true then
return result(name, false, "the NEW character inherited RoninPostureBroken = true")
end

local nextMaxPosture = numberAttribute(nextCharacter, MAX_POSTURE_ATTRIBUTE, -1)
if nextMaxPosture < expectedMaxPosture then
return result(name, false, string.format(
"the NEW character inherited a truncated max posture (%.1f, expected >= %.1f)",
nextMaxPosture,
expectedMaxPosture
))
end

-- The replacement must be a working character, not a frozen one. This is the
-- server's half of that assertion; the client asserts the same property from its
-- side, and both have to hold for the death to be called clean.
local nextHumanoid = nextCharacter:FindFirstChildOfClass("Humanoid")
if nextHumanoid == nil then
return result(name, false, "the NEW character has no Humanoid")
end

if nextHumanoid.WalkSpeed <= 0 then
return result(name, false, string.format(
"the NEW character respawned rooted (walk=%.0f) -- the freeze leaked across the respawn",
nextHumanoid.WalkSpeed
))
end

return result(name, true, string.format(
"died at walk=%.0f, old model released, new character clean at walk=%.0f / maxPosture=%.0f",
wasWalking,
nextHumanoid.WalkSpeed,
nextMaxPosture
))
end

--[[ 
Wiring the suite to its remote.

This is the part the first two live playtests of Day 8 P2/2 both broke, in two
different ways, and both failures were silent, so it is worth spelling out.

`HitValidator` creates every remote inside its own body, and ServerScriptService
runs its children in an order this script does not control. Observed across two
runs: first `HitValidator`, then `PostureChaos`. A single `FindFirstChild` at
this script's load time is therefore a coin flip, and every outcome of that
coin is a failure that looks like working code:

  * Resolve too early and cache the nil, and the suite is deaf forever. That is
    what the first version did, and it produced exactly one log line and no
    [Y] behaviour whatsoever.
  * Resolve too early and *warn*, and the suite is deaf forever with a log line
    blaming a script that was working correctly. That is what the second version
    did, and it is worse, because the message points at the wrong file.

So this script does not resolve at load time at all. It retries on a bounded
schedule until the remote exists, and connects exactly once when it does. The
load order between the two scripts stops being something either of them has to
know about, which is the only version of this that cannot be broken by someone
renaming a file.

The retry is bounded rather than a `while true`, so a genuinely missing remote
produces one clear warning and a suite that is simply absent - not an infinite
background loop for the life of the server.
]]
local RESOLVE_MAX_ATTEMPTS = 40
local RESOLVE_RETRY_STEP = 0.25

--[[ 
Re-entrancy guard. A second [Y] while a run is in flight would race the first
run's death test for the same character, and each would conclude that the
other corrupted the respawn. One run at a time is the only outcome that means
anything.
]]
local running = false

--[[ 
Whether the handler is connected, and the resolved remote.

Kept separate because "the remote exists" and "we are listening to it" are two
different facts, and collapsing them into one cache is what made the second
version permanently deaf.
]]
local cachedChaosEvent: RemoteEvent? = nil
local wired = false

--[[ 
Forward declaration, so `onChaosRequest` can resolve the remote and
`resolveChaosEvent` can wire the handler. The two genuinely reference each
other, and declaring the shape up front is what keeps that from needing a
`local x: T` nil hack in one direction or the other.
]]


local wiringConnection: RBXScriptConnection? = nil

--[[
Forward declaration: `onChaosRequest` resolves the remote, and
`resolveChaosEventImpl` wires the handler that calls it. The two genuinely
reference each other, so one has to be declared before the other is defined.
]]
local resolveChaosEventImpl: () -> RemoteEvent?

local function onChaosRequest(player: Player)
	local chaosEvent = resolveChaosEventImpl()
	if chaosEvent == nil then
		--[[ 
			Unreachable in practice - the handler is only connected after a
			successful resolve - but a nil here would otherwise become a
			runtime error deep inside the spawned thread, so it is checked
			explicitly and reported.
			]]
		warn("[POSTURE CHAOS] Request arrived with no remote; ignoring.")
		return
	end

	if running then
		warn("[POSTURE CHAOS] A run is already in flight; press ignored.")
		return
	end

	running = true

	--[[ 
		The whole run is inside a `pcall`, and the reply is fired both on the
		success path and on the error path. The client is polling for this
		`FireClient`, so a harness that threw would otherwise leave it
		waiting out a 25s timeout with nothing printed.
		]]
	task.spawn(function()
		local ok, err = pcall(function()
			local character = player.Character
			local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil

			if character == nil or humanoid == nil then
				chaosEvent:FireClient(player, {
					result("Suite Setup", false, "no live character with a Humanoid"),
				})
				return
			end

			print(string.format("[POSTURE CHAOS] (a) Posture edge test for %s", player.Name))
			local edgeResult = runPostureEdgeTest(character, humanoid)

			--[[ 
				Test (b) runs against the same character, which is deliberately still
				kneeling from (a) - so the death lands inside a live rupture
				without the test having to manufacture one twice.
				]]
			print(string.format("[POSTURE CHAOS] (b) Death override test for %s", player.Name))
			local deathResult = runDeathOverrideTest(player, character, humanoid)

			chaosEvent:FireClient(player, { edgeResult, deathResult })
		end)

		if not ok then
			warn("[POSTURE CHAOS] Suite threw: " .. tostring(err))
			chaosEvent:FireClient(player, {
				result("Suite Execution", false, "threw: " .. tostring(err)),
			})
		end

		--[[ 
			Cleared unconditionally, in the same place the input gate is reopened on
			the client: a run that ended in an error must not leave the next one
			permanently refused.
			]]
		running = false
	end)
end

--[[ 
Resolves the remote, arming the handler the first time it succeeds.

Called on every retry and on every request, and cached once it succeeds, so the
lookup is paid once in the steady state.
]]
resolveChaosEventImpl = function(): RemoteEvent?
	if cachedChaosEvent ~= nil then
		return cachedChaosEvent
	end

	local instance = ReplicatedStorage:FindFirstChild(AttackConfig.REMOTE_CHAOS_EVENT)
	if instance == nil or not instance:IsA("RemoteEvent") then
		return nil
	end

	local resolved = instance :: RemoteEvent
	cachedChaosEvent = resolved

	if not wired then
		wired = true
		wiringConnection = resolved.OnServerEvent:Connect(onChaosRequest)
	end

	return resolved
end

--[[ 
The bounded retry. 40 attempts at 0.25s is 10 seconds, which is far longer than
the gap between two server scripts starting and short enough that a genuinely
absent remote is reported promptly instead of at the end of the session.
]]
task.spawn(function()
	for _attempt = 1, RESOLVE_MAX_ATTEMPTS do
		if resolveChaosEventImpl() ~= nil then
			print("[POSTURE CHAOS] PostureChaos online. Press [Y] in a playtest to verify the Day 8 invariants.")
			return
		end

		task.wait(RESOLVE_RETRY_STEP)
	end
	--[[ 
		Reaching here means the remote genuinely does not exist after 10
		seconds, which is a real wiring fault in `HitValidator` rather than a
		load-order race. The message says so explicitly so the reader is not sent
		looking for a race that is not the cause.
		]]
	warn("[POSTURE CHAOS] ChaosTestEvent never appeared after 10s. Is HitValidator calling ensureRemote for it?")
end)
