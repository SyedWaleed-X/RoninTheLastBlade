# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 8 (Part 2/2)*

## 1. Project Phase
- Completed: Days 1-4, Day 5 P1/2 + P2/2, Day 6 P1/2 + P2/2, Day 7 P1/2 + P2/2, Day 8 P1/2, **Day 8 P2/2 (client stun freeze, Sekiro HP+posture HUD, [Y] chaos suite)**.
- Next Up: Day 9 — `Executing` / Deathblow off a broken guard (the posture HUD now shows the attacker nearing a break, so the finisher has a visible tell).

## 2. Live System Registry
- `src/client/StarterPlayerScripts/CombatController.local.luau` (**+** `applyStunFreeze`, `releaseStunFreeze`, `holdStunFreeze`, `capturedWalkSpeed`/`capturedJumpPower`/`frozenHumanoid`/`stunGeneration`/`activeStunGeneration`, rupture floor in `applyGuardBreakStun`, teardown clears the freeze)
- `src/client/StarterPlayerScripts/CombatStateBus.luau` (**+** `SetStunInputLock`/`IsStunInputLock`, `SetGuardReleaseRequired`/`IsGuardReleaseRequired`/`ClearGuardReleaseRequirement`)
- `src/client/StarterPlayerScripts/InputBinder.local.luau` (**+** stun lock + wakeup guard-release gate on both the tap and hold edges; `ClearGuardReleaseRequirement` on `End`/`Cancel`)
- `src/client/StarterPlayerScripts/CombatDebugUI.local.luau` (**+** `SekiroVitals` health/posture bars, `CriticalVignette` + `setCriticalWarning`/`updateVitals`/`retargetBar`/`healthColorFor`, `runPostureChaosSuite`/`verifyClientTeardown`, **[Y]** binding)
- `src/server/ServerScriptService/PostureChaos.server.luau` (**new** — `runPostureEdgeTest`, `runDeathOverrideTest`, `resolveChaosEventImpl` bounded retry, `onChaosRequest`)
- `src/server/ServerScriptService/HitValidator.server.luau` (**+** registers `ChaosTestEvent`)
- `src/shared/ReplicatedStorage/AttackConfig.luau` (**+** `DEFAULT_JUMP_POWER` 50, `REMOTE_CHAOS_EVENT` "ChaosTestEvent")
- `src/shared/ReplicatedStorage/CombatTypes.luau` / `StateMachine.luau` (unchanged)
- Unchanged: `PostureEngine` / `SparringDummy` / `TestFSM` / `AttackController` / `WeaponVisuals` / `ParryWindow` / `Hitstop` / `GuardSparks` / `DeflectFeedback` / `BladeHitbox` / `InputBuffer` / `InputGate`; `ReplicatedStorage.KatanaModel`

## 3. Active Invariants
1. **The freeze is re-asserted, not written once.** `PostureEngine` writes `WalkSpeed` on *both* ends of a rupture from the server; those writes land on a **client-owned** Humanoid as ordinary property changes and immediately undid a one-shot client write. Measured on the first playtest: `WALK->0 JUMP->0 ROT->false WALK->16 WALK->0 JUMP->50 ROT->true` — the character was jumpable and turning for the whole stagger. `holdStunFreeze` re-asserts from a per-character `RunService.Heartbeat` while frozen. Verified: `w0/j0/rF` holds continuously for the full stun, then releases to `w16/j50/rT`.
2. **The release is generation-stamped.** `StateMachine` dispatches listeners via `task.spawn`, so freeze and release threads interleave; a release from a *previous* rupture can land inside the current one. `stunGeneration`/`activeStunGeneration` make a stale release a no-op.
3. **WalkSpeed and JumpPower are captured, never assumed.** `WeaponVisuals` writes `GUARD_WALK_SPEED` (9) on guard and restores its own captured rest value, so restoring a hardcoded 16 would leave it permanently editing a rest speed nothing agreed with. `AttackConfig.DEFAULT_WALK_SPEED`/`DEFAULT_JUMP_POWER` are documented **fallbacks**, not restore targets.
4. **The freeze is cleared on death.** A character killed while kneeling never runs `Stunned -> Idle`, so teardown clears the capture, `frozenHumanoid` and the input lock — otherwise the respawn is a character who cannot walk or attack with no stun in sight.
5. **The lock is at the input edge, not the state machine.** `InputBinder` refuses presses *before* `InputBuffer.Push`, because a press during a stun would otherwise sit in the 200ms queue and be spent the instant the stun expired.
6. **Release-and-re-press is explicit.** `SetGuardReleaseRequired(true)` is raised on wakeup and cleared only by a real Mouse2 `End`. `ContextActionService` already produces no fresh press in the common case; the flag covers the same-frame press and touch-held refocus.
7. **The health *tier* is not tweened; the posture *colour* is not tweened.** Size tweens so a hit reads as impact; colour tracks instantly so the bar is never a different colour from the number it represents. The posture ramp is a `Lerp` deliberately — three discrete tiers would throw away "I am at 60%".
8. **The vignette is four edges, not a wash.** A full-screen tint makes the incoming attack harder to read; a gradient transparent in the middle and saturated at the edges costs nothing where the fight is. `ZIndex = 1` keeps it under the state badge.

