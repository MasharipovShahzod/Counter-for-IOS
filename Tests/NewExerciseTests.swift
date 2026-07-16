//
//  NewExerciseTests.swift
//  FitnessTrackerTests
//
//  Dips, pull-ups and plank. Fixtures live in PoseFixtures.swift.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

// MARK: - Dips

final class DipsAnalyzerTests: XCTestCase {

    func testFullDipCountsOnce() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 175))          // top: arms extended, inside 171–180
        feed(a, Pose.dips(elbow: 85))           // bottom: past the 94.5° trigger
        let events = feed(a, Pose.dips(elbow: 175))   // back to the top

        XCTAssertEqual(events.repCounts.last, 1, "Top → Bottom → Top is one rep")
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// The spec's stated window: the top phase must be reachable anywhere in
    /// 171–180°, not only at a perfect 180.
    func testTopPhaseAcceptsTheWholeToleratedWindow() {
        let cfg = ExerciseType.dips.repThresholds!
        XCTAssertEqual(cfg.lockoutAngle, 171, accuracy: 0.0001)

        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 172))   // barely inside the window — must arm
        feed(a, Pose.dips(elbow: 85))
        feed(a, Pose.dips(elbow: 172))
        XCTAssertEqual(a.successfulReps, 1, "171–180 must all count as 'extended'")
    }

    /// The spec's stated bottom: 90° or less, tolerated to 94.5°.
    func testBottomPhaseAcceptsTheToleratedDepth() {
        let cfg = ExerciseType.dips.repThresholds!
        XCTAssertEqual(cfg.depthAngle, 94.5, accuracy: 0.0001)

        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 175))
        feed(a, Pose.dips(elbow: 93))    // deeper than 94.5 but shallower than 90
        let events = feed(a, Pose.dips(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1, "the +5% tolerance must accept 93°")
        XCTAssertTrue(events.invalidFeedback.isEmpty)
    }

    func testShallowDipIsRejected() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 175))
        feed(a, Pose.dips(elbow: 120))   // nowhere near 90°
        let events = feed(a, Pose.dips(elbow: 175))

        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertTrue(events.invalidFeedback.contains { $0.contains("Dip lower") })
    }

    func testStartingAtTheBottomCreditsNothing() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 85))
        feed(a, Pose.dips(elbow: 175))
        XCTAssertEqual(a.successfulReps, 0, "arming applies to dips too")
    }

    func testHangingAtTheTopCountsNothing() {
        let a = DipsAnalyzer()
        feed(a, Pose.dips(elbow: 178), frames: 60)
        XCTAssertEqual(a.successfulReps, 0)
    }
}

// MARK: - Pull-ups

final class PullUpAnalyzerTests: XCTestCase {

    /// Enough frames to clear the 1.0s bar-lock window at 30fps, with margin.
    private let lockFrames = 40

    // MARK: Bar lock

    func testStandingWithHandsDownNeverLocksTheBar() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        // Wrists at 0.5 — below the 0.65 bar zone.
        feed(a, Pose.pullUp(shoulderY: 0.1, wristY: 0.5), frames: 120, clock: clock)

