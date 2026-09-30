--!strict

--[[
BossConfig
Ronin - The Last Blade . Boss 1 "The Corrupted Commander" + Realm 1

Every number the boss fight is made of, in one frozen table. Nothing here is a
value that is convenient to read at the call site: each constant is written down
once, with the reason it has the value it has, and the AI, the HUD, the arena
builder and the strike resolver all read it from here.

That matters more for a boss than it does for a light-attack chain. The player's
katana is already frozen data in `AttackConfig`; the boss is the *other* half of
every exchange in the fight, and a hard-coded 0.75s windup sitting inside a
`task.wait` in the controller is a number the HUD cannot show, the balance pass
cannot find, and a second boss cannot inherit.

Structure:
  S1  Identity + server attributes.
  S2  The wire contract.
  S3  Realm 1 geometry.
  S4  The five moves.
  S5  Telegraph palette.
  S6  AI cadence + move selection.

Rules honoured here:
  * ARCHITECTURE.md #1 - this file is `--!strict`.
  * ARCHITECTURE.md #4 - the tables are frozen, so neither the client HUD nor the
    server controller can mutate a value the other one is reading.
]]

--[[
S1 - Identity and the five server attributes.

These are the five attributes the brief names, spelled exactly. They are written
on the **boss Model** (not the rig) so a consumer can reach them from a single
reference the arena builder already has.

The four extra attributes are the ones the fight needs and the five do not cover:

  * `Engaged`    - the arena has sealed and the fight is live. The HUD fades on it.
  * `State`      - the AI's current state, mirrored for the debug readout.
  * `Vulnerable` - posture is broken; this is the deathblow window's precondition,
    and it is an attribute rather than a client guess precisely so a client
    cannot invent one.
  * `Defeated`   - latch, set once on death. A HUD that keys off "Health <= 0"
    flickers on the frame it crosses; one that keys off a latch cannot.

Attributes replicate, which is why the HUD needs no per-frame remote: it reads
these and nothing else. The remote in S2 exists only for the *fade event*.
]]
local ATTRIBUTE_HEALTH = "RoninBossHealth"
local ATTRIBUTE_MAX_HEALTH = "RoninBossMaxHealth"
local ATTRIBUTE_POSTURE = "RoninBossPosture"
local ATTRIBUTE_MAX_POSTURE = "RoninBossMaxPosture"
local ATTRIBUTE_PHASE = "RoninBossPhase"
local ATTRIBUTE_ENGAGED = "RoninBossEngaged"
local ATTRIBUTE_STATE = "RoninBossState"
local ATTRIBUTE_VULNERABLE = "RoninBossVulnerable"
local ATTRIBUTE_DEFEATED = "RoninBossDefeated"

local BOSS_NAME = "THE CORRUPTED COMMANDER"
local BOSS_DISPLAY_NAME = "The Corrupted Commander"
local BOSS_MAX_HEALTH = 400
local BOSS_MAX_POSTURE = 200

--[[
1.2x the player. Not a display trick: the boss's own hit reach numbers below are
written against *its* size, and the reach is what the player reads. A boss that
looks bigger and swings exactly as far as the player reads as a big character
doing a small animation.
]]
local BOSS_SCALE = 1.2
--[[
S2 - The wire contract.

One remote, created server-side by `Boss1Controller` and named here so the HUD
and the controller cannot drift apart on the string.

`REMOTE_ENGAGE_EVENT` is the only message in the whole boss system, and it is
server -> clients only. It carries no state a client could act on: it says "a
boss with this name and this ceiling has engaged / disengaged", which is all the
HUD needs in order to know *when* to fade. The numbers that matter (current
Health, current Posture, current Phase) are attributes, and attributes are
written by the one authority that owns them.

Server -> all-clients rather than `FireClient(player)` because the boss is a
shared, world-owned fight: every client inside the arena needs the fade, and the
arena-seal that triggers it is decided by the server for *everyone* at once.
Addressing it per-player would mean the server tracking which player is inside
which arena, which is state the gate itself already has.
]]
local REMOTE_ENGAGE_EVENT = "BossEngageEvent"

