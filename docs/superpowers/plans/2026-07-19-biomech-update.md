# Biomechanical & Voice-Coach Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a phone-tilt-proof crunches module, a real One Euro coordinate filter, a reusable frozen-anchor anti-sway layer, relaxed upper-body FSM bounds, and a neural-voice coaching engine — without touching the plank.

**Architecture:** Landmark coordinates flow through a new adaptive `OneEuroFilter` (allocation-free structs) and feed the FSM gates directly, so no second smoothing pass adds latency. A separate `FrozenAnchor` (EMA, alpha 0.3) tracks only a static baseline, frozen at the start of each active phase, against which structural drift is measured; exceeding the bound fires a non-blocking `.swing` cue and never touches the rep counter. Crunches are driven by the rotation-invariant shoulder–hip–knee angle rather than any floor-relative measure.

**Tech Stack:** Swift 5.0, iOS 15.0 deployment target, Vision (`VNHumanBodyPoseObservation`), AVFoundation (`AVSpeechSynthesizer`, `AudioServices`), XCTest, XcodeGen.

## Global Constraints

- **Plank is untouched.** Do not modify `PlankAnalyzer`, `PlankConfig`, or `HoldFormatTests.swift`. Adding the `.crunches` case to a `switch` that also lists `.plank` is allowed; changing `.plank`'s branch is not.
- **Anti-sway never blocks.** Drift/sway detection emits a cue only. It must not cancel, penalize, reset, or decrement a rep, and must not transition the FSM to `.invalidRepDetected` or `.invalidPosition`.
- **No EMA on the active FSM path.** FSM gates consume `OneEuroFilter` output. The alpha-0.3 EMA exists solely inside `FrozenAnchor`.
- **All spatial thresholds are normalized** against a skeletal segment measured on the athlete (thigh length, arm span, upper-arm length). No absolute normalized-coordinate constants in rep gates.
- **New per-frame code allocates nothing.** `OneEuroFilter`, `OneEuroPointFilter`, `FrozenAnchor`, and `SwayMonitor` are `struct`s held as stored properties, mutated in place. See "Known scope limit" below.
- **Camera framing:** pull-ups = front view, dips = side view. Crunches = side view.
- **Sources are globbed** by `project.yml` (`path: ExerciseTracker`, `path: Tests`), so new files in those trees need no project file edit.

### Known scope limit — read before claiming "zero heap allocations per frame"

The spec asks for zero heap allocations per frame in the live loop. The new modules in this plan meet that. **The existing `ExerciseAnalyzer.analyze(frame:) -> [AnalyzerEvent]` contract does not** — it allocates an array every frame, for every exercise, today. Converting that to an inout sink or a fixed-capacity buffer is a cross-cutting refactor of all five analyzers, the manager, and every test, and is deliberately **out of scope here**. Do not claim the loop is allocation-free on completion; state accurately that new code adds no per-frame allocations and the pre-existing event-array allocation remains.

### Spec deviations, already decided — do not "fix" these back

1. **Pull-up peak gate = 0.50 of arm span**, not "15% of upper-arm length". The literal spec value is ~5× stricter than the current gate and would count zero reps forever — the same muscle-up bug already documented at `ExerciseTypes.swift:305` and pinned by `BilateralJointsTests.testTopOfARealPullUpDoesNotReachTheBarLine`. The user chose to relax from today's 0.40 to 0.50. Task 3 updates that test.
2. **Crossed-feet anti-cheat does not exist** in this repo and never did. There is nothing to remove. Do not invent one to then delete it.
3. **Jawline/chin detection does not exist.** `BilateralJoints` carries no facial landmarks by design (`PoseGeometry.swift:408`). Only the UI *string* `"Chin over the bar!"` exists; Task 8 rewords it. Do not add facial landmarks.
4. **`VoiceCue` cases are lowerCamelCase** (`.swing`), not the spec's `VoiceCue.SWING`. SCREAMING_CASE conflicts with the spec's own "idiomatic Swift" deliverable. The `TONE` config flag becomes `VoiceCoach.Mode.tone`.

### Verification reality

**Development is on Windows; Swift cannot be compiled or tested locally.** Every "run the tests" step in this plan executes on the macOS CI runner via `.github/workflows/ios.yml`. Push the branch and read the CI result — do not assert a test passes without a CI run backing it. If you are on macOS with Xcode, run `xcodegen generate && xcodebuild test -scheme FitnessTracker -destination 'platform=iOS Simulator,name=iPhone 15'` instead.

---

## File Structure

**Create:**
- `ExerciseTracker/Filters/OneEuroFilter.swift` — adaptive 1€ filter, scalar + point. No dependencies.
- `ExerciseTracker/Filters/DriftAnchor.swift` — `DriftAnchoring` protocol, `FrozenAnchor` (EMA alpha 0.3), `SwayMonitor` (normalized bound + one-shot cue latch).
- `ExerciseTracker/CrunchAnalyzer.swift` — the crunches FSM. Separate file because `RepAnalyzers.swift` is already 1011 lines.
- `ExerciseTracker/VoiceCoach.swift` — `VoiceCue`, `VoiceCoach`, fidelity detection, terse strategy, tone mode.
- `Tests/OneEuroFilterTests.swift`
- `Tests/DriftAnchorTests.swift`
- `Tests/CrunchAnalyzerTests.swift`
- `Tests/VoiceCoachTests.swift`

**Modify:**
- `ExerciseTracker/ExerciseTypes.swift` — `.crunches` case, `CrunchConfig`, dips 165/98, pull-up hang 160, `PullUpConfig.topTriggerArmFraction` → 0.50.
- `ExerciseTracker/PoseGeometry.swift` — `.crunches` in the mandatory-joint switch; `thighLength`/`upperArmLength` helpers.
- `ExerciseTracker/RepAnalyzers.swift` — sway wiring in `DipsAnalyzer` and `PullUpAnalyzer`.
- `ExerciseTracker/ExerciseTrackerManager.swift` — `.crunches` in `makeAnalyzer`, route `speak()` through `VoiceCoach`.
- `ExerciseTracker/UI/WorkoutViewModel.swift` — cue copy, crunches status text.
- `Tests/BilateralJointsTests.swift` — pull-up trigger bound.
- `Tests/ExerciseThresholdsTests.swift` — dips/pull-up angles.

---

## Task 1: One Euro Filter

**Files:**
- Create: `ExerciseTracker/Filters/OneEuroFilter.swift`
- Test: `Tests/OneEuroFilterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct OneEuroFilter` — `init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007, derivativeCutoff: CGFloat = 1.0)`, `mutating func apply(_ x: CGFloat, at t: TimeInterval) -> CGFloat`, `mutating func reset()`
  - `struct OneEuroPointFilter` — same init signature, `mutating func apply(_ p: CGPoint, at t: TimeInterval) -> CGPoint`, `mutating func reset()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OneEuroFilterTests.swift`:

```swift
//
//  OneEuroFilterTests.swift
//  FitnessTrackerTests
//

import XCTest
@testable import FitnessTracker

final class OneEuroFilterTests: XCTestCase {

    private let acc: CGFloat = 1e-6

    /// The first sample has no history to blend with, so it passes through
    /// untouched. Anything else would mean the filter invents a value before it
    /// has seen the signal.
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.apply(0.7, at: 0), 0.7, accuracy: acc)
    }

    /// A constant signal must stay exactly constant — no drift, no ringing.
    func testConstantSignalIsUnchanged() {
        var f = OneEuroFilter()
        var t: TimeInterval = 0
        for _ in 0..<60 {
            XCTAssertEqual(f.apply(0.5, at: t), 0.5, accuracy: 1e-9)
            t += 1.0 / 60
        }
    }

    /// THE POINT OF THE FILTER. On a slow signal the adaptive cutoff stays low,
    /// so jitter is attenuated: the output must sit closer to the true value than
    /// the noisy sample does.
    func testSlowSignalIsSmoothed() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
        var t: TimeInterval = 0
        // Settle on the true value.
        for _ in 0..<30 { _ = f.apply(0.5, at: t); t += 1.0 / 60 }
        // A single noisy spike must be pulled back toward 0.5.
        let out = f.apply(0.6, at: t)
        XCTAssertLessThan(out, 0.6, "spike must be attenuated")
        XCTAssertGreaterThan(out, 0.5, "but not ignored entirely")
    }

    /// THE OTHER POINT. On a fast movement the cutoff rises with speed, so the
    /// filter tracks rather than lags — this is what stops late peak detection on
    /// fast reps. A high beta must follow a ramp more closely than a zero beta.
    func testFastSignalLagsLessWithHigherBeta() {
        func finalValue(beta: CGFloat) -> CGFloat {
            var f = OneEuroFilter(minCutoff: 1.0, beta: beta)
            var t: TimeInterval = 0
            var out: CGFloat = 0
            for i in 0..<20 {                    // steep ramp: 0 → 2.0
                out = f.apply(CGFloat(i) * 0.1, at: t)
                t += 1.0 / 60
            }
            return out
        }
        XCTAssertGreaterThan(finalValue(beta: 5.0), finalValue(beta: 0.0),
                             "speed-adaptive cutoff must reduce lag on fast motion")
    }

    /// Vision can hand us the same timestamp twice under backpressure. A zero or
    /// negative dt would divide by zero and poison the state with NaN forever.
    func testNonAdvancingTimeIsRejectedNotDividedBy() {
        var f = OneEuroFilter()
        _ = f.apply(0.5, at: 10)
        let out = f.apply(0.9, at: 10)          // same timestamp
        XCTAssertTrue(out.isFinite, "must never emit NaN/inf on a zero dt")
    }

    /// Reset must clear history, so the next sample passes through as a first
    /// sample again. Without this a re-armed analyzer inherits the last rep's tail.
    func testResetClearsHistory() {
        var f = OneEuroFilter()
        var t: TimeInterval = 0
        for _ in 0..<30 { _ = f.apply(0.5, at: t); t += 1.0 / 60 }
        f.reset()
        XCTAssertEqual(f.apply(0.9, at: t), 0.9, accuracy: acc)
    }

    /// The point filter must be exactly two independent scalar filters.
    func testPointFilterFiltersAxesIndependently() {
        var pf = OneEuroPointFilter()
        var fx = OneEuroFilter()
        var fy = OneEuroFilter()
        var t: TimeInterval = 0
        for i in 0..<20 {
            let p = CGPoint(x: CGFloat(i) * 0.01, y: 0.5)
            let got = pf.apply(p, at: t)
            let wantX = fx.apply(p.x, at: t)
            let wantY = fy.apply(p.y, at: t)
            XCTAssertEqual(got.x, wantX, accuracy: acc)
            XCTAssertEqual(got.y, wantY, accuracy: acc)
            t += 1.0 / 60
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Commit and push the test file alone, then read CI. Expected: compile failure, `cannot find 'OneEuroFilter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ExerciseTracker/Filters/OneEuroFilter.swift`:

