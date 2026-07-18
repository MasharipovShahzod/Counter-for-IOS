//
//  ExerciseTypes.swift
//  ExerciseTracker
//
//  Core value types shared across the tracker: the exercise catalogue,
//  the rep state machine states, the device-compatibility result, and
//  the tuning thresholds for each movement.
//

import Foundation

// MARK: - Tolerance

/// The global ±5% error margin applied to every rep-validity angle, to absorb
/// camera noise, micro-jitter and imperfect range of motion.
///
/// WHERE THIS APPLIES — AND WHERE IT DELIBERATELY DOESN'T
/// ------------------------------------------------------
/// Tolerance is applied to *pass criteria* — the angles that decide whether a
/// rep counts (`depthAngle`, `lockoutAngle`) and the anti-cheat bounds. It is
/// NOT applied to `descentStartAngle`, which is not a criterion the athlete is
/// judged against but an internal hysteresis gate. Loosening a "must be at
/// least" angle pushes it DOWN while loosening a "must be at most" angle pushes
/// it UP, so applying both to the two ends of a hysteresis band drives them
/// toward each other — and for the tuned push-up values it inverts the band
/// outright (lockout 165→156.75 would sit BELOW descentStart 150→157.5),
/// making the machine credit and restart a rep in the same frame.
/// `ExerciseThresholds` therefore derives `descentStartAngle` from the
/// tolerated lockout instead, preserving a guaranteed band. See
/// `ExerciseThresholdsTests.testHysteresisBandSurvivesTolerance`.
///
/// NOTE ON THE MATHS: a percentage of an angle is dimensionally arbitrary
/// (angles are not ratios, and 5% of 180° is a 9° window while 5% of 90° is
/// only 4.5°), but it is what the spec asks for and it reproduces the spec's
/// own numbers exactly: 180°→171° and 90°→94.5°.
enum Tolerance {

    /// The ±5% coefficient. Single source of truth for the whole tracker.
    static let fraction: CGFloat = 0.05

    /// Loosens an "athlete must reach AT LEAST this angle" threshold by moving
    /// it down 5%. Per spec: 180° → 171°.
    static func atLeast(_ angle: CGFloat) -> CGFloat { angle * (1 - fraction) }

    /// Loosens an "athlete must reach AT MOST this angle" threshold by moving it
    /// up 5%. Per spec: 90° → 94.5°.
    static func atMost(_ angle: CGFloat) -> CGFloat { angle * (1 + fraction) }
}

// MARK: - Exercise

/// Whether an exercise is scored by counting repetitions or by timing a hold.
public enum ExerciseKind: Equatable {
    /// Counts completed repetitions (push-ups, squats, dips, pull-ups).
    case reps
    /// Times a maintained posture (plank). Never increments a rep count.
    case hold
}

/// The movements the tracker understands.
public enum ExerciseType: String, CaseIterable {
    case pushUp
    case squat
    case dips
    case pullUp
    case plank

    /// Kept short deliberately — `ExercisePickerView` lays these out as equal
    /// segments in a fixed-width capsule, and long labels truncate.
    public var displayName: String {
        switch self {
        case .pushUp: return "Push-ups"
        case .squat:  return "Squats"
        case .dips:   return "Dips"
        case .pullUp: return "Pull-ups"
        case .plank:  return "Plank"
        }
    }

    public var kind: ExerciseKind {
        switch self {
        case .pushUp, .squat, .dips, .pullUp: return .reps
        case .plank:                          return .hold
        }
    }

