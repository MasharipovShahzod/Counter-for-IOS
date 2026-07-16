//
//  SkeletonTopologyTests.swift
//  FitnessTrackerTests
//
//  The skeleton overlay is SwiftUI/CoreAnimation and can't be snapshot-tested
//  here, but its topology is plain data and its invariants are exactly the kind
//  a typo breaks silently: a bone pointing at a joint that's never drawn leaves
//  a line dangling to (0,0), and a miscount quietly drops part of the body.
//

import XCTest
import Vision
@testable import FitnessTracker

final class SkeletonTopologyTests: XCTestCase {

    private var dots: [VNHumanBodyPoseObservation.JointName] {
        CameraPreviewView.PreviewView.jointDots
    }
    private var bones: [(VNHumanBodyPoseObservation.JointName,
                         VNHumanBodyPoseObservation.JointName)] {
        CameraPreviewView.PreviewView.connections
    }

    /// The user chose the full Vision skeleton; Vision exposes exactly 19 joints.
    func testDrawsAllNineteenVisionJoints() {
        XCTAssertEqual(dots.count, 19, "the full Vision skeleton is 19 joints")
        XCTAssertEqual(Set(dots).count, 19, "a joint is listed more than once")
    }

    /// The facial joints are the ones the earlier 15-joint topology was missing.
    func testFacialJointsArePresent() {
        for joint in [.leftEye, .rightEye, .leftEar, .rightEar] as [VNHumanBodyPoseObservation.JointName] {
            XCTAssertTrue(dots.contains(joint), "\(joint) should be drawn")
        }
    }

    /// Every bone must connect two joints that are actually drawn — otherwise it
    /// renders a line to an undefined point.
    func testEveryBoneConnectsDrawnJoints() {
        let drawn = Set(dots)
        for (a, b) in bones {
            XCTAssertTrue(drawn.contains(a), "bone endpoint \(a) is not in jointDots")
            XCTAssertTrue(drawn.contains(b), "bone endpoint \(b) is not in jointDots")
            XCTAssertNotEqual(a, b, "a bone connects a joint to itself")
        }
    }

    /// A fully-connected 19-joint tree needs 18 edges. Fewer means a limb or the
    /// face is drawn as loose dots with no bones.
    func testBoneCountFormsAConnectedSkeleton() {
        XCTAssertEqual(bones.count, 18, "19 joints wired as a tree need 18 bones")
    }
}
