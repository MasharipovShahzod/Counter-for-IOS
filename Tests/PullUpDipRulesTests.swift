//
//  PullUpDipRulesTests.swift
//  ExerciseTrackerTests
//
//  The tracking rules added for the front-view pull-up and side-view dip:
//  the disjunctive peak trigger, the scale-invariant anti-jump gate, the dip's
//  soft depth and foot-plant check, the derived `RepPhase`, and the tiered
//  capture resolutions.
//
//  Every threshold asserted here is the spec's own number, and each is pinned
//  BOTH as a constant (so a silent retune fails) and behaviourally (so a
//  constant that stops being read fails too). A threshold test that only reads
//  the constant is satisfied by dead code.
//

import XCTest
import CoreGraphics
import AVFoundation
@testable import FitnessTracker

// MARK: - Pull-up: disjunctive peak trigger

final class PullUpPeakTriggerTests: XCTestCase {

    /// Enough frames to clear the 1.0s bar-lock window at 30fps, with margin.
    private let lockFrames = 40

    func testPeakElbowGateIsEightyDegrees() {
        XCTAssertEqual(PullUpConfig.standard.peakElbowAngle, 80, accuracy: 0.0001)
    }

    /// DISJUNCT (a) IN ISOLATION. The shoulders stay 0.6 of an arm below the bar
    /// — well outside the 0.525 shoulder trigger — so the only thing that can
    /// credit this rep is the elbow closing past 80°.
    func testElbowClosureAloneCreditsARep() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        XCTAssertTrue(a.isBarLocked)

        feed(a, Pose.pulledByElbowsOnly(elbowDegrees: 75), frames: 20, clock: clock)
        feed(a, Pose.hang(), frames: 20, clock: clock)

        XCTAssertEqual(a.successfulReps, 1,
                       "elbows closed to 75° must count even with the shoulders far from the bar")
    }

    /// DISJUNCT (b) IN ISOLATION. `pulledUp()` sits at 0.35 arm-spans below the
    /// bar (inside the 0.525 trigger) with the elbows at 90° — above the 80°
    /// gate — so only the shoulder disjunct can fire.
    func testShoulderTravelAloneCreditsARep() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        feed(a, Pose.pulledUp(), frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(a.successfulReps, 1,
                       "shoulders inside the trigger must count even with elbows above 80°")
    }

    /// NEITHER disjunct: shoulders outside the trigger AND elbows above the gate.
    /// This is the control that proves the OR is not simply always true.
    func testNeitherTriggerCreditsNothing() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        feed(a, Pose.pulledByElbowsOnly(elbowDegrees: 85), frames: 20, clock: clock)
        let events = feed(a, Pose.hang(), frames: 20, clock: clock)

        XCTAssertEqual(a.successfulReps, 0,
                       "85° elbows with the shoulders 0.6 arms low satisfies neither disjunct")
        XCTAssertTrue(events.invalidFeedback.contains { $0.contains("Pull higher") })
    }

    /// THE FAIL-OPEN REGRESSION. `PoseGeometry.angle` returns 0 for degenerate
    /// joints, and the peak gate is `elbow <= 80`, so `0 <= 80` is TRUE: without
    /// an explicit trust check one broken-but-finite frame certifies a maximal
    /// contraction and buys a rep that never happened.
    ///
    /// This is the exact shape of a bug this project has already shipped once,
    /// on the crunch and dip depth gates. See `PoseGeometry.isTrustworthyAngle`.
    func testDegenerateElbowsCannotCertifyAPeak() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        XCTAssertTrue(a.isBarLocked)

        // Finite, confident, and utterly broken: every guard upstream passes it.
        feed(a, Pose.degenerateElbows(), frames: 20, clock: clock)
        feed(a, Pose.hang(), frames: 20, clock: clock)

        XCTAssertEqual(a.successfulReps, 0,
                       "the 0 sentinel must not read as a maximal contraction")
    }

    /// The smoothing filter must not launder a degenerate frame either: a single
    /// 0 blended with a 180° hang emits ≈72°, which is both above the sentinel
    /// and under the 80° gate. Guarding only the filter's output would let this
    /// through.
    func testASingleDegenerateFrameCannotCertifyAPeak() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        // Exactly one broken frame, surrounded by honest hangs.
        _ = a.analyze(frame: PoseFrame(bilateral: Pose.degenerateElbows(), time: clock.tick()))
        feed(a, Pose.hang(), frames: 20, clock: clock)

        XCTAssertEqual(a.successfulReps, 0,
                       "one degenerate frame must not survive the EMA as a valid peak")
    }
}

