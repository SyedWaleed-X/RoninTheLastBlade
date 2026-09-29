--!strict

--[[
	AttackConfig
	Ronin — The Last Blade · 3-hit chain frame data (Day 4 · Part 1/2)

	Frozen frame data for the light-attack chain. Every duration is in seconds and
	describes one phase of one swing, matching the states in docs/COMBAT_SPEC.md §1:
	  Windup    - startup, the window a parry can cancel into.
	  Active    - the lethal strike window, action locked.
	  Recovery  - follow-through, where a new intent is buffered for the next hit.

	The chain is a dictionary keyed by the 1-based hit index so a consumer reads its
	frame data with a plain index (`COMBO_CHAIN[CurrentComboIndex]`) instead of an
	array walk, and so `HitIndex` travels with the data for logging/serialisation.

	The escalating numbers are the design intent of the chain: every hit is faster to
	start but hits harder, and Hit 3 commits the longest (0.77s of total frame time)
	for the biggest damage and the biggest posture damage.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #4 - the table is frozen so neither client prediction nor the
	    server can mutate shared frame data at runtime.
]]

export type AttackData = {
	HitIndex: number,
	WindupDuration: number,
	ActiveDuration: number,
	RecoveryDuration: number,
	Damage: number,
	PoiseDamage: number,
	LungeSpeed: number,
}

--[[
	The literal is built into an annotated local first and frozen second on purpose:
	`table.freeze` returns a readonly sealed table, and a readonly literal cannot
	satisfy a mutable indexer annotation in strict mode. Assigning the plain literal to
	the annotated `chain` first lets the expected type supply the indexer, then
	`table.freeze` locks it down at runtime (same pattern as CombatTypes).
]]
local chain: { [number]: AttackData } = {
	[1] = {
		HitIndex = 1,
		WindupDuration = 0.15,
		ActiveDuration = 0.12,
		RecoveryDuration = 0.20,
		Damage = 10,
		PoiseDamage = 15,
		LungeSpeed = 22,
	},
	[2] = {
		HitIndex = 2,
		WindupDuration = 0.12,
		ActiveDuration = 0.12,
		RecoveryDuration = 0.22,
		Damage = 14,
		PoiseDamage = 20,
		LungeSpeed = 28,
	},
	[3] = {
		HitIndex = 3,
		WindupDuration = 0.24,
		ActiveDuration = 0.18,
		RecoveryDuration = 0.35,
		Damage = 24,
		PoiseDamage = 35,
		LungeSpeed = 38,
	},
}

local COMBO_CHAIN = table.freeze(chain)

--[[
	Chain window in seconds. A new press only continues the chain when it lands within
	COMBO_RESET_TIMEOUT of the *end* of the previous swing; beyond that the next swing
	restarts at Hit 1. 800ms is deliberately longer than the 200ms InputBuffer
	tolerance, because the buffer window is spent while the character is still busy
	(Recovery) whereas the chain window is what the player actually feels.
]]
local COMBO_RESET_TIMEOUT = 0.80

--[[
	Day 5 · Part 2/2: the shared wire contract between the client hitbox and the
	server validator.

	These three values are named here rather than written into the two scripts that
	need them, because a client and a server that disagree about a remote's name or
	about how far a sword may reach fail *silently*: the client fires into nothing and
	the server never hears about a hit it should have rejected. One frozen definition
	read by both sides is the only version of that contract that cannot drift.

	`MAX_HIT_DISTANCE` is a server-side ceiling, deliberately generous: the longest
	reach in the chain is Hit 3's committed overhead, and a ceiling below the real
	reach would reject honest swings. The cheap rejections (no live Active window, a
	spoofed hit index, no line of sight) are what actually stop a spoof, so the
	distance check is a backstop rather than the gate.
]]
local REMOTE_HIT_EVENT = "RegisterHitEvent"
local REMOTE_ATTACK_STATE_EVENT = "AttackStateEvent"

