# On-Device Testing Protocol — `d28cfb9`

**Status of the artifact under test: experimental.** Every threshold below was derived analytically and validated only against synthetic fixtures. The crunch gate logic changed three times in the two hours before merge and has never processed a camera frame. Treat a passing CI run as evidence the maths is self-consistent, not that it works on a body.

The `.ipa` is the `FitnessTracker-ipa` artifact on the `Build IPA` run for `d28cfb9`. It is unsigned — install via Xcode → Devices, or re-sign with your own profile.

---

## 0. The one identity that makes this whole document work

Both crunch gates derive from the athlete's learned resting hip angle:

```
lyingGate = restHipAngle − lyingMargin   (9°)
peakGate  = restHipAngle − peakClosure   (19°)
```

The progress ring is `(lyingGate − hipAngle) / (lyingGate − peakGate)`. The denominator is `peakClosure − lyingMargin` = **10, always** — it does not depend on `restHipAngle`. Substituting `closure = restHipAngle − hipAngle`:

```
progress = (closure − 9) / 10        ⟺        closure = 10 × progress + 9
```

**The ring is a calibrated protractor.** Its observed maximum converts directly to degrees of hip closure achieved, with no instrumentation, no logs, and no debugger:

| Ring max | Closure achieved | Verdict |
|---|---|---|
| 0.0 (never moves) | ≤ 9° | not curling, or rest badly over-learned |
| 0.5 | 14° | halfway; 5° short of the gate |
| 0.9 | 18° | **1° short** — the near-miss case |
| 1.0 (reaches full, returns to 0) | ≥ 19° | peak satisfied ✅ |
| 1.0 **pinned**, never returns to 0 | undefined | rest over-ratcheted, or degenerate landmarks |

Record the ring maximum for every failing rep. It is the single highest-value observation in this protocol.

---

## 1. Baseline session (run this before anything else)

Purpose: establish that the happy path works at all, so later failures are attributable.

1. Phone propped **upright**, side-on, athlete's full body in frame, good light.
2. Standard crunch setup: on back, knees bent ~45°, feet planted.
3. Lie still for **2 full seconds before moving.** This is not optional — it is the bootstrap window for `restHipAngle`.
4. Perform 10 deliberate crunches at ~2 s/rep, pausing ~0.5 s at the top of each.
5. Record: reps counted, ring maximum per rep, any spoken cues.

**Pass:** 10/10 counted. **Anything less → §3.**

---

## 2. Then vary ONE dimension at a time

Run each as a fresh set (background the app between sets — this clears `restHipAngle` via `reset()`).

| # | Variation | Watching for |
|---|---|---|
| 2.1 | Phone propped at **45°** against an object | Tilt-invariance. Count must match §1 exactly. A drop here means the hip angle is not actually rotation-invariant on device. |
| 2.2 | Knees drawn **close** to the chest (rest ≈ 110–115°) | The archetype fixed gates could never arm. Must still count. |
| 2.3 | Legs **straight** (rest ≈ 170–180°) | Mirror case. Must not demand a full sit-up. |
| 2.4 | **Fast** reps, ~0.6 s/rep | Filter lag. See §4 — this is the threshold-vs-filter discriminator. |
| 2.5 | **Short** reps, deliberately ~15° closure | Must NOT count. Ring should peak ≈ 0.6. |
| 2.6 | Slide hips ~1/3 of a thigh length sideways mid-rep | Must speak "Keep your body steady" **and still count the rep**. |
| 2.7 | Hands behind head, elbows flared (self-occlusion) | Confidence floor. Ring should drop to 0 rather than freeze. |

---

## 3. THE HIGH-RISK FAILURE: counter flat at zero, ring animating

This is the failure mode to expect, and it is deceptive precisely because **nothing looks broken** — the skeleton tracks, the ring moves, no error appears. It almost always means the FSM never armed, or never closed an attempt.

Work the decision tree in order. Do not skip to tuning constants.

### Step 1 — classify by ring behaviour

```
Ring pinned at 1.0, never returns to 0
    └─► restHipAngle over-ratcheted, OR degenerate landmarks   → Step 2

Ring animates 0 → max → 0, but max < 1.0
    └─► closure is short of peakClosure                        → Step 3

Ring never leaves 0
    └─► hipAngle never drops below lyingGate                   → Step 4

Ring animates fully to 1.0 and back, still no rep
    └─► peak IS being satisfied; failure is arming or credit   → Step 5
```

### Step 2 — ring pinned at 1.0

Two causes, distinguishable by whether the skeleton overlay looks sane.

**(a) Degenerate landmarks.** If the shoulder marker sits on or near the hip marker, `PoseGeometry.angle` returns its 0 sentinel. `isTrustworthyAngle` (floor 5°) then correctly refuses to credit a peak — the counter *should* stay at zero. Confirm by checking whether progress is pinned because `hipAngle ≈ 0` rather than because it is genuinely low. **This is correct behaviour, not a bug.** Fix the framing/lighting, not the code.

**(b) Rest over-ratcheted.** `restHipAngle` only rises. If a spurious high reading was absorbed during bootstrap, both gates rise with it. The failure threshold is exact:

```
counter deadlocks when   restHipAngle > trueRest + lyingMargin
                  i.e.   restHipAngle > trueRest + 9°
```

Below that margin the system self-corrects, because *both* gates shift together and the athlete still spans them. Above it, `hipAngle >= lyingGate` is never true → the lying branch never runs → `attemptInProgress` is stuck true → **rest can no longer ratchet** (it only updates when no attempt is open) → permanent deadlock.

**Confirm:** background and relaunch the app (clears rest) and immediately lie still for 2 s. If the first set now counts, this was the cause.
**Fix:** lengthen the still-bootstrap window in the UI, or add an outlier reject to the ratchet (ignore samples more than ~15° above the running estimate).