// MARK: - Pull-up: anti-jump

final class PullUpAntiJumpTests: XCTestCase {

    private let lockFrames = 40

    func testJumpBoundIsFifteenPercentOfHangLength() {
        XCTAssertEqual(PullUpConfig.standard.jumpDriftArmFraction, 0.15, accuracy: 0.0001)
    }

    /// The bound is TIGHTER than the lock-drop bound, so a jump voids one rep
    /// rather than tearing down the bar lock the athlete earned.
    func testJumpBoundIsTighterThanTheLockDropBound() {
        let c = PullUpConfig.standard
        XCTAssertLessThan(c.jumpDriftArmFraction, c.barDriftArmFraction)
    }

    /// Arm span calibrates to 0.4 at the hang, so the jump bound is 0.06 and the
    /// lock-drop bound is 0.10. A 0.08 lift sits between them: the rep is voided,
    /// the lock survives.
    func testWristDriftBeyondTheBoundVoidsTheRep() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        let jumped = Pose.liftedVertically(Pose.pulledUp(), byY: 0.08)
        let pull = feed(a, jumped, frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(a.successfulReps, 0, "a jumped rep must not be credited")
        XCTAssertTrue(pull.invalidFeedback.contains { $0.contains("jump") },
                      "the athlete must be told why")
        XCTAssertTrue(pull.severities.contains(.critical))
        XCTAssertTrue(a.isBarLocked, "voiding a rep must not cost the bar lock")
    }

    /// A body that stays on the bar keeps its rep. 0.04 is inside the 0.06 bound.
    func testWristDriftWithinTheBoundStillCounts() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        feed(a, Pose.liftedVertically(Pose.pulledUp(), byY: 0.04), frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(a.successfulReps, 1, "normal settling on the bar is not a jump")
    }

    /// A jump latches: returning to the bar before lockout does not buy the rep
    /// back. Otherwise the cheat is simply "jump, then land before finishing".
    func testAJumpCannotBeUndoneBeforeLockout() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        feed(a, Pose.liftedVertically(Pose.pulledUp(), byY: 0.08), frames: 6, clock: clock)
        feed(a, Pose.pulledUp(), frames: 12, clock: clock)   // back on the bar, still at the top
        feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(a.successfulReps, 0)
    }

    /// SCALE INVARIANCE — the property that makes this a body-normalized check
    /// rather than a screen-percentage one.
    ///
    /// The SAME absolute drift (0.04) is judged differently at two camera
    /// distances: safe for an athlete whose arm span images at 0.4, a jump for
    /// one at 0.2. A raw screen percentage could not tell these apart, and would
    /// be simultaneously too strict up close and too lax far away.
    func testTheJumpBoundScalesWithTheAthleteNotTheScreen() {
        // Far framing: arm span 0.4 → bound 0.06. 0.04 is safe.
        let farClock = FakeClock()
        let far = PullUpAnalyzer()
        feed(far, Pose.hang(), frames: lockFrames, clock: farClock)
        feed(far, Pose.liftedVertically(Pose.pulledUp(), byY: 0.04), frames: 12, clock: farClock)
        feed(far, Pose.hang(), frames: 12, clock: farClock)
        XCTAssertEqual(far.successfulReps, 1, "0.04 is within 15% of a 0.4 arm span")

        // Near framing: arm span 0.2 → bound 0.03. The identical 0.04 is a jump.
        let nearClock = FakeClock()
        let near = PullUpAnalyzer()
        let nearHang = Pose.pullUp(shoulderY: 0.70, elbowDegrees: 180, wristY: 0.9)
        let nearTop  = Pose.pullUp(shoulderY: 0.80, elbowDegrees: 90,  wristY: 0.9)
        feed(near, nearHang, frames: lockFrames, clock: nearClock)
        XCTAssertTrue(near.isBarLocked)
        feed(near, Pose.liftedVertically(nearTop, byY: 0.04), frames: 12, clock: nearClock)
        feed(near, nearHang, frames: 12, clock: nearClock)
        XCTAssertEqual(near.successfulReps, 0, "0.04 exceeds 15% of a 0.2 arm span")
    }
}