--[[
S3 - Realm 1: The Burning Ash Courtyard.

The courtyard sits *beyond Gate 1*, which is the north torii at Z = -46. The
SanctuaryHub floor is 104x104 and centred on the origin, so it ends at Z = -52.
The arena therefore begins one gate-length past that edge rather than being
centred on the hub's own north face, which would have put a wall through the
torii the player is walking through.

80x80 with a 24-stud approach: long enough that the Shadow Retreat (which dashes
backwards) and the gap-closing lunge (30 studs) both have room to be real moves
instead of animations, and the 24-stud approach is long enough to see the
braziers over the wall before the gate frame is even on screen.
]]
local ARENA_NAME = "The Burning Ash Courtyard"
local ARENA_FOLDER_NAME = "BurningAshCourtyard"
local ARENA_CENTER = Vector3.new(0, 0, -116)
local ARENA_HALF_EXTENT = 40
local ARENA_APPROACH_LENGTH = 24
local ARENA_FLOOR_TOP = 1
local ARENA_FLOOR_THICKNESS = 2
local ARENA_WALL_HEIGHT = 26
local ARENA_WALL_THICKNESS = 3

--[[
The gate barrier is two leaves that meet in the middle. Closed they are one
continuous wall across the 16-stud opening; the tween moves each leaf 8 studs
into the other, which is the smallest motion that can be *seen* to be a gate
closing rather than a wall appearing.
]]
local ARENA_GATE_HALF_WIDTH = 8
local ARENA_GATE_HEIGHT = 18
local ARENA_GATE_SEAL_TIME = 0.85
local ARENA_GATE_OPEN_TIME = 1.20

--[[
Braziers, clockwise from the north-west corner. Six of them: four corners to key
the room's edges, plus one on each long side, so a player circling the perimeter
is never more than ~20 studs from a light source and therefore never standing in
a corner where the geometry hides the boss.

`BRAZIER_OFFSETS` is measured from the arena centre, so the whole layout is a
function of `ARENA_HALF_EXTENT` and cannot drift out through the walls if the
arena is ever resized.
]]
local BRAZIER_OFFSETS: { Vector3 } = table.freeze({
Vector3.new(-32, 0, -32),
Vector3.new(32, 0, -32),
Vector3.new(32, 0, 32),
Vector3.new(-32, 0, 32),
Vector3.new(0, 0, -32),
Vector3.new(0, 0, 32),
})
--[[
S4 - The five moves.

One shape for all five, so the AI can drive any of them from the same three
fields (Windup -> Active -> Recovery) and the resolver can ask the same three
booleans the same questions. A boss whose moves each needed their own bespoke
state machine is a boss whose moves eventually drift out of step with each other,
and out of step is exactly what a player learns to punish.

The three booleans are the *answer* half of the design and they are mutually
exclusive by construction:

  * `Deflectable`  - the parry window answers it. Reflects posture onto the boss
                    and cancels the swing, which is the whole reward loop.
  * `Unblockable` - the guard does not answer it at all. Holding block is not a
                    wrong answer, it is *no* answer: a perilous move goes through a
                    raised guard for full damage. The i-frame dodge is the answer.
  * `MustJump`    - nothing at ground level answers it. A dodge does not (a dodge
                    is a horizontal commitment - see COMBAT_SPEC S3), a guard does
                    not. Only vertical separation does. Checked against
                    `Humanoid.FloorMaterial == Air`, which is the one bit of player
                    state that means "I am not touching the ground".

Note what is *not* here: there is no "unblockable but deflectable" move. A move
that both ignores the guard and answers to the parry would be strictly better
than either answer, and the player would learn to parry everything.
]]

export type BossMoveId =
| "TripleFlurry"
| "DragonCleave"
| "PerilousThrust"
| "PerilousSweep"
| "ShadowRetreat"

--[[
One hit of a multi-hit string. Identical in shape to `AttackConfig.AttackData`
minus the things that are player-specific (lunge tuning that assumes a
HumanoidRootPart the player owns), which is what lets the same state machine in
`Boss1Controller` step a player's chain and the boss's chain with one code path.
]]
export type FlurryStep = {
Label: string,
Windup: number,
Active: number,
Recovery: number,
Damage: number,
Posture: number,
Reach: number,
CloseSpeed: number,
}

