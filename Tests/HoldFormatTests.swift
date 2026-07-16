//
//  HoldFormatTests.swift
//  FitnessTrackerTests
//
//  The one piece of testable logic in the plank HUD: the M:SS formatter. The
//  ring and its animations are SwiftUI and out of unit-test reach, but the
//  string the athlete reads is pure and worth pinning — a "1:5" instead of
//  "1:05" is exactly the kind of bug that ships unnoticed.
//

import XCTest
@testable import FitnessTracker

final class HoldFormatTests: XCTestCase {

    func testZero() {
        XCTAssertEqual(WorkoutViewModel.formatHold(0), "0:00")
    }

    func testSecondsAreZeroPadded() {
        XCTAssertEqual(WorkoutViewModel.formatHold(5), "0:05")
        XCTAssertEqual(WorkoutViewModel.formatHold(9), "0:09")
    }

    func testUnderAMinute() {
        XCTAssertEqual(WorkoutViewModel.formatHold(45), "0:45")
        XCTAssertEqual(WorkoutViewModel.formatHold(59), "0:59")
    }

    func testMinuteRollover() {
        XCTAssertEqual(WorkoutViewModel.formatHold(60), "1:00")
        XCTAssertEqual(WorkoutViewModel.formatHold(61), "1:01")
        XCTAssertEqual(WorkoutViewModel.formatHold(75), "1:15")
    }

    func testMultipleMinutes() {
        XCTAssertEqual(WorkoutViewModel.formatHold(630), "10:30")
    }

    func testFractionalSecondsTruncateTowardZero() {
        // The ring is fed whole-second-quantized values, but the formatter must
        // not round 59.9 up to "1:00" and skip a second visually.
        XCTAssertEqual(WorkoutViewModel.formatHold(59.9), "0:59")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(WorkoutViewModel.formatHold(-3), "0:00")
    }
}