// MARK: - Dips: foot-plant anti-cheat

final class DipFootPlantTests: XCTestCase {

    func testFootPlantConstantsMatchTheSpec() {
        let c = DipsConfig.standard
        XCTAssertEqual(c.footPlantTravelRatio, 0.35, accuracy: 0.0001)
        XCTAssertEqual(c.minAnkleCoverage, 0.80, accuracy: 0.0001)
    }

    /// A real dip carries the ankles down with the shoulders: ratio ≈ 1.
    func testHonestDipCountsWhenAnklesFallWithTheShoulders() {
        let a = DipsAnalyzer()
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(a, Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.05, ankleConfidence: 0.9))
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))

        XCTAssertEqual(a.successfulReps, 1, "ankles travelling with the shoulders is a real dip")
    }

    /// THE CHEAT. Elbows sweep the full range, torso stays upright, depth is
    /// reached — every angular gate passes — but the ankles never move, because
    /// the feet are on the floor taking the load.
    func testFootPlantedDipIsRejectedAndCuesGrounded() {
        let a = DipsAnalyzer()
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(a, Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.15, ankleConfidence: 0.9))
        let events = feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15,
                                           ankleConfidence: 0.9))

        XCTAssertEqual(a.successfulReps, 0, "a rep carried by the feet must not count")
        XCTAssertTrue(events.coachingCues.contains(.grounded), "the GROUNDED cue must fire")
        XCTAssertTrue(events.cueSeverities.contains(.critical),
                      "GROUNDED voids a rep, so it is critical, not advisory")
    }

    /// The ratio boundary, from both sides. Shoulder travel is 0.10 throughout,
    /// so the ankle travel alone decides.
    func testFootPlantRatioBoundary() {
        // 0.03 / 0.10 = 0.30 — below 0.35, a cheat.
        let below = DipsAnalyzer()
        feed(below, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(below, Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.12, ankleConfidence: 0.9))
        feed(below, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        XCTAssertEqual(below.successfulReps, 0, "ratio 0.30 is a foot plant")

        // 0.04 / 0.10 = 0.40 — above 0.35, an honest (if stiff-legged) rep.
        let above = DipsAnalyzer()
        feed(above, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(above, Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.11, ankleConfidence: 0.9))
        feed(above, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        XCTAssertEqual(above.successfulReps, 1, "ratio 0.40 clears the gate")
    }

    /// FAIL-OPEN 1: low-confidence ankles. The ankle is pinned exactly as in the
    /// cheat above, but nothing vouches for the reading — so the check must stand
    /// down rather than punish an honest athlete whose legs are out of frame.
    func testCheckFailsOpenWhenAnklesAreNotConfident() {
        let a = DipsAnalyzer()
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.1))
        feed(a, Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.15, ankleConfidence: 0.1))
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.1))

        XCTAssertEqual(a.successfulReps, 1,
                       "an unvouched ankle is not evidence of cheating")
    }

    /// FAIL-OPEN 2: the ankle drops in and out of view, landing under the 80%
    /// coverage floor. Same pinned ankle; still credited.
    func testCheckFailsOpenBelowTheCoverageFloor() {
        let a = DipsAnalyzer()
        let clock = FakeClock()
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9),
             clock: clock)

        // Alternate confident / unconfident ankles through the descent → ≈50%.
        for i in 0..<20 {
            let conf: Float = (i % 2 == 0) ? 0.9 : 0.0
            _ = a.analyze(frame: PoseFrame(
                unilateral: Pose.dipsBody(elbow: 100, shoulderY: 0.45, ankleY: 0.15,
                                          ankleConfidence: conf),
                time: clock.tick()))
        }
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9),
             clock: clock)

        XCTAssertEqual(a.successfulReps, 1,
                       "under 80% ankle coverage the ratio is not trusted")
    }

    /// FAIL-OPEN 3: the ratio's denominator. If the shoulders barely moved the
    /// ratio is noise, so the check stands down instead of dividing by ~0.
    func testCheckFailsOpenWhenTheShouldersBarelyMove() {
        let a = DipsAnalyzer()
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(a, Pose.dipsBody(elbow: 100, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))
        feed(a, Pose.dipsBody(elbow: 175, shoulderY: 0.55, ankleY: 0.15, ankleConfidence: 0.9))

        XCTAssertEqual(a.successfulReps, 1)
    }

    /// The default `dips` fixture pins everything, so every pre-existing dip test
    /// must still pass — i.e. adding this check cannot have retroactively
    /// invalidated the suite.
    func testLegacyFixtureIsUnaffected() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 175))
        feed(a, Pose.dips(elbow: 100))
        feed(a, Pose.dips(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1)
    }
}

