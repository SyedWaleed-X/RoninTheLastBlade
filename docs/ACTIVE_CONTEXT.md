# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 4 · Part 2/2*

## 1. Project Phase
- Completed: Day 1 (Setup, MCP, Git), Day 2 (FSM + Debug HUD), Day 3 (Input Buffer & Telemetry), Day 4 Part 1/2 (3-Hit Chain & Frame Data), Day 4 Part 2/2 (Instant Idle Trigger, Root Motion Lunge, Commitment).
- Next Up: Day 5 — hitbox resolution during Active, then server-authoritative damage/posture remotes (ARCHITECTURE #2 schemas, #3 authority).

## 2. Live System Registry
- `src/shared/ReplicatedStorage/CombatTypes.luau` (Authoritative Combat States & Types)
- `src/shared/ReplicatedStorage/StateMachine.luau` (Deterministic FSM + Interruption Matrix)
- `src/shared/ReplicatedStorage/AttackConfig.luau` (frozen 3-hit frame data, 0.80s chain window; `LungeSpeed` now live)
- `src/client/StarterPlayerScripts/CombatStateBus.luau` (**+** `SetActionIntake` / `OfferIntent` direct-press seam)
- `src/client/StarterPlayerScripts/AttackController.local.luau` (**+** root-motion lunge, rotation lock, `COMBO_LENGTH` derived from config)
- `src/client/StarterPlayerScripts/CombatController.local.luau` (**+** `dispatchAction` single mapping + `offerIntent` direct intake)
- `src/client/StarterPlayerScripts/InputBuffer.luau` (200ms sliding FIFO queue — unchanged)
- `src/client/StarterPlayerScripts/InputBinder.local.luau` (**+** routes presses via the bus intake; traces direct vs queued)
- `src/client/StarterPlayerScripts/InputGate.luau` (debug-only live-input gate)
- `src/client/StarterPlayerScripts/CombatDebugUI.local.luau` (`COMBO: [ HIT x / 3 ]`; removed a duplicate `InputGate` require)

## 3. Active Invariants
1. A press goes to `CombatStateBus.OfferIntent`. Idle → spent on the spot; any other state → queued in `InputBuffer` for the next Idle entry (COMBAT_SPEC §2.4). Both paths share the single `dispatchAction` mapping.
2. `offerIntent` calls `InputBuffer.Clear()` first: a press is the newest intent, and without the eviction a stale Guard would be spent *instead* of the new attack.
3. Direct spends report `+0 ms` latency — true, since dispatch happens inside the input event.
4. The `task.spawn`'d Idle listener re-checks `CurrentState == "Idle"` before consuming, so one press cannot be spent twice when the intake already started a swing.
5. **Root motion:** entering Active builds an `Attachment` + `LinearVelocity` on `HumanoidRootPart` (`VectorVelocity = LookVector * LungeSpeed`, world space) and sets `Humanoid.AutoRotate = false`. Exiting Active destroys both and restores `AutoRotate = true`.
6. `MaxAxesForce = Vector3.new(100000, 0, 100000)` is honoured only because `ForceLimitsEnabled = true` + `ForceLimitMode = PerAxis` are set explicitly; under engine defaults the engine ignores `MaxAxesForce` entirely.
7. `stopLunge()` is idempotent and runs on *every* exit out of Active (Recovery, `breakChain` on stun/parry-cancel, next swing). A leaked `LinearVelocity` would fling the character permanently.
8. `COMBO_LENGTH` is counted from `COMBO_CHAIN` at load, so wrap arithmetic, timeout and the HUD "/ 3" cannot disagree.
9. `COMBO_RESET_TIMEOUT = 0.80s` runs from the **end** of the last swing; longer gap → next press is Hit 1.

## 4. Verified (live playtest, console traces)
- Direct Idle trigger: `[INPUT] Spent on the spot: LightAttack` on every click, including the first click after a 134s idle gap — the pre-existing "press while already Idle is never spent" gap is closed. Telemetry shows `LIGHT_ATTACK · +0 ms`.
- Root motion: `Root motion committed: 22.0 / 28.0 / 38.0 studs/s for 120 / 120 / 180 ms`, matching `AttackConfig` exactly.
- Turn lock: across 4 swings, 28/28 frames with the constraint live had `AutoRotate = false`, 0 frames turnable. Peak observed speed 39.2 studs/s (Hit 3 target 38).
- Teardown: no leaked `AttackLunge` / `AttackLungeAttachment` after any swing, stun burst or force reset; `AutoRotate` back to `true`.
- Chain `1 → 2 → 3 → 1`; HUD shows `COMBO: [ HIT x / 3 ]` live (read `HIT 1` right after Hit 3 wrapped).
- `AttackConfig` still frozen; Day 3 `[T]` chaos suite still passes all 3 buffer invariants after the controller refactor; server `[FSM TEST]` passes.
- Not reproducible via MCP tooling: a stun landing *inside* the 120ms Active window — virtual input carries tens of seconds of game-time latency per action. That path rests on invariant 7, not on a trace.

## 5. Known Gaps → Next Task (Day 5)
- **No hitbox resolution.** Active is a pure state/animation window; nothing queries a blade volume or applies `Damage` / `PoiseDamage` (config values are read for logging only).
- **No server remotes.** Damage, posture and parry deflection are still client-local prediction — no schema-validated RemoteEvent and no server authority yet (ARCHITECTURE #2/#3 open).
- `LungeSpeed` is client-predicted; the server must eventually own authoritative knockback so it cannot be spoofed.
- No Luau CLI (`luau-analyze`/`rojo`/`stylua`): strict typing is verified by Studio Script Sync + playtest, not a static analyzer.
- The MCP `execute_luau` sandbox has an isolated `require` cache, so client modules cannot be driven from the tool — drive the real input path instead.