export type BossMoveData = {
Id: BossMoveId,
Windup: number,
Active: number,
Recovery: number,
Damage: number,
Posture: number,
Reach: number,
CloseSpeed: number,
Deflectable: boolean,
Unblockable: boolean,
MustJump: boolean,
Steps: { FlurryStep }?,
}
--[[
(a) TRIPLE FLURRY - Slash -> Slash -> Thrust.

Three hits, all deflectable, none perilous. This is the move that teaches the
parry: every hit lands inside a 0.20s windup, and the inter-hit gap is shorter
than the 133ms parry window plus reaction, so a player who gets the rhythm right
deflects all three and reflects 54 posture in one string. A player who does not
will be hit three times.

Escalation, on purpose: the third hit is a *thrust*, not a third slash, and it
reaches 4 studs further and closes 12 studs faster. Same timing, different
answer, because a player who learned the first two by rhythm alone gets punished
for it exactly once and then respects the reach.

The reflection is the point. Four clean triple flurries break the boss's guard,
and that is the only way to reach Phase 2's lethal timing without grinding its
Health down, which is the posture economy working the same way it does on the
player.
]]
local MOVE_TRIPLE_FLURRY: BossMoveData = {
Id = "TripleFlurry",
Windup = 0,
Active = 0,
Recovery = 0,
Damage = 0,
Posture = 0,
Reach = 0,
CloseSpeed = 0,
Deflectable = true,
Unblockable = false,
MustJump = false,
Steps = table.freeze({
{
Label = "Slash",
Windup = 0.20,
Active = 0.10,
Recovery = 0.16,
Damage = 12,
Posture = 18,
Reach = 15,
CloseSpeed = 16,
},
{
Label = "Slash",
Windup = 0.18,
Active = 0.10,
Recovery = 0.16,
Damage = 12,
Posture = 18,
Reach = 15,
CloseSpeed = 18,
},
{
Label = "Thrust",
Windup = 0.22,
Active = 0.12,
Recovery = 0.34,
Damage = 16,
Posture = 26,
Reach = 19,
CloseSpeed = 30,
},
}),
}

--[[
(b) DRAGON'S CLEAVE - the delayed overhead slam.

750ms of windup, which is five and a half times the flurry's. That asymmetry *is*
the move: it is long enough that a player who was only reacting to the flurry's
speed cannot react to this one, and the only thing that carries over is the
parry timing, which is the skill the fight is about.

Amber flash for the whole windup, blade held overhead. Deflectable on the
downswing - and because 750ms is so long, the deflect window is generous in
absolute terms while being *identical* in relative ones, which is the fairness
the brief asks for.

50 posture through a block is the price of the other answer. It is nearly a
quarter of the boss's whole pool, so blocking a Cleave and then blocking another
one is a losing trade and the player learns to choose. Reflected posture on a
deflect is 50 as well, so the deflect is the *safer* of the two options against
this move - which is the correct incentive: the harder-hitting move should be the
one the precision answer is rewarded for.
]]
local MOVE_DRAGON_CLEAVE: BossMoveData = {
Id = "DragonCleave",
Windup = 0.75,
Active = 0.16,
Recovery = 0.58,
Damage = 26,
Posture = 50,
Reach = 17,
CloseSpeed = 20,
Deflectable = true,
Unblockable = false,
MustJump = false,
Steps = nil,
}
--[[
(c) PERILOUS THRUST - DANGER, MUST DODGE.

The red kanji and the chime fire on the first frame of the windup, not at its end,
because the whole point of a perilous telegraph is that the player has to make a
decision *early* and commit to it. A warning that arrives with the strike is not
a warning.

`Unblockable` is the load-bearing flag. It is honoured in two places at once: a
player who is holding block takes the full 30, and a player who tries to parry
takes the full 30. The guard is not a partial answer here; it is no answer, and
the HUD cannot tell them that after the fact, which is why the kanji has to carry
it before.

30 damage through guard is worth roughly two of the flurry's slashes. Eating it
because you mistook it for a Cleave has to cost about a healthbar, or the
mistake is free and the move is decoration.

The i-frame dodge *does* answer it, and it answers it completely: 0.20s of
invulnerability against a 0.55s windup is a 0.55s window to press Q in, which is
generous on purpose. The perilous moves are the game's teaching moments, and a
teaching moment that a correct input does not save is a difficulty spike, not a
lesson.
]]
local MOVE_PERILOUS_THRUST: BossMoveData = {
Id = "PerilousThrust",
Windup = 0.55,
Active = 0.14,
Recovery = 0.46,
Damage = 30,
Posture = 0,
Reach = 21,
CloseSpeed = 46,
Deflectable = false,
Unblockable = true,
MustJump = false,
Steps = nil,
}