// MARK: - Derived rep phase

final class RepPhaseTests: XCTestCase {

    /// A pull-up's contracted state is the TOP of the athlete's travel, even
    /// though the FSM records it as `.atBottom` (the elbow angle's minimum).
    func testPullUpContractedStateMapsToUpPhase() {
        XCTAssertEqual(RepPhase.derive(from: .atBottom, exercise: .pullUp), .upPhase)
        XCTAssertEqual(RepPhase.derive(from: .ascending, exercise: .pullUp), .upPhase)
        XCTAssertEqual(RepPhase.derive(from: .barLocked, exercise: .pullUp), .start)
    }

    /// A dip's contracted state is the BOTTOM — the inversion of the pull-up.
    func testDipContractedStateMapsToDownPhase() {
        XCTAssertEqual(RepPhase.derive(from: .atBottom, exercise: .dips), .downPhase)
        XCTAssertEqual(RepPhase.derive(from: .descending, exercise: .dips), .downPhase)
        XCTAssertEqual(RepPhase.derive(from: .ascending, exercise: .dips), .upPhase)
    }

    /// THE INVERSION, side by side: the same FSM state means opposite things.
    func testPullUpAndDipInvertEachOther() {
        XCTAssertNotEqual(RepPhase.derive(from: .atBottom, exercise: .pullUp),
                          RepPhase.derive(from: .atBottom, exercise: .dips))
    }

    /// THE SIT-UP OVERRIDE. For every other exercise the extended position is a
    /// neutral `.start`; for a sit-up, lying flat IS the bottom of the movement.
    func testSitUpOverridesTheRestingStateToDownPhase() {
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .crunches), .downPhase)
        // Contrast with every other exercise's resting state.
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .pushUp), .start)
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .squat), .start)
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .dips), .start)
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .pullUp), .start)
    }

    func testSitUpApexIsUpPhase() {
        XCTAssertEqual(RepPhase.derive(from: .atBottom, exercise: .crunches), .upPhase)
        XCTAssertEqual(RepPhase.derive(from: .ascending, exercise: .crunches), .upPhase)
    }

    /// Completion is an EVENT, not a state — a credited rep returns the machine
    /// to `.ready` — so it has to be passed in.
    func testCompletionOutranksTheState() {
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .pullUp, justCompletedRep: true),
                       .completed)
        XCTAssertEqual(RepPhase.derive(from: .ready, exercise: .crunches, justCompletedRep: true),
                       .completed)
    }

    /// Faults outrank travel: an athlete can be mid-ascent and cheating.
    func testFaultsMapToCheatsDetected() {
        for exercise in ExerciseType.allCases {
            XCTAssertEqual(RepPhase.derive(from: .invalidRepDetected, exercise: exercise),
                           .cheatsDetected, "\(exercise)")
            XCTAssertEqual(RepPhase.derive(from: .invalidPosition, exercise: exercise),
                           .cheatsDetected, "\(exercise)")
        }
    }

    /// TOTALITY. Every state × every exercise must resolve — no crash, no gap.
    /// Cheap to assert and it is what stops a new `RepState` or `ExerciseType`
    /// from silently acquiring an undefined phase.
    func testMappingIsTotal() {
        let states: [RepState] = [.ready, .descending, .atBottom, .ascending,
                                  .barLocked, .holding, .invalidRepDetected, .invalidPosition]
        for exercise in ExerciseType.allCases {
            for state in states {
                // Total function: the assertion is that this returns at all, and
                // that a fault never reads as ordinary progress.
                let phase = RepPhase.derive(from: state, exercise: exercise)
                if state == .invalidRepDetected || state == .invalidPosition {
                    XCTAssertEqual(phase, .cheatsDetected, "\(exercise)/\(state)")
                } else {
                    XCTAssertNotEqual(phase, .cheatsDetected, "\(exercise)/\(state)")
                }
            }
        }
    }
}

