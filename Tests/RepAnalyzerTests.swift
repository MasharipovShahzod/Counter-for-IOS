//
//  RepAnalyzerTests.swift
//  FitnessTrackerTests
//
//  Drives the rep state machines frame by frame with synthetic poses. These are
//  the rules that decide whether a rep counts, so they're worth testing without
//  a camera in the loop.
//
//  ON SYNTHETIC POSES
//  ------------------
//  `RepTracker` low-pass filters the primary angle (alpha 0.6), so a single
//  frame at a target angle does NOT move the smoothed value there. Every helper
//  below feeds an angle repeatedly until the filter converges, which is also
//  what a real camera does at 30fps.
//

import XCTest
import CoreGraphics
@testable import FitnessTracker

// MARK: - Push-ups

final class PushUpAnalyzerTests: XCTestCase {

    func testFullRepCountsOnce() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))            // locked out at the top
        feed(a, Pose.pushUp(elbow: 85))             // down past 94.5° depth
        let events = feed(a, Pose.pushUp(elbow: 175))  // back to lockout

        XCTAssertEqual(events.repCounts.last, 1)
        XCTAssertEqual(a.successfulReps, 1)
        XCTAssertEqual(a.state, .ready)
    }

    func testThreeRepsCountThree() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))
        for _ in 0..<3 {
            feed(a, Pose.pushUp(elbow: 85))
            feed(a, Pose.pushUp(elbow: 175))
        }
        XCTAssertEqual(a.successfulReps, 3)
    }

    func testHalfRepIsRejectedWithCoaching() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))
        feed(a, Pose.pushUp(elbow: 120))            // bent, but nowhere near depth
        let events = feed(a, Pose.pushUp(elbow: 175))

        XCTAssertEqual(a.successfulReps, 0, "a half-rep must not count")
        XCTAssertTrue(events.invalidFeedback.contains("Go down lower!"))
        XCTAssertEqual(events.severities.first, .warning)
    }

    func testHoldingAtTheTopCountsNothing() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175), frames: 60)
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertEqual(a.state, .ready)
    }

    /// THE ANTI-CHEAT CASE. Full elbow range of motion, but the hips are piked
    /// into a V — i.e. standing/leaning and just bending the arms. The elbow can
    /// swing 175°→85°→175° all it likes; nothing may count.
    func testPikedHipsBlockRepsDespiteFullElbowRange() {
        let a = PushUpAnalyzer()
        // Collect across ALL feeds: the critical alert is debounced to once per
        // posture episode, so it lands in the first feed's events and never
        // repeats in later ones.
        var all: [AnalyzerEvent] = []
        all += feed(a, Pose.pikedPushUp(elbow: 175))
        all += feed(a, Pose.pikedPushUp(elbow: 85))
        all += feed(a, Pose.pikedPushUp(elbow: 175))

        XCTAssertEqual(a.successfulReps, 0, "piked hips must never credit a rep")
        XCTAssertEqual(a.state, .invalidPosition)
        XCTAssertEqual(all.severities.first, .critical)
    }

    func testPostureFailureIsAnnouncedOncePerEpisode() {
        let a = PushUpAnalyzer()
        let events = feed(a, Pose.pikedPushUp(elbow: 175), frames: 40)
        XCTAssertEqual(events.invalidFeedback.count, 1,
                       "the critical alert must debounce, not fire every frame")
        XCTAssertEqual(events.invalidFeedback.first, PushUpPostureValidator.message)
    }

    /// THE DESCENT GAP — closed by arming. Previously credited a rep.
    ///
    /// The posture gate returns early *before* the attempt-start block, so while
    /// posture is broken no attempt is ever opened and nothing gets tainted. The
    /// moment posture recovered, the machine saw a bent elbow and opened a FRESH
    /// attempt right there — at the bottom. Depth was already satisfied, so the
    /// press-up alone locked out and paid for a rep whose descent was never
    /// validated: descend piked, fix your posture at the bottom, press up, get
    /// credit.
    ///
    /// The posture gate now DISARMS, so recovery alone can't open an attempt —
    /// the athlete must return to a valid top position first.
    func testDescentInBadPostureCannotBeSalvagedByRecovering() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))       // armed at a good top
        feed(a, Pose.pikedPushUp(elbow: 85))   // descend piked → disarms
        feed(a, Pose.pushUp(elbow: 85))        // posture "recovered" at the bottom
        feed(a, Pose.pushUp(elbow: 175))       // press up to lockout

        XCTAssertEqual(a.successfulReps, 0,
                       "a descent performed in bad posture must not pay out")
    }

    /// THE SAME GAP in its simplest form, with no posture trickery: entering
    /// frame already at the bottom and pressing up once used to credit a rep for
    /// a movement with no descent at all.
    func testStartingAtTheBottomCreditsNothing() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 85))    // first frame ever: already at the bottom
        feed(a, Pose.pushUp(elbow: 175))   // press up

        XCTAssertEqual(a.successfulReps, 0,
                       "a rep with no observed descent must not count")
    }

    /// The flip side of arming: the athlete who starts at the bottom isn't
    /// locked out forever. Extending to the top arms the machine, and the very
    /// next honest rep counts.
    func testRepAfterArmingCountsNormally() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 85))    // starts at the bottom — no credit
        feed(a, Pose.pushUp(elbow: 175))   // presses up: no credit, but ARMS
        XCTAssertEqual(a.successfulReps, 0)

        feed(a, Pose.pushUp(elbow: 85))    // now a real rep
        feed(a, Pose.pushUp(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1, "arming must not permanently block counting")
    }

    /// Posture recovery must re-arm through a valid TOP, not merely through
    /// valid posture — otherwise the disarm above would be trivially bypassed.
    func testPostureRecoveryAloneDoesNotReArm() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))       // armed
        feed(a, Pose.pikedPushUp(elbow: 175))  // posture breaks at the top → disarms
        feed(a, Pose.pushUp(elbow: 85))        // straight to a descent in good posture
        feed(a, Pose.pushUp(elbow: 175))       // press up

        XCTAssertEqual(a.successfulReps, 0,
                       "recovering posture mid-air must not substitute for a valid top")
    }

    func testPostureRecoveryClearsTheLock() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pikedPushUp(elbow: 175))
        XCTAssertEqual(a.state, .invalidPosition)

        let events = feed(a, Pose.pushUp(elbow: 175))
        XCTAssertNotEqual(a.state, .invalidPosition, "good posture must release the lock")
        XCTAssertTrue(events.states.contains(.ready))
    }

    func testDepthProgressSpansZeroToOne() {
        let a = PushUpAnalyzer()
        let top = feed(a, Pose.pushUp(elbow: 175))
        XCTAssertEqual(top.depths.last ?? -1, 0, accuracy: 0.001,
                       "locked out at the top is 0 depth")

        let bottom = feed(a, Pose.pushUp(elbow: 85))
        XCTAssertEqual(bottom.depths.last ?? -1, 1, accuracy: 0.001,
                       "past the depth target is a full 1")
    }

    func testResetClearsCountAndState() {
        let a = PushUpAnalyzer()
        feed(a, Pose.pushUp(elbow: 175))
        feed(a, Pose.pushUp(elbow: 85))
        feed(a, Pose.pushUp(elbow: 175))
        XCTAssertEqual(a.successfulReps, 1)

        a.reset()
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertEqual(a.state, .ready)
    }

    /// Non-finite joints should never reach an analyzer (BodyJoints.make drops
    /// the frame first), but if one ever did, it must not credit a rep.
    func testNonFiniteJointsCannotCreditARep() {
        let a = PushUpAnalyzer()
        let broken = BodyJoints(shoulder: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                elbow: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                wrist: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                hip: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                knee: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                ankle: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                                minConfidence: 0.9, side: .right)
        feed(a, broken, frames: 30)
        XCTAssertEqual(a.successfulReps, 0)
    }
}

