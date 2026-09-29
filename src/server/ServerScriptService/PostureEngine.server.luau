--!strict

--[[
	PostureEngine
	Ronin — The Last Blade · server-authoritative posture-health (Day 8 · Part 1/2)

	Everything built so far has made posture *cost* something — a block spends it, a
	deflect hands it back — and nothing has ever made it come down. Until this script
	a player who ate four light hits was pinned at 60/100 until they were actually
	broken, and because the parry *reflects* posture the war could never reset: two
	deflects for them, two for you, forever. This is the other half of the currency.

	The rule being implemented
	--------------------------
	Posture recovers while a character is *not being pressured*, and the rate depends
	on how hurt they are:

	    healthy   (hp >= 75%)   16 / sec
	    wounded   (hp >= 25%)    8 / sec
	    critical  (hp <  25%)    0 / sec   <- no recovery at all

	"Pressured" is defined as *the last 1.2 seconds*, not as a state. That
	distinction is the whole design: a character standing in `Blocking` with a clean
	pool is not being pressured and should recover, whereas a character who has not
	been hit for a moment but is mid-swing has committed and should not. So recovery
	is suspended on three independent conditions — the rupture flag, the 1.2s poise
	grace window, and the `Blocking` / `Active` states — and applied otherwise.

	Why the server owns this
	------------------------
	ARCHITECTURE.md #3. Posture already lives on the character as server-written
	attributes (Day 6 invariant 2), and this script is the only writer of the
	*downward* direction of that value. Keeping the decay server-side is not
	ceremony: a client-side recovery term is a client-chosen number deciding how
	fast its own guard heals, which would make the entire posture war a client
	decision. The per-frame cost here is a handful of `GetAttribute` reads and one
	comparison per character, which is the cheapest possible price for authority.

	Zero allocation in the heartbeat
	--------------------------------
	ARCHITECTURE.md #4. The tracked set is a dense array plus a membership set, and
	the tick walks it with a numeric `for` rather than `ipairs` — no iterator closure
	per frame, no per-frame table. The two structures are the standard dual index:
	the array gives O(1) ordered iteration, the set gives O(1) "am I already tracking
	this", which is what makes registration idempotent across the three discovery
	paths below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local world = game:GetService("Workspace")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
Frozen tuning, read once at module scope.

Every threshold, rate and duration is named in `AttackConfig` rather than written
here. The reason is the one that has already bitten this project: a value that
exists in two files is a value that will exist in two files *differently* after the
first tune, and the resulting bug is silent - a posture gauge that disagrees with
the number the rules compared against.
]]
local POSTURE_ATTRIBUTE = AttackConfig.POSTURE_ATTRIBUTE
local MAX_POSTURE_ATTRIBUTE = AttackConfig.MAX_POSTURE_ATTRIBUTE
local MAX_POSTURE = AttackConfig.MAX_POSTURE
local POSTURE_BROKEN_ATTRIBUTE = AttackConfig.POSTURE_BROKEN_ATTRIBUTE
local POSTURE_LAST_HIT_ATTRIBUTE = AttackConfig.POSTURE_LAST_HIT_ATTRIBUTE
local POSTURE_HIT_RECOVERY_DELAY = AttackConfig.POSTURE_HIT_RECOVERY_DELAY
local RECOVERY_HEALTHY_THRESHOLD = AttackConfig.POSTURE_RECOVERY_HEALTHY_THRESHOLD
local RECOVERY_MID_THRESHOLD = AttackConfig.POSTURE_RECOVERY_MID_THRESHOLD
local RECOVERY_RATE_HEALTHY = AttackConfig.POSTURE_RECOVERY_RATE_HEALTHY
local RECOVERY_RATE_MID = AttackConfig.POSTURE_RECOVERY_RATE_MID
local RECOVERY_RATE_CRITICAL = AttackConfig.POSTURE_RECOVERY_RATE_CRITICAL
local POSTURE_RUPTURE_DURATION = AttackConfig.POSTURE_RUPTURE_DURATION
local ACTIVE_STATE_ATTRIBUTE = AttackConfig.ACTIVE_STATE_ATTRIBUTE
local GUARD_STATE_ATTRIBUTE = AttackConfig.GUARD_STATE_ATTRIBUTE
local REMOTE_GUARD_BREAK_EVENT = AttackConfig.REMOTE_GUARD_BREAK_EVENT

