//
//  PoseFixtures.swift
//  FitnessTrackerTests
//
//  Synthetic poses, a fake clock, and the frame-feeding helpers shared by the
//  analyzer tests.
//
//  ON SYNTHETIC POSES
//  ------------------
//  `RepTracker` low-pass filters the primary angle (alpha 0.6), so a single
//  frame at a target angle does NOT move the smoothed value there. The `feed`
//  helpers push an angle repeatedly until the filter converges, which is also
//  what a real camera does at 30fps.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

// MARK: - Clock

/// A synthetic 30fps clock.
///
/// Analyzers never read a real clock — frame time arrives via `PoseFrame` — so
/// the plank's 1.5s arming and the pull-up's 1.0s bar lock are exercised
/// deterministically here rather than by sleeping and hoping the scheduler
/// cooperates.
final class FakeClock {
    private(set) var now: TimeInterval = 1_000
    let frameInterval: TimeInterval = 1.0 / 30.0

    /// Advances one frame and returns the new time.
    func tick() -> TimeInterval {
        now += frameInterval
        return now
    }

    /// How many frames cover `seconds` of wall time.
    func frames(for seconds: TimeInterval) -> Int {
        Int((seconds / frameInterval).rounded(.up))
    }
}

// MARK: - Pose builders

enum Pose {

    // MARK: Unilateral (push-ups, squats, dips, plank)

    /// A push-up pose with a given elbow angle and a VALID torso.
    ///
    /// Shoulder, hip, knee and ankle are laid out collinear and horizontal, so
    /// torsoPitch = 0° and shoulder–hip–knee = 180° — the posture gate passes and
    /// the test isolates elbow behaviour.
    static func pushUp(elbow elbowDegrees: CGFloat) -> BodyJoints {
        let shoulder = CGPoint(x: 0.5, y: 0.5)
        let elbow    = CGPoint(x: 0.5, y: 0.3)
        // elbow→shoulder points at (0, 1). Place the wrist at `elbowDegrees`
        // from that direction, so angle(shoulder, elbow, wrist) == elbowDegrees.
        let r: CGFloat = 0.2
        let t = elbowDegrees * .pi / 180
        let wrist = CGPoint(x: elbow.x + r * sin(t), y: elbow.y + r * cos(t))

        return BodyJoints(shoulder: shoulder, elbow: elbow, wrist: wrist,
                          hip:   CGPoint(x: 0.3, y: 0.5),
                          knee:  CGPoint(x: 0.1, y: 0.5),
                          ankle: CGPoint(x: 0.0, y: 0.5),
                          minConfidence: 0.9, side: .right)
    }

    /// A push-up pose with the hips piked into a V — the classic cheat. The
    /// elbow angle is still whatever you ask for; only the torso is broken.
    static func pikedPushUp(elbow elbowDegrees: CGFloat) -> BodyJoints {
        let j = pushUp(elbow: elbowDegrees)
        // Hip hoisted well above the shoulder→ankle line: torsoPitch ≈ 56°,
        // far past the 31.5° bound.
        return BodyJoints(shoulder: j.shoulder, elbow: j.elbow, wrist: j.wrist,
                          hip:   CGPoint(x: 0.3, y: 0.8),
                          knee:  CGPoint(x: 0.1, y: 0.5),
                          ankle: CGPoint(x: 0.0, y: 0.5),
                          minConfidence: j.minConfidence, side: j.side)
    }

    /// A parallel-bars dip: VERTICAL torso (hip directly below shoulder), arms
    /// bent to `elbowDegrees`. The vertical torso is what the orientation gate
    /// checks — a flat torso here would be read as a push-up and rejected.
    static func dips(elbow elbowDegrees: CGFloat) -> BodyJoints {
        let shoulder = CGPoint(x: 0.5, y: 0.55)
        let elbow    = CGPoint(x: 0.5, y: 0.42)
        // elbow→shoulder points at (0, +1); wrist placed at `elbowDegrees` from it.
        let r: CGFloat = 0.13
        let t = elbowDegrees * .pi / 180
        let wrist = CGPoint(x: elbow.x + r * sin(t), y: elbow.y + r * cos(t))

        return BodyJoints(shoulder: shoulder, elbow: elbow, wrist: wrist,
                          hip:   CGPoint(x: 0.5, y: 0.15),   // straight down → torso vertical
                          knee:  CGPoint(x: 0.5, y: 0.08),
                          ankle: CGPoint(x: 0.5, y: 0.02),
                          minConfidence: 0.9, side: .right)
    }

