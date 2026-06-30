//
//  RepAnalyzers.swift
//  ExerciseTracker
//
//  The per-exercise state machines. Each analyzer consumes one frame of joints
//  at a time and emits events: state changes, a completed valid rep, or an
//  invalid-rep message. The manager forwards these to its delegate.
//
//  DESIGN
//  ------
//  A rep "attempt" begins when the primary joint (elbow for push-ups, knee for
//  squats) bends past `descentStartAngle`. While the attempt is in progress we
//  track the *minimum* angle reached and run continuous form checks. The rep is
//  only credited when the joint locks back out (`lockoutAngle`) AND depth was
//  reached AND no form error fired. Any error transitions to
//  `.invalidRepDetected`, emits a specific message exactly once, and the count
//  is not incremented when the attempt resolves.
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

    func isValid(shoulder: CGPoint, hip: CGPoint, knee: CGPoint) -> Bool {
        // 1. Absolute torso pitch vs the horizon (catches V-shape / standing).
        if PoseGeometry.torsoPitch(shoulder: shoulder, hip: hip) > maxTorsoPitch {
            return false
        }
        // 2. Spinal alignment (catches sag / arch).
        if PoseGeometry.angle(shoulder, hip, knee) < minHipAlignment {
            return false
        }
        return true
    }
}

// MARK: - Protocol

protocol RepAnalyzer: AnyObject {
    var state: RepState { get }
    var successfulReps: Int { get }

    /// Feed one frame. Returns every event produced by that frame (often empty).
    func analyze(joints: BodyJoints) -> [AnalyzerEvent]
    func reset()
}

extension RepAnalyzer {
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

/// Holds the cross-frame bookkeeping common to both exercises and applies a
/// light low-pass filter to the primary angle to suppress per-frame jitter.
private final class RepTracker {
    private(set) var state: RepState = .ready
    private(set) var successfulReps = 0

    var attemptInProgress = false
    var reachedDepth = false
    var errorEmitted = false
    var minPrimaryAngle: CGFloat = .greatestFiniteMagnitude

    private var smoothedPrimary: CGFloat?
    private let smoothingAlpha: CGFloat = 0.6  // higher = more responsive, less smoothing

    /// Exponentially-smoothed primary joint angle.
    func smooth(_ raw: CGFloat) -> CGFloat {
        let next = smoothedPrimary.map { smoothingAlpha * raw + (1 - smoothingAlpha) * $0 } ?? raw
        smoothedPrimary = next
        return next
    }

    func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != state else { return }
        state = newState
        sink.append(.stateChanged(newState))
    }

    func creditRep(sink: inout [AnalyzerEvent]) {
        successfulReps += 1
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
        endAttempt()
    }
}

// MARK: - Push-ups

/// Side-profile push-up tracker.
/// Primary joint: elbow (shoulder–elbow–wrist).
/// Form checks: hip sag/arch (shoulder–hip–knee) and half-reps (no depth).
final class PushUpAnalyzer: RepAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.pushUp.thresholds
    private lazy var posture = PushUpPostureValidator(maxTorsoPitch: cfg.maxTorsoPitch,
                                                      minHipAlignment: cfg.supportAngleMin)
    /// True while we're inside a posture-violation episode (debounces the alert).
    private var postureWarned = false

    var state: RepState { t.state }
    var successfulReps: Int { t.successfulReps }

    func analyze(joints: BodyJoints) -> [AnalyzerEvent] {
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
        if !posture.isValid(shoulder: joints.shoulder, hip: joints.hip, knee: joints.knee) {
            // Void any in-progress rep so it can never be credited on lockout.
            if t.attemptInProgress { t.errorEmitted = true }
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
        if postureWarned {
            postureWarned = false
            if t.state == .invalidPosition {
                t.transition(to: t.attemptInProgress ? .descending : .ready, sink: &events)
            }
        }

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if elbow < cfg.descentStartAngle {
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
final class SquatAnalyzer: RepAnalyzer {
    private let t = RepTracker()
    private let cfg = ExerciseType.squat.thresholds

    /// A shallow squat is flagged if the knee never bends past this before the
    /// athlete reverses. Slightly looser than the strict depth target so a rep
    /// that's *close* still counts but a clearly-shallow one is rejected.
    private let shallowAngle: CGFloat = 100

    var state: RepState { t.state }
    var successfulReps: Int { t.successfulReps }

    func analyze(joints: BodyJoints) -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []

        let knee = t.smooth(PoseGeometry.angle(joints.hip, joints.knee, joints.ankle))
        // Torso lean: angle of the hip→shoulder line away from vertical.
        let torsoLean = PoseGeometry.angleFromVertical(joints.hip, joints.shoulder)

        // Live depth for the progress ring: 0 at lockout, 1 at the target angle.
        events.append(.depthProgress(Self.depthProgress(primary: knee, cfg: cfg)))

        // ---- Start of a new attempt ----
        if !t.attemptInProgress {
            if knee < cfg.descentStartAngle {
                t.beginAttempt()
                t.transition(to: .descending, sink: &events)
            } else {
                t.transition(to: .ready, sink: &events)
                return events
            }
        }

        // ---- Track depth ----
        t.minPrimaryAngle = min(t.minPrimaryAngle, knee)
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
                t.creditRep(sink: &events)
            }
            t.endAttempt()
            t.transition(to: .ready, sink: &events)
        }

        return events
    }

    func reset() { t.reset() }
}
