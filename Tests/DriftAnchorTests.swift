//
//  DriftAnchorTests.swift
//  FitnessTrackerTests
//

import XCTest
@testable import FitnessTracker

final class DriftAnchorTests: XCTestCase {

    private let acc: CGFloat = 1e-6

    /// The first observation seeds the baseline outright — an EMA with no prior
    /// has nothing to average against.
    func testFirstObservationSeedsTheBaseline() {
        var a = FrozenAnchor()
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.5, y: 0.5)), 0, accuracy: acc)
    }

    /// Alpha 0.3 means each new sample contributes 30%. Two samples: the
    /// baseline must sit 30% of the way from the first toward the second.
    func testBaselineTracksWithAlphaPointThree() {
        var a = FrozenAnchor(alpha: 0.3)
        a.updateBaseline(CGPoint(x: 0.0, y: 0.0))
        a.updateBaseline(CGPoint(x: 1.0, y: 0.0))
        // Baseline is now x = 0.3; drift from x = 0.3 must be zero.
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.3, y: 0.0)), 0, accuracy: acc)
    }

    /// THE CORE BEHAVIOUR. Once frozen, further observations must NOT move the
    /// baseline — otherwise the anchor chases the very drift it exists to
    /// measure, and a slow slide reads as zero drift forever.
    func testFreezingStopsTheBaselineFollowing() {
        var a = FrozenAnchor(alpha: 0.3)
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        a.updateBaseline(CGPoint(x: 0.9, y: 0.5))   // must be ignored
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.5)), 0.4, accuracy: acc)
        XCTAssertTrue(a.isFrozen)
    }

    /// Thawing resumes tracking, so the next lying/hang phase re-baselines.
    func testThawResumesTracking() {
        var a = FrozenAnchor(alpha: 1.0)            // alpha 1 = follow exactly
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        a.thaw()
        a.updateBaseline(CGPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.5)), 0, accuracy: acc)
    }

    /// Horizontal drift ignores vertical travel. This is what makes it usable on
    /// a pull-up, where the shoulders are SUPPOSED to move a long way up but the
    /// body is not supposed to swing forward and back.
    func testHorizontalDriftIgnoresVerticalTravel() {
        var a = FrozenAnchor()
        a.updateBaseline(CGPoint(x: 0.5, y: 0.5))
        a.freeze()
        XCTAssertEqual(a.horizontalDrift(from: CGPoint(x: 0.5, y: 0.9)), 0, accuracy: acc)
        XCTAssertEqual(a.horizontalDrift(from: CGPoint(x: 0.6, y: 0.9)), 0.1, accuracy: acc)
    }

    /// A baseline that was never seeded must report zero drift, not a huge one —
    /// firing a sway warning before the athlete has even been observed is noise.
    func testUnseededAnchorReportsNoDrift() {
        let a = FrozenAnchor()
        XCTAssertEqual(a.drift(from: CGPoint(x: 0.9, y: 0.9)), 0, accuracy: acc)
    }

    /// Drift is judged as a FRACTION of a skeletal segment, so the same bound
    /// works at any camera distance. Scale 0.2 with a 0.25 bound → trips at 0.05.
    func testSwayTripsOnlyBeyondTheNormalizedBound() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)   // seed baseline
        m.beginActivePhase()
        XCTAssertFalse(m.observe(CGPoint(x: 0.53, y: 0.5), scale: 0.2), "0.03 < 0.05 bound")
        XCTAssertTrue(m.observe(CGPoint(x: 0.60, y: 0.5), scale: 0.2), "0.10 > 0.05 bound")
    }

    /// The cue fires ONCE per active phase. A swinging athlete would otherwise
    /// be told "steady" on every one of 60 frames a second.
    func testSwayCueFiresOncePerActivePhase() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)
        m.beginActivePhase()
        XCTAssertTrue(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2))
        XCTAssertFalse(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2), "latched for this phase")

        m.endActivePhase()
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)   // re-baseline while idle
        m.beginActivePhase()
        XCTAssertTrue(m.observe(CGPoint(x: 0.9, y: 0.5), scale: 0.2), "new phase, cue re-arms")
    }

    /// A degenerate scale (missing/collapsed limb) must not divide by zero and
    /// must not fire — an unmeasurable body is not a swinging body.
    func testDegenerateScaleNeverFires() {
        var m = SwayMonitor(maxDriftFraction: 0.25)
        m.observe(CGPoint(x: 0.5, y: 0.5), scale: 0.2)
        m.beginActivePhase()
        XCTAssertFalse(m.observe(CGPoint(x: 0.99, y: 0.5), scale: 0))
    }
}
