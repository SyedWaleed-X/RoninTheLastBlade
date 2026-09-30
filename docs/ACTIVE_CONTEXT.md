# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 11 (Boss 1 + Realm 1)*

## 1. Project Phase
- Completed: Days 1-4, 5-10 (all parts), **Day 11: THE CORRUPTED COMMANDER + The Burning Ash Courtyard**.
- Next Up: Day 12 - `Executing` / Deathblow cinematically, then the remaining three regions behind the torii.

## 2. Live System Registry
- `src/server/ServerScriptService/Arena1Builder.server.luau` (**new**) - 80x80 courtyard, 6 braziers, ash, two-leaf gate, **and the Commander itself** (`buildCommander` / `buildBrazier` native templates via `resolveTemplate`)
- `src/server/ServerScriptService/Boss1Controller.server.luau` (**new**) - 5-move AI on a 50ms `task.wait` loop, pose table, telegraph channel, posture economy, phase 2, engage/disengage, defeat/revive
- `src/shared/ReplicatedStorage/BossConfig.luau` + `BossRegistry.luau` (**new**) - every boss number in one frozen table; the two-way player<->boss strike bridge
- `src/client/StarterPlayerScripts/BossHUD.local.luau` (**new**) - nameplate, interpolating health bar, posture bar, phase pips
- `src/server/ServerScriptService/HitValidator.server.luau` (**+** boss branch routes a player hit to `BossRegistry`; `resolveBossStrikeOnPlayer` resolves boss->player through the *existing* guard/parry/dodge chain; `findRoot` hardened)
- Unchanged: everything from Days 1-10.

## 3. Active Invariants (new this part)
1. **The Commander is a native rig, not an imported one.** `buildCommander` writes every Part/Motor6D from script; `C0 = p0.CFrame:ToObjectSpace(p1.CFrame)` holds the authored pose with no `Animate` script. An authored `BossTemplates.CorruptedCommander` still wins if present.
2. **`CanQuery = true` on every boss part.** `CanCollide = false` stops it snagging on scenery, but `CanQuery = false` made it *invisible to spatial queries* - the player's katana passed straight through and the boss sat at a permanent 400 HP. Queryability beats tidiness.
3. **Joints resolve by descendant search.** R15 parents `Root` in `LowerTorso`, `Waist` in `UpperTorso`, `Neck` in `Head`. A direct `FindFirstChild` on the Model finds nothing and the failure is a silent nil - every pose degrades to a no-op and the telegraphs simply do not exist.
4. **`AutoRotate` must stay ON.** The controller faces the player only via `Humanoid:Move`, which turns a character only when it is enabled. Off, the boss slides past and its forward-cone check never passes - a fight that runs and lands nothing.
5. **Boss identity is resolved by walking *up*.** The hitbox reports the inner `Rig`, not the Model carrying the attributes, so `IsBoss` walks ancestors and every consumer is handed the canonical Model.
6. **Handles are addressed by name, not attribute.** An Instance-valued attribute reads back as `InstanceHandle` (S4), so `TheCorruptedCommander` / `GateLeafLeft` / `GateLeafRight` / `ARENA_Burn_Grade` are found by name. `RoninArenaReady` stays an attribute - a boolean, written last, as the ordering promise.
7. **The per-swing latch clears per *move*, not per call.** `fireSwing` is entered 2-4x per swing; clearing inside it re-armed the latch each tick and a 12 HP flurry step landed 2-4x.


## 4. Engine Changes That Broke Working Code (Sept 2026 build)
- **`Motor6D.Priority` removed** (Avatar Joint Upgrade) - raised at load. It only existed to out-rank `Animate`, which this rig does not have.
- **`Enum.FloorMaterial` removed**; `Humanoid.FloorMaterial` now returns an `Enum.Material`. The low sweep's must-jump test is now `GetState() == Freefall or Jumping`.
- **`GuiObject.GroupTransparency` / `GroupColor3` removed** - the HUD fade was a `CanvasGroup` tween, now a per-descendant tween walk over a plain `Frame`. **`CombatDebugUI` still uses `GroupTransparency` and is broken by this** (carried).
- **`TextLabel.Transparency` and `TextTransparency` are no longer aliases** - a fade driven by `Transparency` left the nameplate invisible while every bar faded correctly.
- **Instance-valued attributes return `InstanceHandle`**, which has no `FindFirstChild` and cannot answer `IsA`.
- *Editor notes: `execute_luau` has no `readfile`/`loadstring`; `gmatch` with `"[^\n]*"` double-counts lines; PowerShell `-like` treats `[...]` as a character class; CRLF files need UTF-8-no-BOM writes.*

## 5. Verification Results (Day 11, live)
- **Strict boot**: zero errors, zero warnings across all server + client scripts.
- **Arena**: `80x80 at (0, 0, -116), 6 braziers, boss placed`; gate seals on engage and opens on defeat; grade + taiko bed (`SoundGroup = RoninAmbience`) on engage.
- **Boss**: `400 HP, 200 posture, 5 moves, 50ms cadence`; all five attributes exact; katana welded `part0=RightHand`; all 7 pose joints resolve.
- **All 5 moves observed live**: Flurry (12/12/16), Cleave (26, amber), Perilous Thrust (30, red + kanji, *pierced guard*), Low Sweep (35, `LEAPT the low sweep!`), Shadow Retreat + lunge.
- **Both directions**: `[BOSS HIT] ... struck TheCorruptedCommander for 24 - applied=true reason=hit`; boss 400->342 with posture 29.75/200.
- **Lifecycle**: `already defeated` -> `The Commander rises again.` -> gate re-seals -> re-engages.
- **Cadence**: 28 hits / 10s, avg exactly 12.0 (a 3-hit flurry roughly once a second).
- **HUD**: `Name` alpha 0.00, text `THE CORRUPTED COMMANDER`, stroke 0.55; health fill 0.577 = 231/400; posture fill tracks; pips lit.

## 6. Known Gaps - Next Task (Day 12)
- **No `Executing` / Deathblow.** `Vulnerable` opens the window and `BrokenHealthMultiplier` (1.6) is now read, but nothing plays a finisher.
- **`CombatDebugUI` uses the removed `GroupTransparency`** - its fade and vignette are dead on this engine. Same fix as `BossHUD` (S4).
- **`SanctuaryHub.CourtyardFloor` is 1x104x104 rotated Z=90** - correct as a floor, but it reads as a wall in the Explorer. Left alone; worth renaming.
- **Carried from Day 10**: a deflect plays two sounds (`DeflectFeedback.Clang` plus the palette cue); `WeaponVisuals` pose tweens are not registered with `Hitstop`; the lean is client-local; `CameraShaker` has no HUD row; the other three torii gates lead nowhere.