```swift
//
//  OneEuroFilter.swift
//  ExerciseTracker
//
//  The adaptive 1€ filter (Casiez, Roussel & Vogel, CHI 2012) applied to Vision
//  landmark coordinates.
//
//  WHY THIS RATHER THAN A PLAIN EMA
//  --------------------------------
//  A fixed-alpha EMA forces one choice for two opposite problems: enough
//  smoothing to kill jitter while the athlete is still, and enough
//  responsiveness to catch the apex of a fast rep. Pick a low alpha and the peak
//  arrives ~100ms late, so the rep is credited after the athlete has already
//  started back down. Pick a high alpha and a stationary hand jitters through
//  the gate.
//
//  The 1€ filter resolves that by making the cutoff frequency a function of the
//  signal's own speed: nearly still → low cutoff → heavy smoothing; moving fast
//  → high cutoff → the filter gets out of the way. That is exactly the tradeoff
//  the FSM gates need, which is why they read this filter's output DIRECTLY and
//  no second smoothing pass is applied on top (see `FrozenAnchor`, which is for
//  the drift baseline only and is deliberately NOT in the rep path).
//
//  ALLOCATION: these are structs with only scalar stored properties, mutated in
//  place. Holding one as a stored property costs nothing per frame.
//

import Foundation
import CoreGraphics

/// A one-dimensional adaptive low-pass filter.
struct OneEuroFilter {

    /// Cutoff frequency (Hz) at zero speed. Lower = smoother when still.
    private let minCutoff: CGFloat

    /// How aggressively the cutoff rises with speed. Higher = less lag when fast.
    private let beta: CGFloat

    /// Cutoff (Hz) for the derivative estimate itself, which also needs
    /// smoothing or the adaptive term chases its own noise.
    private let derivativeCutoff: CGFloat

    private var lastValue: CGFloat?
    private var lastDerivative: CGFloat = 0
    private var lastTime: TimeInterval?

    /// - Parameters:
    ///   - minCutoff: tuned for normalized (0...1) Vision coordinates at ~30–60fps.
    ///   - beta: 0 disables speed adaptation, degrading this to a fixed low-pass.
    init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007, derivativeCutoff: CGFloat = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// The standard exponential smoothing factor for a given cutoff and timestep.
    private static func smoothingFactor(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// Filters one sample. `t` must be monotonic; samples that do not advance
    /// time are passed through unchanged rather than dividing by a zero dt.
    ///
    /// FAIL-SAFE: a non-finite input resets the filter and is returned as-is, so
    /// a bad Vision coordinate cannot poison the state permanently. The callers'
    /// own fail-closed guards (see `PoseGeometry.isFinite`) still reject the frame.
    mutating func apply(_ x: CGFloat, at t: TimeInterval) -> CGFloat {
        guard x.isFinite else {
            reset()
            return x
        }
        guard let previous = lastValue, let previousTime = lastTime, t > previousTime else {
            // First sample, or time did not advance: nothing to blend with.
            lastValue = x
            lastTime = t
            lastDerivative = 0
            return x
        }

        let dt = CGFloat(t - previousTime)
        guard dt > 0, dt.isFinite else {
            lastValue = x
            return x
        }

        // Smoothed derivative → the speed estimate that drives the cutoff.
        let derivative = (x - previous) / dt
        let dAlpha = Self.smoothingFactor(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = dAlpha * derivative + (1 - dAlpha) * lastDerivative

        // THE ADAPTIVE STEP: faster movement → higher cutoff → less lag.
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let alpha = Self.smoothingFactor(cutoff: cutoff, dt: dt)
        let filtered = alpha * x + (1 - alpha) * previous

        lastValue = filtered
        lastDerivative = smoothedDerivative
        lastTime = t
        return filtered
    }

    /// Clears all history. Call when a rep attempt is abandoned or tracking is
    /// lost, so the next attempt does not inherit the previous one's tail.
    mutating func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }
}

/// Two independent `OneEuroFilter`s, one per axis. Landmark coordinates are
/// filtered per-axis because x and y jitter independently.
struct OneEuroPointFilter {

    private var x: OneEuroFilter
    private var y: OneEuroFilter

    init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007, derivativeCutoff: CGFloat = 1.0) {
        self.x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        self.y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    mutating func apply(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        CGPoint(x: x.apply(p.x, at: t), y: y.apply(p.y, at: t))
    }

    mutating func reset() {
        x.reset()
        y.reset()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: all 7 `OneEuroFilterTests` pass, no other test regresses.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/Filters/OneEuroFilter.swift Tests/OneEuroFilterTests.swift
git commit -m "feat: add adaptive One Euro filter for landmark coordinates"
```

---

## Task 2: Frozen drift anchor and sway monitor

**Files:**
- Create: `ExerciseTracker/Filters/DriftAnchor.swift`
- Test: `Tests/DriftAnchorTests.swift`

**Interfaces:**
- Consumes: `PoseGeometry.distance` (existing, `PoseGeometry.swift:272`).
- Produces:
  - `protocol DriftAnchoring` — `var isFrozen: Bool { get }`, `mutating func updateBaseline(_ p: CGPoint)`, `mutating func freeze()`, `mutating func thaw()`, `mutating func reset()`, `func drift(from p: CGPoint) -> CGFloat`, `func horizontalDrift(from p: CGPoint) -> CGFloat`
  - `struct FrozenAnchor: DriftAnchoring` — `init(alpha: CGFloat = 0.3)`
  - `struct SwayMonitor` — `init(maxDriftFraction: CGFloat)`, `mutating func observe(_ p: CGPoint, scale: CGFloat) -> Bool`, `mutating func beginActivePhase()`, `mutating func endActivePhase()`, `mutating func reset()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DriftAnchorTests.swift`:

```swift
//
//  DriftAnchorTests.swift
//  FitnessTrackerTests
//

import XCTest
@testable import FitnessTracker

final class DriftAnchorTests: XCTestCase {

    private let acc: CGFloat = 1e-6

    /// The first observation seeds the baseline outright — an EMA with no prior
    /// has nothing to average against.
    func testFirstObservationSeedsTheBaseline() {
        var a = FrozenAnchor()
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.5, y: 0.5)), 0, accuracy: acc)
    }

    /// Alpha 0.3 means each new sample contributes 30%. Two samples: the
    /// baseline must sit 30% of the way from the first toward the second.
    func testBaselineTracksWithAlphaPointThree() {
        var a = FrozenAnchor(alpha: 0.3)
        a.updateBaseline(CGPoint(x: 0.0, y: 0.0))
        a.updateBaseline(CGPoint(x: 1.0, y: 0.0))
        // Baseline is now x = 0.3; drift from x = 0.3 must be zero.
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.3, y: 0.0)), 0, accuracy: acc)
    }

    /// THE CORE BEHAVIOUR. Once frozen, further observations must NOT move the
    /// baseline — otherwise the anchor chases the very drift it exists to
    /// measure, and a slow slide reads as zero drift forever.
    func testFreezingStopsTheBaselineFollowing() {
        var a = FrozenAnchor(alpha: 0.3)
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        a.updateBaseline(CGPoint(x: 0.9, y: 0.5))   // must be ignored
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.5)), 0.4, accuracy: acc)
        XCTAssertTrue(a.isFrozen)
    }

    /// Thawing resumes tracking, so the next lying/hang phase re-baselines.
    func testThawResumesTracking() {
        var a = FrozenAnchor(alpha: 1.0)            // alpha 1 = follow exactly
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        a.thaw()
        a.updateBaseline(CGPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.5)), 0, accuracy: acc)
    }

    /// Horizontal drift ignores vertical travel. This is what makes it usable on
    /// a pull-up, where the shoulders are SUPPOSED to move a long way up but the
    /// body is not supposed to swing forward and back.
    func testHorizontalDriftIgnoresVerticalTravel() {
        var a = FrozenAnchor()
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        XCTAssertEqual(a.horizontalDrift(from: CGPoint(x: 0.5, y: 0.9)), 0, accuracy: acc)
        XCTAssertEqual(a.horizontalDrift(from: CGPoint(x: 0.6, y: 0.9)), 0.1, accuracy: acc)
    }

    /// A baseline that was never seeded must report zero drift, not a huge one —
    /// firing a sway warning before the athlete has even been observed is noise.
    func testUnseededAnchorReportsNoDrift() {
        let a = FrozenAnchor()
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.9)), 0, accuracy: acc)
    }

    /// Drift is judged as a FRACTION of a skeletal segment, so the same bound
    /// works at any camera distance. Scale 0.2 with a 0.25 bound → trips at 0.05.
    func testSwayTripsOnlyBeyondTheNormalizedBound() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)   // seed baseline
        m.beginActivePhase()
        XCTAssertFalse(m.observe(CGPoint(x: 0.53, y: 0.5), scale: 0.2), "0.03 < 0.05 bound")
        XCTAssertTrue(m.observe(CGPoint(x: 0.60, y: 0.5), scale: 0.2), "0.10 > 0.05 bound")
    }

    /// The cue fires ONCE per active phase. A swinging athlete would otherwise
    /// be told "steady" on every one of 60 frames a second.
    func testSwayCueFiresOncePerActivePhase() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)
        m.beginActivePhase()
        XCTAssertTrue(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2))
        XCTAssertFalse(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2), "latched for this phase")

        m.endActivePhase()
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)   // re-baseline while idle
        m.beginActivePhase()
        XCTAssertTrue(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2), "new phase, cue re-arms")
    }

    /// A degenerate scale (missing/collapsed limb) must not divide by zero and
    /// must not fire — an unmeasurable body is not a swinging body.
    func testDegenerateScaleNeverFires() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)
        m.beginActivePhase()
        XCTAssertFalse(m.observe(CGPoint(x: 0.99, y: 0.5), scale: 0))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: compile failure, `cannot find 'FrozenAnchor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ExerciseTracker/Filters/DriftAnchor.swift`:

```swift
//
//  DriftAnchor.swift
//  ExerciseTracker
//
//  The anti-sway layer: a frozen baseline plus a normalized drift bound.
//
//  WHY THE BASELINE MUST FREEZE
//  ----------------------------
//  Measuring drift against a baseline that keeps following the body is circular
//  — the anchor slides along with the athlete, so a steady creep reads as zero
//  drift and the check never fires. The baseline is therefore built ONLY while
//  the athlete is in the reference posture (flat on the floor for a crunch, dead
//  hang for a pull-up) and frozen the instant the active phase begins. Everything
//  after that is measured against where the body actually started.
//
//  WHY EMA HERE AND 1€ THERE
//  -------------------------
//  This is the ONLY place the alpha-0.3 EMA is used. It is appropriate for a
//  baseline precisely because it is laggy: a static anchor wants heavy averaging
//  and does not care about latency. The rep gates want the opposite and read
//  `OneEuroFilter` output directly — layering this EMA on top of them would add
//  ~100ms and detect the apex of a fast rep too late.
//
//  ALLOCATION: value types with scalar/CGPoint storage only.
//

import Foundation
import CoreGraphics

/// A static positional baseline that can be built, frozen, and measured against.
protocol DriftAnchoring {
    /// True once `freeze()` has been called with a seeded baseline.
    var isFrozen: Bool { get }
    /// Feeds a reference-posture sample. Ignored while frozen.
    mutating func updateBaseline(_ p: CGPoint)
    /// Locks the baseline. No-op if nothing has been observed yet.
    mutating func freeze()
    /// Unlocks the baseline so the next reference phase can re-seed it.
    mutating func thaw()
    mutating func reset()
    /// Euclidean distance from the baseline, in normalized units. 0 if unseeded.
    func drift(from p: CGPoint) -> CGFloat
    /// Horizontal-only distance from the baseline. 0 if unseeded.
    func horizontalDrift(from p: CGPoint) -> CGFloat
}

/// The standard `DriftAnchoring` implementation: an alpha-0.3 EMA that stops
/// updating once frozen.
struct FrozenAnchor: DriftAnchoring {

    /// EMA weight for each new sample. 0.3 per spec — heavy averaging, because a
    /// baseline wants stability and has no latency budget to blow.
    private let alpha: CGFloat

    private var baseline: CGPoint?
    private(set) var isFrozen = false

    init(alpha: CGFloat = 0.3) {
        self.alpha = alpha
    }

    mutating func updateBaseline(_ p: CGPoint) {
        guard !isFrozen, PoseGeometry.isFinite(p) else { return }
        guard let current = baseline else {
            baseline = p                      // first sample seeds outright
            return
        }
        baseline = CGPoint(x: alpha * p.x + (1 - alpha) * current.x,
                           y: alpha * p.y + (1 - alpha) * current.y)
    }

    mutating func freeze() {
        guard baseline != nil else { return }
        isFrozen = true
    }

    mutating func thaw() { isFrozen = false }

    mutating func reset() {
        baseline = nil
        isFrozen = false
    }

    /// Returns 0 when unseeded: with no baseline there is no evidence of drift,
    /// and reporting a large value would fire a coaching cue at an athlete we
    /// have not actually measured yet.
    func drift(from p: CGPoint) -> CGFloat {
        guard let baseline = baseline else { return 0 }
        return PoseGeometry.distance(baseline, p)
    }

    func horizontalDrift(from p: CGPoint) -> CGFloat {
        guard let baseline = baseline, PoseGeometry.isFinite(p) else { return 0 }
        return abs(p.x - baseline.x)
    }
}

/// Wraps a `FrozenAnchor` with a skeletally-normalized bound and a once-per-phase
/// latch, which together are what the analyzers actually need.
///
/// NON-BLOCKING BY CONSTRUCTION: `observe` returns a Bool meaning "worth a cue".
/// It has no access to the rep counter or the FSM state and therefore cannot
/// cancel, penalize, or reset a repetition — the spec's requirement is enforced
/// by this type's shape, not by remembering to be careful at each call site.
struct SwayMonitor {

    /// Allowed drift as a fraction of the supplied skeletal scale (thigh length
    /// for crunches, arm span for pull-ups). Normalizing is what makes one number
    /// correct at every camera distance and body size.
    private let maxDriftFraction: CGFloat

    private var anchor = FrozenAnchor()
    private var isActive = false
    private var hasCuedThisPhase = false

    init(maxDriftFraction: CGFloat) {
        self.maxDriftFraction = maxDriftFraction
    }

    /// Call once the active phase (ascent / pull) begins: freezes the baseline
    /// and re-arms the cue.
    mutating func beginActivePhase() {
        anchor.freeze()
        isActive = true
        hasCuedThisPhase = false
    }

    /// Call when the athlete returns to the reference posture: unfreezes so the
    /// baseline re-seeds for the next rep.
    mutating func endActivePhase() {
        anchor.thaw()
        isActive = false
    }

    /// Feeds one frame.
    ///
    /// - Returns: `true` exactly once per active phase, on the first frame whose
    ///   drift exceeds the bound. Always `false` while inactive (the baseline is
    ///   still being built) and always `false` for a degenerate scale.
    @discardableResult
    mutating func observe(_ p: CGPoint, scale: CGFloat) -> Bool {
        guard isActive else {
            anchor.updateBaseline(p)
            return false
        }
        guard scale > 0, scale.isFinite, !hasCuedThisPhase else { return false }
        guard anchor.horizontalDrift(from: p) > maxDriftFraction * scale else { return false }
        hasCuedThisPhase = true
        return true
    }

    mutating func reset() {
        anchor.reset()
        isActive = false
        hasCuedThisPhase = false
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: all 9 `DriftAnchorTests` pass.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/Filters/DriftAnchor.swift Tests/DriftAnchorTests.swift
git commit -m "feat: add frozen-anchor drift baseline and normalized sway monitor"
```

---

## Task 3: Relaxed upper-body thresholds

**Files:**
- Modify: `ExerciseTracker/ExerciseTypes.swift` (dips block ~120–132, pull-up block ~133–147, `PullUpConfig.standard` ~320–326)
- Modify: `Tests/BilateralJointsTests.swift:124-144`
- Modify: `Tests/ExerciseThresholdsTests.swift`

**Interfaces:**
- Consumes: `ExerciseThresholds.init` (existing), `Tolerance` (existing).
- Produces: no new symbols. `PullUpConfig.topTriggerArmFraction` changes value 0.42 → 0.525.

> **Read before editing.** `ExerciseThresholds` bakes the ±5% tolerance in at init. Declare NOMINAL angles; the struct produces the effective ones. Do not pre-apply tolerance by hand.
>
> Spec §4 asks for effective bounds of hang > 160°, dips top > 165°, dips bottom ≤ 98°. Working backwards through `Tolerance`: `atLeast(x) = 0.95x` and `atMost(x) = 1.05x`, so nominal values are 160/0.95 ≈ 168.4, 165/0.95 ≈ 173.7, 98/1.05 ≈ 93.3.

- [ ] **Step 1: Update the threshold tests to the new bounds**

In `Tests/ExerciseThresholdsTests.swift`, add:

```swift
    /// Spec §4: dips top relaxes from a locked 180° to 165°, and the bottom from
    /// a punishing 90° to 98°. Both are stated as EFFECTIVE (post-tolerance)
    /// bounds, so the nominal declarations are pre-divided by the tolerance.
    func testDipsUseTheRelaxedSpecBounds() {
        let t = ExerciseType.dips.repThresholds!
        XCTAssertEqual(t.lockoutAngle, 165, accuracy: 0.5)
        XCTAssertEqual(t.depthAngle, 98, accuracy: 0.5)
    }

    /// Spec §4: the pull-up dead hang relaxes from a strict 180° to 160°, so an
    /// athlete who does not fully lock out at the bottom still re-arms.
    func testPullUpHangUsesTheRelaxedSpecBound() {
        let t = ExerciseType.pullUp.repThresholds!
        XCTAssertEqual(t.lockoutAngle, 160, accuracy: 0.5)
    }

    /// The hysteresis band must survive the relaxation — a descent gate at or
    /// above the lockout would credit and restart a rep on one jittering frame.
    func testRelaxedDipsKeepTheirHysteresisBand() {
        let t = ExerciseType.dips.repThresholds!
        XCTAssertLessThanOrEqual(t.descentStartAngle,
                                 t.lockoutAngle - ExerciseThresholds.minimumHysteresisBand)
    }
```

In `Tests/BilateralJointsTests.swift`, replace `testTopOfARealPullUpDoesNotReachTheBarLine`'s final assertion block (lines 139–143) with:

```swift
        // The calibrated trigger fires on this rep; the literal one doesn't.
        //
        // The bound moved 0.40 → 0.50 per spec §4's relaxation pass. The spec's
        // literal text ("< 15% of upper-arm length") was NOT adopted: an upper
        // arm is about half an arm span, so that reads as ≈0.075 of a span —
        // roughly 5x tighter than this strong rep at 0.35, and about 25x tighter
        // than the 1.0 of a dead hang. It would count zero reps forever, which is
        // the same muscle-up mistake this test was written to prevent.
        let deadHangSpan: CGFloat = 0.4
        let gapInArms = (top.meanWristY - top.meanShoulderY) / deadHangSpan
        XCTAssertEqual(gapInArms, 0.35, accuracy: acc)
        XCTAssertLessThan(gapInArms, PullUpConfig.standard.topTriggerArmFraction,
                          "a strong rep must clear the relaxed 50%-of-arm trigger")
```

Add alongside it:

```swift
    /// The relaxed trigger must still reject a dead hang. Relaxation that reaches
    /// all the way down to "hanging still counts" would make the counter free.
    func testRelaxedTriggerStillRejectsADeadHang() {
        let j = deadHang()
        let gapInArms = (j.meanWristY - j.meanShoulderY) / j.armSpan
        XCTAssertGreaterThan(gapInArms, PullUpConfig.standard.topTriggerArmFraction,
                             "a dead hang must never satisfy the top trigger")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: `testDipsUseTheRelaxedSpecBounds` fails (`171` vs `165`), `testPullUpHangUsesTheRelaxedSpecBound` fails (`171` vs `160`), the bilateral trigger test fails (`0.35 < 0.42` still passes but the new dead-hang test and the changed bound reference compile against the old 0.42).

- [ ] **Step 3: Apply the threshold changes**

In `ExerciseTracker/ExerciseTypes.swift`, replace the `.dips` case body:

```swift
        case .dips:
            // Spec §4 relaxation: top = elbow > 165° effective (was a locked
            // 171°), bottom = elbow <= 98° effective (was a punishing 94.5°).
            // Nominals are pre-divided by `Tolerance` so the EFFECTIVE values
            // land on the numbers the spec states: 173.7 * 0.95 = 165.0 and
            // 93.33 * 1.05 = 98.0.
            return ExerciseThresholds(
                nominalDescentStart: 150,
                nominalDepth:        93.33,   // → 98.0
                nominalLockout:      173.68,  // → 165.0
                reversalMargin:      12,
                // Torso must be clearly vertical/diagonal, not flat — this is the
                // anti-cheat gate that stops push-ups counting as dips. 50° → 47.5°.
                nominalMinTorsoPitch: 50
            )
```

Replace the `.pullUp` case body:

```swift
        case .pullUp:
            // Elbow angles only gate the hang/lockout here — whether a pull-up
            // rep is VALID is decided by shoulder travel against the locked bar
            // line (see PullUpConfig), not by elbow depth.
            //
            // Spec §4 relaxation: the dead hang re-arms at > 160° effective
            // rather than a strict 171°, so an athlete who does not fully lock
            // out at the bottom still gets their next rep counted. Nominal is
            // pre-divided by the tolerance: 168.42 * 0.95 = 160.0.
            return ExerciseThresholds(
                nominalDescentStart: 150,
                nominalDepth:        90,    // unused as a pass criterion; see above
                nominalLockout:      168.42, // → 160.0 dead-hang extension
                reversalMargin:      12
            )
```

Replace `PullUpConfig.standard`'s trigger line:

```swift
    static let standard = PullUpConfig(
        barZoneMinY:          0.65,                  // upper 35% of frame
        barLockDuration:      1.0,                   // per spec
        barLockStability:     0.03,
        // Spec §4 relaxation pass: 0.40 → 0.50 of an arm span, so shorter-range
        // pull-ups count. NOT the spec's literal "15% of upper-arm length" —
        // that reads as ≈0.075 of an arm span, which is tighter than the 0.35 a
        // strong rep reaches and would count zero reps forever. See
        // `BilateralJointsTests.testTopOfARealPullUpDoesNotReachTheBarLine`.
        topTriggerArmFraction: Tolerance.atMost(0.50), // → 0.525
        barDriftArmFraction:  0.25
    )
```

Finally, `DipsAnalyzer`'s doc comment (`RepAnalyzers.swift:502`) states the OLD bounds and would now be a lie. Update it:

```swift
/// Parallel-bars dip tracker.
/// Primary joint: elbow (shoulder–elbow–wrist).
/// Top = arms extended (> 165°); bottom = elbow at or under 98°. Both were
/// relaxed from a stricter 171°/94.5° per spec §4, so a dip that stops a little
/// short of a full lockout still counts.
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: the three new threshold tests pass, both bilateral tests pass, and **`RepAnalyzerTests` / `NewExerciseTests` still pass**. If a dips or pull-up analyzer test now fails, the fixture angles were tuned to the old bounds — update the fixture, not the threshold.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/ExerciseTypes.swift Tests/ExerciseThresholdsTests.swift Tests/BilateralJointsTests.swift
git commit -m "feat: relax dips, pull-up hang, and pull-up peak thresholds per spec"
```

---

## Task 4: Crunches exercise type, config, and geometry

**Files:**
- Modify: `ExerciseTracker/ExerciseTypes.swift` (`ExerciseType` enum, `displayName`, `kind`, `repThresholds`; add `CrunchConfig`)
- Modify: `ExerciseTracker/PoseGeometry.swift` (mandatory-joint switch ~332–357; add segment-length helpers to `BodyJoints`)

**Interfaces:**
- Consumes: `ExerciseType`, `BodyJoints`, `PoseGeometry.distance`.
- Produces:
  - `ExerciseType.crunches`
  - `struct CrunchConfig` with `static let standard`, fields: `lyingHipAngle: CGFloat`, `peakHipAngle: CGFloat`, `maxHipDriftThighFraction: CGFloat`, `minConfidence: Float`
  - `BodyJoints.thighLength: CGFloat`, `BodyJoints.upperArmLength: CGFloat`, `BodyJoints.hipAngle: CGFloat`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CrunchAnalyzerTests.swift` with the geometry half first:

```swift
//
//  CrunchAnalyzerTests.swift
//  FitnessTrackerTests
//

import XCTest
@testable import FitnessTracker

final class CrunchGeometryTests: XCTestCase {

    private let acc: CGFloat = 1e-6

    /// Thigh length is hip→knee. Every crunch spatial bound is a fraction of it,
    /// which is what makes one number correct at any camera distance.
    func testThighLengthIsHipToKnee() {
        let j = CrunchFixtures.lying()
        XCTAssertEqual(j.thighLength,
                       PoseGeometry.distance(j.hip, j.knee), accuracy: acc)
    }

    /// Upper arm is shoulder→elbow, distinct from the full shoulder→wrist span.
    func testUpperArmIsShoulderToElbow() {
        let j = CrunchFixtures.lying()
        XCTAssertEqual(j.upperArmLength,
                       PoseGeometry.distance(j.shoulder, j.elbow), accuracy: acc)
    }

    /// THE DRIVING ANGLE. Shoulder–hip–knee, and it must be rotation-invariant:
    /// rotating the whole body (i.e. tilting the phone) cannot change it. This is
    /// the entire reason the FSM uses it instead of a torso-to-floor angle.
    func testHipAngleIsRotationInvariant() {
        let upright = CrunchFixtures.lying()
        let tilted = CrunchFixtures.rotated(upright, byDegrees: 45)
        XCTAssertEqual(upright.hipAngle, tilted.hipAngle, accuracy: 1e-4,
                       "a 45-degree phone tilt must not move the driving angle")
    }

    /// Sanity on the fixtures themselves: flat-lying must sit above the lying
    /// gate and the peak fixture below the contraction gate, or every FSM test
    /// below is vacuous.
    func testFixturesStraddleTheConfiguredGates() {
        let cfg = CrunchConfig.standard
        XCTAssertGreaterThan(CrunchFixtures.lying().hipAngle, cfg.lyingHipAngle)
        XCTAssertLessThanOrEqual(CrunchFixtures.peak().hipAngle, cfg.peakHipAngle)
    }

    /// The gates need real hysteresis or one jittering frame credits a rep and
    /// opens the next in the same instant.
    func testGatesKeepAHysteresisBand() {
        let cfg = CrunchConfig.standard
        XCTAssertGreaterThanOrEqual(cfg.lyingHipAngle - cfg.peakHipAngle,
                                    ExerciseThresholds.minimumHysteresisBand)
    }
}

/// Synthetic side-view crunch poses. Vision space: origin bottom-left, Y up.
/// The athlete lies with their head to the left (-x) and knees to the right.
enum CrunchFixtures {

    /// Flat on the floor, knees bent with feet planted — the standard setup.
    /// Hip angle here is ~135°.
    static func lying() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.30, y: 0.40),
            elbow:    CGPoint(x: 0.34, y: 0.34),
            wrist:    CGPoint(x: 0.40, y: 0.36),
            hip:      CGPoint(x: 0.50, y: 0.40),
            knee:     CGPoint(x: 0.64, y: 0.54),   // thigh up ~45°
            ankle:    CGPoint(x: 0.72, y: 0.40),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// Peak contraction: the shoulders have curled up and toward the knees.
    static func peak() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.36, y: 0.53),
            elbow:    CGPoint(x: 0.40, y: 0.47),
            wrist:    CGPoint(x: 0.45, y: 0.48),
            hip:      CGPoint(x: 0.50, y: 0.40),
            knee:     CGPoint(x: 0.64, y: 0.54),
            ankle:    CGPoint(x: 0.72, y: 0.40),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// A partial curl that must NOT count — it never reaches the peak gate.
    static func halfway() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.32, y: 0.46),
            elbow:    CGPoint(x: 0.36, y: 0.40),
            wrist:    CGPoint(x: 0.42, y: 0.42),
            hip:      CGPoint(x: 0.50, y: 0.40),
            knee:     CGPoint(x: 0.64, y: 0.54),
            ankle:    CGPoint(x: 0.72, y: 0.40),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// Rigidly rotates every joint about the hip — the geometric equivalent of
    /// propping the phone at an angle.
    static func rotated(_ j: BodyJoints, byDegrees d: CGFloat) -> BodyJoints {
        let r = d * .pi / 180
        let pivot = j.hip
        func rot(_ p: CGPoint) -> CGPoint {
            let dx = p.x - pivot.x, dy = p.y - pivot.y
            return CGPoint(x: pivot.x + dx * cos(r) - dy * sin(r),
                           y: pivot.y + dx * sin(r) + dy * cos(r))
        }
        return BodyJoints(shoulder: rot(j.shoulder), elbow: rot(j.elbow),
                          wrist: rot(j.wrist), hip: rot(j.hip),
                          knee: rot(j.knee), ankle: rot(j.ankle),
                          minConfidence: j.minConfidence, side: j.side)
    }

    /// Translates the whole body — used to simulate physical sliding on the mat.
    static func slid(_ j: BodyJoints, byX dx: CGFloat) -> BodyJoints {
        func mv(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y) }
        return BodyJoints(shoulder: mv(j.shoulder), elbow: mv(j.elbow),
                          wrist: mv(j.wrist), hip: mv(j.hip),
                          knee: mv(j.knee), ankle: mv(j.ankle),
                          minConfidence: j.minConfidence, side: j.side)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: compile failure, `type 'ExerciseType' has no member 'crunches'` / `value of type 'BodyJoints' has no member 'thighLength'`.

- [ ] **Step 3: Add the type, the config, and the geometry**

In `ExerciseTracker/ExerciseTypes.swift`, add the case to the enum:

```swift
public enum ExerciseType: String, CaseIterable {
    case pushUp
    case squat
    case dips
    case pullUp
    case crunches
    case plank
```

Add to `displayName`:

```swift
        case .crunches: return "Crunches"
```

Add to `kind` (crunches count reps):

```swift
        case .pushUp, .squat, .dips, .pullUp, .crunches: return .reps
        case .plank:                                     return .hold
```

Add to `repThresholds`:

```swift
        case .crunches:
            // Crunches are judged on the HIP angle against `CrunchConfig`, not on
            // this struct — exactly as squats are judged on hip-vs-knee height
            // and pull-ups on shoulder travel. The declaration exists because the
            // manager's `.reps` path expects a non-nil value; its angles are
            // deliberately unread by `CrunchAnalyzer`.
            return ExerciseThresholds(
                nominalDescentStart: 150,
                nominalDepth:        90,
                nominalLockout:      170,
                reversalMargin:      12
            )
```

Add `CrunchConfig` after `PullUpConfig`:

```swift
// MARK: - Crunch configuration

/// Geometry for the crunch, driven ENTIRELY by the rotation-invariant hip angle
/// (shoulder–hip–knee).
///
/// WHY NOT A TORSO-TO-FLOOR ANGLE
/// ------------------------------
/// The obvious way to measure a crunch is how far the torso has lifted off the
/// floor — but "the floor" in image space is only the floor when the phone is
/// upright. Propped at 45° against a water bottle, which is how this is actually
/// filmed, every floor-relative angle shifts by 45° and the FSM either fires
/// permanently or never fires at all. Gravity from CoreMotion would fix the tilt
/// but not the case where the phone is too flat for the projection to be trusted
/// (`PoseGeometry.imageDown` returns nil there, and lying-down framing is exactly
/// when that happens).
///
/// The shoulder–hip–knee angle sidesteps all of it: it is a property of the body
/// alone, so rotating the camera cannot change it. See
/// `CrunchGeometryTests.testHipAngleIsRotationInvariant`.
struct CrunchConfig {

