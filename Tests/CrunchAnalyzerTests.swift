//
//  CrunchAnalyzerTests.swift
//  FitnessTrackerTests
//

import XCTest
import CoreGraphics
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