    /// A "dip" attempted with a FLAT (push-up) torso — the cheat the orientation
    /// gate must reject. Same arm bend, horizontal torso.
    static func dipsWithFlatTorso(elbow elbowDegrees: CGFloat) -> BodyJoints {
        let j = dips(elbow: elbowDegrees)
        // Move the hip horizontally out from the shoulder → torso flat.
        return BodyJoints(shoulder: j.shoulder, elbow: j.elbow, wrist: j.wrist,
                          hip:   CGPoint(x: 0.2, y: 0.55),
                          knee:  CGPoint(x: 0.1, y: 0.55),
                          ankle: CGPoint(x: 0.0, y: 0.55),
                          minConfidence: 0.9, side: .right)
    }

    /// A squat pose with a given knee angle and a torso leaning `torsoLean`
    /// degrees from vertical.
    ///
    /// ANATOMICALLY CONSISTENT — WHICH THE PREVIOUS VERSION WAS NOT.
    /// That one pinned the hip at y=0.5 and swung the ankle around a fixed knee,
    /// modelling an athlete whose hips never move and whose foot orbits their
    /// shin. It made the squat tests unfalsifiable in the one dimension that
    /// matters: nothing judging depth on hip travel could be tested against a
    /// hip that never travels, so the fixture quietly asserted that a squat *is*
    /// a knee angle. The analyzer then agreed with it, and both were wrong
    /// together.
    ///
    /// THE MODEL. The ankle is planted. The shin leans forward as the athlete
    /// descends. The thigh hangs off the knee at `kneeDegrees`, sending the hips
    /// down and BACK — which is why the thigh vector is the shin rotated by
    /// *minus* the knee angle; rotating the other way walks the hips forward
    /// over the toes, into a position no one can hold.
    ///
    /// WHERE PARALLEL LANDS. Shin lean is `(180 − knee) / 7`, which puts the hip
    /// level with the knee at a knee angle of **75°** with a 15° shin. That is
    /// not a tuned constant: with the thigh horizontal, the knee angle is
    /// exactly 90° minus the shin's lean, so parallel is wherever
    /// `knee + shin == 90`, and the `/7` merely picks a realistic path there.
    /// Which is the whole point of the rewrite — 90° at the knee is NOT
    /// parallel unless the shin is perfectly vertical, and nobody's is.
    ///
    /// Sanity anchors: `knee: 175` ≈ standing, hip ≈ (0.49, 0.50);
    /// `knee: 75` = exactly parallel; `knee: 65` ≈ 0.03 below parallel.
    static func squat(knee kneeDegrees: CGFloat, torsoLean: CGFloat = 0) -> BodyJoints {
        let ankle = CGPoint(x: 0.5, y: 0.1)
        let shinLength: CGFloat = 0.2
        let thighLength: CGFloat = 0.2

        let theta = kneeDegrees * .pi / 180
        let phi = ((180 - kneeDegrees) / 7) * .pi / 180   // shin lean from vertical

        let knee = CGPoint(x: ankle.x + shinLength * sin(phi),
                           y: ankle.y + shinLength * cos(phi))

        // Unit vector knee→ankle, rotated by −theta to give knee→hip.
        let ux = -sin(phi)
        let uy = -cos(phi)
        let hx =  ux * cos(theta) + uy * sin(theta)
        let hy = -ux * sin(theta) + uy * cos(theta)
        let hip = CGPoint(x: knee.x + thighLength * hx,
                          y: knee.y + thighLength * hy)

        // The torso hangs off the hip at `torsoLean` from vertical, leaning
        // forward (+x). An ANGLE rather than an absolute shoulder point, because
        // the hip moves now: a fixed shoulder would silently mean a different
        // lean at every depth, which is how a lean test ends up measuring depth.
        let lean = torsoLean * .pi / 180
        let torsoLength: CGFloat = 0.3
        let shoulder = CGPoint(x: hip.x + torsoLength * sin(lean),
                               y: hip.y + torsoLength * cos(lean))

        // Arms aren't part of the squat's mandatory joint set; kept plausible so
        // the skeleton reads as a body.
        return BodyJoints(shoulder: shoulder,
                          elbow: CGPoint(x: shoulder.x, y: (shoulder.y + hip.y) / 2),
                          wrist: CGPoint(x: shoulder.x, y: hip.y),
                          hip: hip, knee: knee, ankle: ankle,
                          minConfidence: 0.9, side: .right)
    }