--[[
The rupture's one wire.

Reused rather than a new remote, and the reason is the one `breakGuard` already
gives: `Stunned` is a *state transition*, the state machine lives in the owning
client's process (ARCHITECTURE.md #3), and the established way for the server to
exercise authority over it is a targeted event the client applies locally. The
client's `applyGuardBreakStun` already does exactly what the rupture needs -
`Stunned`, then `Idle` on the same duration, with the `CurrentState ~= "Stunned"`
re-check that keeps a stale timer from yanking a character out of a state it
legitimately reached.

One remote serving both the 1.5s guard break and the 3.0s rupture is also the
correct answer for the *client*: a kneeling posture rupture and a shattered guard
are the same visual and the same input lock, differing only in duration, so
teaching the client a second handler for them would be a second place for the two
to drift apart.
]]
local cachedGuardBreakEvent: RemoteEvent? = nil

--[[
Resolves the rupture's wire *lazily*, on first use.

This is not defensive decoration, it is a load-order fix, and the bug it prevents
was found in playtest rather than by reading. `HitValidator` is what *creates*
`GuardBreakEvent` (via its `ensureRemote`), and ServerScriptService runs its
children in name order - `HitValidator` before `PostureEngine`, but the creation
happens inside `HitValidator`'s own body, which executes after this file has
already been read to its end. Resolving the remote at module scope therefore
cached `nil` *permanently*: every rupture logged correctly, rooted the character
correctly, and silently skipped the `Stunned` transition forever.

That is the worst shape a bug of this kind can take. Nothing errors, the posture
half of the feature works, and the only symptom is a character who kneels for
three seconds but can still swing - which reads as "the stun is weak" rather than
"the wire was never connected". Deferring the lookup to the moment it is needed
makes the engine independent of which script loads first, which is also the honest
dependency: this one only needs the remote to exist *by the time a rupture
happens*, which is orders of magnitude weaker than "exists when I am read".

Cached after the first successful resolve so the steady-state path is a single
table read rather than a name search per rupture - ruptures are rare, but the
lookup is free to avoid and this keeps the hot function honest.
]]
local function resolveGuardBreakEvent(): RemoteEvent?
if cachedGuardBreakEvent ~= nil then
return cachedGuardBreakEvent
end

local instance = ReplicatedStorage:FindFirstChild(REMOTE_GUARD_BREAK_EVENT)
if instance ~= nil then
cachedGuardBreakEvent = instance :: RemoteEvent
end

return cachedGuardBreakEvent
end

--[[
The tracked population: a dense array for iteration, a set for membership.

Both are keyed the same way and are never allowed to disagree - `trackCharacter`
and `untrackCharacter` are the only functions that touch either. Storing the
`Humanoid` alongside would be marginally faster per tick, but the Humanoid is
looked up every tick anyway (a character can be mid-respawn and lose it) and
holding a second reference per character is a second thing to leak.
]]
local trackedCharacters: { Model } = {}
local trackedSet: { [Model]: boolean } = {}

--[[
Seeds a character's four posture attributes, idempotently.

The attribute reads are re-typed for the same reason `HitValidator`'s
`ensurePosture` re-types them: `GetAttribute` returns `any`, and a stripping
script or a hand-built test rig can leave a string in a numeric slot. Comparing a
string to a number happens to work in Luau, but "works by accident" inside the
heartbeat of the authoritative engine is not a property worth keeping.

`POSTURE_LAST_HIT_ATTRIBUTE` is seeded to `0` rather than `os.clock()`. Both read
as "infinitely long ago" to the grace test, and `0` is the honest value for a
character that has never been hit - the timestamp of a nonexistent event.
]]
local function ensurePostureAttributes(character: Model)
if character:GetAttribute(MAX_POSTURE_ATTRIBUTE) == nil then
character:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
end

if character:GetAttribute(POSTURE_ATTRIBUTE) == nil then
character:SetAttribute(POSTURE_ATTRIBUTE, 0)
end

if character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) == nil then
character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, false)
end

if character:GetAttribute(POSTURE_LAST_HIT_ATTRIBUTE) == nil then
character:SetAttribute(POSTURE_LAST_HIT_ATTRIBUTE, 0)
end

