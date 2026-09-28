# COMBAT SPECIFICATION: RONIN — THE LAST BLADE

## 1. Combat State Definitions
- **Idle:** Neutral actionable state. Character has full movement and can initiate any action.
- **Windup:** The startup phase of a swing. Can be feinted or canceled into a Parry.
- **Active:** The lethal strike window. Hitboxes are live. Action-locked; cannot turn or cancel.
- **Recovery:** Follow-through of the swing. Vulnerable to enemy counters; inputs are buffered.
- **Blocking:** Defensive guard active. Frontal damage absorbed and converted to posture damage.
- **Parrying:** Precision 133ms reaction window. Cancels incoming damage and reflects heavy posture damage.
- **Stunned:** Heavy stagger or posture rupture. Complete input lock for 0.5s–3.0s.
- **Executing:** Invulnerable cinematic paired finisher animation on a posture-broken foe.

## 2. Priority Rules
1. `Stunned` overrides ALL states immediately.
2. `Parrying` can interrupt `Windup`, but CANNOT interrupt `Active` or `Recovery`.
3. `Active` cannot be interrupted except by taking damage (`Stunned`).
4. `Recovery` locks out all actions except queued input buffering.