    /// A squat where the knee ANGLE reaches `kneeDegrees` but the hip→ankle
    /// vertical gap stays constant at 0.4 — i.e. depth is faked without the hips
    /// ever descending. The hip and ankle are pinned; only the knee joint slides
    /// sideways to hit the target angle. Used to exercise the displacement gate.
    ///
    /// Derivation: with hip (0.5,0.5), ankle (0.5,0.1), knee at (0.5+d, 0.3),
    /// the knee angle θ satisfies cos θ = (d²−0.04)/(d²+0.04), so
    /// d = 0.2·√((1+cos θ)/(1−cos θ)).
    static func squatNoHipDrop(knee kneeDegrees: CGFloat) -> BodyJoints {
        let c = cos(kneeDegrees * .pi / 180)
        let d = 0.2 * sqrt(max(0, (1 + c) / (1 - c)))
        return BodyJoints(shoulder: CGPoint(x: 0.5, y: 0.8),
                          elbow: CGPoint(x: 0.5, y: 0.65),
                          wrist: CGPoint(x: 0.5, y: 0.6),
                          hip:   CGPoint(x: 0.5, y: 0.5),
                          knee:  CGPoint(x: 0.5 + d, y: 0.3),
                          ankle: CGPoint(x: 0.5, y: 0.1),   // pinned with the hip → gap constant
                          minConfidence: 0.9, side: .right)
    }

    // MARK: Plank

    /// A textbook plank: body flat and collinear from shoulders to ankles.
    static func plank(confidence: Float = 0.9) -> BodyJoints {
        BodyJoints(shoulder: CGPoint(x: 0.5, y: 0.5),
                   elbow:    CGPoint(x: 0.5, y: 0.4),
                   wrist:    CGPoint(x: 0.5, y: 0.3),
                   hip:      CGPoint(x: 0.3, y: 0.5),
                   knee:     CGPoint(x: 0.1, y: 0.5),
                   ankle:    CGPoint(x: 0.0, y: 0.5),
                   minConfidence: confidence, side: .right)
    }

    /// Hips piked upward — fails both the horizon and the spine check.
    static func plankPiked() -> BodyJoints {
        BodyJoints(shoulder: CGPoint(x: 0.5, y: 0.5),
                   elbow:    CGPoint(x: 0.5, y: 0.4),
                   wrist:    CGPoint(x: 0.5, y: 0.3),
                   hip:      CGPoint(x: 0.3, y: 0.8),
                   knee:     CGPoint(x: 0.1, y: 0.5),
                   ankle:    CGPoint(x: 0.0, y: 0.5),
                   minConfidence: 0.9, side: .right)
    }

    /// Flat and straight-spined, but the knees are bent — fails ONLY the leg
    /// check, which is what makes it useful.
    static func plankBentKnees() -> BodyJoints {
        BodyJoints(shoulder: CGPoint(x: 0.5, y: 0.5),
                   elbow:    CGPoint(x: 0.5, y: 0.4),
                   wrist:    CGPoint(x: 0.5, y: 0.3),
                   hip:      CGPoint(x: 0.3, y: 0.5),
                   knee:     CGPoint(x: 0.1, y: 0.5),
                   ankle:    CGPoint(x: 0.1, y: 0.7),   // shin folded up → 90° knee
                   minConfidence: 0.9, side: .right)
    }

    /// A person standing bolt upright. Spine and legs are perfectly straight, so
    /// this passes BOTH straightness checks — only the horizon check catches it.
    /// This is the pose that justifies the horizon check existing.
    static func standingStraight() -> BodyJoints {
        BodyJoints(shoulder: CGPoint(x: 0.5, y: 0.9),
                   elbow:    CGPoint(x: 0.5, y: 0.8),
                   wrist:    CGPoint(x: 0.5, y: 0.7),
                   hip:      CGPoint(x: 0.5, y: 0.6),
                   knee:     CGPoint(x: 0.5, y: 0.3),
                   ankle:    CGPoint(x: 0.5, y: 0.0),
                   minConfidence: 0.9, side: .right)
    }

    // MARK: Bilateral (pull-ups)

