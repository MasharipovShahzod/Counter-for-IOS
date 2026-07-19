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
    /// An advisory coaching cue, carried as a `VoiceCue` rather than a
    /// pre-rendered string.
    ///
    /// WHY THIS ISN'T JUST AN `invalidRep`
    /// -----------------------------------
    /// `invalidRep` carries a `String`, and a string has already lost the
    /// information the voice engine needs: whether to speak the full sentence,
    /// shorten it to one word on a harsh legacy voice, or play a chime instead.
    /// Emitting `VoiceCue.swing.defaultPhrase` fed the full sentence through the
    /// String path, so the terse fallback and TONE mode — both required by the
    /// spec — could never engage. Passing the cue itself keeps that choice open
    /// until the moment of delivery.
    ///
    /// Always advisory: the manager renders it at `.warning` severity and it
    /// never touches a rep count.
    case coachingCue(VoiceCue)
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
        // `isTrustworthyAngle` first: a degenerate frame yields 0, and
        // `0 <= depthAngle` is true, so the sentinel meant to reject a broken
        // frame would instead certify full depth. See PoseGeometry.
        if PoseGeometry.isTrustworthyAngle(elbow), elbow <= cfg.depthAngle {
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
/// Primary joint: knee (hip–knee–ankle) — drives the state machine.
/// Depth criterion: the HIP against the KNEE — decides whether a rep counts.
/// Form checks: shallow depth (half-rep) and excessive torso lean.
///
/// WHY THE KNEE ANGLE RUNS THE MACHINE BUT DOESN'T JUDGE THE REP
/// ------------------------------------------------------------
/// These are two different jobs and they want two different signals.
///
/// The state machine needs something smooth and monotonic to detect "a descent
/// started" and "they stood back up". The knee angle, low-pass filtered, is
/// ideal: it sweeps cleanly from ~175° to ~65° and back.
///
/// Rep VALIDITY needs to answer "were the thighs parallel to the floor", and
/// that is a question about hip height, not about an angle. This analyzer used
/// to answer it with `knee <= depthAngle` (94.5°), which is wrong in a way that
/// always favours the athlete: with the thigh horizontal, the knee angle is 90°
/// minus the shin's forward lean, and a real squat leans the shin 15–25°. True
/// parallel therefore lands around 70–75°, so a 94.5° gate credited reps well
/// above parallel — by a margin that varied with each athlete's own femur and
/// shin proportions. Nobody could see it, because "90° at the knee" sounds
/// exactly like the textbook cue it was standing in for.
///
/// So depth is now measured where the definition actually lives: the hip must
/// reach the knee. See `PoseGeometry.drop(of:below:imageDown:)`.
final class SquatAnalyzer: ExerciseAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.squat.repThresholds!   // .reps exercise: never nil

    /// How far the hip may sit ABOVE the knee and still be credited, as a
    /// fraction of the athlete's OWN thigh length.
    ///
    /// A linear tolerance, not the global ±5% `Tolerance`, because the criterion
    /// it guards is "hip level with knee" — a zero. Five percent of zero is
    /// zero, so the project's angle-percentage scheme has nothing to say here;
    /// scaling to the thigh is the same idea (be lenient in proportion to the
    /// athlete) expressed in the units this measurement actually has.
    private let parallelTolerance: CGFloat = 0.05

    /// Deepest point of the current attempt, as the hip's distance below the
    /// knee. Negative while the hip is still above it. Tracking the MAXIMUM is
    /// deliberate: it captures the bottom of the rep, and it means per-frame
    /// jitter can only ever help the athlete, never rob them of a good rep.
    private var maxHipDropBelowKnee: CGFloat = -.greatestFiniteMagnitude

    /// One message for every "not deep enough" outcome. Names the fix rather
    /// than the symptom — "squat lower" alone leaves an athlete who is already
    /// trying hard with nothing to change.
    static let shallowMessage = "Squat lower! Get your hips below your knees."

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
        // THE DEPTH MEASUREMENT. How far the hip sits below the knee, and the
        // athlete's own thigh to scale it by. Positive drop = at or past
        // parallel.
        let hipDrop = PoseGeometry.drop(of: joints.hip, below: joints.knee,
                                        imageDown: frame.imageDown)
        let thigh = PoseGeometry.distance(joints.hip, joints.knee)

        // Live depth for the progress ring, from the SAME quantity the rep is
        // judged on — so a full ring means a countable rep. Driving the ring off
        // the knee angle instead would fill it at 94.5° and then refuse the rep,
        // which reads as the app being broken rather than the squat being high.
        //
        // Standing puts the hip a full thigh above the knee (drop = −thigh → 0);
        // parallel puts it level (drop = 0 → 1). Self-scaling, no constants.
        events.append(.depthProgress(Self.hipDepthProgress(hipDrop: hipDrop, thigh: thigh)))

        // ---- Arm at a valid standing position ----
        if !t.attemptInProgress, knee >= cfg.lockoutAngle {
            t.arm()
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if t.isArmed, knee < cfg.descentStartAngle {
                t.beginAttempt()
                maxHipDropBelowKnee = hipDrop
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track depth ----
        // `minPrimaryAngle` still drives ascent detection and is what the ledger
        // signs; it is no longer what decides the rep.
        t.minPrimaryAngle = min(t.minPrimaryAngle, knee)
        maxHipDropBelowKnee = max(maxHipDropBelowKnee, hipDrop)
        if thigh > 0, maxHipDropBelowKnee >= -parallelTolerance * thigh {
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
            // Rising without ever having reached parallel. One check now, where
            // there used to be two overlapping ones — a `shallowAngle` gate here
            // and a hip-travel gate at lockout — with a silent band between them
            // where a rep was neither credited nor explained.
            if !t.reachedDepth, !t.errorEmitted {
                t.errorEmitted = true
                t.transition(to: .invalidRepDetected, sink: &events)
                events.append(.invalidRep(feedback: Self.shallowMessage, severity: .warning))
            } else if !t.errorEmitted {
                t.transition(to: .ascending, sink: &events)
            }
        }

        // ---- Resolve the attempt at standing lockout ----
        if knee >= cfg.lockoutAngle {
            if t.reachedDepth, !t.errorEmitted {
                t.creditRep(sink: &events)
            }
            t.endAttempt()
            maxHipDropBelowKnee = -.greatestFiniteMagnitude
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    /// Rep depth as 0...1, from the hip's position relative to the knee.
    ///
    /// 0 = standing (hip a full thigh above the knee), 1 = parallel or deeper.
    /// Expressed in thigh-lengths so it self-scales to the athlete and to how
    /// far away they set the phone.
    ///
    /// Returns 0 for a degenerate thigh rather than dividing by it — a hip
    /// exactly on top of a knee is broken tracking, and 0 shows an empty ring
    /// instead of a full one.
    static func hipDepthProgress(hipDrop: CGFloat, thigh: CGFloat) -> Double {
        guard thigh > 0, hipDrop.isFinite else { return 0 }
        return Double(max(0, min(1, 1 + hipDrop / thigh)))
    }

    func reset() {
        t.reset()
        maxHipDropBelowKnee = -.greatestFiniteMagnitude
    }
}

// MARK: - Parallel bars dips

/// Parallel-bars dip tracker.
/// Primary joint: elbow (shoulder–elbow–wrist).
/// Top = arms extended (> 165°); bottom = elbow at or under 98°. Both were
/// relaxed from a stricter 171°/94.5° per spec §4, so a dip that stops a little
/// short of a full lockout still counts.
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

    /// Horizontal shoulder drift, measured against a baseline frozen when the
    /// descent begins. On the bars this catches the body swinging fore-and-aft
    /// instead of travelling straight down. Advisory only — see `SwayMonitor`,
    /// which cannot reach the counter.
    private var sway = SwayMonitor(maxDriftFraction: 0.15)

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

        // ---- Anti-sway ----
        // Baseline accumulates while the athlete is supported at the top and
        // freezes when the descent opens, so this measures travel away from
        // where the rep actually started. Normalized against the upper arm.
        // Nothing in this block touches the counter or the FSM state.
        if sway.observe(joints.shoulder, scale: joints.upperArmLength) {
            events.append(.coachingCue(.swing))
        }

        // ---- Arm at the top: arms extended, 165–180° ----
        if !t.attemptInProgress, elbow >= cfg.lockoutAngle {
            t.arm()
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if t.isArmed, elbow < cfg.descentStartAngle {
                t.beginAttempt()
                sway.beginActivePhase()    // FREEZE the baseline here
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track the dip depth ----
        t.minPrimaryAngle = min(t.minPrimaryAngle, elbow)
        // `isTrustworthyAngle` first: a degenerate frame yields 0, and
        // `0 <= depthAngle` is true, so the sentinel meant to reject a broken
        // frame would instead certify full depth. See PoseGeometry.
        if PoseGeometry.isTrustworthyAngle(elbow), elbow <= cfg.depthAngle {
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
            sway.endActivePhase()          // re-baseline at the top
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    /// Drops the frozen sway baseline when the body leaves view.
    ///
    /// Without this, `DipsAnalyzer` used the protocol's default no-op and kept a
    /// baseline frozen at wherever the athlete stood before the gap. Stepping
    /// away and returning a few inches to one side then read as drift and
    /// nagged "Keep your body steady" on a clean rep. The same applies to an
    /// abandoned rep that never returns to lockout, so `endActivePhase()` never
    /// runs — advisory only, but noise the athlete learns to tune out.
    func trackingLost() -> [AnalyzerEvent] {
        sway.reset()
        return []
    }

    func reset() {
        t.reset()
        orientationWarned = false
        sway.reset()
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

    /// Horizontal pendulum sway, measured against a baseline frozen at the dead
    /// hang. Advisory only — `SwayMonitor` has no access to the counter or the
    /// FSM, so it cannot void a rep no matter what this analyzer does with the
    /// result. Bound is 15% of the athlete's own calibrated arm span.
    private var sway = SwayMonitor(maxDriftFraction: 0.15)

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

        // ---- Anti-sway ----
        // The baseline accumulates at the dead hang and freezes when the pull
        // begins, so what this measures is how far the body has swung from where
        // it started — not from where it currently is. Normalized against the
        // calibrated arm span, so it holds at any camera distance.
        let shoulderMid = CGPoint(x: (j.leftShoulder.x + j.rightShoulder.x) / 2,
                                  y: j.meanShoulderY)
        if sway.observe(shoulderMid, scale: armSpan) {
            events.append(.coachingCue(.swing))
        }

        // ---- Arm at the dead hang, and recalibrate the arm span there ----
        // Arm span is only truthful with the elbow straight; a bent arm measures
        // shorter. Refreshing at every hang keeps the trigger honest even if the
        // bar happened to lock while the athlete was already partly pulled up.
        if !attemptInProgress, isExtended {
            isArmed = true
            calibratedArmSpan = j.armSpan
            sway.endActivePhase()          // re-baseline at the hang
            transition(to: .barLocked, sink: &events)
        }

        // ---- Start of a rep: the elbows begin to bend from the hang ----
        if !attemptInProgress {
            if isArmed, elbow < cfg.descentStartAngle {
                attemptInProgress = true
                reachedTop = false
                minElbowThisRep = .greatestFiniteMagnitude
                sway.beginActivePhase()    // FREEZE the baseline here
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
        sway.reset()
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
        sway.reset()
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
        sway.reset()
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
