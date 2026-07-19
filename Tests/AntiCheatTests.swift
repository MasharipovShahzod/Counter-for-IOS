//
//  AntiCheatTests.swift
//  FitnessTrackerTests
//
//  Phase 4: the orientation (gravity) and vertical-displacement checks.
//
//  The device→image gravity mapping itself can't be validated without a phone,
//  so these tests pin the parts that ARE checkable: that the gravity path
//  reduces to the existing image-space behaviour when the phone is upright, that
//  it flips the horizontal/vertical judgement under roll, and that the analyzer
//  gates behave on synthetic gravity.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

// MARK: - torsoTilt

final class TorsoTiltTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    /// Poses spanning flat → diagonal → vertical, reused across the reduction
    /// tests. Each is (shoulder, hip).
    private let poses: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),     // horizontal
        (CGPoint(x: 0, y: 1),   CGPoint(x: 1, y: 0)),        // 45° diagonal
        (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),      // vertical
        (CGPoint(x: 0, y: 0),   CGPoint(x: 1, y: 0.3)),      // shallow
    ]

    /// With no gravity, `torsoTilt` IS `torsoPitch` — so nothing that already
    /// worked changes when CoreMotion is absent.
    func testReducesToTorsoPitchWithoutGravity() {
        for (s, h) in poses {
            XCTAssertEqual(PoseGeometry.torsoTilt(shoulder: s, hip: h, imageDown: nil),
                           PoseGeometry.torsoPitch(shoulder: s, hip: h),
                           accuracy: acc)
        }
    }

    /// With gravity pointing straight down the image — an upright portrait phone
    /// — it ALSO equals `torsoPitch`. The common case is identical whether or
    /// not CoreMotion is running.
    func testReducesToTorsoPitchWhenPhoneUpright() {
        let down = CGVector(dx: 0, dy: -1)
        for (s, h) in poses {
            XCTAssertEqual(PoseGeometry.torsoTilt(shoulder: s, hip: h, imageDown: down),
                           PoseGeometry.torsoPitch(shoulder: s, hip: h),
                           accuracy: acc)
        }
    }

    /// The whole point of gravity: a body lying along the image x-axis reads as
    /// horizontal to the image (`torsoPitch == 0`) but, if gravity also points
    /// along x (phone rolled 90°), it's actually parallel to gravity → vertical.
    func testRolledPhoneFlipsTheJudgement() {
        let s = CGPoint(x: 0, y: 0.5), h = CGPoint(x: 1, y: 0.5)   // flat in the image
        XCTAssertEqual(PoseGeometry.torsoPitch(shoulder: s, hip: h), 0, accuracy: acc)

        // Gravity points along image +x → the body is aligned WITH gravity.
        let rolledDown = CGVector(dx: 1, dy: 0)
        XCTAssertEqual(PoseGeometry.torsoTilt(shoulder: s, hip: h, imageDown: rolledDown),
                       90, accuracy: acc, "aligned with gravity ⇒ vertical body")
    }

    func testDegenerateReturnsMidValueThatFailsBothGates() {
        // Coincident shoulder/hip: 45 fails both a "≤31.5 horizontal" gate and a
        // "≥47.5 vertical" gate, so neither push-up nor dip passes on it.
        let p = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(PoseGeometry.torsoTilt(shoulder: p, hip: p, imageDown: CGVector(dx: 0, dy: -1)),
                       45, accuracy: acc)
    }
}

// MARK: - imageDown