--[[
	Day 6 · Part 1/2: the guard wire.

	`REMOTE_GUARD_EVENT` carries one boolean - "I am Blocking" / "I am not" - and
	nothing else. The client cannot *decide* that it is guarding, it can only ask;
	the server answers by writing `GUARD_STATE_ATTRIBUTE` onto the requesting
	character, and that server-written attribute is what `HitValidator` reads when
	it resolves an incoming hit. The attribute is therefore the single source of
	truth, and it is not client-writable: a client changing an attribute on an
	instance that replicated *down* from the server only changes its own copy, and
	that copy never travels back up. A cheater can therefore ask to guard, but
	cannot grant it to itself.

	Keeping the name here rather than in the two scripts that use it is the same
	reason the remote names are here: a client and a server that disagree about a
	string fail silently, and a defender whose attribute is misspelled would simply
	never block anything, with no error anywhere to notice.
]]
local REMOTE_GUARD_EVENT = "GuardStateEvent"
local GUARD_STATE_ATTRIBUTE = "RoninBlocking"

--[[
	Dot-product threshold for a frontal guard, in [-1, 1].

	The defender's LookVector dotted with the unit vector pointing from the
	defender to the attacker. 1.0 is dead-on frontal, 0 is exactly perpendicular
	(90 degrees to either flank), -1.0 is a hit from directly behind.

	0.3 therefore covers roughly 140 degrees of frontal arc - cos(70 degrees) -
	and leaves the remaining 220 degrees (both flanks and the whole back) exposed.
	That is the "turn to face your attacker or get hit" contract: guard covers the
	sword arm, not the whole body, so circling behind a blocking defender is a real
	answer to a real block rather than a formality.

	140 is chosen against Hit 3's committed 38-stud lunge: a frontal guard against
	the finisher has to hold, or the highest-damage swing in the chain would simply
	be unblockable and the guard would read as decorative.
]]
local GUARD_FRONT_DOT_THRESHOLD = 0.3

--[[
	Day 6 · Part 2/2: the posture pool and the guard-break wire.

	Posture is the *currency* a guard spends instead of Health. COMBAT_SPEC §1 says a
	frontal block is "absorbed and converted to posture damage", and this is that
	conversion made concrete: a blocked strike costs the defender zero Health and
	`PoiseDamage` of guard instead, and an empty pool is a guard break.

	Without this, holding the guard button is strictly dominant - it removes 100% of
	frontal damage for free, forever, with no counter-play. Posture is what gives
	blocking a cost, and the cost is what makes letting a fast blade through the
	guard arc a decision rather than a formality.

	`POSTURE_ATTRIBUTE` / `MAX_POSTURE_ATTRIBUTE` are written on the *character*, the
	same way `GUARD_STATE_ATTRIBUTE` is, rather than kept in a server-side table. That
	choice is deliberate: the attributes replicate to every client for free, so a
	posture gauge is a read with no extra network traffic, and a table would have to
	be re-synchronised by hand to get the same result. They remain server-written, so
	the Day 6 · Part 1/2 exploit story is unchanged - a client can change its own copy
	of an attribute, and that copy never travels up.

	`GUARD_BREAK_STUN_DURATION` is 1.5s, inside the 0.5-3.0s band COMBAT_SPEC §1 gives
	Stunned. It is long enough to be a real punish window - a broken guard is the
	opening for a Deathblow, not a flicker - and short enough that a mistaken read
	does not cost a whole fight.
]]
local POSTURE_ATTRIBUTE = "RoninPosture"
local MAX_POSTURE_ATTRIBUTE = "RoninMaxPosture"
local MAX_POSTURE = 100
local GUARD_BREAK_STUN_DURATION = 1.5

