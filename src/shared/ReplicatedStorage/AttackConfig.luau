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
	Day 8 · Part 1/2: the posture *recovery* contract.

	`POSTURE_BROKEN_ATTRIBUTE` is the server's "this character is currently kneeling
	from a posture rupture" flag. It is a **boolean**, matching `GUARD_STATE_ATTRIBUTE`
	rather than the number the Day 8 brief used as a placeholder type: Roblox locks an
	attribute's type on first write, and the neighbouring guard flag is already a
	boolean. Writing `1`/`0` here would therefore have produced a second, differently
	typed flag on the same model for no gain — every reader here tests it for identity
	against `true`, exactly as `resolveGuard` does.

	`POSTURE_LAST_HIT_ATTRIBUTE` is an `os.clock()` stamp of the last *poise* hit on
	this character, and it is the input to the recovery grace period. Without it a
	guard could never recover: the block that spends posture is also what would spend
	the recovery, so a character under sustained pressure would sit at whatever it
	climbed to forever. It is an attribute for the same reason `RoninParryUntil` is
	one — the value's lifetime is the character's, so there is no server table to leak
	on `PlayerRemoving`, and it is server-written, so a client editing its local copy
	changes nothing the engine reads.
]]
local POSTURE_BROKEN_ATTRIBUTE = "RoninPostureBroken"
local POSTURE_LAST_HIT_ATTRIBUTE = "RoninLastPostureHitTime"

--[[
	Day 8 · Part 1/2: how long after the last poise hit recovery stays suspended.

	1.2s. Long enough to cover a whole exchange rather than reacting between two
	hits of the *same* swing, and short enough that a player who disengages feels
	their guard come back rather than waiting out a long invisible timer. The number
	is the direct expression of Sekiro's rule that posture recovers "while you are
	not being pressured" — pressure is not "is blocking", it is "was just hit".
]]
local POSTURE_HIT_RECOVERY_DELAY = 1.2

--[[
	Day 8 · Part 1/2: the non-linear recovery ladder, keyed on *Health* percentage.

	Recovery is deliberately not a flat rate, because a flat rate makes Health
	irrelevant to the posture war. With one rate, a player at 10 HP and a player at
	100 HP recover identically and there is no reason to disengage to heal. The three
	tiers turn Health into the thing that decides how long a broken guard takes to
	recover from:

		hpPct >= 0.75  ->  16/sec. A healthy fighter regroups in about six seconds.
		hpPct >= 0.25  ->   8/sec. Halved: wounded fighters are measurably slower to
		                     re-guard, so trading blows has a compounding cost.
		hpPct <  0.25  ->   0/sec. ZERO recovery. Below a quarter Health a character
		                     cannot rebuild a guard at all and is one block from a
		                     second rupture. This is the tier that makes the posture
		                     war decide fights instead of being a resource both sides
		                     refill at the same rate.

	Two thresholds and three rates is the whole tuning surface. They are named here
	rather than inlined in the engine because they are the numbers a designer tunes,
	and a ladder split across two files is a ladder that drifts.
]]
local POSTURE_RECOVERY_HEALTHY_THRESHOLD = 0.75
local POSTURE_RECOVERY_MID_THRESHOLD = 0.25
local POSTURE_RECOVERY_RATE_HEALTHY = 16
local POSTURE_RECOVERY_RATE_MID = 8
local POSTURE_RECOVERY_RATE_CRITICAL = 0

--[[
	Day 8 · Part 1/2: the rupture itself.

	`POSTURE_RUPTURE_DURATION` is 3.0s — deliberately the very top of the 0.5-3.0s
	band COMBAT_SPEC §1 gives `Stunned`. A guard break is the most expensive thing
	that can happen to a player in a posture war, and a rupture is the *second* one
	being spent on top of it: the character is already carrying posture damage from
	the strike that broke them. It is the longest lock in the spec for that reason,
	and because 3.0s is also the ceiling the client's `applyGuardBreakStun` clamps to
	(`MAX_STUN_DURATION`), the clamp is a no-op here rather than a silent truncation.

	`DEFAULT_WALK_SPEED` is Roblox's stock Humanoid WalkSpeed of 16. It is a
	*fallback*, not the restore target: the engine captures whatever the character
	was actually walking at when the rupture landed and puts that back. Hardcoding a
	restore to 16 would be wrong for any character whose speed is not 16 — and one
	exists in this project already: `WeaponVisuals` writes `GUARD_WALK_SPEED` (9) on
	guard and restores a captured "rest" value on release, so a rupture that landed
	mid-guard and restored a hardcoded 16 would leave the client restoring *16* as
	its rest speed forever after. Capture-and-restore keeps the two writers from
	corrupting each other.
]]
local POSTURE_RUPTURE_DURATION = 3.0
local DEFAULT_WALK_SPEED = 16

--[[
	Day 8 · Part 2/2: the client's stun-rooting restore target for jumping.

	`DEFAULT_JUMP_POWER` is Roblox's stock Humanoid JumpPower of 50 — it is seeded from
	`StarterPlayer.CharacterJumpPower`, whose default is 50 and whose range is 0-1000.
	`UseJumpPower` is true by default, so `JumpPower` (rather than `JumpHeight`) is the
	property the engine is actually reading, which is why the client zeroes and
	restores *this* property rather than the newer one.

	Like `DEFAULT_WALK_SPEED` above it is a **fallback, not the restore target**.
	`CombatController` captures whatever the local character was actually walking and
	jumping at when the stun landed and puts those numbers back. A character that was
	mid-guard walks at `GUARD_WALK_SPEED` (9), and a rupture that landed on it should
	wake that character up walking at 9 — restoring a hardcoded 16 here would leave the
	client permanently editing a rest speed the rest of the project never agreed with.
]]
local DEFAULT_JUMP_POWER = 50