--[[
(d) PERILOUS LOW SWEEP - DANGER, MUST JUMP.

The sweep inverts the perilous rule: the i-frame dodge that saves you from the
thrust is *worthless* here, and the jump that does nothing for the thrust is the
only answer.

That is a real, learnable asymmetry rather than an arbitrary one, and it follows
from the geometry. A committed dodge is a horizontal 7.9-stud step at ground
level (COMBAT_SPEC S3) - it moves the player *through* the plane of a blade
dragging the floor, not above it. `MustJump` therefore ignores
`RoninInvulnerable` entirely, which is the specific, checkable consequence.

`Humanoid.FloorMaterial == Air` is the test. It is the only client-owned fact
that means "no part of me is touching the ground", and unlike a velocity check
it cannot be faked by a small hop: the boss reads it on the frame the blade
crosses the player's standing plane, and a hop that has already come back down by
then is a hop that missed.

35 damage - the highest in the set. The move that cannot be blocked, cannot be
dodged, and cannot be deflected is the one that has to be worth all of that.
]]
local MOVE_PERILOUS_SWEEP: BossMoveData = {
Id = "PerilousSweep",
Windup = 0.62,
Active = 0.20,
Recovery = 0.56,
Damage = 35,
Posture = 0,
Reach = 19,
CloseSpeed = 12,
Deflectable = false,
Unblockable = true,
MustJump = true,
Steps = nil,
}
--[[
(e) SHADOW RETREAT & LUNGING THRUST - the gap closer.

Not a move the player can parry their way out of; a move about *distance*. When
the target is more than `RETREAT_TRIGGER_DISTANCE` (15) studs out, the boss does
not walk after them and it does not idle. It vanishes backwards, and then
arrives.

Two phases, and the gap between them is the taunt:

  * `Retreat` - a backwards dash of `RETREAT_DISTANCE` (10) studs at
    `RETREAT_SPEED`. Short enough to read as evasion, long enough to punish
    running. The kanji stays dark; this is not a perilous move and must not be
    mistaken for one, so it wears no red.

  * `Lunge` - after `MOVE_SHADOW_RETREAT.Windup` (0.22s) of stillness, the boss
    covers `MOVE_LUNGE_DISTANCE` (30) studs at `MOVE_LUNGE_SPEED` (150) in a
    straight line, blade first, and resolves a strike on contact.

30 studs at 150/s is 0.2s of travel after a 0.22s tell: the player gets 0.42s
to react to something covering 30 studs, which at a normal 16 studs/s walk is
nearly two and a half seconds of their own movement. Running is not a strategy;
standing your ground is a strategy; and the move is *deflectable*, so standing
your ground has a reward as well as a cost.

The backwards dash is also the answer to kiting. Without it the boss would have
to walk, and a walking boss can be outpaced forever, which turns the fight into
a footrace instead of a duel.
]]
local MOVE_SHADOW_RETREAT: BossMoveData = {
Id = "ShadowRetreat",
Windup = 0.22,
Active = 0.16,
Recovery = 0.44,
Damage = 28,
Posture = 35,
Reach = 16,
CloseSpeed = 0,
Deflectable = true,
Unblockable = false,
MustJump = false,
Steps = nil,
}

local MOVE_SHADOW_RETREAT_TRIGGER_DISTANCE = 15
local MOVE_SHADOW_RETREAT_DISTANCE = 10
local MOVE_SHADOW_RETREAT_SPEED = 70
local MOVE_SHADOW_RETREAT_DURATION = 0.32
local MOVE_LUNGE_DISTANCE = 30
local MOVE_LUNGE_SPEED = 150