--[[
	The two remotes Part 2/2 adds. Same reasoning as the guard remote above: the name
	lives in one place so a disagreement between the two sides fails loudly at load
	instead of silently doing nothing.

	`REMOTE_GUARD_CLASH_EVENT` goes server -> *all* clients and carries one Vector3.
	Two blades meeting is something everyone nearby should see, and it carries no
	authority whatsoever: it decides where a spark is drawn and nothing else, so it
	is broadcast rather than targeted and its payload is checked for type and nothing
	more.

	`REMOTE_GUARD_BREAK_EVENT` goes server -> the *defender's* client only, and carries
	the character plus the stun duration. It is targeted because it is not cosmetic:
	it is the server exercising its authority over a state transition (COMBAT_SPEC §2.1,
	Stunned overrides ALL states), and it must reach exactly the one player it is
	about. The character is carried as well as derived from the connection so the
	client can refuse an event that is not about the character it is wearing.
]]
local REMOTE_GUARD_CLASH_EVENT = "GuardClashEvent"
local REMOTE_GUARD_BREAK_EVENT = "GuardBreakEvent"

--[[
	Defensive footwork.

	Guarding drops the character from 16 to 9 studs per second. The number is not
	decoration: a guard that costs nothing *and* lets you walk at full speed is a
	guard with no downside, which is the same dominant-strategy problem the posture
	pool exists to solve on the health axis. Roughly 56% of normal speed is enough to
	hold ground and sidestep an angle, and slow enough that committing to a new facing
	is a real cost - which is precisely the manoeuvre a guard is supposed to fear.
]]
local GUARD_WALK_SPEED = 9

--[[
	Day 7 · Part 1/2: the parry ladder.

	COMBAT_SPEC §1 asks for a "precision 133ms reaction window" that reflects posture
	back at the attacker. The window is not one number, it is a *ladder*, because a
	lone number cannot express the answer to the only question a parry raises: what
	stops a player from holding the button and parrying everything?

	    0.133s  the full window - a clean, well-timed press
	    0.080s  mashing, and the window narrows
	    0.033s  mashing harder; two frames at 60Hz, close to unreactable

	`PARRY_SPAM_RESET_COOLDOWN` is the price of mashing: a player who does not press
	block for that long starts every ladder again from the top. It is deliberately
	longer than any single swing (Hit 3 is 0.77s end to end), so the cooldown cannot
	expire *during* an exchange the player is meant to be reacting to - it only
	measures genuine disengagement.

	Why the ladder lives here and not in the client module
	---------------------------------------------------------
	Because the client and the server both need it, and the reason the rest of this
	file exists is that two copies of a number which disagree fail *silently*. The
	parry is worse than silent if they drift: a client that believes its window is
	133ms while the server believes it is 80ms produces a parry the player timed
	perfectly and the server refuses, and the only symptom is a game that feels
	broken. One frozen ladder, read by both sides, is the only version of that
	contract that cannot drift.

	`PARRY_REFLECT_POSTURE` (25) is priced against the same pool the defender spends
	on blocking. Hit 1 costs a blocker 15 and Hit 3 costs 35, so a deflect is worth
	a little more than the cheapest block in the chain and rather less than the most
	expensive: enough that four clean parries break a guard, few enough that a
	player who deflects one light hit is not handed the fight.

	`PARRY_HITSTOP_DURATION` is 0.05s - 50ms, three frames. It exists because a
	deflect that costs no Health, no posture, and produces one spark reads on screen
	as a near-miss. Half a tenth of a second of frozen animation is the difference
	between "my guard ate that" and "I just beat that".
]]
local ladder: { number } = { 0.133, 0.080, 0.033 }

local PARRY_WINDOW_LADDER = table.freeze(ladder)
local PARRY_BASE_WINDOW = PARRY_WINDOW_LADDER[1]
local PARRY_SPAM_RESET_COOLDOWN = 0.60
local PARRY_REFLECT_POSTURE = 25
local PARRY_HITSTOP_DURATION = 0.05

