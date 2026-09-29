--!strict

--[[
	HitValidator
	Ronin — The Last Blade · server-authoritative hit resolution (Day 6 · Part 1/2)

	The client hitbox is prediction. It decides that a blade touched something, and it
	is allowed to be wrong: it runs on hardware the attacker owns. This script is the
	only thing in the project permitted to turn that claim into a Health change
	(ARCHITECTURE.md #3).

	What arrives from a client
	--------------------------
	Two remotes, both created here and named in `AttackConfig` so the two sides cannot
	drift apart on the strings:

	  * `AttackStateEvent` - "I entered Active / left Active" for a hit index. This
	    opens and closes a server-side window. The client cannot widen it: the window's
	    length comes from the frozen frame data on *this* side.
	  * `RegisterHitEvent` - "my blade touched this model". Carries a model reference
	    and a hit index, and deliberately carries **no damage number**: damage is read
	    back out of `AttackConfig` here, so a client asking for 9999 gets the frame
	    data's 10.

	Why the window is the real gate
	--------------------------------
	Distance and line of sight are both cheap to satisfy: stand near somebody, face
	them, fire. What an exploiter cannot do is make their *own* state machine be in
	Active, because the window is opened by a transition and closed by a transition,
	and a client that fires a hit without having opened one has nothing to spend. So
	the window check runs first and rejects the loudest class of abuse - a hit with no
	swing behind it - before any geometry is even measured.

	Every rejection logs `[EXPLOIT BLOCKED] Rejected spoofed hit from <name>` with the
	reason, so a failed exploit is as visible in the console as a landed hit.

	Rules honoured here:
	  * ARCHITECTURE.md #1 - this file is `--!strict`.
	  * ARCHITECTURE.md #2 - both remotes are wrapped in validation schemas; nothing
	    off the wire is read before its type has been checked.
	  * ARCHITECTURE.md #3 - the client may *ask*; this file decides. The only writes
	    to a Humanoid in the project live here.
	  * ARCHITECTURE.md #4 - this is event-driven, not a per-frame path. The per-swing
	    target set is cleared in place rather than reallocated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConfig = require(ReplicatedStorage:WaitForChild("AttackConfig") :: ModuleScript)

--[[
	Frozen frame data and the shared wire contract, read once at module scope.

	These are the values every check below is written against, and each one is
	re-derived on *this* side rather than trusted from the wire. `COMBO_CHAIN` in
	particular is the reason a client cannot choose its own damage: the request that
	arrives names a hit index, and the number of Health that follows comes from this
	table's entry for that index.
]]
local COMBO_CHAIN = AttackConfig.COMBO_CHAIN
local MAX_HIT_DISTANCE = AttackConfig.MAX_HIT_DISTANCE
local ACTIVE_WINDOW_GRACE = AttackConfig.ACTIVE_WINDOW_GRACE
local GUARD_STATE_ATTRIBUTE = AttackConfig.GUARD_STATE_ATTRIBUTE
local GUARD_FRONT_DOT_THRESHOLD = AttackConfig.GUARD_FRONT_DOT_THRESHOLD
local POSTURE_ATTRIBUTE = AttackConfig.POSTURE_ATTRIBUTE
local MAX_POSTURE_ATTRIBUTE = AttackConfig.MAX_POSTURE_ATTRIBUTE
local MAX_POSTURE = AttackConfig.MAX_POSTURE
local GUARD_BREAK_STUN_DURATION = AttackConfig.GUARD_BREAK_STUN_DURATION

--[[
	Day 8 · Part 1/2: the poise stamp, and the `Active` deadline.

	`POSTURE_LAST_HIT_ATTRIBUTE` is written inside `spendPosture` rather than at the
	two call sites, so the stamp cannot be forgotten by a third one added later. The
	deflect path spends posture on the *attacker* through this same function, which is
	exactly right: reflected posture is pressure on the attacker, so the attacker's
	own recovery grace has to start too — otherwise a defender could parry-spam an
	opponent faster than that opponent recovers and never let them back into the fight.

	`ACTIVE_STATE_ATTRIBUTE` is a deadline rather than a boolean for the same reason
	`PARRY_STATE_ATTRIBUTE` is: it is written where the window is opened and expires
	on its own, so there is no teardown path that can leave it stuck on.
]]
local POSTURE_BROKEN_ATTRIBUTE = AttackConfig.POSTURE_BROKEN_ATTRIBUTE
local POSTURE_LAST_HIT_ATTRIBUTE = AttackConfig.POSTURE_LAST_HIT_ATTRIBUTE
local POSTURE_LAST_HIT_ATTRIBUTE = AttackConfig.POSTURE_LAST_HIT_ATTRIBUTE
local ACTIVE_STATE_ATTRIBUTE = AttackConfig.ACTIVE_STATE_ATTRIBUTE

--[[
	Day 7 · Part 1/2: the parry contract, read on the server side of the wire.

	Re-derived here rather than taken from the message, for the same reason
	`COMBO_CHAIN` is: the client names *that* it parried, and this side decides how
	long the window it gets is. A client that sent its own window width would be
	asking to be believed about a number that decides whether it takes no damage.
]]
local PARRY_WINDOW_LADDER = AttackConfig.PARRY_WINDOW_LADDER
local PARRY_SPAM_RESET_COOLDOWN = AttackConfig.PARRY_SPAM_RESET_COOLDOWN
local PARRY_REFLECT_POSTURE = AttackConfig.PARRY_REFLECT_POSTURE
local PARRY_HITSTOP_DURATION = AttackConfig.PARRY_HITSTOP_DURATION

--[[
	Day 7 · Part 1/2: the attribute that records "a parry window is open on this
	character", set on the *server* and read here.

	An attribute rather than a table entry for the same reason posture is one
	(ARCHITECTURE invariant 2): its lifetime is the character's, so there is no entry
	to leak on `PlayerRemoving`, and because it is server-written, a client editing
	its own copy changes nothing the server reads. A client that never pressed block
	has no window here at all, and one that lies about pressing only ever edits a
	local value that never travels upward.
]]
--[[
	Read from `AttackConfig` rather than written here as of Day 7 · Part 2/2.

	The name moved because the sparring dummy now reads this attribute too, and it
	is the only thing that decides whether a dummy's strike is deflected. Two
	spellings of one attribute name would fail silently in the worst possible
	direction: the player would hold a perfect parry and be hit anyway, with nothing
	in the console to explain it.
]]
local PARRY_STATE_ATTRIBUTE = AttackConfig.PARRY_STATE_ATTRIBUTE


--[[
	Reuses an existing child if one is there.

	Script Sync can re-run a server script without clearing ReplicatedStorage, and
	`Instance.new` on a name that is already taken is a hard error that would take the
	whole validator down. Creating-or-reusing makes a re-run idempotent, which is the
	same rule the client modules follow for their published rigs.
]]
local function ensureRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent") :: RemoteEvent
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local hitEvent = ensureRemote(AttackConfig.REMOTE_HIT_EVENT)
local attackStateEvent = ensureRemote(AttackConfig.REMOTE_ATTACK_STATE_EVENT)
local guardEvent = ensureRemote(AttackConfig.REMOTE_GUARD_EVENT)
local guardClashEvent = ensureRemote(AttackConfig.REMOTE_GUARD_CLASH_EVENT)
local guardBreakEvent = ensureRemote(AttackConfig.REMOTE_GUARD_BREAK_EVENT)
local parryResultEvent = ensureRemote(AttackConfig.REMOTE_PARRY_RESULT_EVENT)
local comboBreakEvent = ensureRemote(AttackConfig.REMOTE_COMBO_BREAK_EVENT)
local deflectClashEvent = ensureRemote(AttackConfig.REMOTE_DEFLECT_CLASH_EVENT)

--[[
	Day 8 Part 2/2: the chaos suite's channel.
	
	Registered here, and not created by `PostureChaos` itself, for the same reason
	every other remote on this line is: this function is the single place that owns
	the ReplicatedStorage wire contract. A script that minted its own remote would
	work in isolation and break the day a second writer appeared - and it would
	break silently, because a missing remote is a nil that every listener treats
	as "no events today".
	
	This was found the hard way: the first playtest of Day 8 P2/2 logged
	"[POSTURE CHAOS] ChaosTestEvent not found" while every other remote was live,
	because nothing had ever registered this one.
]]
--[[ 
	Registered for its side effect only: `PostureChaos` owns the connection and
	reads the handle itself, by design (it must resolve lazily - see the note there).
	The name is kept so the remote is visibly part of the wire contract this script
	declares, rather than an anonymous side effect hidden in a call.
]]
local _chaosEvent = ensureRemote(AttackConfig.REMOTE_CHAOS_EVENT)

--[[
	The one live Active window per attacker.

	`HitIndex` is carried so a hit candidate can be checked against the swing that is
	actually in flight: a client that declares Hit 1 and then bills a hit as Hit 3 gets
	rejected, which is what stops "one cheap swing, infinite heavy damage". A nil entry
	means the attacker is not in Active, and every hit is refused.
]]
type ActiveWindow = {
	HitIndex: number,
	ExpiresAt: number,
}

local activeWindows: { [Player]: ActiveWindow } = {}

-- One contact per target per swing, per attacker. Cleared in place on each new window.
local struckTargets: { [Model]: boolean } = {}

-- Reused across resolutions; FilterDescendantsInstances is rebuilt per shot anyway.
local LOS_PARAMS = RaycastParams.new()
LOS_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
LOS_PARAMS.IgnoreWater = true

--[[
	The one exit that every rejection goes through, so a blocked hit is always
	attributable and never silent. `print` rather than `warn`: this fires on the exploit
	path, and a stream of warnings from every client in a public server is noise that
	gets muted, taking the real signal with it.
]]
local function reject(player: Player, reason: string)
	print(string.format(
		"[EXPLOIT BLOCKED] Rejected spoofed hit from %s - %s",
		player.Name,
		reason
	))
end

--[[
	Schema for a hit candidate. ARCHITECTURE.md #2: nothing off the wire is inspected
	before its type is known, and both arguments are checked - a RemoteEvent does not
	stop a client from firing a string where a Model belongs.

	Returns the validated model, or nil plus the reason it was refused.
]]
local function validateHitRequest(target: any, hitIndex: any): (Model?, string)
	if typeof(target) ~= "Instance" or not target:IsA("Model") then
		return nil, "target is not a Model"
	end

	if typeof(hitIndex) ~= "number" or hitIndex ~= math.floor(hitIndex) then
		return nil, "hit index is not a whole number"
	end

	local data = COMBO_CHAIN[hitIndex]
	if data == nil then
		return nil, string.format("no frame data for hit index %d", hitIndex)
	end

	return target :: Model, ""
end

--[[
	Resolves the root part of a character, or nil. Split find and cast so the nil test
	runs before the cast narrows a value the checker already knows is present.
]]
local function findRoot(model: Model): BasePart?
	local instance = model:FindFirstChild("HumanoidRootPart")
	if instance == nil or not instance:IsA("BasePart") then
		return nil
	end

	return instance :: BasePart
end


--[[
	Day 6 · Part 1/2 — directional guard resolution.

	Returns whether the hit is BLOCKED. `dotProduct` is returned alongside it purely
	so the caller can log the real measured value; the decision itself is the boolean.

	The maths, and why it is a dot product at all:

	    defenderLook = defenderRoot.CFrame.LookVector
	    toAttacker   = (attackerRoot.Position - defenderRoot.Position).Unit
	    dot          = defenderLook:Dot(toAttacker)

	Both vectors are unit length, so the result is the cosine of the angle between
	them and lands in [-1, 1]:

	    +1.0  the attacker is dead ahead
	     0.0  the attacker is exactly 90 degrees off, on either flank
	    -1.0  the attacker is directly behind

	Comparing against `GUARD_FRONT_DOT_THRESHOLD` (0.3 = about 70 degrees) is what
	makes the guard directional instead of omnidirectional: a blocking character
	absorbs hits inside a 140-degree frontal cone and takes full damage everywhere
	else. That is the design contract — the guard covers the sword arm, so circling
	behind a defender has to be a real counter-play rather than a formality.

	Two details that are easy to get wrong and are handled explicitly here:

	  * `.Unit` is NOT called on a zero vector. If the two roots are within a
	    millimetre of each other, `.Unit` returns the zero vector, the dot product is
	    0, and a character standing inside its own attacker would read as a flank hit.
	    `Vector3.Unit` on a near-zero vector is also documented as unreliable, so the
	    magnitude is tested first and the fully-overlapped case is treated as
	    point-blank, which is unambiguously frontal.
	  * `LookVector` is the root's -Z axis, i.e. the direction the character model
	    faces, NOT the direction the camera looks. Using the camera here would make
	    the guard follow the mouse, which is both exploitable (turn the camera, turn
	    the guard) and wrong to the player (the character is visibly facing
	    somewhere else while guarding it).

	The posture hook is deliberately left as a comment rather than a stub. Part 2/2
	converts a blocked hit into posture damage on the defender and, on a broken
	guard, into `Stunned`; putting an empty `if` here now would only be a place for
	that logic to land twice.
]]
local function resolveGuard(
	defenderModel: Model,
	defenderRoot: BasePart,
	attackerRoot: BasePart
): (boolean, number)
	--[[
		The server-written attribute is the only input. A client that never asked to
		guard has no attribute here, and a client that lied about it has a local-only
		copy that never arrived - so the honest and the cheating client are
		indistinguishable here only because the cheating client's lie is invisible.
	]]
	if defenderModel:GetAttribute(GUARD_STATE_ATTRIBUTE) ~= true then
		return false, 0
	end

	local offset = attackerRoot.Position - defenderRoot.Position
	local magnitude = offset.Magnitude

	-- Point-blank: the roots are effectively coincident, so there is no meaningful
	-- direction to test. Treated as frontal, which is the conservative choice - it
	-- is the only reading that cannot be turned into a damage exploit by standing
	-- inside somebody.
	if magnitude < 0.001 then
		return true, 1
	end

	local toAttacker = offset.Unit
	local defenderLook = defenderRoot.CFrame.LookVector
	local dotProduct = defenderLook:Dot(toAttacker)

	return dotProduct >= GUARD_FRONT_DOT_THRESHOLD, dotProduct
end

--[[
	Day 6 · Part 2/2 — the posture component.

	Posture lives on the character as two attributes rather than in a table here, and
	that choice is doing real work:

	  * It replicates to every client for free. A posture gauge over a foe's head is
	    then a read of a local attribute, with no network traffic and no server
	    bookkeeping for who is watching whom.
	  * Its lifetime matches the character's. The Day 7 concern about a posture table
	    leaking entries for players who left disappears entirely, because the character
	    holding the value is what gets cleaned up.
	  * It stays server-written, so the Part 1/2 exploit story is untouched. A client
	    editing `RoninPosture` edits its own copy of a value that replicated *down*,
	    and that copy never travels up - the block path below reads the server's.

	`ensurePosture` is idempotent and self-healing. It is called on spawn and again on
	every block, so a character that somehow lost its attributes (a fresh rig, a
	stripping script, a test dummy spawned without them) is repaired on first use
	rather than silently treated as having infinite or zero posture.
]]
local function ensurePosture(character: Model): (number, number)
	if character:GetAttribute(MAX_POSTURE_ATTRIBUTE) == nil then
		character:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
	end

	if character:GetAttribute(POSTURE_ATTRIBUTE) == nil then
		character:SetAttribute(POSTURE_ATTRIBUTE, 0)
	end

	local current = character:GetAttribute(POSTURE_ATTRIBUTE)
	local maximum = character:GetAttribute(MAX_POSTURE_ATTRIBUTE)

	-- The attribute reads are re-typed because `GetAttribute` returns `any`: a client
	-- cannot write these, but a stripping script can leave a string here, and adding
	-- a string to a number is the kind of error that takes down the hit path.
	if typeof(current) ~= "number" then
		character:SetAttribute(POSTURE_ATTRIBUTE, 0)
		current = 0
	end

	if typeof(maximum) ~= "number" or maximum <= 0 then
		character:SetAttribute(MAX_POSTURE_ATTRIBUTE, MAX_POSTURE)
		maximum = MAX_POSTURE
	end

	return current, maximum
end

--[[
	Spends `amount` of a defender's posture and reports whether the pool ran dry.

	Clamped to `maximum` rather than allowed to overshoot, so the number a player sees
	on a gauge is the number the rules compare against. The return is the pool's state
	*after* the spend, so the caller can print one trace line and branch on one value
	rather than reading the attribute back and hoping it matches what was written.
]]
local function spendPosture(character: Model, amount: number): (number, number, boolean)
	local current, maximum = ensurePosture(character)

	--[[
		Day 8 · Part 1/2: the poise stamp, and why it lives here.

		`PostureEngine` suspends recovery for `POSTURE_HIT_RECOVERY_DELAY` after a
		poise hit, and this function is the *only* place posture is ever spent in the
		project — the block path and the deflect's reflection both route through it.
		Stamping inside it means a new caller cannot introduce posture damage without
		also introducing the pressure that suspends recovery, which is the coupling the
		rule actually needs.

		Written on every spend rather than only on one that *changes* the pool: a
		character already at the maximum still had their guard hit, and their recovery
		should still be suspended. A reflected deflect landing on an attacker at 0
		posture is the clearest case — nothing visible changed on that character, but
		they were absolutely pressured.
	]]
	character:SetAttribute(POSTURE_LAST_HIT_ATTRIBUTE, os.clock())

	-- A negative PoiseDamage would be a healing guard. The frame data is server-owned
	-- and positive, so this is a guard against a future edit rather than a live input,
	-- but it costs one comparison and means the clamp above is the only place that
	-- has to reason about the range.
	local nextPosture = current + math.max(amount, 0)
	if nextPosture > maximum then
		nextPosture = maximum
	end

	character:SetAttribute(POSTURE_ATTRIBUTE, nextPosture)

	return nextPosture, maximum, nextPosture >= maximum
end

--[[
	Day 7 · Part 1/2 — the parry window, on the server.

	A client's block press arrives here as a claim, and the response is to write a
	deadline onto the character's own `RoninParryUntil` attribute. Two things follow
	from putting the deadline in an attribute rather than a table:

	  * The window is a *server clock* value. A client that sends `os.clock() + 5` is
	    not believed, because the timestamp was never taken from the message — the
	    number in the attribute is this side's own `os.clock()` plus a rung of the
	    shared ladder. That is the whole reason the parry cannot be widened remotely.
	  * It expires on its own. There is no timer to cancel and no entry to clear: a
	    character that stops pressing simply has a deadline in the past, which is the
	    same as never having pressed.

	The ladder is re-derived here rather than taken from the wire, and it is stepped
	by *this* side's record of when the last claim arrived. That is deliberately
	redundant with the client's own ladder in `ParryWindow`: the client copy is
	prediction, and this one is the authority. Two counters that agree produce one
	number; a client that forges its own produces only a window it cannot time,
	because this side is already counting the presses.

	`parryLastClaim` and `parryRung` are the only extra pieces of state, and both are
	keyed by Player so they are cleaned up on `PlayerRemoving` beside `activeWindows`.
	`parryRung` is separate from the character on purpose: the ladder is a property of
	a *player's* mashing, not of a body, so it has to survive the body dying and
	restart clean with the next one.
]]
local parryLastClaim: { [Player]: number } = {}
local parryRung: { [Player]: number } = {}

--[[
	Opens a parry window on a character and returns the width it was granted, in
	seconds.

	The returned width is the *server's* rung, not the client's claim, and it is what
	gets reported back to the defender's HUD — the number the player is told they
	parried with is the number the hit resolution actually measured.
]]
local function openParryWindow(character: Model, player: Player): number
	local now = os.clock()

	--[[
		Ladder step, re-derived server-side from this side's own record of the last
		claim. A claim inside the cooldown walks down a rung; the first claim of a
		session, or one after a genuine gap, resets to the top.

		`parryRung` is a per-player table rather than a local for the same reason the
		 client's `currentRung` is module state: written as a local initialised to 1,
		every claim inside the cooldown produced rung 2, so the ladder read
		133 -> 133 -> 133 -> 80 -> 80 -> 80 and the 33ms floor was unreachable — a
		spammer could mash indefinitely and never be punished past the second rung.
		This is the authority for that rule, so it is the copy that has to be right.
	]]
	local lastClaim = parryLastClaim[player]
	if lastClaim ~= nil and (now - lastClaim) < PARRY_SPAM_RESET_COOLDOWN then
		local nextRung = (parryRung[player] or 1) + 1
		if nextRung > #PARRY_WINDOW_LADDER then
			nextRung = #PARRY_WINDOW_LADDER
		end
		parryRung[player] = nextRung
	else
		parryRung[player] = 1
	end

	local rung = parryRung[player]
	local window = PARRY_WINDOW_LADDER[rung]

	parryLastClaim[player] = now
	character:SetAttribute(PARRY_STATE_ATTRIBUTE, now + window)

	return window
end

--[[
	Whether a parry window is open on a character *right now*, and how wide it is.

	Returns the width in seconds (0 when closed) rather than a bare boolean, because
	the caller needs the number for its trace line anyway and reading the attribute
	twice would be two chances to read it after something else changed it.

	The type re-check is the same defensive pattern as `ensurePosture`: `GetAttribute`
	returns `any`, and a stripping script that left a string in this attribute must
	produce "no parry", not a type error inside the hit path. Comparing a non-number
	against a number in Luau yields false, so a garbage value simply reads as closed —
	but an explicit test is what makes that a decision rather than an accident.
]]
local function readParryWindow(character: Model): number
	local until_ = character:GetAttribute(PARRY_STATE_ATTRIBUTE)
	if typeof(until_) ~= "number" then
		return 0
	end

	local remaining = until_ - os.clock()
	if remaining <= 0 then
		return 0
	end

	-- Never report a window wider than the top rung, whatever is in the attribute.
	-- This is the clamp that makes the attribute safe to reason about at all: even a
	-- server-side value that somehow survived longer than the ladder's best case is
	-- reported as the best case.
	if remaining > PARRY_WINDOW_LADDER[1] then
		return PARRY_WINDOW_LADDER[1]
	end

	return remaining
end

--[[
	Closes any window on a character.

	Called on the paths where a parry must not survive: the guard dropping, a stun, a
	teardown. Without it, a character that pressed block and was immediately
	staggered would keep a live window through the stagger and deflect the very
	first hit of the recovery, which is a parry with no button behind it.
]]
local function closeParryWindow(character: Model)
	character:SetAttribute(PARRY_STATE_ATTRIBUTE, 0)
end

--[[

--[[
	Forces a defender's guard down and their body into `Stunned`.

	Two things happen here, in this order, and the order matters:

	  1. `GUARD_STATE_ATTRIBUTE` is cleared on the server. Without this the character
	     would keep *blocking* while stunned, which is nonsense and is also an
	     exploit: a player who is mid-stun could still absorb a strike, because
	     `resolveGuard` reads the attribute and knows nothing about `Stunned`. The
	     client will publish `false` a moment later on its own transition, but the
	     server must not be relying on a round trip to protect itself.
	  2. The defender's client is told to enter `Stunned`. The state machine is
	     client-side (ARCHITECTURE.md #3), so the server's authority over this
	     transition is *carried* by a targeted event rather than applied directly.

	`GetPlayerFromCharacter` is the lookup rather than trusting a name on the wire,
	because there is no wire here: the defender is whatever model the server resolved
	the hit against. An NPC is a legitimate `nil`, in which case the pool still resets
	and the stun simply has no local machine to reach.

	Day 7 · Part 1/2 also closes the parry window here, immediately after the guard
	flag. A staggered character must not be able to deflect the first strike of its
	own recovery: COMBAT_SPEC §2.1 makes Stunned override every other state, and a
	live parry window through a stun would be a state that overrides it.
]]
local function breakGuard(defenderModel: Model)
	defenderModel:SetAttribute(GUARD_STATE_ATTRIBUTE, false)
	closeParryWindow(defenderModel)
	ensurePosture(defenderModel)
	defenderModel:SetAttribute(POSTURE_ATTRIBUTE, 0)

	local defender = Players:GetPlayerFromCharacter(defenderModel)
	if defender == nil then
		return
	end

	guardBreakEvent:FireClient(defender, defenderModel, GUARD_BREAK_STUN_DURATION)
end

--[[
	Day 7 · Part 1/2 — the perfect deflect.

	Everything this function does is a consequence of one rule: the defender pays
	nothing and the attacker pays everything. The parry is not "a block that also
	reflects", it is the *exchange* — 0 Health, 0 posture on the defender, and the
	attacker's frame-data posture cost handed straight back to them, plus their chain
	killed. That asymmetry is the whole reason a player would ever choose the harder,
	tighter-timing button over holding guard.

	Five consequences, in the order they are applied:

	1. **Nothing is taken from the defender.** No `spendPosture`, no `TakeDamage`, and
	   the function returns before the ordinary block path can run either. The only
	   thing it *does* touch on the defender is closing the window, because a
	   successful parry spends it — one press, one deflect.

	2. **`PARRY_REFLECT_POSTURE` goes onto the attacker.** Spent through the same
	   `spendPosture` the block path uses, so a reflected hit that empties the
	   attacker's pool breaks their guard exactly as their own strike would have. That
	   symmetry is the point: a defender who is winning the posture war is now
	   breaking the *other* player's guard, using the other player's own damage
	   numbers.

	3. **The attacker's combo is interrupted.** The window is cleared rather than
	   merely expired, so the strike in flight cannot be billed — and a follow-up hit
	   from the same swing is refused, which is what "interrupted" has to mean to be
	   worth anything. The attacker's *client* is told separately, because the chain
	   index it renders lives in that process (ARCHITECTURE #3).

	4. **A 50ms hitstop on both characters.** Sent to each side's own client rather
	   than applied here, for the same reason the guard break is: the server may not
	   write a `Humanoid`'s animation, and the *local* client is the only place where
	   freezing the local character is both possible and invisible to the other
	   player as a rubber band.

	5. **A bright burst at the contact point**, broadcast to everyone, because two
	   blades clashing is something an onlooker should see. The same
	   midpoint-and-lift the block path uses, for the same reason it is within a foot
	   of the real contact every time.

	`deflector` and `attackerPlayer` are resolved by `GetPlayerFromCharacter` rather
	than by trusting anything on the wire. An NPC defender is a legitimate nil, in
	which case the parry still resolves and still reflects — only the two targeted
	events are skipped, because there is no local machine to reach.
]]
local function resolveDeflect(
	defenderModel: Model,
	attackerModel: Model,
	attackerRoot: BasePart,
	defenderRoot: BasePart,
	attackerPlayer: Player,
	window: number
)
	-- 1. The defender pays nothing. The window is spent by the parry itself.
	closeParryWindow(defenderModel)

	-- 2. Reflect onto the attacker, through the ordinary posture path.
	local posture, maxPosture, isBroken = spendPosture(attackerModel, PARRY_REFLECT_POSTURE)

	-- 3. Interrupt the attacker's chain, server-side.
	activeWindows[attackerPlayer] = nil
	table.clear(struckTargets)

	-- 5. Contact point, identical in spirit to the block path's so the two bursts
	-- do not read as coming from different parts of the world.
	local deflectPoint = (attackerRoot.Position + defenderRoot.Position) * 0.5
		+ Vector3.new(0, 1.2, 0)

	deflectClashEvent:FireAllClients(deflectPoint)

	if isBroken then
		breakGuard(attackerModel)
	end

	-- 4. Both sides are told, each about their own character.
	local defenderPlayer = Players:GetPlayerFromCharacter(defenderModel)
	if defenderPlayer ~= nil then
		parryResultEvent:FireClient(
			defenderPlayer,
			defenderModel,
			window,
			PARRY_REFLECT_POSTURE,
			attackerModel.Name
		)
	end

	comboBreakEvent:FireClient(attackerPlayer, attackerModel, PARRY_REFLECT_POSTURE, PARRY_HITSTOP_DURATION)

	print(string.format(
		"[PERFECT DEFLECT] %s parried %s! Reflected %d posture to attacker. (Window: %dms, Attacker posture: %d/%d)",
		defenderModel.Name,
		attackerModel.Name,
		PARRY_REFLECT_POSTURE,
		math.floor(window * 1000),
		posture,
		maxPosture
	))
end

--[[
	Day 6 · Part 1/2 — the guard wire.

	A client may *ask* to guard, and this is the only place that answers. The answer
	is written as an attribute on the requesting player's own character, and that
	attribute - not the client - is what `resolveGuard` reads when a hit lands. The
	distinction is the whole security property: an attribute set here replicates
	*down* to every client, while the same attribute set by the owning client only
	ever changes that client's local copy and is never sent back up. So a cheater can
	send this event and be told yes, but cannot skip sending it and simply declare
	itself Blocking.

	Two guards against the obvious abuses, both of which matter more than they look:

	  * The character is resolved from `player.Character` on *this* side. A client
	    cannot nominate somebody else's model, so it cannot raise a guard on a
	    character it is not wearing, and it cannot clear one either.
	  * There is no cooldown and no trust in the boolean's timing. The client says
	    "I am holding guard" and the server records exactly that. Part 2/2 adds
	    posture cost to holding a block, which is the real incentive structure: once
	    a guard costs something, "always hold the button" stops being a strategy and
	    the client lying about it stops being free.

	Written this way rather than kept in a server-side table so that a *different*
	system (the NPC/AI guard in a later day, or a scripted cutscene) can set the same
	attribute directly and have the identical block logic apply to it, with no second
	implementation of the dot product.
]]
guardEvent.OnServerEvent:Connect(function(player: Player, isBlocking: any, isParrying: any)
	if typeof(isBlocking) ~= "boolean" then
		return
	end

	local character = player.Character
	if character == nil then
		return
	end

	character:SetAttribute(GUARD_STATE_ATTRIBUTE, isBlocking)

	--[[
		Day 7 · Part 1/2: the same message now also carries "a parry window opened".

		The second argument is treated as a *claim*, not a fact, and the response is
		to open a server-clock window of the server's own choosing
		(`openParryWindow`) — never to store the number the client sent. A client
		sending `true` unconditionally gets a window it must still time, and the
		server's own ladder is already counting its presses, so a spammer walks down
		exactly the same rungs a legitimate masher does.

		`typeof ~= "boolean"` rather than a truthiness test: a client that sends
		`"false"` must not open a window, and in Lua every string is truthy, so an
		`if isParrying then` would treat the string as a parry. This is the same
		reason the first argument is type-checked, and the reason ARCHITECTURE #2
		says nothing off the wire is read before its type is known.

		A window is only opened while the guard is actually up. A claim arriving with
		`isBlocking == false` is refused, because a parry is a *precise* version of
		blocking and there is no reading of "parried without holding guard" that
		should cost the attacker posture.
	]]
	if typeof(isParrying) ~= "boolean" then
		return
	end

	if isParrying and isBlocking then
		openParryWindow(character, player)
	elseif not isParrying then
		-- The window is closed explicitly on any "not parrying" report, including a
		-- guard release. Left to expire on its own it would still be live for the
		-- remainder of its 133ms after the player let go of the button, which is a
		-- parry earned by a press the player has since withdrawn.
		closeParryWindow(character)
	end
end)

--[[
	Opens the Active window for a swing.

	The window's length is `ActiveDuration` from the *server's* copy of the frame
	data, not a number the client sent. A client that declares a hit index it knows
	opens a window it cannot then stretch, so the cheapest possible attack - declare
	Active and hold it - still buys only the 120-180ms the real swing lasts.

	A declaration while a window is already open is ignored rather than refreshed: that
	is an exploiter spamming Active to build a permanent window, and the ignore is what
	stops it. The legitimate sequence (Active -> Recovery -> Idle -> Active again)
	always arrives after the previous window has expired, because recovery is longer
	than the window.
]]
attackStateEvent.OnServerEvent:Connect(function(player: Player, hitIndex: any)
	if typeof(hitIndex) ~= "number" or hitIndex ~= math.floor(hitIndex) then
		return
	end

	local data = COMBO_CHAIN[hitIndex]
	if data == nil then
		return
	end

	local now = os.clock()
	local existing = activeWindows[player]
	if existing ~= nil and existing.ExpiresAt > now then
		return
	end

	-- A new swing starts a new set of targets, so the previous swing's debounce does
	-- not carry into it.
	table.clear(struckTargets)

--[[
Day 8 - Part 1/2: mirror the Active window onto the character.

PostureEngine must suspend posture recovery mid-swing, and it owns no state
machine to ask - the machine lives in the client's process (ARCHITECTURE.md #3).
This attribute is that answer, and it is the *same* deadline the hit gate below
already computes: one number, written once, read by two consumers. Deriving it
a second time for the engine would be two answers to one question.

Written on the character rather than left only in ctiveWindows because that
table is keyed by Player and so has no entry for the sparring rig, which the
engine must gate too. The attribute's lifetime is the model's, so nothing leaks
on PlayerRemoving - the Day 6 invariant 2 argument, in a third place now.

Absolute and server-written, so a client cannot claim a swing to suppress its
own recovery: the value is this side's os.clock() plus the frame data's own
Active duration and grace.
]]
local attackerCharacter = player.Character
if attackerCharacter ~= nil then
attackerCharacter:SetAttribute(ACTIVE_STATE_ATTRIBUTE, now + data.ActiveDuration + ACTIVE_WINDOW_GRACE)
end

activeWindows[player] = {
HitIndex = hitIndex,
ExpiresAt = now + data.ActiveDuration + ACTIVE_WINDOW_GRACE,
}
end)

--[[
	Resolves one hit candidate.

	The order below is the whole policy, cheapest and loudest rejection first:

	  1. Schema. A malformed request is a bug or a probe, not a hit.
	  2. A live Active window, whose hit index matches the candidate's. This is the
	     gate - it is what a client cannot manufacture without spending a real swing.
	  3. The target resolves to a character with a living Humanoid, and is not the
	     attacker (a self-hit is either a bug or a damage exploit).
	  4. Debounce: one contact per target per swing.
	  5. Distance, measured root to root against the server-side ceiling.
	  6. Line of sight from the attacker's root to the target's, with both characters
	     excluded. This is what makes "stand next to somebody behind a wall and claim
	     a hit" fail, and it is the last geometric check because it is the only one
	     that costs a raycast.

	Damage is read from the server's frame data at the last moment, so it is never a
	value that arrived over the network.
]]
hitEvent.OnServerEvent:Connect(function(player: Player, target: any, hitIndex: any)
	-- 1. Schema ---------------------------------------------------------------
	local targetModel, schemaReason = validateHitRequest(target, hitIndex)
	if targetModel == nil then
		reject(player, schemaReason)
		return
	end

	-- 2. The gate: an open, unexpired Active window for this exact hit index -------
	local window = activeWindows[player]
	if window == nil or window.ExpiresAt <= os.clock() then
		reject(player, "no active attack window")
		return
	end

	if window.HitIndex ~= hitIndex then
		reject(player, string.format(
			"hit index %d does not match the swing in flight (#%d)",
			hitIndex,
			window.HitIndex
		))
		return
	end

	-- 3. The target is a character, alive, and not the attacker -------------------
	local character = player.Character
	if character == nil then
		reject(player, "the attacker has no character")
		return
	end

	if targetModel == character then
		reject(player, "the target is the attacker")
		return
	end

	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if targetHumanoid == nil or targetHumanoid.Health <= 0 then
		reject(player, "the target has no living Humanoid")
		return
	end

	-- 4. One contact per target per swing ----------------------------------------
	if struckTargets[targetModel] then
		reject(player, "that target was already struck in this swing")
		return
	end

	-- 5. Distance ---------------------------------------------------------------
	local attackerRoot = findRoot(character)
	local targetRoot = findRoot(targetModel)
	if attackerRoot == nil or targetRoot == nil then
		reject(player, "a root part was missing")
		return
	end

	local distance = (attackerRoot.Position - targetRoot.Position).Magnitude
	if distance > MAX_HIT_DISTANCE then
		reject(player, string.format("target was %.1f studs away (max %.0f)", distance, MAX_HIT_DISTANCE))
		return
	end

	-- 6. Line of sight ----------------------------------------------------------
	local toTarget = targetRoot.Position - attackerRoot.Position
	if toTarget.Magnitude > 0.001 then
		LOS_PARAMS.FilterDescendantsInstances = { character, targetModel }
		local obstruction = workspace:Raycast(attackerRoot.Position, toTarget, LOS_PARAMS)
		if obstruction ~= nil then
			reject(player, "no line of sight to the target")
			return
		end
	end

	-- Resolved. The damage is the server's number, not the client's ---------------
	local data = COMBO_CHAIN[hitIndex]
	if data == nil then
		reject(player, "frame data disappeared mid-resolution")
		return
	end

	struckTargets[targetModel] = true

	--[[
		7. Directional guard, posture and guard break (Day 6) -----------------------

		Resolved *after* every rejection and immediately before `TakeDamage`, so a
		blocked hit is still a real hit that passed the whole gauntlet - it simply has
		a different outcome. Nothing is short-circuited before this point on account of
		the guard: a client cannot use "I was blocking" to skip the window check, the
		distance check or the line-of-sight check, because the guard is only consulted
		once the hit has already been proven legitimate.

		It also runs after `struckTargets` is set, which matters: a blocked blade still
		touched the target, so the swing has spent its one contact on that target. If
		the debounce were not consumed, an attacker could spray the same defender for
		the length of one Active window and get a free re-roll on whether they happen
		to be facing the right way.
	]]
	local isBlocked, dotProduct = resolveGuard(targetModel, targetRoot, attackerRoot)

	if isBlocked then
		--[[
			Day 7 · Part 1/2: the parry check, ahead of everything the block does.

			Placed *inside* the frontal branch and *before* the posture spend, and the
			order is the entire policy. COMBAT_SPEC §1 makes a parry strictly better
			than a block (no damage taken, posture reflected) and only inside the same
			frontal cone the guard covers — a parry from behind would be a free trade
			for anyone willing to walk round, which is the counter-play the cone
			exists to reward. And it must precede `spendPosture`, because a parry costs
			the defender *no* posture at all; anything spent here would be a bug the
			player experiences as "parried and still lost ground".

			The window is read from the server's own attribute, so this is a decision
			this side makes about a deadline this side wrote. The client could not have
			widened it even by sending a larger number.
		]]
		local parryWindow = readParryWindow(targetModel)
		if parryWindow > 0 then
			resolveDeflect(targetModel, character, attackerRoot, targetRoot, player, parryWindow)
			return
		end

		--[[
			The whole point of Part 2/2, in three lines.

			Zero Health - COMBAT_SPEC §1's "absorbed and converted to posture damage",
			taken literally and without a chip-damage fudge. What the block costs the
			defender is `data.PoiseDamage` off the frame data, which is why the same
			three numbers the attacker's damage scales with (15 / 20 / 35) also scale
			with how expensive it is to block: Hit 3 is both the hardest hit to eat and
			the swing most likely to break a guard, from the one table.

			The clash point is the midpoint of the two roots, lifted to roughly guard
			height. It is an approximation, and deliberately a coarse one: the true
			contact point lives in the *attacker's* client, because that is where the
			blade sweep ran, and shipping an attacker-supplied position to every client
			to move a spark would mean trusting a client with the location of a VFX for
			no benefit. Midpoint-and-lift is within a foot or so of the real contact
			every time, which is well inside the size of the burst.
		]]
		local clashPoint = (attackerRoot.Position + targetRoot.Position) * 0.5
			+ Vector3.new(0, 1.2, 0)

		guardClashEvent:FireAllClients(clashPoint)

		local posture, maxPosture, isBroken = spendPosture(targetModel, data.PoiseDamage)

		print(string.format(
			"[GUARD] Blocked frontal strike! Posture: %d/%d (Dot: %.3f, +%d)",
			posture,
			maxPosture,
			dotProduct,
			data.PoiseDamage
		))

		if isBroken then
			breakGuard(targetModel)

			print(string.format(
				"[GUARD BREAK] Posture shattered! %s forced into Stunned!",
				targetModel.Name
			))
		end

		-- No `TakeDamage` on this path, ever. The `return` is the guarantee.
		return
	end

	--[[
		Not blocked, so the hit lands at full damage. The trace is split in two
		because "hit a defender who was guarding from the wrong angle" and "hit an
		unguarded target" are different events, and only the first proves the guard
		system is actually running. Logging both as one generic hit would make a
		guard that silently stopped working indistinguishable from a guard that was
		correctly beaten.
	]]
	local isGuarding = targetModel:GetAttribute(GUARD_STATE_ATTRIBUTE) == true

	if isGuarding then
		print(string.format(
			"[GUARD BYPASSED] Backstab landed on %s (Dot: %.3f)",
			targetModel.Name,
			dotProduct
		))
	else
		print(string.format(
			"[SERVER HIT CONFIRMED] Struck: %s for %d HP",
			targetModel.Name,
			data.Damage
		))
	end

	-- The damage is applied on both unblocked paths. COMBAT_SPEC is explicit that a
	-- guard converts a *frontal* hit into posture damage - a flank or rear hit is
	-- full damage, and that is the entire reason circling behind a guard works.
	targetHumanoid:TakeDamage(data.Damage)
end)

--[[
	Day 6 · Part 2/2: seed the posture pool on every character that spawns.

	Both the join and the respawn paths are covered, and the existing-character check
	covers the player who was already in the world when this script started - the same
	three-way problem the client lifecycle modules solve, and solved the same way.

	The block path would repair the attributes on first use anyway (`ensurePosture`), so
	this is not about correctness of the damage rules. It is about a HUD: a gauge that
	reads a nil attribute for the first half second of a character's life flickers from
	"empty" to "0/100" at an arbitrary moment, whereas one seeded at spawn simply
	starts at zero.
]]
--[[
	Seeds a fresh character so the parry attribute is never nil.

	The hit path already treats a missing attribute as "no parry", so this is not
	about correctness of the deflect rule — it is about the same reason posture is
	seeded. A gauge or a HUD that reads `RoninParryUntil` would otherwise have to
	handle "absent" separately from "0", and the two would drift apart the first time
	one of them was written and the other was not.
]]
local function seedPosture(character: Model)
	ensurePosture(character)
	closeParryWindow(character)

	--[[
		Day 8 - Part 1/2: seed the recovery pair here too, for the same reason the
		pool is seeded at all. `PostureEngine` repairs both on its first tick
		regardless, so this is not about correctness - it is that a character which
		spent its first half second with a nil `RoninPostureBroken` is a character
		whose HUD, on Part 2/2, would have to handle "absent" separately from "false",
		and the two readings would drift the first time one was written and the other
		was not.

		`0` is the correct seed for the stamp: it reads as "infinitely long ago" to
		the grace test, which is the truth for a body that has never been hit.
	]]
	character:SetAttribute(POSTURE_BROKEN_ATTRIBUTE, false)
	character:SetAttribute(POSTURE_LAST_HIT_ATTRIBUTE, 0)
	character:SetAttribute(ACTIVE_STATE_ATTRIBUTE, 0)
end

local function bindPlayerPosture(player: Player)
	local character = player.Character
	if character ~= nil then
		seedPosture(character)
	end

	player.CharacterAdded:Connect(seedPosture)
end

Players.PlayerAdded:Connect(bindPlayerPosture)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	bindPlayerPosture(existingPlayer)
end

--[[
	A player who leaves mid-swing must not leave a window behind, or a rejoin under the
	same account would inherit it. The table is keyed by Player, so this is also what
	keeps it from growing for the life of the server.

	`parryLastClaim` is cleared for the same reason and on the same edge. It is the
	one piece of parry state that is *not* an attribute — the ladder rung a player is
	on cannot live on a character, because the rung has to survive the character dying
	and restart clean with the new one. Leaving it behind would mean a rejoin's first
	parry opening on rung 2 for a press the player has not made yet.
]]
Players.PlayerRemoving:Connect(function(player: Player)
	activeWindows[player] = nil
	parryLastClaim[player] = nil
	parryRung[player] = nil
end)

print("[SERVER] HitValidator online: RegisterHitEvent, AttackStateEvent, GuardStateEvent, GuardClashEvent, GuardBreakEvent, ParryResultEvent, ComboBreakEvent, DeflectClashEvent and ChaosTestEvent are live.")