--[[
The selection table. The literal is built into an annotated local first and
frozen second, for the same reason `AttackConfig` does it: `table.freeze` returns
a *readonly* sealed table, and a readonly literal cannot satisfy a mutable
`[BossMoveId]` indexer annotation under `--!strict`. Assigning the plain literal
to the annotated `moves` first lets the expected type supply the indexer, then
`table.freeze` locks it at runtime.
]]
local moves: { [BossMoveId]: BossMoveData } = {
TripleFlurry = MOVE_TRIPLE_FLURRY,
DragonCleave = MOVE_DRAGON_CLEAVE,
PerilousThrust = MOVE_PERILOUS_THRUST,
PerilousSweep = MOVE_PERILOUS_SWEEP,
ShadowRetreat = MOVE_SHADOW_RETREAT,
}
local MOVES: { [BossMoveId]: BossMoveData } = table.freeze(moves)
--[[
S5 - The telegraph palette.

Three colours, three meanings, and they are never reused for anything else in
the fight. A telegraph that can mean two things is a telegraph that only warns.

  * Amber  - a *safe but slow* attack. Deflectable, blockable, dodgeable. You
    have time; the question is whether you are accurate enough to profit.
  * Red    - a *perilous* attack. The kanji and the chime. Unblockable. The only
    question is which of the two evasive answers applies.
  * White  - the parry landed. The boss's own light goes white for a beat,
    which is the same colour `DeflectFeedback` uses for the player's deflect.
    The player should be able to tell they deflected the boss by looking at the
    boss and nothing else.

The light is a single `PointLight` parented to the boss's HumanoidRootPart inside
the template, so the telegraph travels with the boss and costs one property write
per phase change rather than a per-frame lerp on several instances.
]]
local TELEGRAPH_AMBER = Color3.fromRGB(255, 176, 64)
local TELEGRAPH_RED = Color3.fromRGB(255, 52, 40)
local TELEGRAPH_WHITE = Color3.fromRGB(255, 248, 232)
local TELEGRAPH_LIGHT_RANGE = 45
local TELEGRAPH_IDLE_BRIGHTNESS = 0
local TELEGRAPH_AMBER_BRIGHTNESS = 2.6
local TELEGRAPH_RED_BRIGHTNESS = 4.2
local TELEGRAPH_WHITE_BRIGHTNESS = 5.5

--[[
S6 - AI cadence.

`THINK_INTERVAL` is 0.05s. The fight is built on 0.20s parry windows and 0.55s
perilous windups, so a 50ms decision cadence resolves a move's phase to within
5% of its designed length - well inside human reaction error, which is the only
clock the player is actually on.

It is deliberately *not* a `RunService.Heartbeat` loop. ARCHITECTURE #4 forbids
run-time table allocation in a heartbeat path, and the obvious way to honour that
is to pre-allocate everything and drive at 60Hz. This does neither: it is a
`task.wait` loop, so it is not on the frame budget's critical path at all, and
the boss's *movement* between decisions is done by the Humanoid, not by this
loop, so the locomotion stays at full framerate regardless.

The cost of 50ms is real and is worth naming: a strike's active window is 0.10s
of wall clock, which is 2 ticks. Two ticks is enough to fire the hit exactly once
because the per-swing debounce is a latch, not a counter - but it is why no move
in S4 has an active window under 0.10s.
]]
local THINK_INTERVAL = 0.05
local IDLE_THINK_DELAY = 0.45
local REPOSITION_SPEED = 22
local TURN_SPEED_RADIANS = 7.0

--[[
Move selection weights, per phase. Higher = more likely, relative only.

Phase 1 leans on the flurry: the fight should open with the move that teaches
the parry, not with a perilous attack the player has no reason to recognise yet.

Phase 2 is where the perilous moves stop being interruptions and start being the
norm - Flurry drops to 0.8 while both perilous moves roughly triple. The flurry
never reaches zero, because a boss that has stopped teaching can only be
brute-forced, and brute force is not a phase transition.
]]
local WEIGHTS_PHASE_ONE: { [BossMoveId]: number } = table.freeze({
TripleFlurry = 5.0,
DragonCleave = 2.2,
PerilousThrust = 1.0,
PerilousSweep = 0.8,
ShadowRetreat = 0,
})

