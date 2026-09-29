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
- **Dodging:** A committed 350ms evasive step. Untouchable for its first 200ms, fully
  vulnerable for the last 150ms. Cancelable *into* from `Windup` and `Recovery`; it
  cannot be cancelled *out of* except by taking damage.

## 2. Priority Rules
1. `Stunned` overrides ALL states immediately.
2. `Parrying` can interrupt `Windup`, but CANNOT interrupt `Active` or `Recovery`.
3. `Active` cannot be interrupted except by taking damage (`Stunned`).
4. `Recovery` locks out all actions except queued input buffering.
5. `Dodging` cannot be interrupted into another action at all. It resolves on its
   own clock to `Idle` at 350ms, or is cut to `Stunned` by a hit that lands after
   the 200ms i-frames have closed.
6. `Dodging` cannot be entered from `Active`, `Blocking`, `Parrying`, `Stunned` or
   `Executing`. The two it *can* be entered from are the two it was added for: a
   `Windup` feint and a `Recovery` dodge-cancel.

## 3. The Evasion Economy
The dodge exists to answer one question the parry cannot: *"the attack is already
in the air."* A parry requires seeing the windup and hitting a 133ms window; a
dodge only requires reacting. So the two are deliberately not comparable, and
three numbers hold them in that relationship.

1. **200ms of i-frames**, shorter than Hit 1's 0.27s Windup+Active. A dodge that
   outlasted a light swing would be a strictly better answer to it than a parry
   and would cost nothing, so nobody would ever learn to time the parry window.
   At 200ms the dodge reliably beats an attack already swinging and reliably
   loses to one the player saw start.
2. **150ms of vulnerable recovery** after them. This is the price. Ending the
   move the instant the i-frames did would make it a panic button; ending it later
   means a mistimed dodge leaves you open inside the opponent's next windup.
3. **~7.9 studs of ground covered** (45 studs/s held for 200ms). Enough to visibly
   leave the sword's reach, short enough that a missed dodge is still recoverable
   on foot.

Two things are deliberately *not* available: dodging out of a `Blocking` stance
(which would make the posture economy optional — the correct play against any
attack would become "block, then tap Q"), and chaining i-frames (the cooldown
prices every dodge, so invulnerability can never be continuous).