        XCTAssertFalse(a.isBarLocked)
        XCTAssertEqual(a.state, .ready)
        XCTAssertEqual(a.successfulReps, 0)
    }

    func testBarLockRequiresTheFullSecond() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        // 20 frames ≈ 0.63s — not yet a second.
        feed(a, Pose.hang(), frames: 20, clock: clock)
        XCTAssertFalse(a.isBarLocked, "the bar must not lock before 1.0s")

        feed(a, Pose.hang(), frames: 20, clock: clock)
        XCTAssertTrue(a.isBarLocked, "…and must lock once a second has passed")
        XCTAssertEqual(a.state, .barLocked)
    }

    func testUnstableWristsRestartTheLockWindow() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        // Alternate the bar height by well over the 0.03 stability bound, so the
        // window keeps restarting and never completes.
        for i in 0..<120 {
            let wristY: CGFloat = (i % 2 == 0) ? 0.90 : 0.80
            _ = a.analyze(frame: PoseFrame(bilateral: Pose.hang(wristY: wristY),
                                           time: clock.tick()))
        }
        XCTAssertFalse(a.isBarLocked, "flailing hands are not a settled grip")
    }

    // MARK: Reps

    func testFullPullUpCountsOnce() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        XCTAssertTrue(a.isBarLocked)

        feed(a, Pose.pulledUp(), frames: 12, clock: clock)
        let events = feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(events.repCounts.last, 1)
        XCTAssertEqual(a.successfulReps, 1)
    }

    func testThreePullUpsCountThree() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        for _ in 0..<3 {
            feed(a, Pose.pulledUp(), frames: 12, clock: clock)
            feed(a, Pose.hang(), frames: 12, clock: clock)
        }
        XCTAssertEqual(a.successfulReps, 3)
    }

    /// THE TRIGGER THE SPEC GOT WRONG. A rep whose shoulders reach 0.35 of an
    /// arm below the bar is a strong, complete pull-up and must count — even
    /// though the shoulders never come near the bar line itself. The spec's
    /// literal "shoulders touch or rise above barYLevel" would count zero.
    func testRealisticTopCountsEvenThoughShouldersStayBelowTheBar() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        let top = Pose.pulledUp()
        XCTAssertLessThan(top.meanShoulderY, top.meanWristY,
                          "the shoulders are still below the hands at the top")

        feed(a, top, frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)
        XCTAssertEqual(a.successfulReps, 1,
                       "a real pull-up must count without reaching the bar line")
    }

    func testPartialPullIsRejected() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)

        feed(a, Pose.partialPull(), frames: 12, clock: clock)   // only 0.6 arms up
        let events = feed(a, Pose.hang(), frames: 12, clock: clock)

        XCTAssertEqual(a.successfulReps, 0, "a partial pull must not count")
        XCTAssertTrue(events.invalidFeedback.contains("Pull higher!"))
    }

    func testHangingStillCountsNothing() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: 200, clock: clock)
        XCTAssertTrue(a.isBarLocked)
        XCTAssertEqual(a.successfulReps, 0, "dead hanging is not repping")
    }

    // MARK: Anti-cheat

    /// The bar-drift check. Hands on a real bar stay put while the shoulders
    /// travel. An athlete standing on the ground with their hands in the air
    /// moves their WRISTS as they bob — so the lock drops instead of paying out.
    func testBobbingOnTheGroundDropsTheLock() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        XCTAssertTrue(a.isBarLocked)

        // The whole body drops 0.15 — wrists included. That exceeds the drift
        // bound (0.25 × 0.4 arm = 0.1).
        feed(a, Pose.hang(wristY: 0.75), frames: 12, clock: clock)

        XCTAssertFalse(a.isBarLocked, "wrists that move with the body aren't on a bar")
        XCTAssertEqual(a.state, .ready)
        XCTAssertEqual(a.successfulReps, 0)
    }

    func testReAcquiringTheBarAfterADropWorks() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        feed(a, Pose.hang(wristY: 0.75), frames: 12, clock: clock)   // drop the lock
        XCTAssertFalse(a.isBarLocked)

        feed(a, Pose.hang(), frames: lockFrames, clock: clock)       // grab again
        XCTAssertTrue(a.isBarLocked, "a dropped lock must be re-acquirable")

        feed(a, Pose.pulledUp(), frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)
        XCTAssertEqual(a.successfulReps, 1)
    }

    func testResetClearsEverything() {
        let clock = FakeClock()
        let a = PullUpAnalyzer()
        feed(a, Pose.hang(), frames: lockFrames, clock: clock)
        feed(a, Pose.pulledUp(), frames: 12, clock: clock)
        feed(a, Pose.hang(), frames: 12, clock: clock)
        XCTAssertEqual(a.successfulReps, 1)

        a.reset()
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertFalse(a.isBarLocked)
        XCTAssertEqual(a.state, .ready)
    }
}

// MARK: - Plank

final class PlankAnalyzerTests: XCTestCase {

    /// Frames covering the 1.5s arming window at 30fps (45 frames), plus one to
    /// cross the threshold.
    private let armFrames = 46

