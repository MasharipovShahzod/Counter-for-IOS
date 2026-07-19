//
//  OneEuroFilterTests.swift
//  FitnessTrackerTests
//

import XCTest
@testable import FitnessTracker

final class OneEuroFilterTests: XCTestCase {

    private let acc: CGFloat = 1e-6

    /// The first sample has no history to blend with, so it passes through
    /// untouched. Anything else would mean the filter invents a value before it
    /// has seen the signal.
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.apply(0.7, at: 0), 0.7, accuracy: acc)
    }

    /// A constant signal must stay exactly constant — no drift, no ringing.
    func testConstantSignalIsUnchanged() {
        var f = OneEuroFilter()
        var t: TimeInterval = 0
        for _ in 0..<60 {
            XCTAssertEqual(f.apply(0.5, at: t), 0.5, accuracy: 1e-9)
            t += 1.0 / 60
        }
    }

    /// THE POINT OF THE FILTER. On a slow signal the adaptive cutoff stays low,
    /// so jitter is attenuated: the output must sit closer to the true value than
    /// the noisy sample does.
    func testSlowSignalIsSmoothed() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
        var t: TimeInterval = 0
        // Settle on the true value.
        for _ in 0..<30 { _ = f.apply(0.5, at: t); t += 1.0 / 60 }
        // A single noisy spike must be pulled back toward 0.5.
        let out = f.apply(0.6, at: t)
        XCTAssertLessThan(out, 0.6, "spike must be attenuated")
        XCTAssertGreaterThan(out, 0.5, "but not ignored entirely")
    }

    /// THE OTHER POINT. On a fast movement the cutoff rises with speed, so the
    /// filter tracks rather than lags — this is what stops late peak detection on
    /// fast reps. A high beta must follow a ramp more closely than a zero beta.
    func testFastSignalLagsLessWithHigherBeta() {
        func finalValue(beta: CGFloat) -> CGFloat {
            var f = OneEuroFilter(minCutoff: 1.0, beta: beta)
            var t: TimeInterval = 0
            var out: CGFloat = 0
            for i in 0..<20 {                    // steep ramp: 0 → 2.0
                out = f.apply(CGFloat(i) * 0.1, at: t)
                t += 1.0 / 60
            }
            return out
        }
        XCTAssertGreaterThan(finalValue(beta: 5.0), finalValue(beta: 0.0),
                             "speed-adaptive cutoff must reduce lag on fast motion")
    }

    /// Vision can hand us the same timestamp twice under backpressure. A zero or
    /// negative dt would divide by zero and poison the state with NaN forever.
    func testNonAdvancingTimeIsRejectedNotDividedBy() {
        var f = OneEuroFilter()
        _ = f.apply(0.5, at: 10)
        let out = f.apply(0.9, at: 10)          // same timestamp
        XCTAssertTrue(out.isFinite, "must never emit NaN/inf on a zero dt")
    }

    /// Reset must clear history, so the next sample passes through as a first
    /// sample again. Without this a re-armed analyzer inherits the last rep's tail.
    func testResetClearsHistory() {
        var f = OneEuroFilter()
        var t: TimeInterval = 0
        for _ in 0..<30 { _ = f.apply(0.5, at: t); t += 1.0 / 60 }
        f.reset()
        XCTAssertEqual(f.apply(0.9, at: t), 0.9, accuracy: acc)
    }

    /// The point filter must be exactly two independent scalar filters.
    func testPointFilterFiltersAxesIndependently() {
        var pf = OneEuroPointFilter()
        var fx = OneEuroFilter()
        var fy = OneEuroFilter()
        var t: TimeInterval = 0
        for i in 0..<20 {
            let p = CGPoint(x: CGFloat(i) * 0.01, y: 0.5)
            let got = pf.apply(p, at: t)
            let wantX = fx.apply(p.x, at: t)
            let wantY = fy.apply(p.y, at: t)
            XCTAssertEqual(got.x, wantX, accuracy: acc)
            XCTAssertEqual(got.y, wantY, accuracy: acc)
            t += 1.0 / 60
        }
    }
}
