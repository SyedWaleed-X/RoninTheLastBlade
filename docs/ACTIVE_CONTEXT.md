# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 10 (Part 2/2)*

## 1. Project Phase
- Completed: Days 1-4, Day 5 P1/2 + P2/2, Day 6 P1/2 + P2/2, Day 7 P1/2 + P2/2, Day 8 P1/2 + P2/2, Day 9 P1/2 + P2/2, **Day 10 P1/2 + P2/2**.
- Next Up: Day 11 - `Executing` / Deathblow off a broken guard, plus the four region instances behind the torii.

## 2. Live System Registry
- `src/server/ServerScriptService/AudioEngine.server.luau` (**new** - builds the SoundService mix tree: `RoninMaster` over `RoninCombatSFX` (limiter) and `RoninAmbience` (duck); reads the tree back and warns on an unbound `SideChain`)
- `src/client/StarterPlayerScripts/CombatAudio.luau` (**new** - `PlayCue(cue, position)`; per-cue voice pools with oldest-steal; `Block`/`Slash` self-triggered, `Deflect`/`PostureBreak` driven by CombatController)
- `src/server/ServerScriptService/SparringDummy.server.luau` (**+** `RoninInvulnerable` read in `resolveStrike`, after range/LOS and *before* the guard, printing `[DUMMY EVADED]`)
- `src/client/StarterPlayerScripts/CombatController.local.luau` (**+** `CombatAudio` require; `Deflect` cue + `rig:IgniteTrail()` on the defender, `Deflect` cue only on the attacker, `PostureBreak` on guard break)
- `src/client/StarterPlayerScripts/WeaponVisuals.local.luau` (**+** `igniteTrail` with an epoch + cancellable recovery tween; `IgniteTrail` on the `BladeRig` seam; trail colour/emission now from config)
- `src/client/StarterPlayerScripts/CombatStateBus.luau` (**+** `IgniteTrail` on the `BladeRig` type)
- `src/client/StarterPlayerScripts/CombatDebugUI.local.luau` (**+** Key `[U]` `runJuiceChaosSuite`, 5 invariants, reuses `chaosSuiteRunning` + `InputGate`)
- `src/shared/ReplicatedStorage/AttackConfig.luau` (**+** 26 constants + `CombatSoundCue` / `CombatCue` types)
- Unchanged: `StateMachine` / `CombatTypes` / `InputBinder` / `InputBuffer` / `InputGate` / `PostureEngine` / `PostureChaos` / `TestFSM` / `HitValidator` / `AttackController` / `BladeHitbox` / `ParryWindow` / `GuardSparks` / `DeflectFeedback` / `Hitstop` / `DodgeController` / `CameraShaker` / `Workspace.SanctuaryHub` / `Lighting`

## 3. The Mix Tree
Three groups, nested so one master fader owns both leaves. The limiter sits on `CombatSFX` and the duck on `RoninAmbience` - never on the master, or the limiter would fight the duck release and the bed would stutter recovering. **The legacy `SoundGroup` tree is the correct tool, not a deprecated one:** the newer `AudioPlayer`/`AudioCompressor` API has no SoundGroup, and ducking a whole ambience bucket is not expressible as a wire between two players.

## 4. Active Invariants (new this part)
1. **The dummy now honours i-frames.** It is a *second* strike authority: `HitValidator` has read `RoninInvulnerable` since Day 9, the dummy never did. The rule existed; the file just never asked. Checked after range/LOS and before the guard, so an evaded strike reports "evaded" rather than "blocked".
2. **A client attribute write does not reach the server.** Verified live: pinning `RoninInvulnerable` from the Client datamodel left the dummy dealing full damage. The server is the only writer.
3. **A duck whose `SideChain` fails to bind fails silently.** Both buses still play; the only symptom is a bed slightly too present, which reads as taste. Hence the read-back print and warning in `AudioEngine`.
4. **The Creator Hub sidechain sample is wrong.** It documents `MakeUpGain`; the class exposes `GainMakeup`. Verified: `GainMakeup` reads, `MakeUpGain` errors. Setting the documented name is a silent no-op.
5. **The engine rejects a multi-line `if` expression with a leading `else`.** Ours did, all three. `then` on its own line is fine - the killer is a bare `else` starting a line.
6. **Reward asymmetry is preserved.** Defender: clang + 3D cue + gold trail + FOV punch + trauma. Attacker: clang + 3D cue, no ignition, no zoom, no shake.

## 5. Verification Results (Day 10 P2/2)
- **Strict boot**: all 15 modules online, zero errors, zero warnings.
- **Mix tree (live)**: mix tree online, RoninMaster 1.00 over [RoninCombatSFX 1.00 + limiter | RoninAmbience 0.70 ducked]; duck side-chained by RoninCombatSFX at -24dB / 4:1 / 10ms / 0.25s; limiter at -3dB / 20:1.
- **Dodge evasion (live, server-side flag)**: 3x `[DUMMY EVADED]`, Health held 100/100 across 3+ strike cycles; on release the dummy resumed `[DUMMY HIT CONFIRMED]` for 10 HP, proving the fix evades only while invulnerable.
- **Chaos suite [U]**: 5/5 PASS - trauma peak 1.000 over 20 impacts (clamped, no runaway), decay 0.906 to 0.345, mix tree intact, voice cap 7 of 7, 20 of 20 impacts reached the pool.
- **All 4 audio ids** verified loadable via `ContentProvider:PreloadAsync` before being hardcoded.

## 6. Known Gaps - Next Task (Day 11)
- **No `Executing` / Deathblow.** In the state table with nothing driving it. The guard break is the natural trigger and the cue plumbing now exists.
- **A deflect plays two sounds.** The Day 7 non-spatial `DeflectFeedback.Clang()` still fires alongside the new spatial cue. Recommended: retire `Clang()` so the palette owns deflects alone. **Not done - awaiting a call.**
- **A block plays both** the Day 7 sparks event and the new `Block` thud; same double-sound question, smaller stakes.
- **`WeaponVisuals` pose tweens are not registered** with `Hitstop` - only the dodge lean is (carried). The ignition tween is deliberately *not* registered, so the gold lands on the frozen frame.
- **The lean is still not seen by opponents** (client-local `C0` write) - carried from Day 9 P2/2.
- **`CameraShaker` has no HUD row** - `GetTrauma()` exists, `CombatDebugUI` does not read it (carried).
- **The hub gates lead nowhere** - carried; regions and portals are Day 11.
- **Tooling (extended):** the filesystem `edit` tool is unavailable; edits go through PowerShell. `CombatDebugUI.local.luau` is LF in git and `CombatAudio.luau` is CRLF - match the file own endings or replacements silently miss. **Edit-mode `require` of a runtime-created ModuleScript is NOT a valid syntax oracle** (it rejected a valid if-expression *and* a trivial control): trust only a live playtest. `Enum.RollOffMode` is `InverseTapered`, not `InverseTaper`. `FireServer` from the Server datamodel throws. Named returns in a tuple are invalid in a return-type position.
- **Editor gotchas (carried):** repeated `insert_line`-ing on one comment anchor corrupts a file; prefer line-index splices. `loadstring` is unavailable in `execute_luau`.
