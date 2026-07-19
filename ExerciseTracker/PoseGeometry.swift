//
//  PoseGeometry.swift
//  ExerciseTracker
//
//  Pure geometry: the 3-point angle helper plus a typed snapshot of the
//  joints we care about, extracted from a VNHumanBodyPoseObservation.
//
//  COORDINATE NOTE
//  ---------------
//  Vision returns normalized points in the range 0...1 with the ORIGIN AT THE
//  BOTTOM-LEFT and the Y-AXIS POINTING UP. UIKit's origin is top-left with Y
//  pointing DOWN. We deliberately keep everything in Vision's "Y-up" space for
//  the math below — joint *angles* are rotation-invariant so the only place the
//  flip matters is when you draw the skeleton on screen (see PoseOverlay note
//  in ExerciseTrackerManager). Keeping one consistent space here avoids subtle
//  "up vs down" bugs in the lean/sag checks.
//

import Foundation
import Vision

// MARK: - Angle math

enum PoseGeometry {

    /// True when a joint coordinate is usable for maths.
    ///
    /// FAIL-CLOSED CONTRACT
    /// --------------------
    /// Vision can emit non-finite coordinates for a barely-recognized joint. NaN
    /// is uniquely dangerous here because **every** comparison against it returns
    /// false — so `angle < supportAngleMin` would silently report "posture fine"
    /// rather than tripping the check. A NaN that reaches the anti-cheat gates
    /// disables them instead of firing them.
    ///
    /// So each helper below returns the value that makes its caller REJECT the
    /// frame, never the value that makes it pass. Callers should still drop such
    /// frames upstream (see `BodyJoints.make`); this is defence in depth.
    static func isFinite(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite
    }

    /// The floor below which a value from `angle(_:_:_:)` is not a measurement.
    ///
    /// No human joint in the chains this tracker measures folds below a few
    /// degrees, so anything smaller is the degenerate sentinel, not a pose.
    static let minTrustworthyAngle: CGFloat = 5

    /// True when a value from `angle(_:_:_:)` reflects a real measurement.
    ///
    /// WHY CALLERS MUST ASK RATHER THAN TRUST THE SENTINEL
    /// ---------------------------------------------------
    /// `angle` returns 0 for coincident or non-finite joints, and the comment
    /// there calls that fail-closed. It is — but ONLY for gates shaped
    /// `angle >= threshold`, such as a lockout or an alignment minimum.
    ///
    /// A depth or peak gate is shaped `angle <= threshold`, and `0 <= 98` is
    /// TRUE. For those the same sentinel fails wide OPEN: the value that exists
    /// to reject a broken frame instead certifies the deepest possible rep. One
    /// degenerate frame mid-attempt is enough to set `reachedDepth`, and the
    /// athlete's genuine return to lockout then pays out a rep that never
    /// achieved depth.
    ///
    /// `BodyJoints.make` does not save us: it rejects only NON-FINITE points, so
    /// coincident-but-finite joints — routine on a self-occluded lying pose —
    /// pass every upstream guard and reach the analyzers intact.
    ///
    /// So every `<=` angle gate must call this first. See
    /// `CrunchAnalyzerTests.testDegenerateJointsCannotCreditAPeak`.
    static func isTrustworthyAngle(_ degrees: CGFloat) -> Bool {
        degrees.isFinite && degrees > minTrustworthyAngle
    }