local WEIGHTS_PHASE_TWO: { [BossMoveId]: number } = table.freeze({
TripleFlurry = 0.8,
DragonCleave = 2.4,
PerilousThrust = 3.0,
PerilousSweep = 2.6,
ShadowRetreat = 0,
})

--[[
`ShadowRetreat` is weighted 0 in both tables on purpose. It is not chosen by the
roulette; it is chosen by a *rule* - the player is more than 15 studs away, so
the boss uses it, and it is skipped entirely when they are not. Letting the
roulette pick it would mean the boss sometimes "chose" to retreat while standing
three studs from the player, which reads as broken AI.
]]
local PHASE_TWO_HEALTH_THRESHOLD = 0.5
local PHASE_SPEED_MULTIPLIER = 1.22
local PHASE_TWO_DEFLECT_BONUS = 1.35

--[[
Boss posture. Posture is what the player's deflects cost the boss, and it is the
only route to a deathblow window, so it is the fight's second health bar.

`POSTURE_REFLECT_BASE` is the reflection of a single deflected strike - the same
number the *player's* deflect costs the attacker in `AttackConfig`
(`PARRY_REFLECT_POSTURE`), because the economy should not have two rates.

Recovery is deliberately slow and has a delay: the boss relaxes only after
`POSTURE_RECOVERY_DELAY` of not being deflected, and then only down to
`POSTURE_RECOVERY_FLOOR` (30). A boss that recovers to zero between exchanges
would make the posture bar a decoration; a boss that recovers to 30 makes every
fight a matter of banking progress.
]]
local POSTURE_REFLECT_BASE = 25
local POSTURE_RECOVERY_DELAY = 2.4
local POSTURE_RECOVERY_RATE = 9
local POSTURE_RECOVERY_FLOOR = 30
local POSTURE_BROKEN_STUN = 2.8
local POSTURE_BROKEN_HEALTH_MULTIPLIER = 1.6
--[[
Ambience. The taiko bed is a free Creator Store track, verified loadable through
`ContentProvider:PreloadAsync` before the id was hardcoded here, so it cannot fail
to resolve at runtime (the same rule the Day 10 combat palette follows).

It lives in `SoundService.RoninAmbience`, which `AudioEngine` already nests under
`RoninMaster` with the ambience duck side-chained to `RoninCombatSFX`. Putting the
boss bed anywhere else would bypass the duck and the limiter - a boss fight is
exactly the moment the SFX palette is busiest, so the bed is exactly the moment
the duck has to work.
]]
local MUSIC_BOSS_BED = "rbxassetid://84331969561132"
local MUSIC_BOSS_VOLUME = 0.45
local SOUND_PERIL_CHIME = "rbxassetid://1841477142"
local SOUND_PERIL_CHIME_ALT = "rbxassetid://1841478628"
local SOUND_CLEAVE_SLAM = "rbxassetid://9114036511"

--[[
The ash. Two emitters, because falling ash and rising ember are different
things: one is lit from the sky and falls, the other is lit *by the braziers* and
rises. A single emitter can only do one of them, and doing both with one means the
embers are dark when they pass in front of a fire.

`AshTexture` and `EmberTexture` are the default Roblox particle sheets, used
because they are always available and never need an upload: `smoke_main.dds`
reads as a soft ash flake when tinted pale grey, `sparkles_main.dds` reads as a
cooling ember when tinted red-orange and kept small.
]]
local ASH_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local EMBER_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