final class ImageDownTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    func testUprightPortraitPointsDownTheImage() {
        // Gravity ≈ (0, -1, 0) for an upright phone → image-down (0, -1),
        // regardless of camera (x ≈ 0 makes the mirror sign irrelevant).
        for front in [true, false] {
            let d = PoseGeometry.imageDown(deviceGravity: (x: 0, y: -1, z: 0),
                                           usingFrontCamera: front)
            XCTAssertNotNil(d)
            XCTAssertEqual(d!.dx, 0, accuracy: acc)
            XCTAssertEqual(d!.dy, -1, accuracy: acc)
        }
    }

    func testFlatPhoneIsRejected() {
        // Screen up, gravity along z → no usable screen-plane projection → nil,
        // so callers fall back to the image-space assumption.
        XCTAssertNil(PoseGeometry.imageDown(deviceGravity: (x: 0, y: 0, z: -1),
                                            usingFrontCamera: true))
    }

    func testFrontAndBackCamerasMirrorTheXSign() {
        let g = (x: 0.8, y: -0.2, z: 0.0)
        let f = PoseGeometry.imageDown(deviceGravity: g, usingFrontCamera: true)!
        let b = PoseGeometry.imageDown(deviceGravity: g, usingFrontCamera: false)!
        XCTAssertEqual(f.dx, -b.dx, accuracy: acc, "front camera mirrors x")
        XCTAssertEqual(f.dy, b.dy, accuracy: acc, "y is unaffected by mirroring")
    }

    func testResultIsUnitLength() {
        let d = PoseGeometry.imageDown(deviceGravity: (x: 0.5, y: -0.6, z: 0.3),
                                       usingFrontCamera: true)!
        XCTAssertEqual(hypot(d.dx, d.dy), 1, accuracy: acc)
    }
}

// MARK: - Dips orientation gate

final class DipsOrientationTests: XCTestCase {

    /// The gap Phase 4 closes: doing push-ups (flat torso) with "Dips" selected
    /// used to count, because a dip and a push-up are the same elbow movement.
    func testFlatTorsoIsRejectedAsAPushUp() {
        let a = DipsAnalyzer()
        var all: [AnalyzerEvent] = []
        all += feed(a, Pose.dipsWithFlatTorso(elbow: 175))
        all += feed(a, Pose.dipsWithFlatTorso(elbow: 85))
        all += feed(a, Pose.dipsWithFlatTorso(elbow: 175))

        XCTAssertEqual(a.successfulReps, 0, "a flat torso is a push-up, not a dip")
        XCTAssertEqual(a.state, .invalidPosition)
        XCTAssertTrue(all.invalidFeedback.contains(DipsAnalyzer.orientationMessage))
    }

    func testVerticalTorsoIsAcceptedAsADip() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 175))
        feed(a, Pose.dips(elbow: 85))
        feed(a, Pose.dips(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1, "an upright torso is a valid dip")
    }

    /// Recovery works: switch from a flat torso to an upright one and the next
    /// clean rep counts — the gate blocks, it doesn't permanently lock out.
    func testUprightingTheTorsoResumesCounting() {
        let a = DipsAnalyzer()
        feed(a, Pose.dipsWithFlatTorso(elbow: 175))   // rejected
        XCTAssertEqual(a.state, .invalidPosition)

        feed(a, Pose.dips(elbow: 175))                // upright → armed
        feed(a, Pose.dips(elbow: 85))
        feed(a, Pose.dips(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// Supplying upright gravity must not change the vertical-torso judgement.
    func testUprightGravityDoesNotBreakValidDips() {
        let a = DipsAnalyzer()
        let down = CGVector(dx: 0, dy: -1)
        feed(a, Pose.dips(elbow: 175), imageDown: down)
        feed(a, Pose.dips(elbow: 85), imageDown: down)
        feed(a, Pose.dips(elbow: 175), imageDown: down)
        XCTAssertEqual(a.successfulReps, 1)
    }
}

// MARK: - Squat vertical displacement

final class SquatDisplacementTests: XCTestCase {

    /// The depth criterion must not reject an honest squat — the hips clearly
    /// travel below the knees here, so it counts.
    func testRealSquatStillCounts() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))
        feed(a, Pose.squat(knee: 65))
        feed(a, Pose.squat(knee: 175))
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// Depth reached by knee angle alone, with the hips pinned so they never
    /// descend at all: rejected, and coached.
    ///
    /// This used to be caught by a separate, fail-open hip-vs-ankle gate bolted
    /// on beside the knee-angle criterion. It now falls straight out of the
    /// criterion itself — the hip never gets near the knee — so the extra gate
    /// is gone and this case is covered by the rule rather than by an exception
    /// to it.
    func testFakedDepthWithoutHipDescentIsRejected() {
        let a = SquatAnalyzer()
        feed(a, Pose.squatNoHipDrop(knee: 175))   // arm at standing
        feed(a, Pose.squatNoHipDrop(knee: 85))    // knee angle hits the old depth…
        let events = feed(a, Pose.squatNoHipDrop(knee: 175))   // …but hips never dropped

        XCTAssertEqual(a.successfulReps, 0, "faked depth with no hip travel must not count")
        XCTAssertTrue(events.invalidFeedback.contains { $0.contains("hips") })
    }

    /// Pull-ups already satisfy the same principle (shoulder travel measured
    /// against the fixed wrist-bar), so this documents that the pull-up path
    /// needs no separate displacement gate: its trigger IS the displacement.
    func testPullUpTriggerIsItselfADisplacementCheck() {
        // Shoulders that don't rise toward the bar don't count — proven in
        // PullUpAnalyzerTests.testPartialPullIsRejected. This assertion just
        // pins the design intent so the two checks aren't confused for missing.
        XCTAssertEqual(ExerciseType.pullUp.kind, .reps)
    }
}