// MARK: - Squats

final class SquatAnalyzerTests: XCTestCase {

    func testFullRepCountsOnce() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))          // standing tall
        feed(a, Pose.squat(knee: 65))           // hips below the knees
        let events = feed(a, Pose.squat(knee: 175))

        XCTAssertEqual(events.repCounts.last, 1)
        XCTAssertEqual(a.successfulReps, 1)
    }

    /// THE REGRESSION GUARD FOR THE DEPTH FIX.
    ///
    /// 85° at the knee clears the old `depthAngle` gate of 94.5° with room to
    /// spare, and every squat test used to be written at that angle — yet with a
    /// realistic 13.6° shin lean the hip is still ~0.03 ABOVE the knee there.
    /// It is a high squat that the counter used to pay out for, and it read as
    /// correct because "90° at the knee" sounds like the textbook cue.
    ///
    /// If this test ever goes green by counting a rep, the analyzer has drifted
    /// back to judging depth by knee angle.
    func testSquatAboveParallelDoesNotCount() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))
        feed(a, Pose.squat(knee: 85))           // past 94.5° — but ABOVE parallel
        let events = feed(a, Pose.squat(knee: 175))

        XCTAssertEqual(a.successfulReps, 0,
                       "knee angle past the old 94.5° gate is not parallel")
        XCTAssertTrue(events.invalidFeedback.contains { $0.contains("hips below your knees") })
    }

    /// The other side of the same boundary: just past parallel must count, or
    /// the fix would have simply made the app impossible to satisfy.
    func testSquatJustBelowParallelCounts() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))
        feed(a, Pose.squat(knee: 70))           // ~0.015 below parallel
        feed(a, Pose.squat(knee: 175))

        XCTAssertEqual(a.successfulReps, 1)
    }

    func testShallowSquatIsRejected() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))
        feed(a, Pose.squat(knee: 115))          // nowhere near parallel
        let events = feed(a, Pose.squat(knee: 175))

        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertTrue(events.invalidFeedback.contains {
            $0.contains("Squat lower")
        })
    }

    func testExcessiveForwardLeanIsFlagged() {
        let a = SquatAnalyzer()

        var all: [AnalyzerEvent] = []
        all += feed(a, Pose.squat(knee: 175, torsoLean: 63))   // 63° > the 57.75° bound
        all += feed(a, Pose.squat(knee: 65,  torsoLean: 63))
        // Drive it all the way back to lockout, or "0 reps" would pass trivially
        // just because the rep never resolved.
        all += feed(a, Pose.squat(knee: 175, torsoLean: 63))

        XCTAssertTrue(all.invalidFeedback.contains("Keep your chest up!"))
        XCTAssertEqual(a.successfulReps, 0,
                       "a rep with a collapsed chest must not count even at full depth")
    }

    func testUprightTorsoIsNotFlagged() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175))
        let events = feed(a, Pose.squat(knee: 65))
        XCTAssertFalse(events.invalidFeedback.contains("Keep your chest up!"),
                       "a vertical torso must not trip the lean check")
    }

    func testStandingStillCountsNothing() {
        let a = SquatAnalyzer()
        feed(a, Pose.squat(knee: 175), frames: 60)
        XCTAssertEqual(a.successfulReps, 0)
        XCTAssertEqual(a.state, .ready)
    }
}