    /// Rep-counting thresholds. `nil` for `.hold` exercises, which are scored by
    /// duration and have no depth/lockout criteria — plank uses `PlankConfig`.
    var repThresholds: ExerciseThresholds? {
        switch self {
        case .pushUp:
            return ExerciseThresholds(
                nominalDescentStart:  150,   // ceiling for the descent gate (derived down if needed)
                nominalDepth:         90,    // "deep enough" — elbow at/under 90° → tolerated to 94.5°
                nominalLockout:       165,   // arms locked at the top → tolerated to 156.75°
                reversalMargin:       12,    // angle must rise this much past the minimum to count as "ascending"
                nominalSupportMin:    155,   // shoulder–hip–knee: below this = sagging/arching (anti-cheat)
                nominalMaxTorsoPitch: 30     // shoulder→hip line must stay within 30° of horizontal
            )
        case .squat:
            // `nominalDepth` IS NOT THE SQUAT'S PASS CRITERION — do not tune it
            // hoping to change what counts. Depth is decided by the hip reaching
            // the knee (`SquatAnalyzer.parallelTolerance`), because "thighs
            // parallel" is a fact about hip height and the knee angle is only a
            // proxy for it: with the thigh horizontal the knee angle is 90° minus
            // the shin's forward lean, so parallel really sits near 70–75° for a
            // real squat and this 90° would credit reps above it.
            //
            // The declaration stays because `descentStartAngle` is derived from
            // the lockout and the struct's shape is shared across exercises;
            // `depthAngle` itself is simply unread here, exactly as
            // `supportAngleMin` and `maxTorsoPitch` are.
            return ExerciseThresholds(
                nominalDescentStart: 160,
                nominalDepth:        90,    // unread by SquatAnalyzer; see above
                nominalLockout:      170,   // standing tall → tolerated to 161.5°
                reversalMargin:      12,
                nominalTorsoLeanMax: 55     // torso angle from vertical; beyond this = forward collapse
            )
        case .dips:
            // Spec §4 relaxation: top = elbow > 165° effective (was a locked
            // 171°), bottom = elbow <= 98° effective (was a punishing 94.5°).
            //
            // The nominals are written as the DIVISION that inverts `Tolerance`,
            // not as a hand-rounded decimal, so the effective values land on the
            // spec's numbers to full precision. Writing 173.68 instead of
            // 165 / 0.95 yields 164.996, which is visibly "165" in a comment but
            // fails an exact assertion — and did, on CI.
            return ExerciseThresholds(
                nominalDescentStart: 150,
                nominalDepth:        98 / 1.05,    // → 98.0 effective
                nominalLockout:      165 / 0.95,   // → 165.0 effective
                reversalMargin:      12,
                // Torso must be clearly vertical/diagonal, not flat — this is the
                // anti-cheat gate that stops push-ups counting as dips. 50° → 47.5°.
                nominalMinTorsoPitch: 50
            )
        case .pullUp:
            // Elbow angles only gate the hang/lockout here — whether a pull-up
            // rep is VALID is decided by shoulder travel against the locked bar
            // line (see PullUpConfig), not by elbow depth.
            //
            // Spec §4 relaxation: the dead hang re-arms at > 160° effective
            // rather than a strict 171°, so an athlete who does not fully lock
            // out at the bottom still gets their next rep counted. The nominal is
            // written as the division that inverts `Tolerance` — see the dips
            // case above for why a hand-rounded decimal is not good enough.
            return ExerciseThresholds(
                nominalDescentStart: 150,
                nominalDepth:        90,    // unused as a pass criterion; see above
                nominalLockout:      160 / 0.95,  // → 160.0 effective dead-hang
                reversalMargin:      12
            )
        case .plank:
            return nil
        }
    }
}

/// Geometric tolerances for a single exercise. All angles are in degrees, and
/// all are EFFECTIVE values — the ±5% `Tolerance` is already baked in by the
/// initialiser, so the state machines compare against these directly and never
/// re-apply it. Declare exercises with nominal (textbook) angles; read back
/// tolerated ones.
struct ExerciseThresholds {
    /// The primary joint angle (elbow for push-ups, knee for squats) must drop
    /// below this to be considered "starting the descent" of a new rep.
    /// DERIVED, not declared — see the initialiser.
    let descentStartAngle: CGFloat
    /// The primary joint must reach at least this depth for the rep to be valid.
    let depthAngle: CGFloat
    /// The primary joint must return above this to "lock out" / stand up.
    let lockoutAngle: CGFloat
    /// How far past the recorded minimum the angle must climb before we treat
    /// the movement as a genuine ascent (debounces jitter at the bottom).
    /// A delta, not an angle — no tolerance applies.
    let reversalMargin: CGFloat
    /// Push-ups: shoulder–hip–knee angle. Falling below this flags a sag/arch.
    let supportAngleMin: CGFloat
    /// Squats: maximum allowed torso lean from vertical before "chest up" fires.
    let torsoLeanMax: CGFloat
    /// Push-ups: maximum allowed absolute pitch of the shoulder→hip (torso)
    /// vector away from the horizontal plane. Beyond this the body is piked or
    /// standing, not in a plank — the rep is rejected. (Anti-cheat constraint.)
    let maxTorsoPitch: CGFloat
    /// Dips: MINIMUM torso tilt — the torso must be at least this vertical.
    /// This is what separates a dip (upright torso on the bars) from a push-up
    /// (torso flat), which are otherwise the same elbow movement. 0 = no gate.
    let minTorsoPitch: CGFloat