local current = character:GetAttribute(POSTURE_ATTRIBUTE)
if typeof(current) ~= "number" then
character:SetAttribute(POSTURE_ATTRIBUTE, 0)
end

local maximum = character:GetAttribute(MAX_POSTURE_ATTRIBUTE)
if typeof(maximum) ~= "number" or maximum <= 0 then
character:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
end

local broken = character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE)
if typeof(broken) ~= "boolean" then
character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, false)
end

local lastHit = character:GetAttribute(POSTURE_LAST_HIT_ATTRIBUTE)
if typeof(lastHit) ~= "number" then
character:SetAttribute(POSTURE_LAST_HIT_ATTRIBUTE, 0)
end
end

--[[
The non-linear recovery rate for a given Health fraction.

A pure function of one number, so the ladder is a single readable expression and
the tick below carries no branching policy of its own. The ordering is
deliberately high-to-low: testing `>= 0.75` first means the common case costs one
comparison, and the zero-recovery tier is reached by falling through rather than
by being tested for explicitly.
]]
local function recoveryRateFor(hpPercent: number): number
if hpPercent >= RECOVERY_HEALTHY_THRESHOLD then
return RECOVERY_RATE_HEALTHY
end

if hpPercent >= RECOVERY_MID_THRESHOLD then
return RECOVERY_RATE_MID
end

return RECOVERY_RATE_CRITICAL
end

--[[
Whether this character is mid-swing right now, from the server's own record.

`Blocking` is the server-written guard flag, read directly - no new attribute, and
no possibility of the engine and the validator disagreeing about it.

`Active` is a deadline rather than a boolean, mirroring `RoninParryUntil`: it is
written when `HitValidator` opens the Active window and expires on its own, so
there is no teardown path that can leave it stuck on. A client cannot write it
(server-authoritative), and cannot widen it - the value is this side's own
`os.clock()` plus the frame data's Active duration and grace, the same derivation
`activeWindows[player]` performs.
]]
local function isSwinging(character: Model, now: number): boolean
if character:GetAttribute(GUARD_STATE_ATTRIBUTE) == true then
return true
end

local activeUntil = character:GetAttribute(ACTIVE_STATE_ATTRIBUTE)
if typeof(activeUntil) ~= "number" then
return false
end

return activeUntil > now
end

--[[
Breaks a character's posture: kneel, root, stun, and a 3.0s recovery.

Order matters and is not arbitrary:

  1. The broken flag goes on **first**. It is the single suspension condition the
     tick tests, so setting it before anything else means there is no window - not
     even one frame - in which a character flagged as kneeling is also having its
     pool drained by recovery.

  2. Posture is pinned to the maximum, not left wherever it landed.
     `spendPosture` clamps to the maximum already, so this is belt-and-braces, but
     it means a rupture is always reported as a *full* pool: a gauge that briefly
     showed 97/100 on a character that just ruptured would be reporting a state
     that cannot exist.

  3. `WalkSpeed` goes to 0, and the previous value is captured for the restore.
     Capturing before overwriting is the whole point - see the
     `DEFAULT_WALK_SPEED` note in `AttackConfig` for why a hardcoded 16 corrupts
     `WeaponVisuals`' own rest-speed bookkeeping.

  4. The `Stunned` transition is *carried* to the owner's client rather than
     applied here, and the `Idle` return is that client's own timer on the same
     duration. This script never writes to another process's state machine
     (ARCHITECTURE.md #3).

An NPC - the sparring rig - has no owning client and so no local machine to stun,
exactly as `breakGuard` documents. Its pool still resets and it is still rooted,
so it remains a legible target for the whole 3.0s; only the input lock is absent,
and an NPC has no inputs.
]]
local function rupturePosture(character: Model, humanoid: Humanoid)
character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, true)
character:SetAttribute(POSTURE_ATTRIBUTE, character:GetAttribute(MAX_POSTURE_ATTRIBUTE) or MAX_POSTURE)

local previousWalkSpeed = humanoid.WalkSpeed
humanoid.WalkSpeed = 0

print(string.format(
"[POSTURE RUPTURE] %s posture broken! Kneeling for %.1fs.",
character.Name,
POSTURE_RUPTURE_DURATION
))

