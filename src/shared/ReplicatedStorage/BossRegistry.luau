--!strict

--[[
BossRegistry
Ronin - The Last Blade . the two-way bridge between the boss and the fight

Why this file exists at all
--------------------------
`HitValidator` is a `Script`, not a `ModuleScript`, so `require` cannot load it -
and that is fine, because nothing needs to load it. What is not fine is the fact
that a boss fight has *two* directions of damage and the existing project already
owns one of them.

Direction 1 - the player's katana lands on the boss.
`HitValidator` can resolve this itself: it has the window gate, the debounce,
the range check, the line-of-sight check and the frame data. All it lacks is
somebody who knows what 24 damage is *worth* to the Commander, and that
somebody is `Boss1Controller`.

Direction 2 - the boss's nodachi lands on a player.
This is the one that must NOT be reimplemented. `HitValidator` already owns
the parry window, the frontal guard cone, the posture pool, the guard break
and every remote that makes the feedback play (`GuardClashEvent`,
`DeflectClashEvent`, `ParryResultEvent`, `GuardBreakEvent`). Copying those
into the boss controller would be the exact duplication the `SparringDummy`
header warns about - two authorities for one rule, drifting.

So the registry carries a resolver *in each direction*, and each side installs
the half it owns:

Boss1Controller  installs ResolveBossDamage   (what a player hit is worth)
HitValidator     installs ResolvePlayerDamage  (what a boss hit is worth)

Both are server-only functions. The module lives in ReplicatedStorage because the
HUD reads the same attributes, but `Set*` is only ever called from a server
Script, so a client can reach this module and cannot install anything in it.

Rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #2 - nothing arrives over a wire here; these are direct calls
    between two server scripts.
  * ARCHITECTURE.md #3 - the server remains the sole authority on both sides.
]]

local BossConfig = require(script.Parent:WaitForChild("BossConfig"))

--[[
How a boss strike is answered, passed down from the AI so the *rules* can stay in
one place while the *geometry* stays in the other.

Three flags, mutually exclusive by construction (see `BossConfig` S4):

  * `Deflectable` - the parry window answers it, reflects posture onto the boss
    and cancels the swing.
  * `Unblockable` - the guard is not a partial answer, it is no answer. Full
    damage through a raised guard; the i-frame dodge still works.
  * `MustJump`    - nothing at ground level answers it. The i-frame dodge does not
    even get consulted, because a committed dodge is a *horizontal* step and this
    is a low horizontal blade.
]]
export type BossStrikeKind = {
Deflectable: boolean,
Unblockable: boolean,
MustJump: boolean,
-- The resolved numbers for this particular hit (a flurry's third step differs
-- from its first), not the move's averages.
Damage: number,
Posture: number,
-- The world-space contact point, for the clash VFX. The boss computes it because
-- the boss is the attacker and owns its own blade's position.
ContactPoint: Vector3,
}

export type BossDamageResult = {
Applied: boolean,
Defeated: boolean,
PostureBroken: boolean,
Reason: string,
}

-- What the boss controller installs: "the player's katana landed - what is it worth?"
export type BossResolver = (attacker: Model, damage: number, poise: number, hitIndex: number) -> BossDamageResult

-- What HitValidator installs: "the boss's nodachi landed - what does it cost?"
export type PlayerStrikeResolver = (boss: Model, victim: Model, kind: BossStrikeKind) -> string

local bossResolver: BossResolver? = nil
local playerStrikeResolver: PlayerStrikeResolver? = nil

--[[
Identity test, and the only one.

It reads the attribute rather than asking a registry of known bosses, because a
registry of known bosses would be a second thing to forget to populate when the
boss is cloned in, and a boss that exists but is not in a registry is a boss the
player's sword passes straight through. The attribute is written by the builder
before the model is parented, so "has the attribute" and "is a boss" are the same
question.

`typeof(value) == "number"` rather than truthiness, for the reason
`CombatTypes.isCombatState` gives: `GetAttribute` returns `any`, and a stripping
script or a half-built model must read as "not a boss", not as a type error
inside the hit path.
]]
--[[
Resolving a *reference* to the Commander, from whatever the caller happened to
have.

The five attributes are written on the boss **Model** - that is the brief's
contract and it is what the HUD reads. But the thing that actually arrives from a
player's katana is not that Model. `BladeHitbox` reports whatever it touched, and
what it touches on a character rig is the inner `Rig` model or one of its parts,
so the payload names a *descendant* of the boss. Checking the attribute on that
descendant returns nil, `IsBoss` says false, and the strike quietly falls through
to the ordinary `TakeDamage` path - which is exactly what the first live test
showed: `[SERVER HIT CONFIRMED] Struck: Rig for 10 HP` against a boss that has a
400 Health pool and a posture bar, and no posture bar moved.

So identity is resolved by walking *up* the ancestor chain until the attribute
appears, and every caller is handed the canonical outer Model rather than the
descendant it happened to be given. One rule, and it is the difference between a
boss that is damageable on its own terms and a boss that is merely a humanoid
with a health bar drawn next to it.

`typeof(value) == "number"` rather than truthiness, for the reason
`CombatTypes.isCombatState` gives: `GetAttribute` returns `any`, and a stripping
	script or a half-built model must read as "not a boss", not as a type error
inside the hit path.
]]
local function resolveBossModel(model: Model): Model?
	local current: Instance? = model
	while current ~= nil do
		if current:IsA("Model") and typeof(current:GetAttribute(BossConfig.Attributes.Health)) == "number" then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

local function isBoss(model: Model): boolean
	return resolveBossModel(model) ~= nil
end

return table.freeze({
Attributes = BossConfig.Attributes,

IsBoss = isBoss,

	-- The canonical boss Model for whatever reference the caller was handed,
	-- or nil. Exported so a consumer reads the five attributes off the instance
	-- that actually carries them rather than off the descendant it was given.
	ResolveBoss = resolveBossModel,

-- Direction 1: player -> boss. Called by HitValidator after its window,
-- debounce, range and line-of-sight checks have all passed.
	ApplyStrike = function(attacker: Model, target: Model, damage: number, poise: number, hitIndex: number): BossDamageResult
		-- `target` is whatever the hitbox reported, which on a character rig is a
		-- descendant of the boss rather than the boss itself. It is resolved up to
		-- the canonical Model here, so the controller is always handed the instance
		-- that actually carries the attributes.
		local boss = resolveBossModel(target)
		if boss == nil then
			return { Applied = false, Defeated = false, PostureBroken = false, Reason = "target is not a boss" }
		end
		if bossResolver == nil then
			return { Applied = false, Defeated = false, PostureBroken = false, Reason = "no boss controller registered a resolver" }
		end
		return bossResolver(attacker, damage, poise, hitIndex)
	end,

-- Direction 2: boss -> player. Called by Boss1Controller once it has decided a
-- swing actually reached somebody, so HitValidator owns the resolution.
ResolvePlayerStrike = function(boss: Model, victim: Model, kind: BossStrikeKind): string
if playerStrikeResolver == nil then
return "no strike resolver registered"
end
return playerStrikeResolver(boss, victim, kind)
end,

SetBossResolver = function(fn: BossResolver): ()
bossResolver = fn
end,

SetPlayerStrikeResolver = function(fn: PlayerStrikeResolver): ()
playerStrikeResolver = fn
end,

HasBossResolver = function(): boolean
return bossResolver ~= nil
end,

HasPlayerStrikeResolver = function(): boolean
return playerStrikeResolver ~= nil
end,
})