    /// Hip angle at or above which the athlete counts as flat/lying, re-arming
    /// the machine for the next rep.
    ///
    /// A flat-lying athlete with knees bent and feet planted sits near 135°. The
    /// gate is set below that — the "soft buffer near flat extension" the spec
    /// asks for — so a rep re-arms without demanding the athlete flatten out
    /// perfectly between reps.
    let lyingHipAngle: CGFloat

    /// Hip angle at or below which the athlete counts as at peak contraction.
    ///
    /// DERIVED FROM THE SPEC'S OWN EQUIVALENCE. The spec defines the peak as the
    /// shoulders travelling forward past 40% of thigh length. The shoulders swing
    /// about the hip on a radius of the torso length, which runs ≈1.2 thigh
    /// lengths, so that arc is 0.4 / 1.2 ≈ 0.33 rad ≈ 19° of hip closure. From a
    /// 135° flat-lying start that lands at ≈116°; 112° is used to hold a real
    /// hysteresis band against `lyingHipAngle` (see `minimumHysteresisBand` — the
    /// same collapse-and-invert failure applies here).
    let peakHipAngle: CGFloat

    /// Allowed hip slide away from the frozen lying baseline, as a fraction of
    /// thigh length, before the sway cue fires. Normalized so it holds at any
    /// camera distance.
    let maxHipDriftThighFraction: CGFloat

    /// Per-joint confidence floor. Higher than the global 0.3 default because a
    /// lying athlete self-occludes badly and a low-confidence hip produces a
    /// wildly wrong driving angle.
    let minConfidence: Float

    /// NOT routed through `Tolerance`. These are already the relaxed values the
    /// spec asks for, derived from the shoulder-travel equivalence above; running
    /// them through the ±5% again would drag the two gates toward each other and
    /// collapse the hysteresis band, which is the exact failure `Tolerance`'s own
    /// documentation warns about.
    static let standard = CrunchConfig(
        lyingHipAngle:            128,
        peakHipAngle:             112,
        maxHipDriftThighFraction: 0.30,
        minConfidence:            0.4
    )
}
```

In `ExerciseTracker/PoseGeometry.swift`, add to the mandatory-joint switch inside `BodyJoints.make`:

```swift
                case .crunches:
                    // shoulder, hip, knee — the three joints of the driving
                    // angle. Elbow/wrist stay optional: hands behind the head or
                    // across the chest are both normal and both self-occlude.
                    return [recognized[0], recognized[3], recognized[4]]
```

Add the segment helpers to the `BodyJoints` extension (place them above `make`):

```swift
extension BodyJoints {

    /// Hip→knee distance: the crunch's normalizing scale. Every crunch spatial
    /// bound is a fraction of this, so the same number holds at any camera
    /// distance and on any body.
    var thighLength: CGFloat { PoseGeometry.distance(hip, knee) }

    /// Shoulder→elbow distance. Distinct from `BilateralJoints.armSpan`, which is
    /// the full shoulder→wrist reach — roughly twice this.
    var upperArmLength: CGFloat { PoseGeometry.distance(shoulder, elbow) }