    /// The smallest gap we allow between `descentStartAngle` and `lockoutAngle`.
    ///
    /// This band is the hysteresis that stops the machine from crediting a rep
    /// and immediately opening a new attempt on the same jittering frame. The
    /// raw spec tolerance eats it: squats nominally have a 10° band (160→170)
    /// but tolerating lockout alone drops it to 1.5° (160→161.5), which is well
    /// inside camera noise even after the analyzer's low-pass filter. We hold
    /// the band at 10° and let `descentStartAngle` move down to make room.
    static let minimumHysteresisBand: CGFloat = 10

    /// Declares an exercise in NOMINAL (textbook) angles and applies the global
    /// ±5% tolerance to the rep-validity criteria and anti-cheat bounds.
    ///
    /// `descentStartAngle` is derived rather than declared: it is pinned at
    /// least `minimumHysteresisBand` below the tolerated lockout, so widening
    /// the tolerance can never collapse or invert the band. `nominalDescentStart`
    /// acts as a ceiling — the gate never sits *higher* than the author asked.
    init(nominalDescentStart: CGFloat,
         nominalDepth: CGFloat,
         nominalLockout: CGFloat,
         reversalMargin: CGFloat,
         nominalSupportMin: CGFloat = .infinity,
         nominalTorsoLeanMax: CGFloat = .infinity,
         nominalMaxTorsoPitch: CGFloat = .infinity,
         nominalMinTorsoPitch: CGFloat = 0) {

        let tolerantLockout = Tolerance.atLeast(nominalLockout)

        self.lockoutAngle    = tolerantLockout
        self.depthAngle      = Tolerance.atMost(nominalDepth)
        self.reversalMargin  = reversalMargin
        self.supportAngleMin = Tolerance.atLeast(nominalSupportMin)
        self.torsoLeanMax    = Tolerance.atMost(nominalTorsoLeanMax)
        self.maxTorsoPitch   = Tolerance.atMost(nominalMaxTorsoPitch)
        // A minimum the athlete must exceed → loosen it DOWNWARD, like lockout.
        self.minTorsoPitch   = Tolerance.atLeast(nominalMinTorsoPitch)

        // `.infinity - 10` is still `.infinity`, so the unused-constraint
        // sentinels above pass through untouched.
        self.descentStartAngle = min(nominalDescentStart,
                                     tolerantLockout - Self.minimumHysteresisBand)
    }
}

// MARK: - Plank configuration

/// Geometry and timing for the plank hold.
///
/// WHY THIS ISN'T `ExerciseThresholds`
/// -----------------------------------
/// A plank has no depth, no lockout and no reps. Forcing it through the rep
/// threshold struct would mean inventing meaningless values for fields the
/// state machine would then have to be trusted not to read.
struct PlankConfig {

    /// Shoulder→hip line must stay within this many degrees of horizontal.
    /// This is the check that separates a plank from a standing person holding
    /// a straight body — without it, the spine and leg checks below both pass
    /// while upright.
    let maxTorsoPitch: CGFloat

    /// shoulder–hip–knee. Below this the hips have piked or sagged.
    let minSpineAngle: CGFloat

    /// hip–knee–ankle. Below this the knees have bent out of the plank.
    let minLegAngle: CGFloat

    /// How long valid posture must persist before the clock starts.
    let armingDuration: TimeInterval

    /// Per-joint confidence floor. The spec asks for the timer to start only
    /// under "high confidence", which is stricter than the tracker's global
    /// `minimumJointConfidence` default of 0.3.
    let minConfidence: Float

    /// THE ANGLE BOUNDS ARE DELIBERATELY *NOT* DERIVED FROM `Tolerance`.
    ///
    /// The brief specifies "a 5% variance, meaning hip-knee-ankle angles between
    /// 160 and 180 are valid" — but 5% of 180° is 9°, which gives 171–180, not
    /// 160–180. The two halves of that sentence disagree; 160° is roughly an 11%
    /// variance. 160 is used here because it is the number the author stated
    /// explicitly and confirmed when asked, and because a stricter 171° bound
    /// would work against the stated goal of starting the timer reliably.
    ///
    /// Do not "fix" this by routing it through `Tolerance.atLeast(180)`.
    static let standard = PlankConfig(
        maxTorsoPitch:   Tolerance.atMost(30),   // → 31.5°, matching the push-up plank bound
        minSpineAngle:   160,                    // author's literal value, see above
        minLegAngle:     160,                    // author's literal value, see above
        armingDuration:  1.5,
        minConfidence:   0.5
    )
}