// MARK: - Pendulum sway (spec §3: advisory, never blocking)

final class SwayReportingTests: XCTestCase {

    /// Drives the analyzer to a locked bar, armed at the dead hang.
    private func lockBar(_ a: PullUpAnalyzer, from t: inout TimeInterval) {
        for _ in 0..<45 {
            _ = a.analyze(frame: PoseFrame(bilateral: Pose.hang(), time: t))
            t += 1.0 / 30
        }
    }

    @discardableResult
    private func feed(_ a: PullUpAnalyzer,
                      _ j: BilateralJoints,
                      frames: Int = 10,
                      from t: inout TimeInterval) -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        for _ in 0..<frames {
            events += a.analyze(frame: PoseFrame(bilateral: j, time: t))
            t += 1.0 / 30
        }
        return events
    }

    private func sawWarning(_ events: [AnalyzerEvent]) -> Bool {
        events.contains { e in
            if case .invalidRep(_, let severity) = e { return severity == .warning }
            if case .coachingCue = e { return true }
            return false
        }
    }

    /// Swinging on the bar must be reported. The baseline is frozen at the dead
    /// hang, so a body that travels 0.12 sideways against a 0.4 arm span clears
    /// the 15% bound (0.06) comfortably.
    func testPullUpSwingFiresTheSwayCue() {
        let a = PullUpAnalyzer()
        var t: TimeInterval = 0
        lockBar(a, from: &t)
        XCTAssertTrue(a.isBarLocked, "precondition: the bar must lock")

        // Open the rep un-swung so the baseline freezes at the true start...
        feed(a, Pose.pulledUp(), from: &t)
        // ...then swing.
        let events = feed(a, Pose.displaced(Pose.pulledUp(), byX: 0.12), from: &t)
        XCTAssertTrue(sawWarning(events), "pendulum sway must be reported")
    }

    /// THE NON-BLOCKING GUARANTEE. Sway warns; it must never cost the rep.
    /// This is the requirement most likely to regress silently, because the
    /// obvious "fix" for a swinging athlete is to void their rep.
    func testPullUpSwingDoesNotCancelTheRep() {
        let a = PullUpAnalyzer()
        var t: TimeInterval = 0
        lockBar(a, from: &t)

        feed(a, Pose.pulledUp(), from: &t)
        feed(a, Pose.displaced(Pose.pulledUp(), byX: 0.12), from: &t)
        feed(a, Pose.hang(), from: &t)          // return to the hang closes the rep

        XCTAssertEqual(a.successfulReps, 1, "sway warns; it never voids a rep")
    }

    /// A clean rep must NOT be nagged. A monitor that fires on every rep is
    /// noise the athlete will learn to ignore, which is worse than silence.
    func testCleanPullUpDoesNotFireTheSwayCue() {
        let a = PullUpAnalyzer()
        var t: TimeInterval = 0
        lockBar(a, from: &t)

        var events = feed(a, Pose.pulledUp(), from: &t)
        events += feed(a, Pose.hang(), from: &t)
        XCTAssertFalse(sawWarning(events), "a straight-line rep must not be flagged")
        XCTAssertEqual(a.successfulReps, 1)
    }
}