### Step 3 — ring max below 1.0

Convert with the identity: `closure = 10 × ringMax + 9`.

- **ringMax ≈ 0.9 (18°)** — a genuine near-miss. The athlete is 1° short. This is `peakClosure` being slightly too strict for real bodies, *not* a filter problem. Sanity-check the spec derivation against the athlete's actual torso:thigh ratio: `closure = 0.4 / (torso/thigh)` radians. The code assumes 1.2, giving 19.1°. A long-torso athlete (ratio 1.4) only needs 16.4°, so `peakClosure` should come **down** for them.
- **ringMax ≈ 0.3–0.7** — the athlete genuinely is not closing far enough. Coach the movement before touching constants.
- **Before changing `peakClosure`, re-run at half tempo.** If slow reps reach 1.0 and fast ones do not, it is the filter → §4.

### Step 4 — ring never leaves 0

`hipAngle` never drops below `lyingGate`, meaning either no real curl, or `restHipAngle` bootstrapped **low** (athlete was already curled when tracking started) so `lyingGate` sits below their actual movement.

The ratchet should recover this within ~1 s of lying still (alpha 0.1 ⇒ ~90 % convergence in ~22 frames). If it does not recover, `attemptInProgress` is stuck — same deadlock as Step 2(b).

### Step 5 — ring completes but nothing counts

The peak is being satisfied, so the failure is on the arming or credit side:

- Was the athlete seen **lying** before the first curl? Walking into frame mid-curl leaves `isArmed` false by design, and the first rep is deliberately not credited.
- Did tracking drop mid-rep? `trackingLost()` voids the attempt **and** disarms, by design — an unobserved return cannot be credited.
- Is `minConfidence` (0.4) rejecting the return-to-lying frames? Those frames emit `depthProgress(0)`, so the ring would snap to 0 rather than ease down. A ring that *snaps* rather than eases is the signature.

---

## 4. Threshold problem or filter problem? Vary tempo.

This is the only reliable discriminator, and it costs one extra set.

| Slow (2 s/rep) | Fast (0.6 s/rep) | Diagnosis | Act on |
|---|---|---|---|
| ✅ counts | ✅ counts | Working | — |
| ❌ fails | ❌ fails | **Threshold.** Speed-independent. | `peakClosure`, `lyingMargin` |
| ✅ counts | ❌ fails | **Filter lag.** Peak smoothed away before the gate sees it. | `beta` ↑ |
| ❌ fails | ✅ counts | Rest mis-learned during the slow approach | ratchet / bootstrap |

**Why tempo separates them:** a threshold is a static comparison — it cannot know how fast you moved. Only the 1€ filter is speed-dependent. If a failure survives a tempo change, the filter is exonerated.

### 1€ parameters, and which knob does what

At 30 fps with `minCutoff 1.2`, `beta 10`:

- **at rest** (speed ≈ 0): cutoff 1.2 Hz → α ≈ 0.20 → time constant ≈ **130 ms**
- **mid-crunch** (~0.33 normalized units/s): cutoff ≈ 4.5 Hz → α ≈ 0.49 → ≈ **65 ms**

| Symptom | Knob | Direction |
|---|---|---|
| Peak detected late on fast reps | `beta` | **increase** (more speed adaptation) |
| Counter jitters / double-counts while still | `minCutoff` | **decrease** (smoother at rest) |
| Ring feels laggy even when still | `minCutoff` | increase — but expect more jitter |

`beta` is deliberately ~30× published 1€ values because coordinates here are normalized 0–1, not pixels. **Do not "correct" it toward literature defaults** — at the published value the adaptive term contributes under 9 %, and a spec-conformant rep never crosses the gate at any duration.

---

## 5. Sway bounds

Note the geometry: `SwayMonitor` measures **horizontal drift only**, against a baseline frozen when the active phase starts. There is no vertical component — that is deliberate, so a pull-up's intended vertical travel is not read as sway.

| Constant | Where | Normalized against | Test |
|---|---|---|---|
| `maxHipDriftThighFraction` 0.30 | crunches | thigh length | §2.6 — slide ~⅓ thigh, expect one cue |
| 0.15 | `PullUpAnalyzer` | calibrated arm span | swing on the bar, wrists fixed |
| 0.15 | `DipsAnalyzer` | upper-arm length | rock fore/aft on the bars |

**The cue must fire at most once per rep and must never cost the rep.** If a clean rep is nagged, the bound is too tight — raise it. If a clear swing is silent, lower it. `SwayMonitor` has no access to the counter, so a sway cue voiding a rep would indicate a wiring bug, not a tuning problem.

---

## 6. Report template

```
Build:            d28cfb9
Device / iOS:
Exercise:         crunches
Phone angle:      upright | 45°
Setup:            knees bent | knees close | legs straight
Tempo:            ~__ s/rep
Reps performed:   __        Reps counted: __
Ring max/rep:     __ , __ , __ …     → closure = 10×max + 9 = __°
Ring behaviour:   animates fully | max < 1.0 | pinned at 1.0 | never moves
Cues heard:
Decision-tree step reached (§3):
```

Attach a screen recording where possible — ring behaviour is far more legible in motion than in a description.

---

## 7. Known-good expectations

These come from simulation, not device, and are what "working" should look like:

- 135° rest → gates 126 / 116; a 19.0° closure lands at 116.0 and counts
- 112° rest (knees close) → gates 103 / 93; a 26° closure lands at 86 and counts
- Phone at 45° must produce an identical count to upright — the driving angle is rotation-invariant by construction
- A partial curl of 15° must **not** count, with ring peaking ≈ 0.6
