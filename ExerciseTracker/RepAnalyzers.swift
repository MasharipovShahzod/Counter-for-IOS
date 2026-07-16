//
//  RepAnalyzers.swift
//  ExerciseTracker
//
//  The per-exercise state machines. Each analyzer consumes one frame of joints
//  at a time and emits events: state changes, a completed valid rep, an
//  invalid-rep message, or (for holds) accumulated time. The manager forwards
//  these to its delegate.
//
//  DESIGN
//  ------
//  A rep "attempt" begins when the primary joint (elbow for push-ups and dips,
//  knee for squats) bends past `descentStartAngle` — but ONLY once the machine
//  has been ARMED by observing a valid top position first. While the attempt is
//  in progress we track the *minimum* angle reached and run continuous form
//  checks. The rep is only credited when the joint locks back out
//  (`lockoutAngle`) AND depth was reached AND no form error fired. Any error
//  transitions to `.invalidRepDetected`, emits a specific message exactly once,
//  and the count is not incremented when the attempt resolves.
//
//  WHY ARMING EXISTS
//  -----------------
//  Without it a rep is defined as "reach depth, then lock out" — which pays out
//  for a movement that never had a descent at all. Walk into frame already at
//  the bottom of a push-up, press up once, and the old machine credited a rep.
//  Arming makes the definition "start at the top, reach depth, return to the
//  top", which is what a repetition actually is.
//

import Foundation

// MARK: - Events

/// What an analyzer reports after consuming a frame.
enum AnalyzerEvent {
    case stateChanged(RepState)
    case repCompleted(totalCount: Int)
    case invalidRep(feedback: String, severity: FormSeverity)
    /// Normalized rep depth, 0 (top / lockout) → 1 (target depth reached).
    /// Emitted every analyzed frame to drive the live depth progress ring.
    case depthProgress(Double)
    /// Timed-hold exercises only (plank): total accumulated hold time, in
    /// seconds. Emitted every analyzed frame while a hold is being judged, and
    /// once more when the hold pauses — so the UI can show a frozen total rather
    /// than a stale ticking one. Rep-counting exercises never emit this.
    case holdProgress(TimeInterval)
}

// MARK: - Push-up posture validator (anti-cheat)

/// Enforces the GLOBAL spatial constraints a push-up must satisfy regardless of
/// what the elbows are doing: the torso must be roughly parallel to the floor,
/// and the shoulder–hip–knee line must stay near-straight. This is what closes
/// the "pike the hips / stand up and just bend the arms" exploit.
struct PushUpPostureValidator {
    let maxTorsoPitch: CGFloat
    let minHipAlignment: CGFloat

    /// Single user-facing message for any posture failure, per spec.
    static let message = "Fix your posture! Keep your entire body flat and parallel to the floor."

    /// `imageDown` (from CoreMotion) makes the horizontal check robust to a
    /// tilted phone; when nil it falls back to the image-space horizon exactly
    /// as before.
    func isValid(shoulder: CGPoint, hip: CGPoint, knee: CGPoint, imageDown: CGVector?) -> Bool {
        // 1. Torso pitch vs true (or image) horizon (catches V-shape / standing).
        if PoseGeometry.torsoTilt(shoulder: shoulder, hip: hip, imageDown: imageDown) > maxTorsoPitch {
            return false
        }
        // 2. Spinal alignment (catches sag / arch). Rotation-invariant, so no
        //    gravity needed.
        if PoseGeometry.angle(shoulder, hip, knee) < minHipAlignment {
            return false
        }
        return true
    }
}

// MARK: - Protocol

/// One exercise's judging logic. Named for exercises rather than reps because
/// `PlankAnalyzer` scores duration and never increments `successfulReps`.
protocol ExerciseAnalyzer: AnyObject {
    var state: RepState { get }
    var successfulReps: Int { get }

    /// The primary joint angle at the deepest point of the most recently
    /// COMPLETED rep, in degrees. `nil` before the first rep, and always `nil`
    /// for `.hold` exercises.
    ///
    /// This exists so the security ledger can sign the depth actually achieved.
    /// It previously signed `state == .atBottom ? 90 : 0`, evaluated on the main
    /// queue after the analyzer had already returned to `.ready` — so every
    /// entry in the tamper-evident ledger recorded a depth of 0°, a fabricated
    /// value the backend has no way to distinguish from a real one.
    var lastRepPeakDepthAngle: Double? { get }

    /// Feed one frame. Returns every event produced by that frame (often empty).
    func analyze(frame: PoseFrame) -> [AnalyzerEvent]