    func testTimerDoesNotStartBeforeArmingDuration() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 42, clock: clock)   // ≈1.37s — just short

        XCTAssertNotEqual(a.state, .holding, "the clock must not start before 1.5s")
        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001)
    }

    func testTimerStartsAfterArmingDuration() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 50, clock: clock)

        XCTAssertEqual(a.state, .holding)
        XCTAssertGreaterThan(a.elapsed, 0)
    }

    func testTimerAccumulatesRealTime() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        // 45 frames to arm, then 90 more ≈ 3.0s of credited hold.
        feed(a, Pose.plank(), frames: 45 + 90, clock: clock)
        XCTAssertEqual(a.elapsed, 3.0, accuracy: 0.15)
    }

    func testHoldProgressIsEmitted() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        let events = feed(a, Pose.plank(), frames: 60, clock: clock)
        XCTAssertFalse(events.holds.isEmpty, "a hold must report its time")
        XCTAssertGreaterThan(events.holds.last ?? 0, 0)
    }

    // MARK: Form gates

    /// THE ANTI-CHEAT CASE, and the reason the horizon check exists at all.
    /// A person standing bolt upright has a perfectly straight spine AND
    /// perfectly straight legs — both straightness checks pass. Only the torso
    /// pitch catches them.
    func testStandingIsNotAPlank() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.standingStraight(), frames: 120, clock: clock)

        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001, "standing must never bank plank time")
        XCTAssertNotEqual(a.state, .holding)
    }

    func testStandingDefeatsBothStraightnessChecksAndOnlyTheHorizonCatchesIt() {
        let p = Pose.standingStraight()
        let cfg = PlankConfig.standard

        // Spine and legs both look immaculate…
        XCTAssertGreaterThanOrEqual(PoseGeometry.angle(p.shoulder, p.hip, p.knee),
                                    cfg.minSpineAngle)
        XCTAssertGreaterThanOrEqual(PoseGeometry.angle(p.hip, p.knee, p.ankle),
                                    cfg.minLegAngle)
        // …and the horizon check is the only thing standing between a standing
        // athlete and a running plank clock.
        XCTAssertGreaterThan(PoseGeometry.torsoPitch(shoulder: p.shoulder, hip: p.hip),
                             cfg.maxTorsoPitch)
    }

    func testPikedHipsAreRejected() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        let events = feed(a, Pose.plankPiked(), frames: 90, clock: clock)

        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001)
        XCTAssertEqual(a.state, .invalidPosition)
        XCTAssertEqual(events.severities.first, .critical)
    }

    func testBentKneesAreRejected() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plankBentKnees(), frames: 90, clock: clock)
        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001, "kneeling is not a plank")
    }

    /// Bent knees fail ONLY the leg check — flat torso, straight spine. Without
    /// the hip–knee–ankle gate this would time as a valid plank.
    func testBentKneesPassTheHorizonAndSpineChecks() {
        let p = Pose.plankBentKnees()
        let cfg = PlankConfig.standard
        XCTAssertLessThanOrEqual(PoseGeometry.torsoPitch(shoulder: p.shoulder, hip: p.hip),
                                 cfg.maxTorsoPitch)
        XCTAssertGreaterThanOrEqual(PoseGeometry.angle(p.shoulder, p.hip, p.knee),
                                    cfg.minSpineAngle)
        XCTAssertLessThan(PoseGeometry.angle(p.hip, p.knee, p.ankle), cfg.minLegAngle)
    }

    func testLowConfidenceDoesNotStartTheClock() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        // Geometrically perfect, but Vision isn't sure — the spec asks for the
        // timer to start only under high confidence.
        feed(a, Pose.plank(confidence: 0.4), frames: 90, clock: clock)
        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001)
    }

    // MARK: Pause semantics

    func testFormBreakPausesButPreservesBankedTime() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 45 + 60, clock: clock)   // ≈2s banked
        let banked = a.elapsed
        XCTAssertGreaterThan(banked, 1.5)

        feed(a, Pose.plankPiked(), frames: 30, clock: clock)

        XCTAssertEqual(a.state, .invalidPosition)
        XCTAssertEqual(a.elapsed, banked, accuracy: 0.001,
                       "a form break pauses the clock — it must not reset it")
    }

    /// Resuming costs the full 1.5s arming window again. That's deliberate: it
    /// stops a wobbling athlete from banking time by flickering in and out of a
    /// valid pose.
    func testResumingRequiresReArming() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 45 + 30, clock: clock)
        let banked = a.elapsed

        feed(a, Pose.plankPiked(), frames: 10, clock: clock)     // break
        feed(a, Pose.plank(), frames: 20, clock: clock)          // back, but <1.5s

        XCTAssertEqual(a.elapsed, banked, accuracy: 0.001,
                       "time must not resume until the pose is re-armed")
        XCTAssertNotEqual(a.state, .holding)

        feed(a, Pose.plank(), frames: 60, clock: clock)          // now past 1.5s
        XCTAssertEqual(a.state, .holding)
        XCTAssertGreaterThan(a.elapsed, banked, "…and then it resumes from where it paused")
    }

    // MARK: Kind

    func testPlankNeverCountsReps() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 300, clock: clock)
        XCTAssertEqual(a.successfulReps, 0, "a hold is scored by time, never by reps")
        XCTAssertNil(a.lastRepPeakDepthAngle)
    }

    func testResetClearsAccumulatedTime() {
        let clock = FakeClock()
        let a = PlankAnalyzer()
        feed(a, Pose.plank(), frames: 100, clock: clock)
        XCTAssertGreaterThan(a.elapsed, 0)

        a.reset()
        XCTAssertEqual(a.elapsed, 0, accuracy: 0.001)
        XCTAssertEqual(a.state, .ready)
    }
}

// MARK: - Exercise catalogue

final class ExerciseCatalogueTests: XCTestCase {

    func testRepExercisesHaveThresholdsAndHoldsDoNot() {
        for exercise in ExerciseType.allCases {
            switch exercise.kind {
            case .reps:
                XCTAssertNotNil(exercise.repThresholds,
                                "\(exercise.rawValue) counts reps and needs thresholds")
            case .hold:
                XCTAssertNil(exercise.repThresholds,
                             "\(exercise.rawValue) is a hold and must not carry rep thresholds")
            }
        }
    }

    func testPlankIsTheOnlyHold() {
        let holds = ExerciseType.allCases.filter { $0.kind == .hold }
        XCTAssertEqual(holds, [.plank])
    }

    func testDisplayNamesAreShortEnoughForThePicker() {
        // ExercisePickerView lays all cases out as equal segments in a ~320pt
        // capsule. With 5 exercises that's ~64pt each; long labels truncate.
        for exercise in ExerciseType.allCases {
            XCTAssertLessThanOrEqual(exercise.displayName.count, 10,
                                     "\(exercise.rawValue): '\(exercise.displayName)' will truncate")
        }
    }
}