// MARK: - Pull-up configuration

/// Geometry and timing for the rear-view pull-up.
///
/// Every spatial threshold here is expressed as a FRACTION OF THE ATHLETE'S OWN
/// ARM SPAN, measured at the dead hang when the bar is locked. That is what lets
/// one set of numbers work for different body sizes and camera distances — an
/// absolute normalized offset would only ever be correct at one framing.
struct PullUpConfig {

    /// Wrists must be above this normalized Y to be considered on a bar.
    /// Vision's origin is bottom-left with Y up, so the "upper 35% of the frame"
    /// from the spec is y > 0.65.
    let barZoneMinY: CGFloat

    /// Both wrists must stay in the zone, and stable, for this long before the
    /// bar line locks and reps can begin counting.
    let barLockDuration: TimeInterval

    /// Maximum wrist-Y wobble tolerated during the lock window, in normalized
    /// units. Larger than zero because a hanging athlete always sways slightly.
    let barLockStability: CGFloat

    /// THE REP TRIGGER. The top of a rep fires when the shoulders rise to within
    /// this fraction of an arm span below the locked bar line.
    ///
    /// The brief specified firing when the shoulders "touch or rise above" the
    /// bar line itself. That is a muscle-up, not a pull-up: at the top of a real
    /// chin-over-bar rep the shoulders are still roughly a third of an arm below
    /// the hands, so the literal trigger would never fire and the exercise would
    /// count zero reps forever. See
    /// `BilateralJointsTests.testTopOfARealPullUpDoesNotReachTheBarLine`.
    let topTriggerArmFraction: CGFloat

    /// If the wrists drift further than this (as a fraction of arm span) from
    /// the locked bar line, the athlete is not hanging from a fixed bar any more
    /// — the lock drops. This is what stops a standing athlete from "repping" by
    /// bobbing up and down with their hands in the air: real hands on a real bar
    /// stay put while the shoulders travel.
    let barDriftArmFraction: CGFloat

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
}

// MARK: - Rep state machine

/// The phases a single repetition passes through. One machine per exercise.
///
/// Not every exercise visits every phase. Timed holds (plank) use `.ready` and
/// `.holding` only; pull-ups add `.barLocked` and never use `.atBottom` in the
/// push-up sense.
public enum RepState: String {
    /// Top / start position — arms locked (push-up) or standing tall (squat).
    /// For pull-ups: not yet hanging. For plank: posture not yet valid.
    case ready
    /// Moving down, depth not yet reached.
    case descending
    /// Reached valid depth at the bottom of the rep.
    case atBottom
    /// Moving back up toward the start position.
    case ascending
    /// Pull-ups only: both wrists have been stable in the bar zone long enough
    /// that the bar line is locked and reps can be counted. A standing athlete
    /// never reaches this state.
    case barLocked
    /// Timed-hold exercises only: posture has been valid long enough that the
    /// clock is running. Leaving this state pauses the clock without zeroing it.
    case holding
    /// A rep-level form error was detected (e.g. half-rep); it won't be counted.
    case invalidRepDetected
    /// Global body orientation/alignment is invalid (piked hips, standing, or
    /// spinal sag). The counter is hard-locked until posture is corrected.
    case invalidPosition
}

// MARK: - Form feedback severity

/// Distinguishes a transient coaching cue from a hard posture/anti-cheat block.
/// The UI maps `.critical` to the crimson posture-failure styling.
public enum FormSeverity {
    /// Amber coaching cue (e.g. "Go down lower!"). Auto-clears.
    case warning
    /// Crimson posture / anti-cheat failure. Persists until corrected.
    case critical
}

// MARK: - Device compatibility

/// Result of `ExerciseTrackerManager.checkDeviceCompatibility()`.
public enum SafetyCheckResult: Equatable {
    /// Hardware + OS can run real-time body pose estimation.
    case supported
    /// The OS is too old for the required Vision request revision.
    case unsupportedOS(message: String)
    /// The chip lacks a Neural Engine fast enough for real-time tracking.
    case unsupportedHardware(message: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// User-facing message for the failure cases (nil when supported).
    public var userMessage: String? {
        switch self {
        case .supported:                       return nil
        case .unsupportedOS(let m):            return m
        case .unsupportedHardware(let m):      return m
        }
    }
}