    /// The body stopped being usable this frame — out of view, below the
    /// confidence floor, or blocked by the security layer.
    ///
    /// WHY THIS EXISTS
    /// ---------------
    /// Absence of a frame is information, and without this hook it was silently
    /// discarded: when the body left view the manager simply stopped calling
    /// `analyze`, so time-based state just froze mid-flight rather than being
    /// told to stand down. The plank was the visible casualty — it kept
    /// `isHolding` true across an arbitrarily long gap, so stepping out of frame
    /// and back resumed the clock instantly and skipped the 1.5s re-arm the
    /// analyzer documents and a wobbling athlete is deliberately charged.
    ///
    /// Analyzers judged purely on the current frame's geometry have nothing to
    /// do here, hence the default no-op.
    ///
    /// Returns events like `analyze` does, so an analyzer standing down can put
    /// the UI back in step (e.g. leaving `.holding`) instead of leaving the view
    /// model believing a clock is still running.
    func trackingLost() -> [AnalyzerEvent]

    func reset()
}

extension ExerciseAnalyzer {

    /// No-op by default: only analyzers carrying time-based state across frames
    /// (plank's clock, the pull-up's bar-lock window) need to react.
    func trackingLost() -> [AnalyzerEvent] { [] }

    /// Maps the primary joint angle to a 0...1 depth: 0 at lockout (top of the
    /// movement), 1 once the target depth angle is reached (and clamped beyond).
    static func depthProgress(primary: CGFloat, cfg: ExerciseThresholds) -> Double {
        let range = cfg.lockoutAngle - cfg.depthAngle
        guard range > 0 else { return 0 }
        let raw = (cfg.lockoutAngle - primary) / range
        return Double(max(0, min(1, raw)))
    }
}

// MARK: - Shared scaffolding

/// Holds the cross-frame bookkeeping common to the rep-counting exercises and
/// applies a light low-pass filter to the primary angle to suppress per-frame
/// jitter.
private final class RepTracker {
    private(set) var state: RepState = .ready
    private(set) var successfulReps = 0

    var attemptInProgress = false
    var reachedDepth = false
    var errorEmitted = false
    var minPrimaryAngle: CGFloat = .greatestFiniteMagnitude

    /// True once a valid TOP position has been observed, meaning a descent may
    /// legitimately begin. Starts false: a machine that has never seen the
    /// athlete at the top has no business crediting a rep. Cleared whenever
    /// posture breaks, so a descent performed in bad form cannot be salvaged by
    /// fixing posture at the bottom and pressing up.
    private(set) var isArmed = false

    /// Primary joint angle at the deepest point of the last CREDITED rep.
    /// Captured in `creditRep` because `endAttempt` clears `minPrimaryAngle`.
    private(set) var lastRepPeakAngle: CGFloat?

    private var smoothedPrimary: CGFloat?
    private let smoothingAlpha: CGFloat = 0.6  // higher = more responsive, less smoothing

    /// Exponentially-smoothed primary joint angle.
    func smooth(_ raw: CGFloat) -> CGFloat {
        let next = smoothedPrimary.map { smoothingAlpha * raw + (1 - smoothingAlpha) * $0 } ?? raw
        smoothedPrimary = next
        return next
    }

    func arm()    { isArmed = true }
    func disarm() { isArmed = false }

    func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != state else { return }
        state = newState
        sink.append(.stateChanged(newState))
    }

    func creditRep(sink: inout [AnalyzerEvent]) {
        successfulReps += 1
        // Snapshot the achieved depth BEFORE `endAttempt` wipes it — this is
        // what the ledger signs.
        lastRepPeakAngle = minPrimaryAngle
        sink.append(.repCompleted(totalCount: successfulReps))
    }

    func beginAttempt() {
        attemptInProgress = true
        reachedDepth = false
        errorEmitted = false
        minPrimaryAngle = .greatestFiniteMagnitude
    }

    func endAttempt() {
        attemptInProgress = false
        reachedDepth = false
        errorEmitted = false
        minPrimaryAngle = .greatestFiniteMagnitude
    }

    func reset() {
        state = .ready
        successfulReps = 0
        smoothedPrimary = nil
        isArmed = false
        lastRepPeakAngle = nil
        endAttempt()
    }
}

// MARK: - Push-ups

