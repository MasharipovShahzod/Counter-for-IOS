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

    // All poses share hip (0.50, 0.40) and knee (0.64, 0.54), giving a thigh of
    // 0.19799. The shoulder sits at 1.2 thigh-lengths from the hip — the
    // torso:thigh ratio `CrunchConfig`'s own derivation assumes for real
    // anatomy. An earlier revision used a 1.01 ratio, which distorted every hip
    // angle and let a gate that rejected spec-conformant reps look correct.

    /// Flat on the floor, knees bent with feet planted — the standard setup.
    /// Hip angle 135.000°, clearing the 126° lying gate.
    static func lying() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.2624, y: 0.4000),
            elbow:    CGPoint(x: 0.3200, y: 0.3400),
            wrist:    CGPoint(x: 0.3900, y: 0.3600),
            hip:      CGPoint(x: 0.5000, y: 0.4000),
            knee:     CGPoint(x: 0.6400, y: 0.5400),   // thigh up ~45°
            ankle:    CGPoint(x: 0.7200, y: 0.4000),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// A strong crunch: hip angle 110.000°, comfortably inside the 116° gate.
    static func peak() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.2847, y: 0.5004),
            elbow:    CGPoint(x: 0.3400, y: 0.4500),
            wrist:    CGPoint(x: 0.4100, y: 0.4600),
            hip:      CGPoint(x: 0.5000, y: 0.4000),
            knee:     CGPoint(x: 0.6400, y: 0.5400),
            ankle:    CGPoint(x: 0.7200, y: 0.4000),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// EXACTLY the rep the spec describes, and no more: shoulders travelling
    /// 40% of a thigh length about a 1.2-thigh torso is 0.4/1.2 rad ≈ 19.1° of
    /// closure, which from a 135° rest lands at 115.985°.
    ///
    /// This fixture exists to pin the gate to the spec. It must COUNT. The gate
    /// was previously 112°, four degrees inside this pose, so an athlete doing
    /// precisely what the spec asks scored zero — and no fixture then existed to
    /// notice.
    static func specBoundaryPeak() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.2754, y: 0.4774),
            elbow:    CGPoint(x: 0.3350, y: 0.4400),
            wrist:    CGPoint(x: 0.4050, y: 0.4500),
            hip:      CGPoint(x: 0.5000, y: 0.4000),
            knee:     CGPoint(x: 0.6400, y: 0.5400),
            ankle:    CGPoint(x: 0.7200, y: 0.4000),
            minConfidence: 0.9,
            side: .right
        )
    }

    /// A partial curl that must NOT count: 120.993°, short of the 116° gate but
    /// past the 126° lying gate, so it is neither lying nor a peak.
    static func halfway() -> BodyJoints {
        BodyJoints(
            shoulder: CGPoint(x: 0.2695, y: 0.4575),
            elbow:    CGPoint(x: 0.3300, y: 0.4200),
            wrist:    CGPoint(x: 0.4000, y: 0.4300),
            hip:      CGPoint(x: 0.5000, y: 0.4000),
            knee:     CGPoint(x: 0.6400, y: 0.5400),
            ankle:    CGPoint(x: 0.7200, y: 0.4000),
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

// MARK: - FSM

final class CrunchAnalyzerTests: XCTestCase {

    /// Feeds one pose repeatedly so the 1€ filter settles, and collects events.
    @discardableResult
    private func feed(_ a: CrunchAnalyzer,
                      _ j: BodyJoints,
                      frames: Int = 12,
                      from t: inout TimeInterval) -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        for _ in 0..<frames {
            events += a.analyze(frame: PoseFrame(unilateral: j, time: t))
            t += 1.0 / 30
        }
        return events
    }

    private func repCount(_ events: [AnalyzerEvent]) -> Int {
        events.reduce(0) { n, e in
            if case .repCompleted = e { return n + 1 }
            return n
        }
    }

    private func sawWarning(_ events: [AnalyzerEvent]) -> Bool {
        events.contains { e in
            if case .invalidRep(_, let severity) = e { return severity == .warning }
            if case .coachingCue = e { return true }
            return false
        }
    }

    /// THE HAPPY PATH: lying → peak → lying credits exactly one rep.
    func testFullCycleCountsOneRep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.peak(), from: &t)
        let closing = feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(repCount(closing), 1)
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// Returning to lying without ever reaching the peak is a half-rep. It must
    /// not count.
    func testPartialCurlDoesNotCount() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.halfway(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0)
    }

    /// ARMING. Walking into frame already curled up must not pay out a rep on
    /// the way down — a repetition starts at the start position, by definition.
    func testStartingAtThePeakDoesNotCreditARep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.peak(), from: &t)      // never seen lying
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0)
    }

    /// Three clean cycles, three reps. Catches a machine that credits on every
    /// frame at the top or fails to re-arm.
    func testThreeCyclesCountThreeReps() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        for _ in 0..<3 {
            feed(a, CrunchFixtures.peak(), from: &t)
            feed(a, CrunchFixtures.lying(), from: &t)
        }
        XCTAssertEqual(a.successfulReps, 3)
    }

    /// THE PHONE-TILT GUARANTEE, end to end. The same repetition filmed with the
    /// phone propped at 45° must produce the same count. A floor-relative
    /// driving angle fails this test; that is why it exists.
    func testRepCountIsUnchangedByPhoneTilt() {
        func count(tilt: CGFloat) -> Int {
            let a = CrunchAnalyzer()
            var t: TimeInterval = 0
            feed(a, CrunchFixtures.rotated(CrunchFixtures.lying(), byDegrees: tilt), from: &t)
            feed(a, CrunchFixtures.rotated(CrunchFixtures.peak(), byDegrees: tilt), from: &t)
            feed(a, CrunchFixtures.rotated(CrunchFixtures.lying(), byDegrees: tilt), from: &t)
            return a.successfulReps
        }
        XCTAssertEqual(count(tilt: 0), 1)
        XCTAssertEqual(count(tilt: 45), 1, "a 45-degree phone tilt must not change the count")
        XCTAssertEqual(count(tilt: -30), 1)
    }

    /// Sliding on the mat during the ascent fires the sway cue...
    func testHipSlideDuringAscentFiresTheSwayCue() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        let slidPeak = CrunchFixtures.slid(CrunchFixtures.peak(), byX: 0.12)
        let events = feed(a, slidPeak, from: &t)
        XCTAssertTrue(sawWarning(events), "structural drift must be reported")
    }

    /// ...but MUST NOT cost the athlete the rep. This is the spec's
    /// non-blocking requirement, and the one most likely to regress silently.
    func testSwayCueDoesNotCancelTheRep() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.slid(CrunchFixtures.peak(), byX: 0.12), from: &t)
        feed(a, CrunchFixtures.slid(CrunchFixtures.lying(), byX: 0.12), from: &t)
        XCTAssertEqual(a.successfulReps, 1, "sway warns; it never voids a rep")
    }

    /// THE SPEC BOUNDARY. A rep that closes exactly as far as the spec
    /// describes — shoulders travelling 40% of a thigh length — must count.
    ///
    /// This is the regression test for a gate set 4° tighter than the movement
    /// it was derived from. With `peakHipAngle` at 112 this failed, while every
    /// other test passed, because the `peak()` fixture was a near-full sit-up.
    func testSpecConformantRepCounts() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        // 30 frames (~1s) rather than the usual 12: this pose sits 0.015° inside
        // the gate, so the filter needs to settle almost completely to register
        // it — it crosses at frame 14. A real athlete pauses at the top, so a
        // held peak is the realistic case. At the previous beta of 0.35 this
        // never crossed at all, at any duration.
        feed(a, CrunchFixtures.specBoundaryPeak(), frames: 30, from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 1,
                       "a rep matching the spec's own definition must be credited")
    }

    /// A mid-rep tracking gap must void the attempt AND disarm the machine, so
    /// the athlete has to be seen lying again before anything counts.
    ///
    /// This is an anti-cheat surface: without the disarm, someone could reach
    /// the peak, step out of frame, step back in flat, and be paid for a rep
    /// whose return journey was never observed.
    func testTrackingLossVoidsTheAttemptAndDisarms() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.peak(), from: &t)      // mid-rep, at the apex

        _ = a.trackingLost()

        // Coming back flat must NOT close the interrupted attempt.
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0, "an unobserved return cannot be credited")

        // And a full clean cycle afterwards must still work.
        feed(a, CrunchFixtures.peak(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 1, "the machine must re-arm normally")
    }

    /// Frames below the confidence floor must keep reporting progress rather
    /// than returning nothing. An empty event list reads to the manager as
    /// "nothing happened", not as tracking loss, which froze the HUD.
    func testLowConfidenceFrameStillReportsProgress() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        let dim = BodyJoints(
            shoulder: CGPoint(x: 0.2624, y: 0.4000),
            elbow:    CGPoint(x: 0.3200, y: 0.3400),
            wrist:    CGPoint(x: 0.3900, y: 0.3600),
            hip:      CGPoint(x: 0.5000, y: 0.4000),
            knee:     CGPoint(x: 0.6400, y: 0.5400),
            ankle:    CGPoint(x: 0.7200, y: 0.4000),
            minConfidence: 0.35,          // inside the [0.3, 0.4) dead zone
            side: .right
        )
        let events = feed(a, dim, frames: 3, from: &t)
        XCTAssertFalse(events.isEmpty,
                       "a declined frame must still drive the HUD, or the ring freezes")
    }

    /// A clean crunch must not be nagged about sway. A monitor that fires on
    /// every rep is noise the athlete learns to ignore.
    func testCleanCrunchDoesNotFireTheSwayCue() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        var events = feed(a, CrunchFixtures.lying(), from: &t)
        events += feed(a, CrunchFixtures.peak(), from: &t)
        events += feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertFalse(sawWarning(events), "a still crunch must not be flagged")
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// Reset must zero everything, including the filter and the anchor.
    func testResetClearsCountAndState() {
        let a = CrunchAnalyzer()
        var t: TimeInterval = 0
        feed(a, CrunchFixtures.lying(), from: &t)
        feed(a, CrunchFixtures.peak(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 1)
        a.reset()
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertEqual(a.state, .ready)

        // Assert BEHAVIOURALLY, not just on the two public counters: a reset
        // that forgot to clear `isArmed` would pass those and then credit a rep
        // for a curl it never saw start from flat.
        feed(a, CrunchFixtures.peak(), from: &t)
        feed(a, CrunchFixtures.lying(), from: &t)
        XCTAssertEqual(a.successfulReps, 0,
                       "reset must disarm, so a curl-first sequence pays nothing")
    }
}