--[[
	Day 7 · Part 1/2: the three remotes the parry needs, and why each has the
	audience it has.

	`REMOTE_PARRY_RESULT_EVENT` is server -> the *defender's* client only, and carries
	the character plus the window the server resolved. It is targeted because it is
	the server exercising authority over a presentation and a state read: it is what
	tells the defender's HUD that the parry landed and how wide it was. The character
	is carried as well as derived from the connection so the client can refuse an
	event that is not about the character it is wearing (same rule as
	`REMOTE_GUARD_BREAK_EVENT`).

	`REMOTE_COMBO_BREAK_EVENT` is server -> the *attacker's* client only, and carries
	the character plus the posture just reflected onto it. The server has decided the
	attacker's chain is broken, but the chain index the attacker sees lives in its
	own client process, so that decision has to be carried across rather than applied.

	`REMOTE_DEFLECT_CLASH_EVENT` is server -> *all* clients, carrying one Vector3, on
	the same reasoning as `REMOTE_GUARD_CLASH_EVENT`: two blades meeting is something
	everyone nearby should see, and it decides where a burst is drawn and nothing
	else. It is a *separate* remote rather than a reuse of the clash one because the
	deflect burst is deliberately hotter and wider - if it reused the block's burst,
	the single most important moment in a defensive exchange would look identical to
	holding your guard still.
]]
local REMOTE_PARRY_RESULT_EVENT = "ParryResultEvent"
local REMOTE_COMBO_BREAK_EVENT = "ComboBreakEvent"
local REMOTE_DEFLECT_CLASH_EVENT = "DeflectClashEvent"

local MAX_HIT_DISTANCE = 14

--[[
	Grace added to a declared Active window, in seconds.

	A hit candidate has to travel from the client's frame to the server, so a window
	closed to the microsecond would reject the very swing that opened it. The grace is
	one frame of slack (60fps) plus a little, and nothing more: a window that is
	generous in the other direction is a window an exploiter can sit in.
]]
local ACTIVE_WINDOW_GRACE = 0.1

local AttackConfig = table.freeze({
	COMBO_CHAIN = COMBO_CHAIN,
	COMBO_RESET_TIMEOUT = COMBO_RESET_TIMEOUT,
	REMOTE_HIT_EVENT = REMOTE_HIT_EVENT,
	REMOTE_ATTACK_STATE_EVENT = REMOTE_ATTACK_STATE_EVENT,
	REMOTE_GUARD_EVENT = REMOTE_GUARD_EVENT,
	GUARD_STATE_ATTRIBUTE = GUARD_STATE_ATTRIBUTE,
	GUARD_FRONT_DOT_THRESHOLD = GUARD_FRONT_DOT_THRESHOLD,
	POSTURE_ATTRIBUTE = POSTURE_ATTRIBUTE,
	MAX_POSTURE_ATTRIBUTE = MAX_POSTURE_ATTRIBUTE,
	MAX_POSTURE = MAX_POSTURE,
	GUARD_BREAK_STUN_DURATION = GUARD_BREAK_STUN_DURATION,
	REMOTE_GUARD_CLASH_EVENT = REMOTE_GUARD_CLASH_EVENT,
	REMOTE_GUARD_BREAK_EVENT = REMOTE_GUARD_BREAK_EVENT,
	GUARD_WALK_SPEED = GUARD_WALK_SPEED,
	PARRY_WINDOW_LADDER = PARRY_WINDOW_LADDER,
	PARRY_BASE_WINDOW = PARRY_BASE_WINDOW,
	PARRY_SPAM_RESET_COOLDOWN = PARRY_SPAM_RESET_COOLDOWN,
	PARRY_REFLECT_POSTURE = PARRY_REFLECT_POSTURE,
	PARRY_HITSTOP_DURATION = PARRY_HITSTOP_DURATION,
	REMOTE_PARRY_RESULT_EVENT = REMOTE_PARRY_RESULT_EVENT,
	REMOTE_COMBO_BREAK_EVENT = REMOTE_COMBO_BREAK_EVENT,
	REMOTE_DEFLECT_CLASH_EVENT = REMOTE_DEFLECT_CLASH_EVENT,
	MAX_HIT_DISTANCE = MAX_HIT_DISTANCE,
	ACTIVE_WINDOW_GRACE = ACTIVE_WINDOW_GRACE,
})

return AttackConfig
