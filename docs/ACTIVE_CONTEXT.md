# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 9 (Part 2/2)*

## 1. Project Phase
- Completed: Days 1-4, Day 5 P1/2 + P2/2, Day 6 P1/2 + P2/2, Day 7 P1/2 + P2/2, Day 8 P1/2 + P2/2, Day 9 P1/2 (step-dodge), **Day 9 P2/2 (procedural dash lean, dodge posture cost + spam penalty, 4-Boss Sanctuary Hub)**.
- Next Up: Day 10 â€” `Executing` / Deathblow off a broken guard, plus the four region instances behind the torii.

## 2. Live System Registry
- `src/client/StarterPlayerScripts/DodgeController.local.luau` (**+** `findLeanJoint`/`applyDodgeLean`/`releaseDodgeLean`/`cancelDodgeLean`, `isDodgePostureLocked`/`spendDodgePosture`; P1/2 items unchanged)
- `src/shared/ReplicatedStorage/AttackConfig.luau` (**+** `DODGE_LEAN_JOINT` `"Root"`, `DODGE_LEAN_FORWARD_DEG` 25, `DODGE_LEAN_BACKWARD_DEG` 14, `DODGE_LEAN_BANK_DEG` 20, `DODGE_LEAN_TORSO_DROP` 0.45, `DODGE_LEAN_TWEEN_IN` 0.06, `DODGE_LEAN_RETURN_DURATION` 0.12, `DODGE_POSTURE_COST` 10, `DODGE_SPAM_WINDOW` 0.8, `DODGE_SPAM_COST_STEP` 5, `DODGE_SPAM_MAX_CHAIN` 3, `DODGE_POSTURE_LOCKOUT` 90)
- `Workspace.SanctuaryHub` (**new** â€” 4 Grand Torii gates N/S/E/W, flat stone courtyard r=52, 8 sakura, 8 toro lanterns, 2 petal emitters; 325 BaseParts / 16 MeshPart, **0 scripts**)
- `Lighting` (**+** `SANCTUARY_Atmosphere` / `SANCTUARY_Bloom` / `SANCTUARY_Grade`; `ClockTime` 16.2)
- Unchanged: `StateMachine` / `CombatTypes` / `InputBinder` / `CombatStateBus` / `CombatController` / `HitValidator` / `PostureEngine` / `PostureChaos` / `SparringDummy` / `TestFSM` / `AttackController` / `WeaponVisuals` / `ParryWindow` / `Hitstop` / `GuardSparks` / `DeflectFeedback` / `BladeHitbox` / `InputBuffer` / `InputGate` / `CombatDebugUI`

## 3. The 4-Boss Open-World Hub
Spawn at the centre of a stone courtyard; four Grand Torii gates mark the four boss regions, each with a coloured `BillboardGui` label readable from the dais:

| Gate | Region | Accent |
| --- | --- | --- |
| North | The Burning Ash Courtyard | red |
| South | The Whispering Bamboo Grove | green |
| East | The Sunken Pagoda | blue |
| West | The Crimson Eclipse Temple | crimson |

Everything is authored in the Editor (not a runtime script), so the hub costs zero server work and zero per-frame cost. Creator Store assets used: torii `125054743679756`, sakura `107353504764126`, toro `873427672`, petal texture `243344624`. **All are free.**

## 4. Active Invariants (new this part)
1. **The lean tweens `C0`, never `Transform`.** `Motor6D.Transform` is the property the `Animator` writes (batched in a parallel job after `PreSimulation`); a dodging character has an `Animator` driving that exact joint, so a `Transform` overlay is overwritten before it applies. `C0` is the immediate non-Animator path and is **not** deprecated — the docs recommend `Transform` for animating *rigged models*, which is not a 200ms procedural overlay. Verified against the live engine reference.
2. **The neutral `C0` is cached per joint *instance*, not per dodge.** Re-reading `joint.C0` each cast would capture whatever the previous release tween was passing through, and a dodge landing mid-release would store a half-unwound pose as "neutral" and tween back to it forever.
3. **The lean is released at 350ms, not at 200ms.** Releasing when the i-frames close would stand the character upright through the vulnerable recovery tail — the one stretch of the move where they can actually be hit. The torso must still be pitched when the hitbox is live.
4. **`onStateChanged` also unwinds the lean.** The 350ms timer only runs if the dodge resolves on its own clock; a character hit into `Stunned` on the next frame never reaches it, and would otherwise lie at 25 degrees through the whole stagger. Teardown uses a hard `cancelDodgeLean` (direct `C0` write) rather than a tween, so nothing is left running against a body leaving the world.
5. **Both rotations are `-amount * angle`.** Pitch about local +X: positive swings the facing *up*, so forward needs negative. Bank about local +Z: positive tips the up-vector toward *left*, so banking into a rightward slide is negative. Verified live: forward −25.0°, backward +14.0°, right −20.0°, left +20.0°.
6. **The posture cost is charged only on the accepted path.** Every earlier exit (no machine / no character / no direction / illegal edge / spent pool) returns before `spendDodgePosture`, so a player being stunned and mashing Q does not arrive at their one legal dodge already carrying a 25-posture penalty.
7. **The lockout gate sits before `RequestState`.** A refusal that had already flipped the machine to `Dodging` would have to hand the state back, and each such path is a chance to strand the player in a state they never earned. It also prints the *reading* — a refusal with no number in it is indistinguishable from a cooldown.
8. **The posture write is a client-side prediction, deliberately.** `RoninPosture` replicated down from the server, so a client write never travels up — it cannot be used to gain anything, only to make the gauge honest at the moment the cost is paid. The lockout is likewise local. Stated explicitly so nobody later "fixes" it into a remote.
9. **The courtyard has no lip.** The floor is a single flat disc (top y=1.00). An earlier raised dais was deleted: a 0.5-stud step is walkable but the dodge is a 45 studs/s `LinearVelocity`, and an edge to climb at that speed snags a dodge. The duelling circle is a `CanCollide=false` inlay 5cm proud — it reads as stone-in-stone and physics never sees it.
10. **Zero collidable intrusions into the four approach lanes** (10 studs wide, r=5..50), verified by scan. Tree canopies are `CanCollide=false`; only trunks collide.