--[[
	Day 8 · Part 1/2: how the server reads "this character is mid-swing".

	Recovery is suspended while a character is `Blocking` or `Active`, and the
	server has no state machine of its own to ask (ARCHITECTURE #3 — the machine
	lives in the owning client's process, which is exactly why `breakGuard` *carries*
	its transition across on a targeted event instead of applying it).

	`Blocking` needs no new attribute: `GUARD_STATE_ATTRIBUTE` is already a
	server-written boolean on the character, so the engine reads that directly and
	the two can never disagree.

	`Active` does need one, and it is the same shape as `PARRY_STATE_ATTRIBUTE` — an
	absolute `os.clock()` deadline written by `HitValidator` when it opens the Active
	window, rather than a boolean that has to be polled and cleared from two places.
	A deadline expires on its own and needs no teardown, and it is strictly
	server-written, so a client cannot claim a swing to suppress its own recovery.
]]
local ACTIVE_STATE_ATTRIBUTE = "RoninActiveUntil"

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
	Day 7 · Part 2/2: the attribute that records "a parry window is open on this
	character", as an absolute `os.clock()` deadline written by the server.

	It was a private string inside `HitValidator` until this part. It is here now
	because a *second* server-side attacker reads it: the sparring dummy has to ask
	"is this defender inside a parry window?" with exactly the question the player
	path asks, and a second copy of the string is precisely the silent failure this
	whole file exists to prevent - a dummy that checks a misspelled attribute simply
	never deflects, with no error anywhere, and the feature looks unimplemented
	rather than miswired.

	The attribute stays server-written: it is the server's own deadline, so a client
	editing its local copy changes nothing either attacker reads.
]]
local PARRY_STATE_ATTRIBUTE = "RoninParryUntil"

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

--[[
	Day 8 · Part 2/2: the client -> server handshake for the posture chaos suite.

	The [Y] harness cannot assert a *server* invariant from the client: it can set
	attributes on its own copy of the model, but those writes never replicate back and
	the client is not the party that decides a rupture. So the two Day 8 tests that
	genuinely need server truth (the 99.9% edge and the death-during-rupture
	override) are driven over this remote and answered on the same one, while the
	invariants that *are* client-side (freeze enforced, listeners torn down) are
	asserted locally against the real bound machine.

	One remote, two directions, rather than a request remote and a reply remote: a
	test that reports its own result on the channel that asked for it cannot have its
	answer delivered to a different player's client by mistake, and the suite is
	strictly one-shot so there is nothing for a second channel to disambiguate.
]]
local REMOTE_CHAOS_EVENT = "ChaosTestEvent"

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
	POSTURE_BROKEN_ATTRIBUTE = POSTURE_BROKEN_ATTRIBUTE,
	POSTURE_LAST_HIT_ATTRIBUTE = POSTURE_LAST_HIT_ATTRIBUTE,
	POSTURE_HIT_RECOVERY_DELAY = POSTURE_HIT_RECOVERY_DELAY,
	POSTURE_RECOVERY_HEALTHY_THRESHOLD = POSTURE_RECOVERY_HEALTHY_THRESHOLD,
	POSTURE_RECOVERY_MID_THRESHOLD = POSTURE_RECOVERY_MID_THRESHOLD,
	POSTURE_RECOVERY_RATE_HEALTHY = POSTURE_RECOVERY_RATE_HEALTHY,
	POSTURE_RECOVERY_RATE_MID = POSTURE_RECOVERY_RATE_MID,
	POSTURE_RECOVERY_RATE_CRITICAL = POSTURE_RECOVERY_RATE_CRITICAL,
	POSTURE_RUPTURE_DURATION = POSTURE_RUPTURE_DURATION,
	DEFAULT_WALK_SPEED = DEFAULT_WALK_SPEED,
	DEFAULT_JUMP_POWER = DEFAULT_JUMP_POWER,
	ACTIVE_STATE_ATTRIBUTE = ACTIVE_STATE_ATTRIBUTE,
	REMOTE_GUARD_CLASH_EVENT = REMOTE_GUARD_CLASH_EVENT,
	REMOTE_GUARD_BREAK_EVENT = REMOTE_GUARD_BREAK_EVENT,
	GUARD_WALK_SPEED = GUARD_WALK_SPEED,
	PARRY_WINDOW_LADDER = PARRY_WINDOW_LADDER,
	PARRY_BASE_WINDOW = PARRY_BASE_WINDOW,
	PARRY_SPAM_RESET_COOLDOWN = PARRY_SPAM_RESET_COOLDOWN,
	PARRY_REFLECT_POSTURE = PARRY_REFLECT_POSTURE,
	PARRY_HITSTOP_DURATION = PARRY_HITSTOP_DURATION,
	PARRY_STATE_ATTRIBUTE = PARRY_STATE_ATTRIBUTE,
	REMOTE_PARRY_RESULT_EVENT = REMOTE_PARRY_RESULT_EVENT,
	REMOTE_COMBO_BREAK_EVENT = REMOTE_COMBO_BREAK_EVENT,
	REMOTE_DEFLECT_CLASH_EVENT = REMOTE_DEFLECT_CLASH_EVENT,
	REMOTE_CHAOS_EVENT = REMOTE_CHAOS_EVENT,
	MAX_HIT_DISTANCE = MAX_HIT_DISTANCE,
	ACTIVE_WINDOW_GRACE = ACTIVE_WINDOW_GRACE,
})

return AttackConfig
