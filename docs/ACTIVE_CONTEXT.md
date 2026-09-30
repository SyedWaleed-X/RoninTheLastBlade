# RONIN: ACTIVE CONTEXT RELAY
*Last Updated: End of Day 12 (Cinematic Future lighting + the four Horizon POIs)*

## 1. Project Phase
- Completed: Days 1-11. **Day 12: THE HORIZON - cinematic golden hour + the four regions behind the four torii.**
- Next Up: Day 13 - `Executing` / Deathblow cinematically (carried; still the top gap).

## 2. Live System Registry
- `src/server/ServerScriptService/WorldEnvironment.server.luau` (**new**, ~2.9k lines) - owns `Lighting` and builds `SanctuaryHub.Horizon`: **1507 parts, 4 regions, 4 zone anchors.** S1 skeleton+palette, S2 shared kit, S3 golden hour, S4-S7 regions, S8 boot. Idempotent (destroys and rebuilds `Horizon`).
- `SanctuaryHub.Horizon.{North_BurningAshFortress | East_WhisperingBambooGrove | West_SunkenPagoda | South_CrimsonEclipseCitadel}` (**new**) - `RoninRegion`, `RoninRegionDirection`, `RoninRegionParts`, `RoninRegionReady`; the parent carries `RoninHorizonReady` (written last), `RoninHorizonParts`, `RoninHorizonZones`.
- Zone anchors (**new**): `Arena1Zone` (90x40x90 over the courtyard), `BambooGroveZone`, `SunkenPagodaZone`, `CrimsonCitadelZone`; each with `RoninZone` / `RoninZoneIndex` / `RoninZoneDirection`.
- Lighting owners (**new**): `WORLD_Atmosphere`, `WORLD_Bloom`, `WORLD_SunRays`, `WORLD_Grade`. `ARENA_Burn_Grade` deliberately untouched.
- Unchanged: every Days 1-11 file, the hub geometry, the arena, the boss.

## 3. Active Invariants (new this part)
1. **Lighting quality is place-level, not script-level.** `Lighting.Technology` is `ReadOnly`/`RobloxScript`; `LightingStyle` + `PrioritizeLightingQuality` are `PluginOrOpenCloud`. A server script can write *neither*, so the place is authored `Realistic` + `true` and the script `pcall`s all three, warns once, and carries on. Sharing one `pcall` between `Technology` and `LightingStyle` killed the entire first boot.
2. **Exactly one `Atmosphere` / `Bloom` / `SunRays`.** `adopt` takes the existing instance and renames it; leftovers are destroyed. `ColorCorrectionEffect` is **never** pruned: multiple compose by design, and that is how `ARENA_Burn_Grade` tints the fight.
3. **Scenery is `CanQuery = false`.** `BladeHitbox` resolves the *first* thing four swept rays hit, so a queryable bamboo stalk between blade and target eats the hit silently.
4. **`Arena1Zone` must stay *larger* than the room it covers** (90 > 86 outer). A ray with both ends inside a box never crosses its surface, so the invisible anchor cannot swallow a swing or a line-of-sight check. Shrinking it below the courtyard would break the boss fight.
5. **A cylinder's axis is its local X.** `Vector3.new(h, d, d)` plus a quarter turn about Z is a standing stalk; `Vector3.new(d, h, d)` is a pancake. `makeCylinder` owns this, and every stalk in the file goes through it.
6. **No per-frame loop exists in `WorldEnvironment`.** Bob, sway and flicker are `TweenInfo` with `RepeatCount = -1`; bobbing instances replicate a CFrame per frame, so only 8 of the 16 water lanterns move.
7. **Nothing moves that could drop a player off the arena wall.** The north flights stop at y = 64 and never touch the courtyard; the only walkable route out of any region is the south citadel's staircase.
8. **`Baseplate` is restyled, never deleted** (colour + material only). It is the fallback floor for the whole place.