    /// Interior angle (in degrees) at vertex `b`, formed by the segments
    /// b→a and b→c. Range 0...180.
    ///
    /// Used for every joint angle in the tracker, e.g. the elbow angle is
    /// `angle(shoulder, elbow, wrist)`.
    ///
    /// Returns 0 for non-finite or degenerate input.
    ///
    /// READ THIS BEFORE COMPARING THE RESULT. This comment used to claim the 0
    /// sentinel "fails the depth/lockout/alignment comparisons rather than
    /// passing them". That is only half true, and the false half was a live
    /// rep-inflation bug:
    ///
    ///   • `angle >= lockout` and `angle < alignmentMin` — 0 FAILS. Fail-closed,
    ///     as intended.
    ///   • `angle <= depth` / `angle <= peak` — `0 <= 98` is TRUE, so 0 PASSES.
    ///     Fail-OPEN: a broken frame certifies the deepest possible rep.
    ///
    /// Every `<=` comparison must therefore be guarded by `isTrustworthyAngle`
    /// first. See that method for the full reasoning.
    static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        guard isFinite(a), isFinite(b), isFinite(c) else { return 0 }

        let v1 = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)

        let dot   = (v1.dx * v2.dx) + (v1.dy * v2.dy)
        let mag   = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
        guard mag > 0, mag.isFinite else { return 0 }

        // Clamp to guard against tiny floating-point overshoot of acos's domain.
        // (Perfectly straight joints land exactly on -1 and are safe; this is
        // purely about float rounding pushing |cosine| a hair past 1.)
        let cosine = min(1, max(-1, dot / mag))
        return acos(cosine) * 180 / .pi
    }

    /// Absolute pitch (in degrees) of the segment a→b away from the HORIZONTAL
    /// plane (the screen's X-axis), folded into the range 0...90.
    /// 0° = perfectly horizontal (ideal push-up plank), 90° = vertical.
    ///
    /// Uses `atan2(dy, dx)` directly on Vision's coordinates. Because Vision's
    /// origin is bottom-left (Y-up), `dy` already points "up the screen" — but
    /// that's irrelevant here: we take the absolute value and fold past 90°, so
    /// the result is the line's tilt regardless of which way it points or the
    /// Y-axis convention. This is the global spatial constraint that prevents
    /// the "piked hips / standing" cheat where only the elbows bend.
    /// Returns 90 (maximum tilt) for non-finite or degenerate input, because the
    /// caller's test is `pitch > maxTorsoPitch` — 90 trips it, 0 would silently
    /// report "perfectly horizontal" and wave the frame through the very
    /// anti-cheat gate this exists to enforce. See `isFinite`.
    ///
    /// Note `atan2(0, 0)` is defined as 0 and does not produce NaN, so straight
    /// or coincident joints never NaN here; the guard is about non-finite input
    /// arriving from Vision, and about coincident points being meaningless
    /// (a shoulder exactly on top of a hip is broken tracking, not a plank).
    static func torsoPitch(shoulder: CGPoint, hip: CGPoint) -> CGFloat {
        guard isFinite(shoulder), isFinite(hip) else { return 90 }
        let dx = hip.x - shoulder.x
        let dy = hip.y - shoulder.y
        guard dx != 0 || dy != 0 else { return 90 }
        let degrees = abs(atan2(dy, dx) * 180 / .pi)   // 0...180
        return degrees > 90 ? 180 - degrees : degrees   // fold to 0...90 tilt
    }

    /// Torso tilt (0° = horizontal, 90° = vertical) measured against TRUE gravity
    /// when a device-gravity reading is available, and against the image's
    /// horizontal axis otherwise.
    ///
    /// WHY THIS EXISTS ALONGSIDE `torsoPitch`
    /// --------------------------------------
    /// `torsoPitch` assumes "down" is the bottom of the image, which is only true
    /// when the phone is held upright. Feeding the gravity direction (projected
    /// into the image plane — see `imageDown`) lets the same horizontal/vertical
    /// judgement survive the phone being rolled, e.g. propped on its side.
    ///
    /// DELIBERATELY REDUCES TO `torsoPitch`. With `imageDown == nil` it *is*
    /// `torsoPitch`, so every existing caller and test is unchanged when no
    /// gravity is present. With `imageDown == (0, -1)` — an upright portrait
    /// phone — the maths also collapses to `torsoPitch`, so the common case is
    /// identical whether or not CoreMotion is running. Gravity only changes the
    /// result when the phone is actually tilted, which is the case it exists for.
    ///
    /// UNVERIFIED ON DEVICE: the roll-compensated path depends on `imageDown`'s
    /// sign conventions, which cannot be checked without a phone. It is written
    /// to fail SAFE — the near-upright case (where `imageDown.x ≈ 0`) is correct
    /// regardless of the x-sign convention, and only a genuinely rolled phone
    /// exercises the unverified path.
    ///
    /// Returns 45 for degenerate (coincident) joints: a value that fails BOTH a
    /// "must be horizontal" gate and a "must be vertical" gate, so neither the
    /// push-up nor the dip orientation check passes on broken tracking.
    static func torsoTilt(shoulder: CGPoint, hip: CGPoint, imageDown: CGVector?) -> CGFloat {
        guard let down = imageDown else {
            return torsoPitch(shoulder: shoulder, hip: hip)
        }
        guard isFinite(shoulder), isFinite(hip) else { return 45 }

        let tx = hip.x - shoulder.x
        let ty = hip.y - shoulder.y
        let tmag = hypot(tx, ty)
        let dmag = hypot(down.dx, down.dy)
        guard tmag > 0, dmag > 0, tmag.isFinite else { return 45 }

        // Angle between the torso vector and "down", folded to 0...90.
        // 0 = torso parallel to gravity (vertical body); 90 = perpendicular
        // (horizontal body).
        let cosine = min(1, max(-1, (tx * down.dx + ty * down.dy) / (tmag * dmag)))
        let theta = acos(cosine) * 180 / .pi           // 0...180
        let folded = theta > 90 ? 180 - theta : theta  // 0...90
        // Re-express as tilt-from-horizontal to match `torsoPitch` (0 = flat).
        return 90 - folded
    }

    /// The direction of real-world "down" as it appears in the upright Vision
    /// image, derived from a device-frame gravity vector. Returns a unit vector
    /// in Vision's normalized (Y-up) image space, or `nil` when the phone is too
    /// flat for the projection to be trustworthy.
    ///
    /// DERIVATION (portrait, the only UI orientation the app supports):
    /// CoreMotion reports gravity in the device frame — x = right edge, y = top
    /// edge, z = out of the screen. For an upright portrait phone gravity is
    /// ≈ (0, -1, 0), i.e. toward the bottom of the screen, which is also the
    /// bottom of the upright Vision image → `(0, -1)`. So the screen-plane
    /// components (x, y) map almost directly; the front camera mirrors x, so its
    /// sign flips.
    ///
    /// FAIL-OPEN: when the screen-plane projection is weak (`|(x, y)|` small, i.e.
    /// the phone is lying flat or aimed straight up/down), the direction is
    /// ambiguous and this returns `nil`, so callers fall back to the image-space
    /// assumption rather than trusting a bad vector. The `x`-sign convention is
    /// only exercised once the phone is rolled far enough for `x` to matter; the
    /// upright case (`x ≈ 0`) is sign-independent.
    static func imageDown(deviceGravity g: (x: Double, y: Double, z: Double),
                          usingFrontCamera front: Bool) -> CGVector? {
        let screenMag = (g.x * g.x + g.y * g.y).squareRoot()
        // ~0.3 ≈ phone within ~72° of upright. Below this it's too flat to trust.
        guard screenMag >= 0.3, screenMag.isFinite else { return nil }
        let x = (front ? -g.x : g.x) / screenMag
        let y = g.y / screenMag
        // Explicit CGFloat conversion — don't lean on implicit Double↔CGFloat
        // bridging under the project's Swift 5.0 language mode.
        return CGVector(dx: CGFloat(x), dy: CGFloat(y))
    }

    /// Angle (in degrees) of the segment a→b measured from the vertical axis.
    /// 0° = perfectly vertical, 90° = perfectly horizontal. Used for torso lean.
    ///
    /// Returns 90 for non-finite or degenerate input: the caller's test is
    /// `lean > torsoLeanMax`, so 90 trips it while 0 would read as a flawless
    /// upright torso. See the fail-closed contract on `isFinite`.
    static func angleFromVertical(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        guard isFinite(a), isFinite(b) else { return 90 }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let mag = hypot(dx, dy)
        guard mag > 0, mag.isFinite else { return 90 }
        // |dy| / mag is the cosine of the angle to the vertical axis.
        let cosine = min(1, max(-1, abs(dy) / mag))
        return acos(cosine) * 180 / .pi
    }

    /// Angle (in degrees) of the segment a→b away from TRUE vertical when a
    /// gravity reading is available, and from the image's vertical axis
    /// otherwise. 0° = perfectly upright, 90° = perfectly horizontal.
    ///
    /// This is to `angleFromVertical` exactly what `torsoTilt` is to
    /// `torsoPitch`: the same judgement, made robust to a tilted phone. Squats
    /// were the last check still measuring against the image's vertical while
    /// push-ups, dips and planks had already moved to gravity — so a phone
    /// propped at an angle flagged "Keep your chest up!" on an honest rep.
    ///
    /// DELIBERATELY REDUCES TO `angleFromVertical`. With `imageDown == nil` it
    /// *is* `angleFromVertical`, and with `imageDown == (0, -1)` — an upright
    /// portrait phone — the maths collapses to it as well, so the common case is
    /// identical whether or not CoreMotion is running.
    ///
    /// Returns 90 for non-finite or degenerate input: the caller's test is
    /// `lean > torsoLeanMax`, so 90 trips it while 0 would read as a flawless
    /// upright torso. Note this is stricter than `torsoTilt`'s degenerate value
    /// of 45, and deliberately so — 45 exists there to fail a "must be
    /// horizontal" gate AND a "must be vertical" gate at once, whereas here
    /// there is only one gate to fail. See the fail-closed contract on
    /// `isFinite`.
    static func leanFromGravity(_ a: CGPoint, _ b: CGPoint, imageDown: CGVector?) -> CGFloat {
        guard let down = imageDown else { return angleFromVertical(a, b) }
        guard isFinite(a), isFinite(b) else { return 90 }

        let vx = b.x - a.x
        let vy = b.y - a.y
        let vmag = hypot(vx, vy)
        let dmag = hypot(down.dx, down.dy)
        guard vmag > 0, dmag > 0, vmag.isFinite else { return 90 }

        // Angle between the segment and the gravity axis, folded to 0...90.
        // Folding is what makes the direction of `down` irrelevant: a torso
        // pointing "with" gravity and one pointing "against" it are both
        // vertical, which is the only thing this measures.
        let cosine = min(1, max(-1, (vx * down.dx + vy * down.dy) / (vmag * dmag)))
        let theta = acos(cosine) * 180 / .pi           // 0...180
        return theta > 90 ? 180 - theta : theta        // 0...90 from vertical
    }

    /// How far `a` sits BELOW `b` along real-world "down", in normalized units.
    /// Positive when `a` is lower than `b`, negative when it is higher.
    ///
    /// WHY A SQUAT NEEDS THIS AND AN ANGLE WON'T DO
    /// -------------------------------------------
    /// "Thighs parallel to the floor" is a statement about the hip being level
    /// with the knee — a linear fact — and the knee ANGLE is only a proxy for it.
    /// A bad one, too: with the thigh horizontal, the knee angle equals 90° minus
    /// the shin's forward lean, so parallel lands anywhere from 90° (a perfectly
    /// vertical shin, which nobody has) down to ~70° for the 20° lean a real
    /// squat carries. Judging depth at "knee ≤ 90°" therefore credits reps well
    /// above parallel, and how far above depends on the athlete's own limb
    /// proportions. Measuring the hip against the knee just asks the question
    /// directly.
    ///
    /// Falls back to the image's vertical axis when no gravity reading is
    /// available — Vision is Y-up, so "lower" means a smaller y.
    ///
    /// Returns the most negative value possible for non-finite input: the
    /// caller's test is `drop >= -tolerance`, so this rejects the frame rather
    /// than waving it through. See the fail-closed contract on `isFinite`.
    static func drop(of a: CGPoint, below b: CGPoint, imageDown: CGVector?) -> CGFloat {
        guard isFinite(a), isFinite(b) else { return -.greatestFiniteMagnitude }

        guard let down = imageDown else { return b.y - a.y }
        let dmag = hypot(down.dx, down.dy)
        guard dmag > 0, dmag.isFinite else { return b.y - a.y }

        // Project (a − b) onto the unit "down" direction.
        return ((a.x - b.x) * down.dx + (a.y - b.y) * down.dy) / dmag
    }

    /// Euclidean distance between two joints, in normalized units.
    ///
    /// Used to derive scale-invariant reference lengths (e.g. the shoulder→wrist
    /// span that calibrates the pull-up trigger to the athlete's own arm rather
    /// than to an absolute pixel offset). Returns 0 for non-finite input.
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        guard isFinite(a), isFinite(b) else { return 0 }
        let d = hypot(b.x - a.x, b.y - a.y)
        return d.isFinite ? d : 0
    }
}