local owner = Players:GetPlayerFromCharacter(character)
	if owner ~= nil then
		local guardBreak = resolveGuardBreakEvent()
		if guardBreak ~= nil then
			guardBreak:FireClient(owner, character, POSTURE_RUPTURE_DURATION)
		else
			-- Loud on purpose: a kneeling character with no input lock still *looks*
			-- like it worked, so silence here would be the bug repeating itself.
			warn("[POSTURE RUPTURE] GuardBreakEvent is missing from ReplicatedStorage; this character will kneel without an input lock.")
		end
	end

task.delay(POSTURE_RUPTURE_DURATION, function()
--[[
The character may have died, respawned or been destroyed during those three
seconds. Every write below is gated on the model still being in the world
*and* still being the one that ruptured, so a stale timer can never clear
a flag on a fresh body or restore a WalkSpeed onto a retired Humanoid.

Re-reading the broken flag rather than trusting this closure is what makes
the release safe, and for the same reason the client re-reads its state:
"is this still my rupture?" is the only question a deferred release is
allowed to ask.
]]
if character.Parent == nil then
return
end

if character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) ~= true then
return
end

character:SetAttribute(POSTURE_ATTRIBUTE, 0)
character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, false)

local currentHumanoid = character:FindFirstChildOfClass("Humanoid")
if currentHumanoid ~= nil and currentHumanoid.Parent ~= nil then
currentHumanoid.WalkSpeed = previousWalkSpeed
end

print(string.format("[POSTURE RECOVERED] %s is back on their feet.", character.Name))
end)
end

--[[
One character's worth of work per frame.

Deliberately a separate function from the tick, so the policy reads top to bottom
against the brief: dead? kneeling? full? pressured? committed? recover.
]]
local function updateCharacter(character: Model, now: number, dt: number)
local humanoid = character:FindFirstChildOfClass("Humanoid")
if humanoid == nil or humanoid.Health <= 0 then
return
end

-- A kneeling character is not recovering, and is not evaluated any further.
if character:GetAttribute(POSTURE_BROKEN_ATTRIBUTE) == true then
return
end

local maximum = character:GetAttribute(MAX_POSTURE_ATTRIBUTE)
if typeof(maximum) ~= "number" or maximum <= 0 then
return
end

local current = character:GetAttribute(POSTURE_ATTRIBUTE)
if typeof(current) ~= "number" then
character:SetAttribute(POSTURE_ATTRIBUTE, 0)
return
end

--[[
The rupture check, ahead of the recovery grace and ahead of the state check.

A character at a full pool has a *full pool* whether or not they were just hit,
and deferring the break behind a 1.2s window would mean the value sits at
100/100 - the exact reading the rules compare against - while the character
walks around still guarding. The break is a consequence of the value, not of
how recently the value changed.
]]
if current >= maximum then
rupturePosture(character, humanoid)
return
end

-- Nothing to do at zero. This keeps the common idle case to three reads.
if current <= 0 then
return
end

-- Suspension 1: a poise hit inside the grace window. This is "pressured".
local lastHit = character:GetAttribute(POSTURE_LAST_HIT_ATTRIBUTE)
if typeof(lastHit) == "number" and (now - lastHit) < POSTURE_HIT_RECOVERY_DELAY then
return
end

-- Suspension 2: committed - guarding, or mid-swing.
if isSwinging(character, now) then
return
end

--[[
Non-linear recovery, keyed on Health percentage.

`MaxHealth` is read fresh rather than cached: nothing in the project resizes a
Humanoid today, but a test rig that did would otherwise divide by a stale
denominator and silently select the wrong tier. The `> 0` guard is the same
concern - a zero MaxHealth would be a division by zero inside the
authoritative tick, which takes the whole engine down rather than one
character.
]]
local maxHealth = humanoid.MaxHealth
if maxHealth <= 0 then
return
end

local hpPercent = humanoid.Health / maxHealth
local rate = recoveryRateFor(hpPercent)

-- The critical tier. Explicit rather than implied, because "no recovery" is the
-- most important rule in the ladder and deserves to be legible as one.
if rate <= 0 then
return
end

--[[
The write. Clamping to 0 rather than against the minimum is correct here
because recovery only ever moves the value *down*: the floor is 0, so a
character at 4/100 recovering at 16/sec lands on exactly 0 and never dips
negative on a long frame.
]]
local recovered = current - rate * dt
if recovered < 0 then
recovered = 0
end

character:SetAttribute(POSTURE_ATTRIBUTE, recovered)
end

