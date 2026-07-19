//
//  ExerciseThresholdsTests.swift
//  FitnessTrackerTests
//
//  Pins the ±5% tolerance arithmetic against the numbers the spec states
//  literally, and guards the hysteresis invariant that the tolerance threatens.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

final class ToleranceTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    /// The spec's own worked examples. If these drift, the brief and the code
    /// have silently diverged.
    func testMatchesSpecStatedNumbers() {
        // "Elbow close to 180 degrees (apply ±5% tolerance, detecting 171-180)"
        XCTAssertEqual(Tolerance.atLeast(180), 171, accuracy: acc)
        // "90 degrees or less (apply +5% tolerance, triggering up to 94.5)"
        XCTAssertEqual(Tolerance.atMost(90), 94.5, accuracy: acc)
    }

    func testDirections() {
        // "At least" loosens DOWNWARD (easier to reach).
        XCTAssertLessThan(Tolerance.atLeast(170), 170)
        // "At most" loosens UPWARD (easier to reach).
        XCTAssertGreaterThan(Tolerance.atMost(90), 90)
    }

    func testInfinitySentinelPassesThrough() {
        // `.infinity` marks "this constraint doesn't apply to this exercise".
        // Tolerance must not turn it into a real, enforceable bound.
        XCTAssertEqual(Tolerance.atLeast(.infinity), .infinity)
        XCTAssertEqual(Tolerance.atMost(.infinity), .infinity)
    }

    /// Documents the dimensional oddity rather than hiding it: a percentage of
    /// an angle gives a window whose size depends on the angle's magnitude.
    func testToleranceWindowScalesWithAngle() {
        XCTAssertEqual(180 - Tolerance.atLeast(180), 9, accuracy: acc)
        XCTAssertEqual(Tolerance.atMost(90) - 90, 4.5, accuracy: acc)
    }
}