// MARK: - Body joints snapshot

/// A typed, single-frame snapshot of the joints used by the analyzers.
/// One body side (left or right) is chosen — whichever is more confidently
/// visible — because these exercises are judged from a side profile where
/// the far-side limbs are often occluded.
struct BodyJoints {
    let shoulder: CGPoint
    let elbow: CGPoint
    let wrist: CGPoint
    let hip: CGPoint
    let knee: CGPoint
    let ankle: CGPoint

    /// Lowest confidence among the joints that were actually required.
    let minConfidence: Float

    /// Which physical side these joints came from (useful for overlays/UX).
    let side: Side
    enum Side { case left, right }
}

/// Invariant joint-name lists, allocated once for the process rather than twice
/// per frame inside `BodyJoints.make`. Order is fixed and load-bearing:
/// [shoulder, elbow, wrist, hip, knee, ankle] — the `mandatory` switch indexes
/// into it positionally.
private let leftJointNames: [VNHumanBodyPoseObservation.JointName] =
    [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle]
private let rightJointNames: [VNHumanBodyPoseObservation.JointName] =
    [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle]

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

    /// Builds a `BodyJoints` from an observation, automatically picking the more
    /// visible side. Returns `nil` if neither side clears `minConfidence` for the
    /// joints the given exercise needs.
    ///
    /// - Parameters:
    ///   - observation: a recognized 2D body pose (iOS 14+).
    ///   - exercise: used to decide which joints are mandatory.
    ///   - minConfidence: per-joint confidence floor (0...1).
    static func make(from observation: VNHumanBodyPoseObservation,
                     for exercise: ExerciseType,
                     minConfidence: Float) -> BodyJoints? {

        // HOISTED OUT OF `side`, which runs twice per frame.
        //
        // `recognizedPoints(.all)` builds and returns a dictionary of every
        // recognized joint. Calling it inside `side` meant paying for that twice
        // on every single frame — at 30fps, 60 needless dictionary builds a
        // second — to obtain the identical result both times. The joint-name
        // lists are likewise invariant and now live as static storage instead of
        // being rebuilt per side per frame.
        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        // Required joints differ slightly per exercise; we still read all six
        // because both analyzers benefit from the full chain.
        func side(_ s: Side) -> BodyJoints? {
            let names = (s == .left) ? leftJointNames : rightJointNames
            let recognized = names.compactMap { points[$0] }
            guard recognized.count == names.count else { return nil }

            // Which joints must be confident depends on the exercise.
            // `recognized` is ordered [shoulder, elbow, wrist, hip, knee, ankle].
            let mandatory: [VNRecognizedPoint] = {
                switch exercise {
                case .pushUp:
                    // shoulder, elbow, wrist, hip, knee
                    return Array(recognized.prefix(5))
                case .squat:
                    // shoulder, hip, knee, ankle
                    return [recognized[0], recognized[3], recognized[4], recognized[5]]
                case .dips:
                    // Arms plus the hip: the hip is needed for the torso-
                    // orientation anti-cheat gate (a dip torso must be vertical,
                    // which is what separates it from a push-up). Knees/ankles
                    // stay optional — legs are often bent or crossed on the bars.
                    return [recognized[0], recognized[1], recognized[2], recognized[3]]
                case .pullUp:
                    // Pull-ups are judged on `BilateralJoints`, not this snapshot —
                    // both arms are needed and a single side cannot express the
                    // bar line. This case exists only so the switch stays
                    // exhaustive; the manager does not build a `BodyJoints` for
                    // pull-ups.
                    return [recognized[0], recognized[1], recognized[2]]
                case .crunches:
                    // shoulder, hip, knee — the three joints of the driving
                    // angle. Elbow/wrist stay optional: hands behind the head or
                    // across the chest are both normal and both self-occlude.
                    return [recognized[0], recognized[3], recognized[4]]
                case .plank:
                    // shoulder, hip, knee, ankle — the full spine-and-legs chain.
                    return [recognized[0], recognized[3], recognized[4], recognized[5]]
                }
            }()

            // Allocation-free min: `map` built a throwaway array every frame.
            var weakest: Float = .greatestFiniteMagnitude
            for p in mandatory { weakest = min(weakest, p.confidence) }
            guard weakest >= minConfidence else { return nil }

            // Reject the whole frame if any mandatory joint is non-finite.
            // This is the primary fail-closed gate: dropping the frame here
            // (→ "tracking lost") is strictly safer than letting a NaN reach the
            // analyzers, where every comparison against it silently returns false
            // and would disable the form checks instead of tripping them.
            guard mandatory.allSatisfy({ PoseGeometry.isFinite($0.location) }) else { return nil }

            return BodyJoints(
                shoulder: recognized[0].location,
                elbow:    recognized[1].location,
                wrist:    recognized[2].location,
                hip:      recognized[3].location,
                knee:     recognized[4].location,
                ankle:    recognized[5].location,
                minConfidence: weakest,
                side: s
            )
        }

        let left = side(.left)
        let right = side(.right)

        // Pick whichever side is more confidently visible.
        switch (left, right) {
        case let (l?, r?): return l.minConfidence >= r.minConfidence ? l : r
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil):   return nil
        }
    }
}