    /// Shoulder–hip–knee. The crunch FSM's driving angle, and rotation-invariant
    /// by construction: it is a property of the body, not of the camera.
    var hipAngle: CGFloat { PoseGeometry.angle(shoulder, hip, knee) }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: the five `CrunchGeometryTests` pass. **`SkeletonTopologyTests` may fail** if it asserts over `ExerciseType.allCases` — if so, extend it to cover `.crunches` rather than excluding the case.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/ExerciseTypes.swift ExerciseTracker/PoseGeometry.swift Tests/CrunchAnalyzerTests.swift
git commit -m "feat: add crunches exercise type, hip-angle config, and segment geometry"
```

---

## Task 5: Crunch FSM

**Files:**
- Create: `ExerciseTracker/CrunchAnalyzer.swift`
- Modify: `Tests/CrunchAnalyzerTests.swift` (add the FSM test class)

**Interfaces:**
- Consumes: `CrunchConfig.standard`, `BodyJoints.hipAngle`/`.thighLength`, `OneEuroFilter`, `SwayMonitor`, `ExerciseAnalyzer`, `AnalyzerEvent`, `RepState`, `PoseFrame`, `CrunchFixtures`.
- Produces: `final class CrunchAnalyzer: ExerciseAnalyzer`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CrunchAnalyzerTests.swift`:

```swift
final class CrunchAnalyzerTests: XCTestCase {

    /// Feeds one pose repeatedly so the 1€ filter settles, and collects events.
    @discardableResult
    private func feed(_ a: CrunchAnalyzer,
                      _ j: BodyJoints,
                      frames: Int = 12,
                      from t: inout TimeInterval) -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        for _ in 0..<frames {
            events += a.analyze(frame: PoseFrame(unilateral: j, time: t))
            t += 1.0 / 30
        }
        return events
    }

    private func repCount(_ events: [AnalyzerEvent]) -> Int {
        events.reduce(0) { n, e in
            if case .repCompleted = e { return n + 1 }
            return n
        }
    }

    private func sawSwayCue(_ events: [AnalyzerEvent]) -> Bool {
        events.contains { e in
            if case .invalidRep(_, let severity) = e { return severity == .warning }
            return false
        }
    }

    /// THE HAPPY PATH: lying → peak → lying credits exactly one rep.
    func testFullCycleCountsOneRep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.peak(), from: &t)
        let closing = feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(repCount(closing), 1)
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// Returning to lying without ever reaching the peak is a half-rep. It must
    /// not count, and it must say why.
    func testPartialCurlDoesNotCount() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.halfway(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0)
    }

    /// ARMING. Walking into frame already curled up must not pay out a rep on the
    /// way down — a repetition starts at the start position, by definition.
    func testStartingAtThePeakDoesNotCreditARep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.peak(), from: &t)      // never seen lying
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0)
    }

    /// Three clean cycles, three reps. Catches a machine that credits on every
    /// frame at the top or fails to re-arm.
    func testThreeCyclesCountThreeReps() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        for _ in 0..<3 {
            feed(a, CrunchFixtures.peak(), from: &t)
            feed(a, CrunchFixtures.lying(), from: &t)
        }
        XCTAssertEqual(a.successfulReps, 3)
    }

    /// THE PHONE-TILT GUARANTEE, end to end. The same repetition filmed with the
    /// phone propped at 45° must produce the same count. A floor-relative driving
    /// angle fails this test; that is why it exists.
    func testRepCountIsUnchangedByPhoneTilt() {
        func count(tilt: CGFloat) -> Int {
            let a = CrunchAnalyzer()
            var t: TimeInterval = 0
            feed(a, CrunchFixtures.rotated(CrunchFixtures.lying(), byDegrees: tilt), from: &t)
            feed(a, CrunchFixtures.rotated(CrunchFixtures.peak(), byDegrees: tilt), from: &t)
            feed(a, CrunchFixtures.rotated(CrunchFixtures.lying(), byDegrees: tilt), from: &t)
            return a.successfulReps
        }
        XCTAssertEqual(count(tilt: 0), 1)
        XCTAssertEqual(count(tilt: 45), 1, "a 45-degree phone tilt must not change the count")
        XCTAssertEqual(count(tilt: -30), 1)
    }

    /// Sliding on the mat during the ascent fires the sway cue...
    func testHipSlideDuringAscentFiresTheSwayCue() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        // Curl up while the whole body slides well past 30% of a thigh.
        let slidPeak = CrunchFixtures.slid(CrunchFixtures.peak(), byX: 0.12)
        let events = feed(a, slidPeak, from: &t)
        XCTAssertTrue(sawSwayCue(events), "structural drift must be reported")
    }

    /// ...but MUST NOT cost the athlete the rep. This is the spec's non-blocking
    /// requirement, and it is the one most likely to regress silently.
    func testSwayCueDoesNotCancelTheRep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.slid(CrunchFixtures.peak(), byX: 0.12), from: &t)
        feed(a, CrunchFixtures.slid(CrunchFixtures.lying(), byX: 0.12), from: &t)
        XCTAssertEqual(a.successfulReps, 1, "sway warns; it never voids a rep")
    }

    /// Reset must zero everything, including the filter and the anchor.
    func testResetClearsCountAndState() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.peak(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 1)
        a.reset()
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertEqual(a.state, .ready)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: compile failure, `cannot find 'CrunchAnalyzer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ExerciseTracker/CrunchAnalyzer.swift`:

```swift
//
//  CrunchAnalyzer.swift
//  ExerciseTracker
//
//  The crunch state machine. Side-view framing.
//
//  DRIVEN BY THE HIP ANGLE, ON PURPOSE
//  -----------------------------------
//  Shoulder–hip–knee is rotation-invariant, so it survives the phone being
//  propped at whatever angle the athlete found convenient. See the long note on
//  `CrunchConfig` for why every floor-relative alternative was rejected.
//
//  FILTERING
//  ---------
//  The three driving joints go through `OneEuroFilter` and the FSM gates read
//  that output DIRECTLY. No second EMA pass sits on the rep path — that would add
//  ~100ms and detect the peak of a fast crunch after the athlete had already
//  started back down. The alpha-0.3 EMA appears only inside `SwayMonitor`, whose
//  baseline is frozen at the start of the ascent and never touches the counter.
//
//  ALLOCATION: the filters and the monitor are structs stored inline. The only
//  per-frame allocation is the `[AnalyzerEvent]` return, which is the existing
//  protocol contract shared by every analyzer.
//

import Foundation
import CoreGraphics

final class CrunchAnalyzer: ExerciseAnalyzer {

    private let cfg = CrunchConfig.standard

    private var currentState: RepState = .ready
    private var reps = 0

    /// True once a valid LYING position has been observed. A machine that has
    /// never seen the athlete flat has no business crediting a rep — otherwise
    /// walking into frame already curled up pays out on the way down.
    private var isArmed = false

    /// True between leaving the lying gate and returning to it.
    private var attemptInProgress = false

    /// True once the peak gate has been satisfied during the current attempt.
    private var reachedPeak = false

    /// Smallest hip angle seen this attempt, and the value from the last credited
    /// rep — this is what the security ledger signs.
    private var minHipThisRep: CGFloat = .greatestFiniteMagnitude
    private var lastPeak: CGFloat?

    // Per-joint coordinate filters. Tuned for normalized coordinates at 30fps:
    // beta is well above the 1€ default because a crunch's shoulder travel is
    // fast relative to its amplitude, and lag there is what loses the peak.
    private var shoulderFilter = OneEuroPointFilter(minCutoff: 1.2, beta: 0.35)
    private var hipFilter      = OneEuroPointFilter(minCutoff: 1.2, beta: 0.35)
    private var kneeFilter     = OneEuroPointFilter(minCutoff: 1.2, beta: 0.35)

    /// Measures physical hip sliding against a baseline frozen the moment the
    /// ascent begins. Non-blocking by construction — see `SwayMonitor`.
    private var sway = SwayMonitor(maxDriftFraction: CrunchConfig.standard.maxHipDriftThighFraction)

    var state: RepState { currentState }
    var successfulReps: Int { reps }
    var lastRepPeakDepthAngle: Double? { lastPeak.map(Double.init) }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let raw = frame.unilateral else { return [] }
        guard raw.minConfidence >= cfg.minConfidence else { return [] }

        var events: [AnalyzerEvent] = []

        // ---- Filtered coordinates, straight into the gates ----
        let shoulder = shoulderFilter.apply(raw.shoulder, at: frame.time)
        let hip      = hipFilter.apply(raw.hip, at: frame.time)
        let knee     = kneeFilter.apply(raw.knee, at: frame.time)

        let hipAngle = PoseGeometry.angle(shoulder, hip, knee)
        let thigh = PoseGeometry.distance(hip, knee)
        guard thigh > 0 else { return events }

        let isLying = hipAngle >= cfg.lyingHipAngle
        let isAtPeak = hipAngle <= cfg.peakHipAngle

        // ---- Progress ring: 0 flat, 1 at peak contraction ----
        let span = cfg.lyingHipAngle - cfg.peakHipAngle
        if span > 0 {
            let progress = (cfg.lyingHipAngle - hipAngle) / span
            events.append(.depthProgress(Double(max(0, min(1, progress)))))
        }

        // ---- Anti-sway ----
        // While lying, the monitor is accumulating its EMA baseline. Once the
        // ascent starts it is frozen, and everything after is measured against
        // where the hip actually was. The cue is advisory: note that nothing in
        // this block touches `reps`, `reachedPeak`, or `currentState`.
        if sway.observe(hip, scale: thigh) {
            events.append(.invalidRep(feedback: VoiceCue.swing.defaultPhrase,
                                      severity: .warning))
        }

        // ---- Lying: arm the machine and close any attempt in flight ----
        if isLying {
            if attemptInProgress {
                if reachedPeak {
                    reps += 1
                    lastPeak = minHipThisRep
                    events.append(.repCompleted(totalCount: reps))
                } else {
                    events.append(.invalidRep(feedback: "Curl up higher!",
                                              severity: .warning))
                }
                attemptInProgress = false
                reachedPeak = false
                minHipThisRep = .greatestFiniteMagnitude
            }
            isArmed = true
            sway.endActivePhase()          // re-baseline for the next rep
            transition(to: .ready, sink: &events)
            return events
        }

        // ---- Ascent begins ----
        if !attemptInProgress {
            guard isArmed else { return events }   // never seen flat: no rep to open
            attemptInProgress = true
            reachedPeak = false
            minHipThisRep = .greatestFiniteMagnitude
            sway.beginActivePhase()        // FREEZE the baseline here
            transition(to: .ascending, sink: &events)
        }

        minHipThisRep = min(minHipThisRep, hipAngle)

        if isAtPeak {
            reachedPeak = true
            transition(to: .atBottom, sink: &events)   // apex of the contraction
        }

        return events
    }

    /// A tracking gap cannot be judged: the apex is exactly what would have been
    /// missed, so an attempt in flight is voided rather than credited on the next
    /// flat frame. The machine also disarms — the athlete must be seen lying
    /// again before reps resume.
    func trackingLost() -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        attemptInProgress = false
        reachedPeak = false
        minHipThisRep = .greatestFiniteMagnitude
        isArmed = false
        shoulderFilter.reset()
        hipFilter.reset()
        kneeFilter.reset()
        sway.reset()
        transition(to: .ready, sink: &events)
        return events
    }

    private func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != currentState else { return }
        currentState = newState
        sink.append(.stateChanged(newState))
    }

    func reset() {
        currentState = .ready
        reps = 0
        isArmed = false
        attemptInProgress = false
        reachedPeak = false
        minHipThisRep = .greatestFiniteMagnitude
        lastPeak = nil
        shoulderFilter.reset()
        hipFilter.reset()
        kneeFilter.reset()
        sway.reset()
    }
}
```

> **Note:** this references `VoiceCue.swing.defaultPhrase`, which Task 7 creates. Implement Task 7 before running these tests, or temporarily inline the string `"Steady"` and restore the reference in Task 7. Prefer doing Task 7 first if executing out of order.

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: all 8 `CrunchAnalyzerTests` pass. If `testFullCycleCountsOneRep` fails with 0 reps, the 1€ filter has not settled — raise the `frames:` count in `feed`, do not loosen the gates.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/CrunchAnalyzer.swift Tests/CrunchAnalyzerTests.swift
git commit -m "feat: add tilt-invariant crunch FSM driven by the hip angle"
```

---

## Task 6: Anti-sway for pull-ups and dips

**Files:**
- Modify: `ExerciseTracker/RepAnalyzers.swift` (`PullUpAnalyzer` ~624–851, `DipsAnalyzer`)
- Modify: `Tests/AntiCheatTests.swift`

**Interfaces:**
- Consumes: `SwayMonitor`, `VoiceCue.swing`, `BilateralJoints`, `BodyJoints`.
- Produces: no new public symbols; `PullUpAnalyzer` and `DipsAnalyzer` gain a private `sway` property.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AntiCheatTests.swift`:

```swift
    /// A pendulum swing on the bar must be reported...
    func testPullUpSwingFiresTheSwayCue() {
        let a = PullUpAnalyzer()
        var t: TimeInterval = 0
        // Lock the bar from a still dead hang.
        for _ in 0..<45 {
            _ = a.analyze(frame: PoseFrame(bilateral: PullUpFixtures.deadHang(), time: t))
            t += 1.0 / 30
        }
        XCTAssertTrue(a.isBarLocked, "precondition: the bar must lock")

        // Pull up while swinging forward well past the bound.
        var events: [AnalyzerEvent] = []
        for _ in 0..<20 {
            events += a.analyze(frame: PoseFrame(bilateral: PullUpFixtures.swungTop(), time: t))
            t += 1.0 / 30
        }
        let warned = events.contains { e in
            if case .invalidRep(_, let s) = e { return s == .warning }
            return false
        }
        XCTAssertTrue(warned, "pendulum sway must be reported")
    }

    /// ...without costing the rep. Spec §3: the callback is non-blocking.
    func testPullUpSwingDoesNotCancelTheRep() {
        let a = PullUpAnalyzer()
        var t: TimeInterval = 0
        for _ in 0..<45 {
            _ = a.analyze(frame: PoseFrame(bilateral: PullUpFixtures.deadHang(), time: t))
            t += 1.0 / 30
        }
        for _ in 0..<20 {
            _ = a.analyze(frame: PoseFrame(bilateral: PullUpFixtures.swungTop(), time: t))
            t += 1.0 / 30
        }
        for _ in 0..<20 {
            _ = a.analyze(frame: PoseFrame(bilateral: PullUpFixtures.deadHang(), time: t))
            t += 1.0 / 30
        }
        XCTAssertEqual(a.successfulReps, 1, "sway warns; it never voids a rep")
    }
```

Add these fixtures to `Tests/PoseFixtures.swift` (if a `PullUpFixtures` enum already exists there, add the two cases to it rather than declaring a second one):

```swift
/// Synthetic front-view pull-up poses. Vision space: origin bottom-left, Y up.
/// Arm span at the dead hang is 0.40, so every fraction-of-arm bound in
/// `PullUpConfig` can be reasoned about directly.
enum PullUpFixtures {

    /// Dead hang: wrists high in the bar zone, shoulders a full arm below,
    /// elbows straight (180°) so the machine arms.
    static func deadHang() -> BilateralJoints {
        BilateralJoints(
            leftShoulder:  CGPoint(x: 0.40, y: 0.50),
            rightShoulder: CGPoint(x: 0.60, y: 0.50),
            leftElbow:     CGPoint(x: 0.40, y: 0.70),
            rightElbow:    CGPoint(x: 0.60, y: 0.70),
            leftWrist:     CGPoint(x: 0.40, y: 0.90),
            rightWrist:    CGPoint(x: 0.60, y: 0.90),
            minConfidence: 0.9
        )
    }

    /// Top of a clean rep: shoulders pulled to 0.35 of an arm below the bar,
    /// which clears the relaxed 0.525 trigger. Elbows bent to ~90°.
    static func top() -> BilateralJoints {
        BilateralJoints(
            leftShoulder:  CGPoint(x: 0.40, y: 0.76),
            rightShoulder: CGPoint(x: 0.60, y: 0.76),
            leftElbow:     CGPoint(x: 0.30, y: 0.80),
            rightElbow:    CGPoint(x: 0.70, y: 0.80),
            leftWrist:     CGPoint(x: 0.40, y: 0.90),
            rightWrist:    CGPoint(x: 0.60, y: 0.90),
            minConfidence: 0.9
        )
    }

    /// The same top position, but the whole body has swung 0.12 forward — well
    /// past 0.15 of the 0.40 arm span (0.06). The WRISTS stay put, because hands
    /// on a real bar do not move; only the body below them swings. Keeping the
    /// wrists fixed also keeps the bar lock alive, which is what makes this a
    /// sway test rather than a lock-drop test.
    static func swungTop() -> BilateralJoints {
        BilateralJoints(
            leftShoulder:  CGPoint(x: 0.52, y: 0.76),
            rightShoulder: CGPoint(x: 0.72, y: 0.76),
            leftElbow:     CGPoint(x: 0.42, y: 0.80),
            rightElbow:    CGPoint(x: 0.82, y: 0.80),
            leftWrist:     CGPoint(x: 0.40, y: 0.90),
            rightWrist:    CGPoint(x: 0.60, y: 0.90),
            minConfidence: 0.9
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: `testPullUpSwingFiresTheSwayCue` fails — no warning event is emitted.

- [ ] **Step 3: Wire the monitor into both analyzers**

In `PullUpAnalyzer`, add the stored property beside the other rep-attempt state:

```swift
    /// Horizontal pendulum sway, measured against a baseline frozen at the dead
    /// hang. Advisory only — see `SwayMonitor`, which has no access to the
    /// counter and therefore cannot void a rep.
    private var sway = SwayMonitor(maxDriftFraction: 0.15)
```

In `analyze(frame:)`, immediately after the `gapInArms` / `isExtended` computation, add:

```swift
        // ---- Anti-sway ----
        // The baseline accumulates at the dead hang and freezes when the pull
        // begins, so what is measured is how far the body has swung from where it
        // started — not from where it currently is.
        let torsoMidX = CGPoint(x: (j.leftShoulder.x + j.rightShoulder.x) / 2,
                                y: (j.leftShoulder.y + j.rightShoulder.y) / 2)
        if sway.observe(torsoMidX, scale: armSpan) {
            events.append(.invalidRep(feedback: VoiceCue.swing.defaultPhrase,
                                      severity: .warning))
        }
```

In the "Arm at the dead hang" branch, add `sway.endActivePhase()`:

```swift
        if !attemptInProgress, isExtended {
            isArmed = true
            calibratedArmSpan = j.armSpan
            sway.endActivePhase()          // re-baseline at the hang
            transition(to: .barLocked, sink: &events)
        }
```

In the "Start of a rep" branch, add `sway.beginActivePhase()`:

```swift
            if isArmed, elbow < cfg.descentStartAngle {
                attemptInProgress = true
                reachedTop = false
                minElbowThisRep = .greatestFiniteMagnitude
                sway.beginActivePhase()    // FREEZE the baseline here
                transition(to: .ascending, sink: &events)
            }
```

Add `sway.reset()` to both `dropLock`, `trackingLost()`, and `reset()`.

In `DipsAnalyzer`, add the stored property beside `orientationWarned` (`RepAnalyzers.swift:513`):

```swift
    /// Horizontal shoulder drift, measured against a baseline frozen when the
    /// descent begins. On the bars this catches the body swinging fore-and-aft
    /// instead of travelling straight down. Advisory only.
    private var sway = SwayMonitor(maxDriftFraction: 0.15)
```

In `analyze(frame:)`, insert this immediately after the orientation-recovery block (after the closing brace of `if orientationWarned { ... }`, `RepAnalyzers.swift:552`) and before the `// ---- Arm at the top` comment:

```swift
        // ---- Anti-sway ----
        // Baseline accumulates while the athlete is supported at the top and
        // freezes when the descent opens, so this measures travel away from where
        // the rep actually started. Normalized against the upper arm so it holds
        // at any camera distance. Nothing here touches the counter.
        if sway.observe(joints.shoulder, scale: joints.upperArmLength) {
            events.append(.invalidRep(feedback: VoiceCue.swing.defaultPhrase,
                                      severity: .warning))
        }
```

In the "Start of a new attempt" block, freeze the baseline as the descent opens:

```swift
            if t.isArmed, elbow < cfg.descentStartAngle {
                t.beginAttempt()
                sway.beginActivePhase()    // FREEZE the baseline here
                t.transition(to: .descending, sink: &events)
            } else {
```

In the rep-completion block, release it so the next rep re-baselines:

```swift
        if elbow >= cfg.lockoutAngle {
            if t.reachedDepth, !t.errorEmitted {
                t.creditRep(sink: &events)
            }
            t.endAttempt()
            sway.endActivePhase()          // re-baseline at the top
            t.transition(to: .ready, sink: &events)
        }
```

And clear it in `reset()`:

```swift
    func reset() {
        t.reset()
        orientationWarned = false
        sway.reset()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: both new anti-cheat tests pass and every existing `RepAnalyzerTests` / `NewExerciseTests` / `AntiCheatTests` case still passes. **If an existing pull-up rep test now fails, the sway bound is too tight for the fixtures — widen `maxDriftFraction`, never suppress the rep.**

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/RepAnalyzers.swift Tests/AntiCheatTests.swift Tests/PoseFixtures.swift
git commit -m "feat: report non-blocking pendulum sway on pull-ups and dips"
```

---

## Task 7: Voice coach

**Files:**
- Create: `ExerciseTracker/VoiceCoach.swift`
- Test: `Tests/VoiceCoachTests.swift`

**Interfaces:**
- Consumes: `AVFoundation`.
- Produces:
  - `public enum VoiceCue: String` — cases `.swing`, `.higher`, `.lower`, `.posture`, `.goodRep`; `var defaultPhrase: String`, `var tersePhrase: String`, `var systemSoundID: UInt32`
  - `public final class VoiceCoach` — `enum Mode { case speech, tone, silent }`, `enum Fidelity { case neural, legacy }`, `init(mode: Mode = .speech)`, `var mode: Mode`, `private(set) var fidelity: Fidelity`, `private(set) var isTerse: Bool`, `func say(_ cue: VoiceCue)`, `func say(_ phrase: String)`
  - `static func selectVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice?` — testable pure selection
  - `static func fidelity(of voice: AVSpeechSynthesisVoice?) -> Fidelity`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VoiceCoachTests.swift`:

```swift
//
//  VoiceCoachTests.swift
//  FitnessTrackerTests
//

import XCTest
import AVFoundation
@testable import FitnessTracker

final class VoiceCoachTests: XCTestCase {