return table.freeze({
Attributes = table.freeze({
Health = ATTRIBUTE_HEALTH,
MaxHealth = ATTRIBUTE_MAX_HEALTH,
Posture = ATTRIBUTE_POSTURE,
MaxPosture = ATTRIBUTE_MAX_POSTURE,
Phase = ATTRIBUTE_PHASE,
Engaged = ATTRIBUTE_ENGAGED,
State = ATTRIBUTE_STATE,
Vulnerable = ATTRIBUTE_VULNERABLE,
Defeated = ATTRIBUTE_DEFEATED,
}),
Name = BOSS_NAME,
DisplayName = BOSS_DISPLAY_NAME,
MaxHealth = BOSS_MAX_HEALTH,
MaxPosture = BOSS_MAX_POSTURE,
Scale = BOSS_SCALE,
RemoteEngage = REMOTE_ENGAGE_EVENT,

Arena = table.freeze({
Name = ARENA_NAME,
FolderName = ARENA_FOLDER_NAME,
Center = ARENA_CENTER,
HalfExtent = ARENA_HALF_EXTENT,
ApproachLength = ARENA_APPROACH_LENGTH,
FloorTop = ARENA_FLOOR_TOP,
FloorThickness = ARENA_FLOOR_THICKNESS,
WallHeight = ARENA_WALL_HEIGHT,
WallThickness = ARENA_WALL_THICKNESS,
GateHalfWidth = ARENA_GATE_HALF_WIDTH,
GateHeight = ARENA_GATE_HEIGHT,
GateSealTime = ARENA_GATE_SEAL_TIME,
GateOpenTime = ARENA_GATE_OPEN_TIME,
BrazierOffsets = BRAZIER_OFFSETS,
}),

Move = table.freeze({
Moves = MOVES,
TripleFlurry = MOVE_TRIPLE_FLURRY,
DragonCleave = MOVE_DRAGON_CLEAVE,
PerilousThrust = MOVE_PERILOUS_THRUST,
PerilousSweep = MOVE_PERILOUS_SWEEP,
ShadowRetreat = MOVE_SHADOW_RETREAT,
RetreatTriggerDistance = MOVE_SHADOW_RETREAT_TRIGGER_DISTANCE,
RetreatDistance = MOVE_SHADOW_RETREAT_DISTANCE,
RetreatSpeed = MOVE_SHADOW_RETREAT_SPEED,
RetreatDuration = MOVE_SHADOW_RETREAT_DURATION,
LungeDistance = MOVE_LUNGE_DISTANCE,
LungeSpeed = MOVE_LUNGE_SPEED,
}),

Telegraph = table.freeze({
Amber = TELEGRAPH_AMBER,
Red = TELEGRAPH_RED,
White = TELEGRAPH_WHITE,
Range = TELEGRAPH_LIGHT_RANGE,
IdleBrightness = TELEGRAPH_IDLE_BRIGHTNESS,
AmberBrightness = TELEGRAPH_AMBER_BRIGHTNESS,
RedBrightness = TELEGRAPH_RED_BRIGHTNESS,
WhiteBrightness = TELEGRAPH_WHITE_BRIGHTNESS,
}),

AI = table.freeze({
ThinkInterval = THINK_INTERVAL,
IdleThinkDelay = IDLE_THINK_DELAY,
RepositionSpeed = REPOSITION_SPEED,
TurnSpeed = TURN_SPEED_RADIANS,
PhaseTwoThreshold = PHASE_TWO_HEALTH_THRESHOLD,
PhaseSpeedMultiplier = PHASE_SPEED_MULTIPLIER,
PhaseTwoDeflectBonus = PHASE_TWO_DEFLECT_BONUS,
WeightsPhaseOne = WEIGHTS_PHASE_ONE,
WeightsPhaseTwo = WEIGHTS_PHASE_TWO,
}),

Posture = table.freeze({
ReflectBase = POSTURE_REFLECT_BASE,
RecoveryDelay = POSTURE_RECOVERY_DELAY,
RecoveryRate = POSTURE_RECOVERY_RATE,
RecoveryFloor = POSTURE_RECOVERY_FLOOR,
BrokenStun = POSTURE_BROKEN_STUN,
BrokenHealthMultiplier = POSTURE_BROKEN_HEALTH_MULTIPLIER,
}),

Audio = table.freeze({
MusicBed = MUSIC_BOSS_BED,
MusicVolume = MUSIC_BOSS_VOLUME,
PerilChime = SOUND_PERIL_CHIME,
PerilChimeAlt = SOUND_PERIL_CHIME_ALT,
CleaveSlam = SOUND_CLEAVE_SLAM,
}),

Particles = table.freeze({
Ash = ASH_TEXTURE,
Ember = EMBER_TEXTURE,
}),
})