// MARK: - Bilateral joints snapshot

/// A single-frame snapshot of BOTH arms plus both shoulders.
///
/// WHY THIS EXISTS SEPARATELY FROM `BodyJoints`
/// --------------------------------------------
/// `BodyJoints` deliberately collapses to one body side, because push-ups,
/// squats and dips are judged from a side profile where the far limbs are
/// occluded. Pull-ups can't use that model: the bar line is defined as the mean
/// of BOTH wrists and the rep trigger compares it against the mean of BOTH
/// shoulders, so a one-sided snapshot cannot express the measurement at all.
/// Rear-view framing is what makes this practical — from behind the athlete,
/// both arms are visible simultaneously.
///
/// Facial joints are intentionally absent: the camera sits behind the athlete,
/// so nose/eyes/ears are occluded and must never gate a rep.
struct BilateralJoints {
    let leftShoulder: CGPoint
    let rightShoulder: CGPoint
    let leftElbow: CGPoint
    let rightElbow: CGPoint
    let leftWrist: CGPoint
    let rightWrist: CGPoint

    /// Lowest confidence across all six joints.
    let minConfidence: Float

    /// The bar line: mean wrist height. In Vision's Y-up space, larger = higher.
    var meanWristY: CGFloat { (leftWrist.y + rightWrist.y) / 2 }