## 5. Verification Results (Day 9 P2/2)
- **Strict boot**: `[CLIENT] DodgeController online` with zero errors in the output log.
- **Lean math (live rig probe)**: forward −25.0° / backward +14.0° / right −20.0° / left +20.0°.
- **Lean returns to neutral**: after a real [Q] dodge, `LowerTorso.Root.C0` = position `(0, -1, 0)`, rotation `(0, 0, 0)` — exact.
- **Full dodge cycle through the real binding**: `Idle -> Dodging` → i-frames close at 200ms / 149ms recovery → `Dodging -> Idle` at 350ms, with `[SERVER] ... dodged (0,0,1) - i-frames open for 200ms`.
- **Spam ladder (live)**: presses at 24.3s and 0.72s gaps gave `posture -10, -10` (gap > 0.8s resets the chain), then `-15, -20, -25` at 0.7s gaps. The chain caps at +15, so the worst press costs 25.
- **Lockout (live)**: with posture pinned at 95 server-side, `[DODGE] Refused: posture is at 94/100 - too broken to dodge (lockout 90)` and **no** state change followed. Predicate checked across 0/40/89/90/100 → `false/false/false/true/true`.
- **World**: 4 gates all report `opensTowardCentre=true` with correct labels; bounds X[-47..47] Z[-47..47]; 0 collidable lane intrusions; 0 solid parts over the spawn pad; player spawns standing on `SpawnLocation` (ground raycast hit at y=1.00); both petal emitters live at `rbxassetid://243344624`.


## 6. Known Gaps -> Next Task (Day 10)
- **No `Executing` / Deathblow.** `Executing` is in the state table and nothing drives it. Now that the dodge is *not* free, the finisher has to answer the posture threat specifically — a broken guard is the natural trigger.
- **The posture cost is not server-authoritative.** Invariant 8 states the trade honestly. A server-side deduction in `HitValidator`'s `dodgeEvent` handler would make it real; left client-side because the spec scoped it to `DodgeController` and the gain is zero.
- **The lean is not seen by opponents.** It is a client-local `C0` write, so a remote player still sees the unleaned slide. Same root cause as the Day 9 P1/2 dodge-trail read; one cosmetic `DodgeStarted` server->all remote would fix both.
- **The `Windup -> Dodging` / `Recovery -> Dodging` cancels remain unobserved live** (carried from P1/2) — MCP input latency ~7s against a 150-350ms window. `AttackController.breakChain` only releases the blade on its next timer tick, up to 240ms later.
- **The hub gates lead nowhere.** All four regions are labels on geometry; the instances, portals and `StreamingEnabled` setup are Day 10+.
- **A 0.30-scale sakura is a compromise** — the 52-stud native tree could not sit on the rim without crowding a gate approach. Trees read as small ornamental specimens; scale up alongside the regions.
- **Tooling limits (carried forward, extended):** no Luau CLI, so strict typing is verified by a real boot. MCP `execute_luau` is an **isolated VM** — `require`-ing a PlayerScripts ModuleScript returns a fresh unbound copy. `VirtualInput` cannot send digit keys (bound to CoreGUI) nor route `MouseLeftButton` through `ContextActionService`; `ContextActionService:CreateAction` **does not exist**. **Script Sync is unreliable and a stale compile reports a syntax error that no longer exists.** `GetBoundingBox` is **Model-only** (errors on a bare `Part`); a cylinder's thickness runs along its *local X*, so a rotated disc's height is `Size.X/2`, not `Size.Y/2`. `Texture.Texture` and `ParticleEmitter.Texture` both take a **content-id string**, never an Instance. Line endings: `CombatDebugUI` / `CombatController` / `CombatTypes` / `InputGate` / `DodgeController` are LF; `HitValidator`, `CombatStateBus`, `InputBinder`, `AttackConfig`, `StateMachine` are CRLF.
- **Editor insert gotcha:** repeatedly `insert_line`-ing against the *same* comment anchor silently collided and corrupted `DodgeController` twice. Insert at a line number or against a unique anchor, then re-read the region.