    /// A rear-view pull-up pose.
    ///
    /// Shoulders sit at `shoulderY`, wrists (on the bar) at `wristY`. The elbows
    /// are placed on the perpendicular bisector of the shoulder→wrist segment,
    /// flared outward by whatever offset produces `elbowDegrees` at the elbow.
    ///
    /// Solving for that offset `h`: with the shoulder and wrist vertically
    /// aligned and separated by `d`, the elbow vectors are (±h, ∓d/2), giving
    /// cos θ = (h² − d²/4) / (h² + d²/4). Rearranged: h = √(k(1+cos θ)/(1−cos θ))
    /// where k = d²/4. Sanity: θ=180° → h=0 (collinear); θ=90° → h=d/2.
    static func pullUp(shoulderY: CGFloat,
                       elbowDegrees: CGFloat = 180,
                       wristY: CGFloat = 0.9) -> BilateralJoints {
        let d = wristY - shoulderY
        let k = (d * d) / 4
        let cosT = cos(elbowDegrees * .pi / 180)

        let h: CGFloat
        if abs(1 - cosT) < 1e-9 {
            h = 0   // degenerate θ→0; not used by any test
        } else {
            h = sqrt(max(0, k * (1 + cosT) / (1 - cosT)))
        }
        let midY = (shoulderY + wristY) / 2

        return BilateralJoints(
            leftShoulder:  CGPoint(x: 0.40, y: shoulderY),
            rightShoulder: CGPoint(x: 0.60, y: shoulderY),
            leftElbow:     CGPoint(x: 0.40 - h, y: midY),
            rightElbow:    CGPoint(x: 0.60 + h, y: midY),
            leftWrist:     CGPoint(x: 0.40, y: wristY),
            rightWrist:    CGPoint(x: 0.60, y: wristY),
            minConfidence: 0.9
        )
    }

    /// A dead hang: arms straight, shoulders a full arm below the bar.
    /// armSpan = 0.4, gap = 1.0 arm.
    static func hang(wristY: CGFloat = 0.9) -> BilateralJoints {
        pullUp(shoulderY: wristY - 0.4, elbowDegrees: 180, wristY: wristY)
    }

    /// The top of a strong, REALISTIC pull-up: shoulders 0.35 of an arm below
    /// the bar. Clears the 0.42 trigger. Note the shoulders are still well below
    /// the hands — shoulders level with the wrists would be a muscle-up.
    static func pulledUp() -> BilateralJoints {
        pullUp(shoulderY: 0.9 - 0.35 * 0.4, elbowDegrees: 90)   // shoulderY = 0.76
    }

    /// A half-hearted pull: shoulders only 0.6 of an arm below the bar, which
    /// does NOT clear the 0.42 trigger.
    static func partialPull() -> BilateralJoints {
        pullUp(shoulderY: 0.9 - 0.6 * 0.4, elbowDegrees: 120)    // shoulderY = 0.66
    }
}

// MARK: - Event helpers

extension Array where Element == AnalyzerEvent {
    var repCounts: [Int] {
        compactMap { if case .repCompleted(let n) = $0 { return n } else { return nil } }
    }
    var invalidFeedback: [String] {
        compactMap { if case .invalidRep(let f, _) = $0 { return f } else { return nil } }
    }
    var severities: [FormSeverity] {
        compactMap { if case .invalidRep(_, let s) = $0 { return s } else { return nil } }
    }
    var states: [RepState] {
        compactMap { if case .stateChanged(let s) = $0 { return s } else { return nil } }
    }
    var depths: [Double] {
        compactMap { if case .depthProgress(let d) = $0 { return d } else { return nil } }
    }
    var holds: [TimeInterval] {
        compactMap { if case .holdProgress(let t) = $0 { return t } else { return nil } }
    }
}

// MARK: - Feeding

/// Feeds one unilateral pose repeatedly so the low-pass filter converges.
/// `imageDown` injects a synthetic gravity direction for orientation tests;
/// nil (the default) exercises the image-space fallback.
@discardableResult
func feed(_ analyzer: ExerciseAnalyzer,
          _ pose: BodyJoints,
          frames: Int = 12,
          clock: FakeClock = FakeClock(),
          imageDown: CGVector? = nil) -> [AnalyzerEvent] {
    var all: [AnalyzerEvent] = []
    for _ in 0..<frames {
        all += analyzer.analyze(frame: PoseFrame(unilateral: pose,
                                                 time: clock.tick(),
                                                 imageDown: imageDown))
    }
    return all
}

/// Feeds one bilateral pose repeatedly (pull-ups).
@discardableResult
func feed(_ analyzer: ExerciseAnalyzer,
          _ pose: BilateralJoints,
          frames: Int = 12,
          clock: FakeClock = FakeClock()) -> [AnalyzerEvent] {
    var all: [AnalyzerEvent] = []
    for _ in 0..<frames {
        all += analyzer.analyze(frame: PoseFrame(bilateral: pose, time: clock.tick()))
    }
    return all
}