    /// Every cue must carry BOTH a full sentence and a single-word fallback, or
    /// the terse strategy has nothing to fall back to.
    func testEveryCueHasBothPhrasings() {
        for cue in VoiceCue.allCases {
            XCTAssertFalse(cue.defaultPhrase.isEmpty, "\(cue) has no phrase")
            XCTAssertFalse(cue.tersePhrase.isEmpty, "\(cue) has no terse phrase")
        }
    }

    /// The terse form is a single soft word — that is the whole point. A terse
    /// phrase with a space in it is a sentence wearing a disguise.
    func testTersePhrasesAreSingleWords() {
        for cue in VoiceCue.allCases {
            XCTAssertFalse(cue.tersePhrase.contains(" "),
                           "\(cue) terse phrase must be one word, got '\(cue.tersePhrase)'")
        }
    }

    /// Selection must prefer higher-quality voices. Given a premium and a default
    /// voice, it takes the premium one.
    func testSelectionPrefersHigherQuality() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        try XCTSkipIf(voices.isEmpty, "no English voices on this runner")

        let picked = try XCTUnwrap(VoiceCoach.selectVoice(from: voices))
        let bestQuality = voices.map(\.quality.rawValue).max()
        XCTAssertEqual(picked.quality.rawValue, bestQuality,
                       "must pick the highest quality available")
    }

    /// A legacy/default-quality voice must flip the terse flag. This is the whole
    /// fallback strategy: a harsh OEM voice reading full sentences is worse than
    /// one soft word.
    func testLegacyVoiceEnablesTerseSpeech() {
        XCTAssertEqual(VoiceCoach.fidelity(of: nil), .legacy,
                       "no voice at all is the worst case, not the best")
    }

    /// Tone mode must never speak. The spec's TONE flag is an escape hatch for
    /// users who find any voice irritating, so leaking one utterance defeats it.
    func testToneModeNeverSpeaks() {
        let coach = VoiceCoach(mode: .tone)
        coach.say(.swing)
        XCTAssertFalse(coach.isSpeaking, "tone mode must not produce speech")
    }

    /// Silent mode is fully inert.
    func testSilentModeIsInert() {
        let coach = VoiceCoach(mode: .silent)
        coach.say(.swing)
        XCTAssertFalse(coach.isSpeaking)
    }

