//
//  BilateralJointsTests.swift
//  FitnessTrackerTests
//
//  The bilateral snapshot pull-ups will be built on. Nothing consumes it yet
//  (PullUpAnalyzer lands in Phase 3), so these tests pin the measurements the
//  analyzer will depend on — especially `armSpan`, which is what makes the rep
//  trigger scale-invariant instead of a hardcoded offset.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

final class BilateralJointsTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    /// A dead hang: hands on the bar overhead, arms straight, shoulders below.
    /// Vision space is Y-UP, so the bar is at the HIGH y value.
    private func deadHang(shoulderY: CGFloat = 0.5,
                          wristY: CGFloat = 0.9) -> BilateralJoints {
        BilateralJoints(
            leftShoulder:  CGPoint(x: 0.40, y: shoulderY),
            rightShoulder: CGPoint(x: 0.60, y: shoulderY),
            leftElbow:     CGPoint(x: 0.40, y: (shoulderY + wristY) / 2),
            rightElbow:    CGPoint(x: 0.60, y: (shoulderY + wristY) / 2),
            leftWrist:     CGPoint(x: 0.40, y: wristY),
            rightWrist:    CGPoint(x: 0.60, y: wristY),
            minConfidence: 0.9
        )
    }

    func testMeanWristYIsTheBarLine() {
        let j = BilateralJoints(
            leftShoulder:  CGPoint(x: 0.4, y: 0.5),
            rightShoulder: CGPoint(x: 0.6, y: 0.5),
            leftElbow:     CGPoint(x: 0.4, y: 0.7),
            rightElbow:    CGPoint(x: 0.6, y: 0.7),
            leftWrist:     CGPoint(x: 0.4, y: 0.88),   // uneven grip height
            rightWrist:    CGPoint(x: 0.6, y: 0.92),
            minConfidence: 0.9
        )
        // Averaging both hands absorbs a slightly uneven grip rather than
        // letting one wrist define the bar.
        XCTAssertEqual(j.meanWristY, 0.9, accuracy: acc)
    }

    func testMeanShoulderY() {
        XCTAssertEqual(deadHang(shoulderY: 0.5).meanShoulderY, 0.5, accuracy: acc)
    }

    func testArmSpanIsShoulderToWristDistance() {
        let j = deadHang(shoulderY: 0.5, wristY: 0.9)
        XCTAssertEqual(j.armSpan, 0.4, accuracy: acc)
    }

    /// THE POINT OF armSpan. The same athlete framed twice as large must produce
    /// the same *ratio* of travel to arm length, even though every absolute
    /// coordinate differs. This is what lets one pull-up threshold work at any
    /// camera distance and for any body size.
    func testArmSpanScalesWithFraming() {
        let near = deadHang(shoulderY: 0.2, wristY: 1.0)   // span 0.8
        let far  = deadHang(shoulderY: 0.6, wristY: 1.0)   // span 0.4

        XCTAssertEqual(near.armSpan, 0.8, accuracy: acc)
        XCTAssertEqual(far.armSpan, 0.4, accuracy: acc)

        // Shoulders sitting 50% of an arm below the bar, at both framings.
        let nearGap = (near.meanWristY - near.meanShoulderY) / near.armSpan
        let farGap  = (far.meanWristY - far.meanShoulderY) / far.armSpan
        XCTAssertEqual(nearGap, farGap, accuracy: acc)
        XCTAssertEqual(nearGap, 1.0, accuracy: acc)
    }

    func testMeanElbowAngleStraightArmsIsOneEighty() {
        // Dead hang: shoulder, elbow and wrist collinear.
        XCTAssertEqual(deadHang().meanElbowAngle, 180, accuracy: acc)
    }

    func testMeanElbowAngleBentArms() {
        // Elbows flared out to the sides, forming a right angle at each elbow.
        let j = BilateralJoints(
            leftShoulder:  CGPoint(x: 0.4, y: 0.5),
            rightShoulder: CGPoint(x: 0.6, y: 0.5),
            leftElbow:     CGPoint(x: 0.2, y: 0.5),
            rightElbow:    CGPoint(x: 0.8, y: 0.5),
            leftWrist:     CGPoint(x: 0.2, y: 0.7),
            rightWrist:    CGPoint(x: 0.8, y: 0.7),
            minConfidence: 0.9
        )
        XCTAssertEqual(j.meanElbowAngle, 90, accuracy: acc)
    }

    func testMeanElbowAngleAveragesAsymmetricArms() {
        // One arm straight, one bent 90° — a rep pulled unevenly.
        let j = BilateralJoints(
            leftShoulder:  CGPoint(x: 0.4, y: 0.5),
            rightShoulder: CGPoint(x: 0.6, y: 0.5),
            leftElbow:     CGPoint(x: 0.4, y: 0.7),
            rightElbow:    CGPoint(x: 0.8, y: 0.5),
            leftWrist:     CGPoint(x: 0.4, y: 0.9),   // straight → 180°
            rightWrist:    CGPoint(x: 0.8, y: 0.7),   // right angle → 90°
            minConfidence: 0.9
        )
        XCTAssertEqual(j.meanElbowAngle, 135, accuracy: acc)
    }

    /// A dead hang must NOT read as a completed rep under any sane trigger:
    /// shoulders sit a full arm-length below the bar. This is the baseline the
    /// Phase 3 trigger has to clear.
    func testDeadHangShouldersSitAFullArmBelowTheBar() {
        let j = deadHang()
        let gapInArms = (j.meanWristY - j.meanShoulderY) / j.armSpan
        XCTAssertEqual(gapInArms, 1.0, accuracy: acc)
    }

    /// WHY THE BRIEF'S ORIGINAL TRIGGER WAS REJECTED.
    ///
    /// The spec said to fire the top phase when mean shoulder Y reaches the bar
    /// line. At the top of a real chin-over-bar pull-up the shoulders are still
    /// well below the hands — roughly 0.35 of an arm here. Shoulders level with
    /// the wrists is a muscle-up, so the literal trigger would never fire.
    func testTopOfARealPullUpDoesNotReachTheBarLine() {
        // Shoulders pulled up to 0.35 arm-lengths below the bar — a strong rep.
        let top = BilateralJoints(
            leftShoulder:  CGPoint(x: 0.40, y: 0.76),
            rightShoulder: CGPoint(x: 0.60, y: 0.76),
            leftElbow:     CGPoint(x: 0.30, y: 0.80),
            rightElbow:    CGPoint(x: 0.70, y: 0.80),
            leftWrist:     CGPoint(x: 0.40, y: 0.90),
            rightWrist:    CGPoint(x: 0.60, y: 0.90),
            minConfidence: 0.9
        )
        XCTAssertLessThan(top.meanShoulderY, top.meanWristY,
                          "shoulders never reach the bar in a standard pull-up — "
                              + "the spec's literal trigger would count zero reps")

        // The calibrated trigger (Phase 3) fires on this rep; the literal one doesn't.
        let deadHangSpan: CGFloat = 0.4
        let gapInArms = (top.meanWristY - top.meanShoulderY) / deadHangSpan
        XCTAssertEqual(gapInArms, 0.35, accuracy: acc)
        XCTAssertLessThan(gapInArms, 0.4, "clears the planned 40%-of-arm trigger")
    }
}