/// Side-profile push-up tracker.
/// Primary joint: elbow (shoulder–elbow–wrist).
/// Form checks: hip sag/arch (shoulder–hip–knee) and half-reps (no depth).
final class PushUpAnalyzer: ExerciseAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.pushUp.repThresholds!   // .reps exercise: never nil
    private lazy var posture = PushUpPostureValidator(maxTorsoPitch: cfg.maxTorsoPitch,
                                                      minHipAlignment: cfg.supportAngleMin)
    /// True while we're inside a posture-violation episode (debounces the alert).
    private var postureWarned = false

    var state: RepState { t.state }
    var successfulReps: Int { t.successfulReps }
    var lastRepPeakDepthAngle: Double? { t.lastRepPeakAngle.map(Double.init) }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let joints = frame.unilateral else { return [] }
        var events: [AnalyzerEvent] = []

        let elbow = t.smooth(PoseGeometry.angle(joints.shoulder, joints.elbow, joints.wrist))

        // Live depth for the progress ring: 0 at lockout, 1 at the target angle.
        events.append(.depthProgress(Self.depthProgress(primary: elbow, cfg: cfg)))

        // ====================================================================
        // GLOBAL POSTURE GATE (anti-cheat) — evaluated EVERY frame, BEFORE any
        // elbow/rep logic. Closes the "pike hips / stand up and bend the arms"
        // exploit: the elbow can swing 180°→90° all it wants, but if the torso
        // isn't parallel to the floor (or the spine is broken) nothing counts.
        // ====================================================================
        if !posture.isValid(shoulder: joints.shoulder, hip: joints.hip, knee: joints.knee,
                            imageDown: frame.imageDown) {
            // Void any in-progress rep so it can never be credited on lockout.
            if t.attemptInProgress { t.errorEmitted = true }
            // DISARM. Without this, a descent performed piked could be salvaged
            // by fixing posture at the bottom and pressing up: the athlete would
            // still be armed from the last good top position, so a fresh attempt
            // would open at the bottom and pay out for half a rep.
            t.disarm()
            if !postureWarned {
                postureWarned = true
                t.transition(to: .invalidPosition, sink: &events)
                events.append(.invalidRep(feedback: PushUpPostureValidator.message,
                                          severity: .critical))
            }
            // Hard-freeze the state machine while posture is broken.
            return events
        }

        // Posture recovered: re-arm the alert and step out of the locked state.
        // (Re-arming the REP machine is separate and happens only at lockout.)
        if postureWarned {
            postureWarned = false
            if t.state == .invalidPosition {
                t.transition(to: t.attemptInProgress ? .descending : .ready, sink: &events)
            }
        }

        // ---- Arm at a valid top position ----
        if !t.attemptInProgress, elbow >= cfg.lockoutAngle {
            t.arm()
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if t.isArmed, elbow < cfg.descentStartAngle {
                t.beginAttempt()
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track depth ----
        t.minPrimaryAngle = min(t.minPrimaryAngle, elbow)
        if elbow <= cfg.depthAngle {
            t.reachedDepth = true
            t.transition(to: .atBottom, sink: &events)
        }

        // ---- Detect the ascent (angle climbing past the recorded minimum) ----
        let isAscending = elbow > t.minPrimaryAngle + cfg.reversalMargin
        if isAscending {
            // Half-rep: started rising without ever reaching depth.
            if !t.reachedDepth, !t.errorEmitted {
                t.errorEmitted = true
                t.transition(to: .invalidRepDetected, sink: &events)
                events.append(.invalidRep(feedback: "Go down lower!", severity: .warning))
            } else if !t.errorEmitted {
                t.transition(to: .ascending, sink: &events)
            }
        }

        // ---- Resolve the attempt at lockout ----
        if elbow >= cfg.lockoutAngle {
            if t.reachedDepth, !t.errorEmitted {
                t.creditRep(sink: &events)
            }
            t.endAttempt()
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    func reset() {
        t.reset()
        postureWarned = false
    }
}

// MARK: - Squats

/// Side / 45°-profile squat tracker.
/// Primary joint: knee (hip–knee–ankle).
/// Form checks: shallow depth (half-rep) and excessive torso lean.
final class SquatAnalyzer: ExerciseAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.squat.repThresholds!   // .reps exercise: never nil

    /// A shallow squat is flagged if the knee never bends past this before the
    /// athlete reverses. Slightly looser than the strict depth target so a rep
    /// that's *close* still counts but a clearly-shallow one is rejected.
    private let shallowAngle: CGFloat = 100

    // MARK: Vertical-displacement corroboration (spec Step 3.2)
    //
    // The brief asks to confirm real hip travel relative to the ankles so that
    // "bobbing the phone" can't fake a squat. Worth being honest about scope:
    // the rep is already judged on the KNEE ANGLE, and angles are
    // translation-invariant, so moving the whole phone (or the whole body)
    // uniformly already changes no angle and counts nothing. This check is
    // therefore defense-in-depth — it catches a knee-angle change unaccompanied
    // by genuine hip descent (mistracking, a seated "knee wave") — not the
    // phone-bob case, which was never countable. It is FAIL-OPEN and loose so it
    // can never reject an honest squat.

    /// Vertical hip→ankle gap while standing (captured at the top). The
    /// reference the descent is measured against.
    private var standingHipAnkleGap: CGFloat?
    /// Smallest hip→ankle gap seen during the current attempt (deepest point).
    private var minHipAnkleGap: CGFloat = .greatestFiniteMagnitude
    /// The hip must close at least this fraction of the standing gap to confirm
    /// a real descent. A parallel squat closes ~40–50%; 0.10 clears any honest
    /// rep with huge margin while still rejecting "no descent at all".
    private let minDescentFraction: CGFloat = 0.10

    var state: RepState { t.state }
    var successfulReps: Int { t.successfulReps }
    var lastRepPeakDepthAngle: Double? { t.lastRepPeakAngle.map(Double.init) }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let joints = frame.unilateral else { return [] }
        var events: [AnalyzerEvent] = []

        let knee = t.smooth(PoseGeometry.angle(joints.hip, joints.knee, joints.ankle))
        // Torso lean: angle of the hip→shoulder line away from vertical, measured
        // against TRUE gravity when it's available. Squats were the last check
        // still using the image's vertical after push-ups, dips and planks had
        // moved to gravity, so a phone propped at an angle fired "Keep your chest
        // up!" on an honest rep.
        let torsoLean = PoseGeometry.leanFromGravity(joints.hip, joints.shoulder,
                                                     imageDown: frame.imageDown)
        // Vertical hip→ankle gap (Vision is Y-up: standing hip sits well above
        // the ankle → large gap; at the bottom the hip drops → smaller gap).
        let hipAnkleGap = joints.hip.y - joints.ankle.y

        // Live depth for the progress ring: 0 at lockout, 1 at the target angle.
        events.append(.depthProgress(Self.depthProgress(primary: knee, cfg: cfg)))

        // ---- Arm at a valid standing position ----
        if !t.attemptInProgress, knee >= cfg.lockoutAngle {
            t.arm()
            // Refresh the standing reference while genuinely standing tall.
            standingHipAnkleGap = hipAnkleGap
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if t.isArmed, knee < cfg.descentStartAngle {
                t.beginAttempt()
                minHipAnkleGap = hipAnkleGap
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track depth ----
        t.minPrimaryAngle = min(t.minPrimaryAngle, knee)
        minHipAnkleGap = min(minHipAnkleGap, hipAnkleGap)
        if knee <= cfg.depthAngle {
            t.reachedDepth = true
            t.transition(to: .atBottom, sink: &events)
        }

        // ---- Form check 1: forward lean / chest collapse (runs the whole rep) ----
        if !t.errorEmitted, torsoLean > cfg.torsoLeanMax {
            t.errorEmitted = true
            t.transition(to: .invalidRepDetected, sink: &events)
            events.append(.invalidRep(feedback: "Keep your chest up!", severity: .warning))
        }

        // ---- Detect the ascent ----
        let isAscending = knee > t.minPrimaryAngle + cfg.reversalMargin
        if isAscending {
            // Form check 2: rising while still shallower than `shallowAngle`.
            if t.minPrimaryAngle > shallowAngle, !t.errorEmitted {
                t.errorEmitted = true
                t.transition(to: .invalidRepDetected, sink: &events)
                events.append(.invalidRep(feedback: "Squat lower! Thighs parallel to the floor.",
                                          severity: .warning))
            } else if !t.errorEmitted {
                t.transition(to: .ascending, sink: &events)
            }
        }

        // ---- Resolve the attempt at standing lockout ----
        if knee >= cfg.lockoutAngle {
            if t.reachedDepth, !t.errorEmitted {
                if descendedEnough {
                    t.creditRep(sink: &events)
                } else {
                    // Knee angle reached depth but the hips never actually
                    // dropped relative to the ankles — reject as unverified.
                    t.errorEmitted = true
                    events.append(.invalidRep(feedback: "Drop your hips into the squat.",
                                              severity: .warning))
                }
            }
            t.endAttempt()
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    /// Did the hip close enough of its standing gap to the ankle to confirm a
    /// real descent? FAIL-OPEN: with no valid standing reference it returns
    /// true, so a missing/degenerate reference never blocks a rep.
    private var descendedEnough: Bool {
        guard let standing = standingHipAnkleGap, standing > 0 else { return true }
        let drop = standing - minHipAnkleGap
        return drop >= minDescentFraction * standing
    }

    func reset() {
        t.reset()
        standingHipAnkleGap = nil
        minHipAnkleGap = .greatestFiniteMagnitude
    }
}

// MARK: - Parallel bars dips

/// Parallel-bars dip tracker.
/// Primary joint: elbow (shoulder–elbow–wrist).
/// Top = arms extended (tolerated 171–180°); bottom = elbow at or under 94.5°.
///
/// Geometrically a dip and a push-up are the SAME elbow movement — bend, then
/// straighten — so the only thing separating them is torso ORIENTATION: a dip's
/// torso is vertical/diagonal, a push-up's is flat. That constraint is enforced
/// by the orientation gate in `analyze` (see `cfg.minTorsoPitch`), which is what
/// stops push-ups counting while Dips is selected.
final class DipsAnalyzer: ExerciseAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.dips.repThresholds!   // .reps exercise: never nil
    /// Debounces the orientation alert to once per violation episode.
    private var orientationWarned = false

    /// Shown when the torso is too flat to be a dip (i.e. it's a push-up).
    static let orientationMessage = "Keep your torso upright — that's a dip, not a push-up."

    var state: RepState { t.state }
    var successfulReps: Int { t.successfulReps }
    var lastRepPeakDepthAngle: Double? { t.lastRepPeakAngle.map(Double.init) }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let joints = frame.unilateral else { return [] }
        var events: [AnalyzerEvent] = []

        let elbow = t.smooth(PoseGeometry.angle(joints.shoulder, joints.elbow, joints.wrist))
        events.append(.depthProgress(Self.depthProgress(primary: elbow, cfg: cfg)))

        // ====================================================================
        // ORIENTATION GATE (anti-cheat), every frame, before any rep logic.
        // A dip's torso is vertical/diagonal; a push-up's is flat. Geometrically
        // the two are the SAME elbow movement, so without this gate doing
        // push-ups with "Dips" selected would count. Requires a vertical torso.
        // ====================================================================
        let tilt = PoseGeometry.torsoTilt(shoulder: joints.shoulder, hip: joints.hip,
                                          imageDown: frame.imageDown)
        if tilt < cfg.minTorsoPitch {
            if t.attemptInProgress { t.errorEmitted = true }
            t.disarm()
            if !orientationWarned {
                orientationWarned = true
                t.transition(to: .invalidPosition, sink: &events)
                events.append(.invalidRep(feedback: Self.orientationMessage, severity: .critical))
            }
            return events
        }
        if orientationWarned {
            orientationWarned = false
            if t.state == .invalidPosition {
                t.transition(to: t.attemptInProgress ? .descending : .ready, sink: &events)
            }
        }

        // ---- Arm at the top: arms extended, 171–180° ----
        if !t.attemptInProgress, elbow >= cfg.lockoutAngle {
            t.arm()
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if t.isArmed, elbow < cfg.descentStartAngle {
                t.beginAttempt()
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track the dip depth ----
        t.minPrimaryAngle = min(t.minPrimaryAngle, elbow)
        if elbow <= cfg.depthAngle {
            t.reachedDepth = true
            t.transition(to: .atBottom, sink: &events)
        }

        // ---- Detect the press back up ----
        let isAscending = elbow > t.minPrimaryAngle + cfg.reversalMargin
        if isAscending {
            if !t.reachedDepth, !t.errorEmitted {
                t.errorEmitted = true
                t.transition(to: .invalidRepDetected, sink: &events)
                events.append(.invalidRep(feedback: "Dip lower! Bend to 90°.", severity: .warning))
            } else if !t.errorEmitted {
                t.transition(to: .ascending, sink: &events)
            }
        }

        // ---- Top → Bottom → Top completes one rep ----
        if elbow >= cfg.lockoutAngle {
            if t.reachedDepth, !t.errorEmitted {
                t.creditRep(sink: &events)
            }
            t.endAttempt()
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    func reset() {
        t.reset()
        orientationWarned = false
    }
}

// MARK: - Pull-ups

/// Rear-view pull-up tracker.
///
/// Optimised for a camera BEHIND the athlete, so no facial or chin landmark is
/// ever consulted — from behind they are occluded, and a rep that depends on
/// them would simply stop counting.
///
/// TWO PHASES
/// ----------
/// 1. BAR LOCK. Nothing counts until both wrists sit in the upper 35% of frame,
///    stable, for a full second. Then the bar line locks at the mean wrist
///    height and the athlete's arm span is calibrated at the dead hang. This is
///    what stops a standing athlete from accumulating reps.
/// 2. REPS. The top of a rep fires on SHOULDER TRAVEL toward the locked bar
///    line, measured in units of the athlete's own arm span. The rep completes
///    on the way back down, when the elbows extend to the dead hang again.
final class PullUpAnalyzer: ExerciseAnalyzer {

    private let cfg = ExerciseType.pullUp.repThresholds!   // .reps exercise: never nil
    private let pull = PullUpConfig.standard

    private var currentState: RepState = .ready
    private var reps = 0

    // Bar lock
    private var barYLevel: CGFloat?
    private var calibratedArmSpan: CGFloat?
    private var zoneEntryTime: TimeInterval?
    private var zoneReferenceWristY: CGFloat?

    // Rep attempt
    private var isArmed = false
    private var attemptInProgress = false
    private var reachedTop = false
    private var smoothedElbow: CGFloat?
    private let smoothingAlpha: CGFloat = 0.6

    /// Deepest elbow flexion seen during the attempt in progress, and the value
    /// captured from the last credited rep. Pull-up validity is decided by
    /// shoulder travel, not elbow depth — but the elbow is still the primary
    /// joint, so this is what the ledger signs.
    private var minElbowThisRep: CGFloat = .greatestFiniteMagnitude
    private var lastPeak: CGFloat?

    var state: RepState { currentState }
    var successfulReps: Int { reps }
    var lastRepPeakDepthAngle: Double? { lastPeak.map(Double.init) }

    /// True once the bar line has been established.
    var isBarLocked: Bool { barYLevel != nil }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let j = frame.bilateral else { return [] }
        var events: [AnalyzerEvent] = []

        let elbow = smooth(j.meanElbowAngle)

        guard let bar = barYLevel, let armSpan = calibratedArmSpan, armSpan > 0 else {
            // The ring sits at zero until there is a bar to measure against —
            // but this event is ALSO the view model's only proof that a body is
            // in view, and pull-ups emit it nowhere else. Omitting it left the
            // athlete hanging on the bar looking at "Position your body" for the
            // entire bar-lock window, with the real cue ("Grab the bar")
            // unreachable behind the `!isBodyTracked` branch of `statusText`.
            events.append(.depthProgress(0))
            updateBarLock(j, time: frame.time, sink: &events)
            return events
        }

        // ---- Maintain the lock ----
        // Hands on a real bar do not move. If the wrists have wandered away from
        // the locked line, the athlete is not hanging from it — drop the lock
        // rather than let them "rep" by bobbing up and down on the ground.
        if abs(j.meanWristY - bar) > pull.barDriftArmFraction * armSpan {
            dropLock(sink: &events)
            return events
        }

        // ---- The rep measurement ----
        // Gap from the bar down to the shoulders, in arm-spans. ~1.0 at a dead
        // hang; shrinks as the athlete pulls up.
        let gapInArms = (bar - j.meanShoulderY) / armSpan
        let isAtTop = gapInArms <= pull.topTriggerArmFraction
        let isExtended = elbow >= cfg.lockoutAngle

        // Ring progress: 0 at a dead hang, 1 at the trigger height.
        let span = 1 - pull.topTriggerArmFraction
        if span > 0 {
            let progress = (1 - gapInArms) / span
            events.append(.depthProgress(Double(max(0, min(1, progress)))))
        }

        // ---- Arm at the dead hang, and recalibrate the arm span there ----
        // Arm span is only truthful with the elbow straight; a bent arm measures
        // shorter. Refreshing at every hang keeps the trigger honest even if the
        // bar happened to lock while the athlete was already partly pulled up.
        if !attemptInProgress, isExtended {
            isArmed = true
            calibratedArmSpan = j.armSpan
            transition(to: .barLocked, sink: &events)
        }

        // ---- Start of a rep: the elbows begin to bend from the hang ----
        if !attemptInProgress {
            if isArmed, elbow < cfg.descentStartAngle {
                attemptInProgress = true
                reachedTop = false
                minElbowThisRep = .greatestFiniteMagnitude
                transition(to: .ascending, sink: &events)   // pulling UP
            } else {
                return events
            }
        }

        minElbowThisRep = min(minElbowThisRep, elbow)

        // ---- Top of the rep ----
        if isAtTop {
            reachedTop = true
            transition(to: .atBottom, sink: &events)   // apex of a pull-up
        }

        // ---- Descent completes the rep ----
        if isExtended {
            if reachedTop {
                reps += 1
                lastPeak = minElbowThisRep
                events.append(.repCompleted(totalCount: reps))
            } else {
                events.append(.invalidRep(feedback: "Pull higher!", severity: .warning))
            }
            attemptInProgress = false
            reachedTop = false
            transition(to: .barLocked, sink: &events)
        }

        return events
    }

    // MARK: Bar lock

    /// Phase 1: watch for both wrists sitting still, high in frame, long enough
    /// to be a bar grip rather than a passing gesture.
    private func updateBarLock(_ j: BilateralJoints,
                               time: TimeInterval,
                               sink: inout [AnalyzerEvent]) {

        let bothInZone = j.leftWrist.y > pull.barZoneMinY && j.rightWrist.y > pull.barZoneMinY

        guard bothInZone else {
            zoneEntryTime = nil
            zoneReferenceWristY = nil
            transition(to: .ready, sink: &sink)
            return
        }

        guard let entered = zoneEntryTime, let reference = zoneReferenceWristY else {
            zoneEntryTime = time
            zoneReferenceWristY = j.meanWristY
            transition(to: .ready, sink: &sink)
            return
        }

        // Wobbled too far: this isn't a settled grip. Restart the window rather
        // than abandon it — the athlete is probably still getting set.
        if abs(j.meanWristY - reference) > pull.barLockStability {
            zoneEntryTime = time
            zoneReferenceWristY = j.meanWristY
            return
        }

        if time - entered >= pull.barLockDuration {
            barYLevel = j.meanWristY
            calibratedArmSpan = j.armSpan
            isArmed = false          // must still be seen at a dead hang to arm
            transition(to: .barLocked, sink: &sink)
        }
    }

    private func dropLock(sink: inout [AnalyzerEvent]) {
        barYLevel = nil
        calibratedArmSpan = nil
        zoneEntryTime = nil
        zoneReferenceWristY = nil
        isArmed = false
        attemptInProgress = false
        reachedTop = false
        transition(to: .ready, sink: &sink)
    }

    // MARK: Helpers

    /// The body left view. Invalidate anything that was being measured over time.
    ///
    /// Two things must not survive a gap. The bar lock is earned by a full
    /// second of STILL wrists, and a tracking gap is absence of evidence rather
    /// than evidence of stillness — so the window restarts. And a rep in flight
    /// cannot be judged across the gap, because the apex is exactly what we
    /// would have missed; it is voided rather than credited on the next
    /// extension.
    ///
    /// The bar line itself is KEPT: a bar does not move because the athlete
    /// stepped away, and re-earning the lock costs a second the returning
    /// athlete has already paid once. They must still be seen at a dead hang
    /// before reps resume, which is what `isArmed = false` enforces.
    func trackingLost() -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        zoneEntryTime = nil
        zoneReferenceWristY = nil
        attemptInProgress = false
        reachedTop = false
        minElbowThisRep = .greatestFiniteMagnitude
        isArmed = false
        transition(to: barYLevel == nil ? .ready : .barLocked, sink: &events)
        return events
    }

    private func smooth(_ raw: CGFloat) -> CGFloat {
        let next = smoothedElbow.map { smoothingAlpha * raw + (1 - smoothingAlpha) * $0 } ?? raw
        smoothedElbow = next
        return next
    }

    private func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != currentState else { return }
        currentState = newState
        sink.append(.stateChanged(newState))
    }

    func reset() {
        currentState = .ready
        reps = 0
        barYLevel = nil
        calibratedArmSpan = nil
        zoneEntryTime = nil
        zoneReferenceWristY = nil
        isArmed = false
        attemptInProgress = false
        reachedTop = false
        smoothedElbow = nil
        minElbowThisRep = .greatestFiniteMagnitude
        lastPeak = nil
    }
}

// MARK: - Plank

/// Plank hold tracker. Scores DURATION, never reps.
///
/// Validates three things every frame, all of which must hold:
///   • the torso is actually horizontal (shoulder→hip vs the horizon),
///   • the spine is straight (shoulder–hip–knee),
///   • the legs are straight (hip–knee–ankle).
///
/// The horizon check is the one that matters most for anti-cheat: without it, a
/// standing athlete satisfies both straightness checks trivially and the clock
/// would run while they stood still.
final class PlankAnalyzer: ExerciseAnalyzer {

    private let cfg = PlankConfig.standard

    private var currentState: RepState = .ready
    private var accumulated: TimeInterval = 0
    private var validSince: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var isHolding = false
    private var warned = false

    /// The largest gap between two frames we're willing to credit to the hold.
    ///
    /// Frames get dropped under backpressure, so a gap of a few hundred
    /// milliseconds is normal and should still count — the athlete was holding
    /// through it. But a multi-second gap means we stopped observing (app
    /// backgrounded, tracking lost), and crediting unobserved time would be
    /// inventing data.
    private let maxCreditableFrameGap: TimeInterval = 1.0

    /// Plank never counts reps — it is a `.hold` exercise.
    var successfulReps: Int { 0 }
    var state: RepState { currentState }

    /// Always nil: a hold has no rep, therefore no rep depth.
    var lastRepPeakDepthAngle: Double? { nil }

    /// Accumulated hold time in seconds.
    var elapsed: TimeInterval { accumulated }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let j = frame.unilateral else { return [] }
        var events: [AnalyzerEvent] = []

        defer { lastFrameTime = frame.time }

        let valid = isValidPlank(j, imageDown: frame.imageDown) && j.minConfidence >= cfg.minConfidence

        guard valid else {
            // "Pause it instantly if the user's form sags out of bounds."
            // Accumulated time is PRESERVED, not zeroed — the athlete keeps what
            // they earned. Re-arming costs the full 1.5s again, which is
            // deliberate: it stops a wobbling athlete from banking time by
            // flickering in and out of a valid pose.
            validSince = nil
            isHolding = false
            if !warned {
                warned = true
                transition(to: .invalidPosition, sink: &events)
                events.append(.invalidRep(feedback: Self.formMessage, severity: .critical))
            }
            // Emitted on EVERY invalid frame, not just the holding→paused edge.
            // This event doubles as the view model's "a body is in view" signal,
            // and a plank held in bad form emits nothing else — so gating it on
            // `isHolding` left the athlete staring at "Position your body" while
            // the real problem was their posture. Republishing an unchanged
            // total is free: the view model only forwards whole-second changes.
            events.append(.holdProgress(accumulated))
            return events
        }

        warned = false

        // ---- Arming: posture must persist before the clock starts ----
        guard let since = validSince else {
            validSince = frame.time
            transition(to: .ready, sink: &events)
            events.append(.holdProgress(accumulated))
            return events
        }

        if !isHolding, frame.time - since >= cfg.armingDuration {
            isHolding = true
            transition(to: .holding, sink: &events)
        }

        // ---- Accumulate ----
        if isHolding, let last = lastFrameTime {
            let dt = frame.time - last
            if dt > 0, dt <= maxCreditableFrameGap {
                accumulated += dt
            }
        }

        events.append(.holdProgress(accumulated))
        return events
    }

    /// Single user-facing message for any plank posture failure.
    static let formMessage = "Straighten up! Keep your body flat from shoulders to ankles."

    private func isValidPlank(_ j: BodyJoints, imageDown: CGVector?) -> Bool {
        // 1. Is the body actually horizontal? (Rejects standing.) Uses true
        //    gravity when available, image horizon otherwise.
        if PoseGeometry.torsoTilt(shoulder: j.shoulder, hip: j.hip, imageDown: imageDown) > cfg.maxTorsoPitch {
            return false
        }
        // 2. Is the spine straight? (Rejects piking and sagging.)
        if PoseGeometry.angle(j.shoulder, j.hip, j.knee) < cfg.minSpineAngle {
            return false
        }
        // 3. Are the legs straight? (Rejects kneeling.)
        if PoseGeometry.angle(j.hip, j.knee, j.ankle) < cfg.minLegAngle {
            return false
        }
        return true
    }

    /// The body left view mid-plank. Stand the clock down.
    ///
    /// Without this the analyzer simply stopped being called, so `isHolding` and
    /// `validSince` froze mid-hold: stepping out of frame and back resumed the
    /// clock on the very next frame, skipping the `armingDuration` that a
    /// wobbling athlete is deliberately charged. The unobserved seconds
    /// themselves were never credited — `maxCreditableFrameGap` already refused
    /// them — but the re-arm was, which is the part that made "flicker out of
    /// view to dodge the penalty" work.
    ///
    /// `accumulated` is PRESERVED, exactly as when form breaks: the athlete
    /// keeps what they earned, and only the right to keep accruing is withdrawn.
    func trackingLost() -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        validSince = nil
        isHolding = false
        // Drop the timestamp so the first frame back computes no gap at all,
        // rather than one that `maxCreditableFrameGap` has to catch.
        lastFrameTime = nil
        transition(to: .ready, sink: &events)
        events.append(.holdProgress(accumulated))
        return events
    }

    private func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != currentState else { return }
        currentState = newState
        sink.append(.stateChanged(newState))
    }

    func reset() {
        currentState = .ready
        accumulated = 0
        validSince = nil
        lastFrameTime = nil
        isHolding = false
        warned = false
    }
}