## 4. Engine Changes That Constrain Working Code (Sept 2026 build)
- **`Lighting.Technology` is `ReadOnly` (`RobloxScript`)** and the docs say it is superseded by `Lighting.LightingStyle` ("Realistic - the most advanced and realistic lighting and shadows Roblox can deliver") plus `PrioritizeLightingQuality`. The brief's "Technology = Future" is unreachable from a script; its equivalent is authored in the place.
- **`Lighting.LightingStyle` / `PrioritizeLightingQuality` are `PluginOrOpenCloud`** - command bar and plugin yes, **server script no** ("cannot write 'LightingStyle'"). This is what stopped the first boot of the day.
- **`Enum.Material.Water` is documented "Applies to Terrain only"**, and terrain water is locked to y = 0 - exactly this place's `Baseplate` top face. The flooded courtyard is therefore a part with `Reflectance`.
- **`Atmosphere.Decay` renders only when `Haze` *and* `Glare` are both above 0**, so the brief's `Decay` needed a `Glare` of 0.35 to exist at all.
- Carried from Sept 2026: `Motor6D.Priority` removed; `Enum.FloorMaterial` removed; `GuiObject.GroupTransparency` removed (`CombatDebugUI` still broken by it); `TextLabel.Transparency` is not an alias of `TextTransparency`; Instance attributes read back as `InstanceHandle`.
- *Editor notes: `execute_luau` rejects some multi-line table literals and inline `if` expressions - keep MCP probes simple. CRLF files need UTF-8-no-BOM writes.*

## 5. Verification Results (Day 12, live)
- **Boot**: `[WORLD] Horizon built: 1507 parts across 4 regions, 4 zone anchors` - North 278 / East 616 / West 284 / South 329. Zero errors from the new script, and the arena, its six braziers and the boss still build alongside it.
- **Spec values, read back off the live `Lighting`**: Atmosphere `Density 0.35 / Offset 0.25 / Haze 1.5 / Glare 0.35 / Color (190,160,140) / Decay (106,112,125)`; Bloom `0.6 / 24 / 0.8`; SunRays `0.08 / 0.2`; Grade `Contrast 0.15 / Saturation 0.12 / Tint (255,245,235)`; `ClockTime 17.5`, `ExposureCompensation 0.25`, `GeographicLatitude 45`.
- **Legacy cleanup**: `SANCTUARY_Atmosphere` + `SANCTUARY_Bloom` destroyed from the place, `SANCTUARY_Grade` renamed `WORLD_Grade`, `ARENA_Burn_Grade` left alive and still driving the boss grade.
- **Panorama proven by raycast, not by eye** - from the spawn eye `(0, 6, 0)`, the north pagoda spire (y 158), the east hill bamboo (y 107), the west pagoda spire (y 80) and the south keep spire (y 166) are each reached by *their own* geometry first, i.e. nothing else is in the way. Only the citadel's gate (y 74) is hidden behind the south torii, by design: the climb is a route, not a billboard.
- **Ground**: 60+ downward raycasts across all four regions - **0 holes**. This caught a real bug: `WEST_APRON_FAR - WEST_BASIN_FAR` is **negative** (every west coordinate is negative and the far bank is the *more* negative one), so the far bank silently clamped to a 0.05-stud sliver and 54 studs of shore fell back to the bare `Baseplate`.
- **Combat unaffected**: the zone anchor swallowed **0 of 4** intra-arena blade and line-of-sight rays.
- **Region heights** (why the panorama works at all): north 158, east 107, west 80, south 166 - every skyline clears the 26-stud torii, and the north clears the arena's 27-stud wall.

## 6. Known Gaps - Next Task (Day 13)
- **No `Executing` / Deathblow.** `Vulnerable` opens the window and `BrokenHealthMultiplier` (1.6) is read, but nothing plays a finisher. Still the top gap.
- **`CombatDebugUI` uses the removed `GroupTransparency`** - its fade and vignette are dead on this engine. Same fix as `BossHUD` (S4).
- The other three regions are built but **not yet encounters** - only the north has a fight. Each needs its own `BossConfig` entry, controller and gate before a player is sent through it.
- **`Lighting`'s effects are adopted at boot rather than present under their world names** (`Atmosphere`, `Bloom`, `SunRays` keep their old names on disk and are renamed in the runtime DataModel). Harmless, but the Explorer and the running game disagree until the first boot.
- Carried from Day 11: a deflect plays two sounds (`DeflectFeedback.Clang` plus the palette cue); `WeaponVisuals` pose tweens are not registered with `Hitstop`; the lean is client-local; `CameraShaker` has no HUD row; `SanctuaryHub.CourtyardFloor` is 1x104x104 rotated Z=90 (reads as a wall in the Explorer; worth renaming).