--[[
Registration and teardown.

Idempotent by construction: the set is checked before the array is appended to, so
a player character arriving through both `CharacterAdded` and the descendant watch
is tracked exactly once. `Humanoid` is deliberately *not* required to track - a
character is registered the moment it exists and the tick skips it until the
Humanoid lands, which is the normal state of a model for the first frame or two of
a respawn. Requiring it here would mean missing a character that is mid-spawn.
]]
local function trackCharacter(character: Model)
if trackedSet[character] then
ensurePostureAttributes(character)
return
end

trackedSet[character] = true
table.insert(trackedCharacters, character)
ensurePostureAttributes(character)
end

local function untrackCharacter(character: Model)
if not trackedSet[character] then
return
end

trackedSet[character] = nil

local index = table.find(trackedCharacters, character)
if index ~= nil then
table.remove(trackedCharacters, index)
end
end

--[[
The tick. Allocation free by construction (ARCHITECTURE.md #4): a numeric `for`
over the pre-built array, no `ipairs` iterator closure, no temporary table, and the
only string work anywhere in the path is inside `rupturePosture`, which fires once
per character per three seconds at most.
]]
local function onHeartbeat(dt: number)
local now = os.clock()

for index = 1, #trackedCharacters do
local character = trackedCharacters[index]

--[[
A character can be destroyed between frames without the descendant signal
having been processed yet, so liveness is re-tested here. Removing it in
place keeps this pass's iteration valid - the loop re-reads `#tracked` each
step, and decrementing the index compensates for the shift - and stops the
tracked array from growing for the life of the server.
]]
if character.Parent == nil then
trackedSet[character] = nil
table.remove(trackedCharacters, index)
index -= 1
continue
end

updateCharacter(character, now, dt)
end
end

--[[
Discovery path 1 - players.

`CharacterAdded` covers both the join and the respawn, and explicitly binding an
already-present player covers the player who was in the world before this script
started. The descendant watch below would catch those too, but binding explicitly
means a player is never dependent on the relative ordering of two signals.
]]
local function bindPlayer(player: Player)
local character = player.Character
if character ~= nil then
trackCharacter(character)
end

player.CharacterAdded:Connect(trackCharacter)
end

Players.PlayerAdded:Connect(bindPlayer)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
bindPlayer(existingPlayer)
end

--[[
Discovery paths 2 and 3 - the world's own models.

`DescendantAdded` rather than `ChildAdded` at the top level, so a rig nested in a
folder is found as readily as one standing loose in the place. The matching
`DescendantRemoving` is the teardown: it keeps the tracked array from growing for
the life of the server, and it means a model destroyed while kneeling never has its
release timer fire against a corpse.

Every Model is accepted without a name check. That is deliberate and it is the one
departure from `SparringDummy`'s `DUMMY_NAMES` approach: the engine has no idea
which models are meant to fight, and a `Humanoid`-less prop parked in Workspace
costs it exactly one `FindFirstChildOfClass` per frame. Filtering by name here
would mean the posture system silently stops working the moment somebody renames
the rig - the exact failure `DUMMY_NAMES` was written to *avoid*, but inverted:
there, two spellings were handled explicitly; here, only two spellings would be
handled at all.

Path 3, the one-time sweep, is folded into the same predicate.
]]
local function onDescendantAdded(instance: Instance)
if instance:IsA("Model") then
trackCharacter(instance)
end
end

local function onDescendantRemoving(instance: Instance)
if instance:IsA("Model") then
untrackCharacter(instance)
end
end

world.DescendantAdded:Connect(onDescendantAdded)
world.DescendantRemoving:Connect(onDescendantRemoving)

for _, descendant in ipairs(world:GetDescendants()) do
if descendant:IsA("Model") then
trackCharacter(descendant)
end
end

RunService.Heartbeat:Connect(onHeartbeat)

print(string.format(
"[SERVER] PostureEngine online: %d character(s) tracked. Recovery %d/%d/%d per sec by health tier, %.1fs poise grace, %.1fs rupture.",
#trackedCharacters,
RECOVERY_RATE_HEALTHY,
RECOVERY_RATE_MID,
RECOVERY_RATE_CRITICAL,
POSTURE_HIT_RECOVERY_DELAY,
POSTURE_RUPTURE_DURATION
))