    /// The spec pins the prosody. These are the numbers that make the voice read
    /// as encouraging rather than robotic, so they are worth locking down.
    func testUtteranceProsodyMatchesSpec() {
        let u = VoiceCoach.makeUtterance(phrase: "Steady", voice: nil)
        XCTAssertEqual(u.pitchMultiplier, 1.05, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(u.rate, 0.45)
        XCTAssertLessThanOrEqual(u.rate, 0.50)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Push and read CI. Expected: compile failure, `cannot find 'VoiceCue' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ExerciseTracker/VoiceCoach.swift`:

```swift
//
//  VoiceCoach.swift
//  ExerciseTracker
//
//  Spoken and tonal coaching feedback.
//
//  THE TERSE FALLBACK, AND WHY IT EXISTS
//  -------------------------------------
//  iOS does not guarantee a good voice. On a device where the enhanced/premium
//  English voices were never downloaded, `AVSpeechSynthesisVoice` falls back to a
//  compact legacy voice that is genuinely unpleasant to listen to — and a bad
//  voice reading "Keep your body steady and controlled" mid-set is worse feedback
//  than no feedback, because the athlete turns the audio off and then gets none
//  of it. So the engine measures what it actually got and, on a legacy voice,
//  shortens every cue to one soft word. `TONE` mode drops speech entirely in
//  favour of a chime for users who want neither.
//

import Foundation
import AVFoundation
#if os(iOS)
import AudioToolbox
#endif

// MARK: - Cues

/// A single coaching moment. Each carries a full sentence, a one-word fallback,
/// and a chime, so the delivery strategy can be chosen at speak time rather than
/// duplicated at every call site.
///
/// NAMING: the spec writes these as `VoiceCue.SWING`. Swift enum cases are
/// lowerCamelCase, and the spec also asks for idiomatic Swift; the idiom wins.
public enum VoiceCue: String, CaseIterable {
    /// Structural drift / pendulum sway. Advisory — never voids a rep.
    case swing
    /// Insufficient range of motion at the top.
    case higher
    /// Insufficient depth at the bottom.
    case lower
    /// Posture / alignment failure.
    case posture
    /// A rep was credited.
    case goodRep

    /// Full natural sentence, used with a high-fidelity voice.
    public var defaultPhrase: String {
        switch self {
        case .swing:   return "Keep your body steady."
        case .higher:  return "Try to come up a little higher."
        case .lower:   return "Go a little deeper on the next one."
        case .posture: return "Straighten up and keep your body aligned."
        case .goodRep: return "Nice rep."
        }
    }

    /// Single soft word, used when the system fell back to a harsh legacy voice.
    public var tersePhrase: String {
        switch self {
        case .swing:   return "Steady"
        case .higher:  return "Higher"
        case .lower:   return "Deeper"
        case .posture: return "Align"
        case .goodRep: return "Good"
        }
    }

    /// System sound used in `.tone` mode. These are short, soft, built-in chimes
    /// — no bundled audio assets, so nothing to ship or fail to load.
    public var systemSoundID: UInt32 {
        switch self {
        case .swing:   return 1103   // gentle tick
        case .higher:  return 1113
        case .lower:   return 1114
        case .posture: return 1073
        case .goodRep: return 1057
        }
    }
}

// MARK: - Coach

public final class VoiceCoach {

    /// How feedback is delivered.
    public enum Mode {
        /// Spoken cues, full or terse depending on the voice we got.
        case speech
        /// The spec's `TONE` flag: chimes only, no speech at all.
        case tone
        /// Nothing.
        case silent
    }

    /// How good the voice we actually got is.
    public enum Fidelity {
        /// Enhanced or premium — natural enough for full sentences.
        case neural
        /// Compact/default OEM voice, or none at all. Triggers terse speech.
        case legacy
    }

    public var mode: Mode

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    public private(set) var fidelity: Fidelity

    /// True when cues must be shortened to a single word.
    public var isTerse: Bool { fidelity == .legacy }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Debounce: the same cue cannot repeat inside this window. A form fault
    /// persists for many frames and would otherwise be spoken on every one.
    private var lastSpokenAt: [String: Date] = [:]
    private let cooldown: TimeInterval = 2.5

    public init(mode: Mode = .speech) {
        self.mode = mode
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        self.voice = Self.selectVoice(from: candidates)
        self.fidelity = Self.fidelity(of: self.voice)
    }

    // MARK: Voice selection

    /// Picks the best available voice: highest quality first, then a female
    /// profile where the platform reports gender, then a stable name order so the
    /// choice does not wander between launches.
    ///
    /// Pure and `static` so it can be tested against a supplied list rather than
    /// whatever voices happen to be installed on the CI runner.
    public static func selectVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        guard !voices.isEmpty else { return nil }
        return voices.max { a, b in
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue < b.quality.rawValue
            }
            let aFemale = Self.isFemale(a), bFemale = Self.isFemale(b)
            if aFemale != bFemale { return bFemale }
            return a.name > b.name          // stable tiebreak
        }
    }

    private static func isFemale(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 13.0, *) { return v.gender == .female }
        return false
    }

    /// Enhanced and premium voices are the neural ones; anything else (including
    /// the absence of a voice) is treated as legacy and triggers terse speech.
    public static func fidelity(of voice: AVSpeechSynthesisVoice?) -> Fidelity {
        guard let voice = voice else { return .legacy }
        if #available(iOS 16.0, *), voice.quality == .premium { return .neural }
        return voice.quality == .enhanced ? .neural : .legacy
    }

    // MARK: Speaking

    /// Prepares the audio session once, lazily. `.duckOthers` is the right shape:
    /// a cue is a second long and should dip the athlete's music, not end it.
    private static let prepareAudioSession: Void = {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])
        #endif
    }()

    /// Builds the utterance with the spec's prosody. `static` and pure so the
    /// numbers can be asserted without a synthesizer.
    public static func makeUtterance(phrase: String,
                                     voice: AVSpeechSynthesisVoice?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: phrase)
        u.voice = voice
        // Spec: warmer, encouraging, less robotic.
        u.pitchMultiplier = 1.05
        u.rate = 0.47                       // inside the specified 0.45...0.50
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        return u
    }

    /// Delivers a cue through whichever channel the current mode selects.
    public func say(_ cue: VoiceCue) {
        switch mode {
        case .silent:
            return
        case .tone:
            playTone(cue)
        case .speech:
            say(isTerse ? cue.tersePhrase : cue.defaultPhrase)
        }
    }

    /// Speaks a raw phrase. Debounced per-phrase.
    public func say(_ phrase: String) {
        guard mode == .speech else { return }
        let now = Date()
        if let last = lastSpokenAt[phrase], now.timeIntervalSince(last) < cooldown {
            return
        }
        lastSpokenAt[phrase] = now

        _ = Self.prepareAudioSession
        synthesizer.speak(Self.makeUtterance(phrase: phrase, voice: voice))
    }

    private func playTone(_ cue: VoiceCue) {
        #if os(iOS)
        let now = Date()
        let key = "tone-\(cue.rawValue)"
        if let last = lastSpokenAt[key], now.timeIntervalSince(last) < cooldown { return }
        lastSpokenAt[key] = now
        _ = Self.prepareAudioSession
        AudioServicesPlaySystemSound(SystemSoundID(cue.systemSoundID))
        #endif
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Push and read CI. Expected: all 7 `VoiceCoachTests` pass (`testSelectionPrefersHigherQuality` may skip if the runner has no English voices — a skip is an acceptable result, a failure is not).

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/VoiceCoach.swift Tests/VoiceCoachTests.swift
git commit -m "feat: add neural voice coach with terse fallback and tone mode"
```

---

## Task 8: Manager and UI wiring

**Files:**
- Modify: `ExerciseTracker/ExerciseTrackerManager.swift` (`makeAnalyzer` ~276–284, `speech`/`speak` ~201, ~619–634)
- Modify: `ExerciseTracker/UI/WorkoutViewModel.swift:361` and the exercise-picker copy
- Modify: `project.yml` (camera usage description)

**Interfaces:**
- Consumes: `CrunchAnalyzer`, `VoiceCoach`, `VoiceCue`.
- Produces: `ExerciseTrackerManager.voiceCoach: VoiceCoach` (replaces the private `speech`/`lastSpokenAt`/`speechCooldown` trio).

- [ ] **Step 1: Register the crunch analyzer**

In `ExerciseTrackerManager.makeAnalyzer`:

```swift
    private static func makeAnalyzer(for exercise: ExerciseType) -> ExerciseAnalyzer {
        switch exercise {
        case .pushUp:   return PushUpAnalyzer()
        case .squat:    return SquatAnalyzer()
        case .dips:     return DipsAnalyzer()
        case .pullUp:   return PullUpAnalyzer()
        case .crunches: return CrunchAnalyzer()
        case .plank:    return PlankAnalyzer()
        }
    }
```

- [ ] **Step 2: Route speech through the coach**

Replace the three stored properties:

```swift
    /// Spoken/tonal coaching. Owns voice selection, the terse fallback, the
    /// TONE-mode chimes, and per-phrase debouncing — all of which used to be
    /// three ad-hoc properties here.
    public let voiceCoach = VoiceCoach()
```

Delete `private let speech`, `private var lastSpokenAt`, `private let speechCooldown`, and the whole `private static let prepareAudioSession` block (it moved into `VoiceCoach`). Replace `speak(_:)` with:

```swift
    /// Speaks a phrase through the coach, unless voice feedback is switched off.
    private func speak(_ phrase: String) {
        guard isVoiceFeedbackEnabled else { return }
        voiceCoach.say(phrase)
    }
```

Remove the now-unused `import AVFoundation` only if nothing else in the file needs it — `AVCaptureVideoOrientation` and friends likely still do, so verify before deleting.

- [ ] **Step 3: Fix the pull-up cue copy**

In `ExerciseTracker/UI/WorkoutViewModel.swift:361`, the string `"Chin over the bar!"` names a landmark the tracker deliberately never reads (`BilateralJoints` has no facial joints, and pull-ups are judged on shoulder travel). Replace:

```swift
        case .atBottom:           return exercise == .pullUp ? "Pull those shoulders up!" : "Looking good!"
```

Add crunches to whatever `switch exercise` drives setup guidance, with front/side framing per spec §1:

```swift
        case .crunches: return "Lie down side-on to the camera"
        case .pullUp:   return "Face the camera, then grab the bar"
        case .dips:     return "Stand side-on to the camera"
```

- [ ] **Step 4: Run the full suite**

Push and read CI. Expected: the entire suite green, including every pre-existing test. A `switch must be exhaustive` error anywhere means a `.crunches` case is still missing — add it; **never add `default:` to these switches**, the exhaustiveness is what caught this.

- [ ] **Step 5: Commit**

```bash
git add ExerciseTracker/ExerciseTrackerManager.swift ExerciseTracker/UI/WorkoutViewModel.swift project.yml
git commit -m "feat: wire crunches and the voice coach into the manager and UI"
```

---

## Final verification

- [ ] **Full suite green on CI.** Read the actual run; do not infer.
- [ ] **Plank untouched:** `git diff main --stat` shows no change to `PlankAnalyzer`, `PlankConfig`, or `HoldFormatTests.swift`.
- [ ] **No EMA on a rep path:** `grep -rn "0.3" ExerciseTracker/` — every alpha-0.3 hit must be inside `DriftAnchor.swift`.
- [ ] **Non-blocking sway:** `SwayMonitor` appears in no expression that assigns to `reps`, `reachedPeak`, `reachedTop`, or transitions to `.invalidPosition`.
- [ ] **Report honestly** on the allocation deliverable — see "Known scope limit" above.