// MARK: - Voice cue

final class GroundedCueTests: XCTestCase {

    func testGroundedIsAFullyFormedCue() {
        XCTAssertTrue(VoiceCue.allCases.contains(.grounded))
        XCTAssertFalse(VoiceCue.grounded.defaultPhrase.isEmpty)
        XCTAssertFalse(VoiceCue.grounded.tersePhrase.isEmpty)
        XCTAssertNotEqual(VoiceCue.grounded.systemSoundID, 0)
    }

    /// The terse fallback exists for harsh legacy voices, where a long sentence
    /// is worse than none. Pin it as genuinely short.
    func testGroundedTerseFallbackIsShort() {
        XCTAssertLessThan(VoiceCue.grounded.tersePhrase.count,
                          VoiceCue.grounded.defaultPhrase.count)
    }
}

// MARK: - Capture configuration

final class CaptureConfigurationTests: XCTestCase {

    func testTierClassification() {
        // A14 and newer → high.
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPhone13,2"), .high)  // iPhone 12
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPhone16,1"), .high)
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPad13,1"),   .high)
        // A12/A13 → supported, but low tier.
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPhone11,2"), .low)   // XS
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPhone12,1"), .low)   // 11
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPad8,1"),    .low)
    }

    /// Unknown identifiers are almost certainly hardware NEWER than this build,
    /// so they must not be capped at 720p forever.
    func testUnknownIdentifiersResolveToHighTier() {
        XCTAssertEqual(DeviceCompatibility.tier(for: "iPhone99,9"), .high)
        XCTAssertEqual(DeviceCompatibility.tier(for: "arm64"),      .high)
        XCTAssertEqual(DeviceCompatibility.tier(for: ""),           .high)
    }

    func testPreviewPresetsMatchTheSpec() {
        XCTAssertEqual(CaptureConfiguration.previewPreset(for: .high), .hd1920x1080)
        XCTAssertEqual(CaptureConfiguration.previewPreset(for: .low),  .hd1280x720)
    }

    func testAnalysisResolutionsMatchTheSpec() {
        XCTAssertEqual(CaptureConfiguration.analysisResolution(for: .high),
                       .init(width: 1280, height: 720))
        XCTAssertEqual(CaptureConfiguration.analysisResolution(for: .low),
                       .init(width: 960, height: 540))
    }

    /// THE INVARIANT THAT KEEPS NORMALIZED COORDINATES VALID. Vision reports
    /// landmarks as 0...1 per axis, so a preview and an analysis buffer of
    /// different SHAPES would disagree about where a joint is. Every resolution
    /// on both tiers must therefore be exactly 16:9.
    func testEveryResolutionIsSixteenByNine() {
        for tier in [DeviceCompatibility.PerformanceTier.high, .low] {
            let r = CaptureConfiguration.analysisResolution(for: tier)
            XCTAssertEqual(Double(r.width) / Double(r.height), 16.0 / 9.0, accuracy: 0.0001,
                           "analysis buffer for \(tier) must be 16:9")
        }
        // 1920×1080 and 1280×720 are 16:9 by definition; assert the presets are
        // those and not, say, `.high` (whose shape is device-dependent).
        XCTAssertEqual(CaptureConfiguration.previewPreset(for: .high), .hd1920x1080)
        XCTAssertEqual(CaptureConfiguration.previewPreset(for: .low),  .hd1280x720)
    }

    /// The analysis buffer must never be LARGER than the preview: the whole point
    /// of the split is to spend pixels on the display and save them on the hot
    /// path.
    func testAnalysisIsNeverLargerThanPreview() {
        XCTAssertLessThan(CaptureConfiguration.analysisResolution(for: .high).height, 1080)
        XCTAssertLessThan(CaptureConfiguration.analysisResolution(for: .low).height,  720)
    }

    /// The low tier must be strictly cheaper than the high tier on both paths —
    /// otherwise the tiering buys nothing on the hardware it exists to protect.
    func testLowTierIsCheaperOnBothPaths() {
        XCTAssertLessThan(CaptureConfiguration.analysisResolution(for: .low).height,
                          CaptureConfiguration.analysisResolution(for: .high).height)
    }
}
