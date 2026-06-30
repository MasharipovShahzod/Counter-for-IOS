//
//  PoseGeometry.swift
//  ExerciseTracker
//
//  Pure geometry: the 3-point angle helper plus a typed snapshot of the
//  joints we care about, extracted from a VNHumanBodyPoseObservation.
//
//  COORDINATE NOTE
//  ---------------
//  Vision returns normalized points in the range 0...1 with the ORIGIN AT THE
//  BOTTOM-LEFT and the Y-AXIS POINTING UP. UIKit's origin is top-left with Y
//  pointing DOWN. We deliberately keep everything in Vision's "Y-up" space for
//  the math below — joint *angles* are rotation-invariant so the only place the
//  flip matters is when you draw the skeleton on screen (see PoseOverlay note
//  in ExerciseTrackerManager). Keeping one consistent space here avoids subtle
//  "up vs down" bugs in the lean/sag checks.
//

import Foundation
import Vision

// MARK: - Angle math

enum PoseGeometry {

    /// Interior angle (in degrees) at vertex `b`, formed by the segments
    /// b→a and b→c. Range 0...180.
    ///
    /// Used for every joint angle in the tracker, e.g. the elbow angle is
    /// `angle(shoulder, elbow, wrist)`.
    static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)

        let dot   = (v1.dx * v2.dx) + (v1.dy * v2.dy)
        let mag   = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
        guard mag > 0 else { return 0 }

        // Clamp to guard against tiny floating-point overshoot of acos's domain.
        let cosine = min(1, max(-1, dot / mag))
        return acos(cosine) * 180 / .pi
    }

    /// Absolute pitch (in degrees) of the segment a→b away from the HORIZONTAL
    /// plane (the screen's X-axis), folded into the range 0...90.
    /// 0° = perfectly horizontal (ideal push-up plank), 90° = vertical.
    ///
    /// Uses `atan2(dy, dx)` directly on Vision's coordinates. Because Vision's
    /// origin is bottom-left (Y-up), `dy` already points "up the screen" — but
    /// that's irrelevant here: we take the absolute value and fold past 90°, so
    /// the result is the line's tilt regardless of which way it points or the
    /// Y-axis convention. This is the global spatial constraint that prevents
    /// the "piked hips / standing" cheat where only the elbows bend.
    static func torsoPitch(shoulder: CGPoint, hip: CGPoint) -> CGFloat {
        let dx = hip.x - shoulder.x
        let dy = hip.y - shoulder.y
        guard dx != 0 || dy != 0 else { return 0 }
        let degrees = abs(atan2(dy, dx) * 180 / .pi)   // 0...180
        return degrees > 90 ? 180 - degrees : degrees   // fold to 0...90 tilt
    }

    /// Angle (in degrees) of the segment a→b measured from the vertical axis.
    /// 0° = perfectly vertical, 90° = perfectly horizontal. Used for torso lean.
    static func angleFromVertical(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let mag = hypot(dx, dy)
        guard mag > 0 else { return 0 }
        // |dy| / mag is the cosine of the angle to the vertical axis.
        let cosine = min(1, max(-1, abs(dy) / mag))
        return acos(cosine) * 180 / .pi
    }
}

// MARK: - Body joints snapshot

/// A typed, single-frame snapshot of the joints used by the analyzers.
/// One body side (left or right) is chosen — whichever is more confidently
/// visible — because these exercises are judged from a side profile where
/// the far-side limbs are often occluded.
struct BodyJoints {
    let shoulder: CGPoint
    let elbow: CGPoint
    let wrist: CGPoint
    let hip: CGPoint
    let knee: CGPoint
    let ankle: CGPoint

    /// Lowest confidence among the joints that were actually required.
    let minConfidence: Float

    /// Which physical side these joints came from (useful for overlays/UX).
    let side: Side
    enum Side { case left, right }
}

extension BodyJoints {

    /// Builds a `BodyJoints` from an observation, automatically picking the more
    /// visible side. Returns `nil` if neither side clears `minConfidence` for the
    /// joints the given exercise needs.
    ///
    /// - Parameters:
    ///   - observation: a recognized 2D body pose (iOS 14+).
    ///   - exercise: used to decide which joints are mandatory.
    ///   - minConfidence: per-joint confidence floor (0...1).
    static func make(from observation: VNHumanBodyPoseObservation,
                     for exercise: ExerciseType,
                     minConfidence: Float) -> BodyJoints? {

        // Required joints differ slightly per exercise; we still read all six
        // because both analyzers benefit from the full chain.
        func side(_ s: Side) -> BodyJoints? {
            let names: [VNHumanBodyPoseObservation.JointName]
            switch s {
            case .left:
                names = [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle]
            case .right:
                names = [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle]
            }

            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            let recognized = names.compactMap { points[$0] }
            guard recognized.count == names.count else { return nil }

            // Which joints must be confident depends on the exercise.
            let mandatory: [VNRecognizedPoint] = {
                switch exercise {
                case .pushUp:
                    // shoulder, elbow, wrist, hip, knee
                    return Array(recognized.prefix(5))
                case .squat:
                    // shoulder, hip, knee, ankle
                    return [recognized[0], recognized[3], recognized[4], recognized[5]]
                }
            }()

            guard let weakest = mandatory.map({ $0.confidence }).min(),
                  weakest >= minConfidence else { return nil }

            return BodyJoints(
                shoulder: recognized[0].location,
                elbow:    recognized[1].location,
                wrist:    recognized[2].location,
                hip:      recognized[3].location,
                knee:     recognized[4].location,
                ankle:    recognized[5].location,
                minConfidence: weakest,
                side: s
            )
        }

        let left = side(.left)
        let right = side(.right)

        // Pick whichever side is more confidently visible.
        switch (left, right) {
        case let (l?, r?): return l.minConfidence >= r.minConfidence ? l : r
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil):   return nil
        }
    }
}