final class ExerciseThresholdsTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    // MARK: - Derived values

    func testPushUpEffectiveAngles() {
        let t = ExerciseType.pushUp.repThresholds!
        XCTAssertEqual(t.depthAngle, 94.5, accuracy: acc)        // 90 nominal
        XCTAssertEqual(t.lockoutAngle, 156.75, accuracy: acc)    // 165 nominal
        XCTAssertEqual(t.supportAngleMin, 147.25, accuracy: acc) // 155 nominal
        XCTAssertEqual(t.maxTorsoPitch, 31.5, accuracy: acc)     // 30 nominal
        XCTAssertEqual(t.torsoLeanMax, .infinity)                // N/A for push-ups
        XCTAssertEqual(t.reversalMargin, 12, accuracy: acc)      // a delta — untolerated
    }

    func testSquatEffectiveAngles() {
        let t = ExerciseType.squat.repThresholds!
        XCTAssertEqual(t.depthAngle, 94.5, accuracy: acc)      // 90 nominal
        XCTAssertEqual(t.lockoutAngle, 161.5, accuracy: acc)   // 170 nominal
        XCTAssertEqual(t.torsoLeanMax, 57.75, accuracy: acc)   // 55 nominal
        XCTAssertEqual(t.supportAngleMin, .infinity)           // N/A for squats
        XCTAssertEqual(t.maxTorsoPitch, .infinity)             // N/A for squats
    }

    // MARK: - The invariant the tolerance threatens

    /// THE REGRESSION GUARD FOR THIS WHOLE CHANGE.
    ///
    /// `descentStartAngle` and `lockoutAngle` are the two ends of a hysteresis
    /// band: you must extend past lockout to finish a rep, then bend back below
    /// descentStart to open the next one. Tolerating both ends drives them
    /// TOWARD each other, because "at least" loosens down while "at most"
    /// loosens up.
    ///
    /// Applied naively to the tuned values, the band inverts for push-ups
    /// (lockout 165→156.75 landing BELOW descentStart 150→157.5), which would
    /// let one jittering frame credit a rep and immediately open the next —
    /// a rep counter that free-runs while the athlete holds still. Squats fare
    /// no better: the band collapses from 10° to 1.5°, well inside camera noise.
    ///
    /// `ExerciseThresholds` therefore derives descentStart from the tolerated
    /// lockout. This test fails if anyone reverts that.
    func testHysteresisBandSurvivesTolerance() {
        for exercise in ExerciseType.allCases {
            // Holds have no descent gate to protect.
            guard let t = exercise.repThresholds else { continue }
            let band = t.lockoutAngle - t.descentStartAngle
            XCTAssertGreaterThanOrEqual(
                band, ExerciseThresholds.minimumHysteresisBand,
                "\(exercise.rawValue): hysteresis band collapsed to \(band)° — "
                    + "the rep counter can credit and restart on one noisy frame"
            )
        }
    }

    func testDescentStartNeverExceedsTheAuthorsCeiling() {
        // The derivation may lower the gate to protect the band, but must never
        // raise it above what the exercise author declared.
        XCTAssertLessThanOrEqual(ExerciseType.pushUp.repThresholds!.descentStartAngle, 150)
        XCTAssertLessThanOrEqual(ExerciseType.squat.repThresholds!.descentStartAngle, 160)
    }

    func testDerivedDescentStartValues() {
        // push-up: min(150, 156.75 - 10) = 146.75
        XCTAssertEqual(ExerciseType.pushUp.repThresholds!.descentStartAngle, 146.75, accuracy: acc)
        // squat: min(160, 161.5 - 10) = 151.5 — the nominal 160 gate WAS lowered
        // here; without it the band would have been 1.5°.
        XCTAssertEqual(ExerciseType.squat.repThresholds!.descentStartAngle, 151.5, accuracy: acc)
    }

    func testDepthIsAlwaysReachableBeforeDescentStarts() {
        // A rep must be able to pass through the descent gate before it can hit
        // depth, or the machine could register depth without ever opening an
        // attempt.
        for exercise in ExerciseType.allCases {
            guard let t = exercise.repThresholds else { continue }
            XCTAssertLessThan(t.depthAngle, t.descentStartAngle,
                              "\(exercise.rawValue): depth target sits above the descent gate")
        }
    }

    func testUnusedMaxConstraintsNeverTrip() {
        // For "at most" bounds, `.infinity` correctly means "never trips":
        // the caller asks `value > bound`, and nothing exceeds infinity.
        let squat = ExerciseType.squat.repThresholds!
        XCTAssertFalse(180 > squat.maxTorsoPitch, "an infinite pitch bound must never trip")

        let pushUp = ExerciseType.pushUp.repThresholds!
        XCTAssertFalse(90 > pushUp.torsoLeanMax, "an infinite lean bound must never trip")
    }

    /// DOCUMENTS A LATENT TRAP, inherited and deliberately left in place.
    ///
    /// `supportAngleMin` is a MINIMUM, tested as `angle < supportAngleMin`. The
    /// disabled sentinel is `+.infinity`, so every angle is below it and the
    /// check would report "sagging" on every single frame if it were ever
    /// switched on. Disabling a minimum requires `-.infinity`, not `+.infinity`.
    ///
    /// This is harmless today only because the exercises carrying the sentinel
    /// never run the support check. Plank does check shoulder–hip–knee, and this
    /// trap is exactly why it carries its own `PlankConfig.minSpineAngle` rather
    /// than reaching for this field. The landmine stays armed for whoever adds
    /// the next exercise.
    func testSupportAngleMinSentinelIsInvertedAndOnlySafeBecauseItIsUnused() {
        let squat = ExerciseType.squat.repThresholds!
        XCTAssertEqual(squat.supportAngleMin, .infinity)

        // A perfectly straight back reads as sagging against this sentinel:
        XCTAssertTrue(180 < squat.supportAngleMin,
                      "a +infinity minimum flags even a flawless 180° back as sagging")

        // The only reason that's safe: SquatAnalyzer never consults it. Push-ups
        // (which do) carry a real, finite bound.
        XCTAssertTrue(ExerciseType.pushUp.repThresholds!.supportAngleMin.isFinite,
                      "the exercise that USES this check must have a real bound")
    }

    /// Spec §4: dips top relaxes from a locked 180° to 165°, and the bottom from
    /// a punishing 90° to 98°. Both are stated as EFFECTIVE (post-tolerance)
    /// bounds, so the nominal declarations are pre-divided by the tolerance.
    func testDipsUseTheRelaxedSpecBounds() {
        let t = ExerciseType.dips.repThresholds!
        XCTAssertEqual(t.lockoutAngle, 165, accuracy: 0.5)
        XCTAssertEqual(t.depthAngle, 98, accuracy: 0.5)
    }

    /// Spec §4: the pull-up dead hang relaxes from a strict 180° to 160°, so an
    /// athlete who does not fully lock out at the bottom still re-arms.
    func testPullUpHangUsesTheRelaxedSpecBound() {
        let t = ExerciseType.pullUp.repThresholds!
        XCTAssertEqual(t.lockoutAngle, 160, accuracy: 0.5)
    }

    /// The hysteresis band must survive the relaxation — a descent gate at or
    /// above the lockout would credit and restart a rep on one jittering frame.
    func testRelaxedDipsKeepTheirHysteresisBand() {
        let t = ExerciseType.dips.repThresholds!
        XCTAssertLessThanOrEqual(t.descentStartAngle,
                                 t.lockoutAngle - ExerciseThresholds.minimumHysteresisBand)
    }
}