## 4. Verified (live playtest, console traces)
- **Boot clean under `--!strict`**: all seven servers online, no errors, no warnings.
- **HUD**: health full/emerald `(0.18, 0.80, 0.44)` at 100%; gold `(0.91, 0.75, 0.24)` at 40%; posture bar at 0.60 with ramp colour `(0.861, 0.292, 0.138)`; 4 gradient edges at rotations 0/180/90/270; the 85% tick present.
- **Critical pulse**: `edgeTrans` 0.95 -> 0.55 -> 0.95 and `barR` 0.78 -> 0.90 -> 0.78 over ~1.0s, smooth and continuous, repeating.
- **Stun freeze**: `w0/j0/rF` held for the full ~2.8s across consecutive ruptures, then released cleanly to `w16/j50/rT`. Transitions `Idle -> Stunned` / `Stunned -> Idle (dt: 3.017)`.
- **[Y] suite, twice consecutively**: `PASS Posture Edge (99.9% + 0.2% poise) -- broke in 0.033s (grace 1.2s), pool pinned at 100, walk=0`; `PASS Death Override (HP 0 during rupture) -- died at walk=0, old model released, new character clean at walk=16 / maxPosture=100`; `PASS Client Teardown -- new machine bound, Idle, lock cleared, responsive`; then `[POSTURE CHAOS] All Day 8 invariants verified cleanly.`

## 5. Known Gaps -> Next Task (Day 9)
- **No posture HUD for the *attacker*.** The gauge reads the local character only, so a player cannot watch an opponent's pool climb toward a break their parries are causing.
- **No `Executing` / Deathblow.** A broken guard is still a free punish window. `Executing` exists in the state table and nothing drives it. The posture HUD now gives the finisher a visible tell, which is what makes it worth building next.
- **`Parrying` is still not a real combat state.** The 133ms window resolves entirely inside `Blocking`; `ALLOWED_TRANSITIONS` has the edges and `CombatTypes.DeflectResult` models the result, but neither is used. Deliberate for now.
- **The rupture has no visual.** It roots and stuns, but there is no kneeling pose, and `Stunned` is also what a stagger uses - the two are still indistinguishable in-world. The HUD gauge is currently the only tell.
- **The guard is still all-or-nothing**: 100% absorb, no chip damage, and the 145-degree frontal cone has no visual tell.
- **Recovery is untested against the dummy's own attacks** in a real exchange; the tiers were driven by direct Health writes. `SLASH_CLIP_IDS` is still empty on purpose. Hit detection is still client-local.
- **Tooling limits:** no Luau CLI, so strict typing is verified by Script Sync + playtest. MCP `execute_luau` `loadstring` **cannot parse method calls at all** (`aa:m()` fails) - useless for syntax-checking Luau containing `:`, and its "syntax errors" are untrustworthy. Verify syntax from a real playtest boot.
- **Script Sync does not always pick up an edit, and a stale compile reports a syntax error that no longer exists in the source.** The symptom is an error at a line the edit did not touch. Writing through MCP `multi_edit` forces a recompile; if the error survives that, it is real. Also: `CombatDebugUI.local.luau` is **CRLF** and the file `editor` tool matches on `\n` - use MCP `multi_edit` for it.
- **Remotes are still created inside `HitValidator's own body**, and ServerScriptService runs children in an order that is *not* stable across runs (observed both ways). `PostureChaos` therefore does **not** resolve its remote at load time: `resolveChaosEventImpl` retries on a bounded 10s schedule and connects once. Any future server script needing another script's remote must do the same.
