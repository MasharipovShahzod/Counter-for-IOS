//
//  PoseGeometryTests.swift
//  FitnessTrackerTests
//
//  Covers the pure trigonometry every form check and rep decision rests on,
//  plus the fail-closed contract for degenerate and non-finite input.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

final class PoseGeometryTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    // MARK: - angle(_:_:_:)

    func testStraightLimbIsOneEightyDegrees() {
        // The case the brief worried about: perfectly aligned joints. acos's
        // argument lands exactly on -1 here, which is in-domain and safe — no
        // NaN, no clamp needed. This test pins that.
        let angle = PoseGeometry.angle(CGPoint(x: 0, y: 0),
                                       CGPoint(x: 1, y: 0),
                                       CGPoint(x: 2, y: 0))
        XCTAssertEqual(angle, 180, accuracy: acc)
        XCTAssertFalse(angle.isNaN, "Straight joints must never produce NaN")
    }

    func testRightAngle() {
        let angle = PoseGeometry.angle(CGPoint(x: 0, y: 1),
                                       CGPoint(x: 0, y: 0),
                                       CGPoint(x: 1, y: 0))
        XCTAssertEqual(angle, 90, accuracy: acc)
    }

    func testFullyFoldedLimbIsZeroDegrees() {
        // Both segments point the same way — a completely closed joint.
        let angle = PoseGeometry.angle(CGPoint(x: 1, y: 0),
                                       CGPoint(x: 0, y: 0),
                                       CGPoint(x: 2, y: 0))
        XCTAssertEqual(angle, 0, accuracy: acc)
    }

    func testAngleIsRotationInvariant() {
        // Joint angles must not depend on how the athlete is oriented in frame —
        // this is what lets the same thresholds work at any camera angle.
        let flat = PoseGeometry.angle(CGPoint(x: 0, y: 1),
                                      CGPoint(x: 0, y: 0),
                                      CGPoint(x: 1, y: 0))
        let rotated = PoseGeometry.angle(CGPoint(x: -1, y: 0),
                                         CGPoint(x: 0, y: 0),
                                         CGPoint(x: 0, y: 1))
        XCTAssertEqual(flat, rotated, accuracy: acc)
    }

    func testCoincidentVertexFailsClosed() {
        // Degenerate: vertex sits exactly on one endpoint, so one vector has zero
        // magnitude. Must return 0 ("fully bent"), which FAILS depth/lockout and
        // alignment comparisons rather than passing them.
        let angle = PoseGeometry.angle(CGPoint(x: 0, y: 0),
                                       CGPoint(x: 0, y: 0),
                                       CGPoint(x: 1, y: 0))
        XCTAssertEqual(angle, 0, accuracy: acc)
    }

    func testNonFiniteInputFailsClosed() {
        let nan = PoseGeometry.angle(CGPoint(x: .nan, y: 0),
                                     CGPoint(x: 1, y: 0),
                                     CGPoint(x: 2, y: 0))
        XCTAssertEqual(nan, 0, accuracy: acc)
        XCTAssertFalse(nan.isNaN, "NaN must be absorbed, never propagated")

        let inf = PoseGeometry.angle(CGPoint(x: 0, y: 0),
                                     CGPoint(x: .infinity, y: 0),
                                     CGPoint(x: 2, y: 0))
        XCTAssertEqual(inf, 0, accuracy: acc)
        XCTAssertFalse(inf.isNaN)
    }

    /// The reason the fail-closed direction matters at all: NaN loses every
    /// comparison, so a propagated NaN would silently DISABLE the anti-cheat
    /// gate instead of tripping it. This test documents that hazard directly.
    func testNaNWouldSilentlyPassComparisons() {
        let nan = CGFloat.nan
        XCTAssertFalse(nan < 147.25, "NaN < x is false — a sag check would pass")
        XCTAssertFalse(nan > 31.5, "NaN > x is false — a pitch check would pass")
        // Which is exactly why angle() returns 0 and torsoPitch() returns 90.
    }

    // MARK: - torsoPitch(shoulder:hip:)

    func testTorsoPitchHorizontalIsZero() {
        let pitch = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 0, y: 0.5),
                                            hip: CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(pitch, 0, accuracy: acc)
    }

    func testTorsoPitchVerticalIsNinety() {
        let pitch = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 0.5, y: 1),
                                            hip: CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(pitch, 90, accuracy: acc)
    }

    func testTorsoPitchFoldsPastNinety() {
        // Same physical tilt, opposite direction: a body lying head-left and
        // head-right are both horizontal. Folding is what makes the single
        // maxTorsoPitch threshold work regardless of which way the athlete faces.
        let leftward = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 1, y: 0),
                                               hip: CGPoint(x: 0, y: 0))
        XCTAssertEqual(leftward, 0, accuracy: acc)

        let diagonal = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 0, y: 0),
                                               hip: CGPoint(x: 1, y: 1))
        XCTAssertEqual(diagonal, 45, accuracy: acc)

        let mirrored = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 1, y: 1),
                                               hip: CGPoint(x: 0, y: 0))
        XCTAssertEqual(mirrored, 45, accuracy: acc)
    }

    func testTorsoPitchDegenerateFailsClosed() {
        // Shoulder exactly on hip is broken tracking, not a perfect plank.
        // Must return 90 (max tilt) so `pitch > maxTorsoPitch` REJECTS.
        let pitch = PoseGeometry.torsoPitch(shoulder: CGPoint(x: 0.5, y: 0.5),
                                            hip: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(pitch, 90, accuracy: acc)
    }

    func testTorsoPitchNonFiniteFailsClosed() {
        let pitch = PoseGeometry.torsoPitch(shoulder: CGPoint(x: .nan, y: 0.5),
                                            hip: CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(pitch, 90, accuracy: acc)
    }

    /// atan2 is the call the brief flagged as a NaN risk. It isn't: atan2(0,0)
    /// is defined as 0 by IEEE-754 and returns cleanly. Pinning that here so the
    /// guard above is understood as input validation, not a division-by-zero fix.
    func testAtan2AtOriginIsDefined() {
        let result = atan2(CGFloat(0), CGFloat(0))
        XCTAssertFalse(result.isNaN, "atan2(0,0) is defined as 0, not NaN")
        XCTAssertEqual(result, 0, accuracy: acc)
    }

    // MARK: - angleFromVertical(_:_:)

    func testAngleFromVerticalUprightIsZero() {
        let angle = PoseGeometry.angleFromVertical(CGPoint(x: 0.5, y: 0),
                                                   CGPoint(x: 0.5, y: 1))
        XCTAssertEqual(angle, 0, accuracy: acc)
    }

    func testAngleFromVerticalHorizontalIsNinety() {
        let angle = PoseGeometry.angleFromVertical(CGPoint(x: 0, y: 0.5),
                                                   CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(angle, 90, accuracy: acc)
    }

    func testAngleFromVerticalDiagonalIsFortyFive() {
        let angle = PoseGeometry.angleFromVertical(CGPoint(x: 0, y: 0),
                                                   CGPoint(x: 1, y: 1))
        XCTAssertEqual(angle, 45, accuracy: acc)
    }

    func testAngleFromVerticalDegenerateFailsClosed() {
        // Must return 90, so `lean > torsoLeanMax` trips rather than reporting a
        // flawless upright torso.
        let angle = PoseGeometry.angleFromVertical(CGPoint(x: 0.5, y: 0.5),
                                                   CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(angle, 90, accuracy: acc)
    }

    // MARK: - distance(_:_:)

    func testDistanceIsEuclidean() {
        let d = PoseGeometry.distance(CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4))
        XCTAssertEqual(d, 5, accuracy: acc)
    }

    func testDistanceNonFiniteIsZero() {
        let d = PoseGeometry.distance(CGPoint(x: .nan, y: 0), CGPoint(x: 3, y: 4))
        XCTAssertEqual(d, 0, accuracy: acc)
    }

    // MARK: - isFinite(_:)

    func testIsFinite() {
        XCTAssertTrue(PoseGeometry.isFinite(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(PoseGeometry.isFinite(CGPoint(x: .nan, y: 0.5)))
        XCTAssertFalse(PoseGeometry.isFinite(CGPoint(x: 0.5, y: .nan)))
        XCTAssertFalse(PoseGeometry.isFinite(CGPoint(x: .infinity, y: 0.5)))
        XCTAssertFalse(PoseGeometry.isFinite(CGPoint(x: 0.5, y: -.infinity)))
    }
}