    /// Mean shoulder height, the moving quantity a pull-up rep is judged on.
    var meanShoulderY: CGFloat { (leftShoulder.y + rightShoulder.y) / 2 }

    /// Mean shoulder→wrist distance — the athlete's own arm span in normalized
    /// units. Every pull-up threshold is expressed as a FRACTION of this so the
    /// trigger self-scales across body sizes and camera distances instead of
    /// baking in an absolute offset that only works at one framing.
    var armSpan: CGFloat {
        (PoseGeometry.distance(leftShoulder, leftWrist)
            + PoseGeometry.distance(rightShoulder, rightWrist)) / 2
    }

    /// Mean elbow angle across both arms (shoulder–elbow–wrist).
    var meanElbowAngle: CGFloat {
        (PoseGeometry.angle(leftShoulder, leftElbow, leftWrist)
            + PoseGeometry.angle(rightShoulder, rightElbow, rightWrist)) / 2
    }
}

extension BilateralJoints {

    /// Builds a bilateral snapshot. Returns `nil` unless BOTH arms clear
    /// `minConfidence` and every joint is finite — a pull-up judged on one arm
    /// is not a pull-up, so there is no single-side fallback here by design.
    static func make(from observation: VNHumanBodyPoseObservation,
                     minConfidence: Float) -> BilateralJoints? {

        guard let points = try? observation.recognizedPoints(.all) else { return nil }

        let names: [VNHumanBodyPoseObservation.JointName] = [
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
        ]
        let recognized = names.compactMap { points[$0] }
        guard recognized.count == names.count else { return nil }

        guard let weakest = recognized.map({ $0.confidence }).min(),
              weakest >= minConfidence else { return nil }

        guard recognized.allSatisfy({ PoseGeometry.isFinite($0.location) }) else { return nil }

        return BilateralJoints(
            leftShoulder:  recognized[0].location,
            rightShoulder: recognized[1].location,
            leftElbow:     recognized[2].location,
            rightElbow:    recognized[3].location,
            leftWrist:     recognized[4].location,
            rightWrist:    recognized[5].location,
            minConfidence: weakest
        )
    }
}

// MARK: - Pose frame

/// One frame of pose data handed to an analyzer.
///
/// WHY TIME IS CARRIED HERE RATHER THAN READ FROM A CLOCK
/// ------------------------------------------------------
/// Plank must start its timer after 1.5s of valid posture, and pull-ups must
/// lock the bar after 1.0s of stable wrists. If the analyzers called `Date()` or
/// `systemUptime` internally, testing either rule would mean actually sleeping
/// for seconds and hoping the scheduler cooperated. Injecting the frame time
/// makes both rules deterministic: a test hands over whatever timeline it wants.
///
/// The manager supplies a MONOTONIC clock. Wall-clock time would let an NTP
/// correction (or a user changing the date) rewind mid-hold, which at best
/// corrupts a duration and at worst is an exploit.
struct PoseFrame {

    /// Single-side joints. Present for every exercise except pull-ups.
    let unilateral: BodyJoints?

    /// Both arms. Present only for pull-ups, which cannot be judged from one side.
    let bilateral: BilateralJoints?

    /// Monotonic frame time, in seconds. Only differences between frames are
    /// meaningful — the absolute value has no epoch.
    let time: TimeInterval

    /// Real-world "down" in the image plane (Vision Y-up), from CoreMotion.
    /// `nil` when gravity is unavailable or the phone is too flat to trust — in
    /// which case orientation checks fall back to the image-space assumption
    /// that the phone is upright. See `PoseGeometry.imageDown`.
    let imageDown: CGVector?

    init(unilateral: BodyJoints? = nil,
         bilateral: BilateralJoints? = nil,
         time: TimeInterval,
         imageDown: CGVector? = nil) {
        self.unilateral = unilateral
        self.bilateral = bilateral
        self.time = time
        self.imageDown = imageDown
    }
}
