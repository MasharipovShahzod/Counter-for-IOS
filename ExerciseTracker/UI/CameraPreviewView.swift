//
//  CameraPreviewView.swift
//  ExerciseTracker
//
//  Wraps AVCaptureVideoPreviewLayer for SwiftUI AND draws the live skeleton
//  overlay on top of it. Using `layerClass` makes the preview layer the view's
//  backing layer, so it resizes automatically with SwiftUI.
//
//  WHY DRAW THE SKELETON HERE (not as a SwiftUI overlay)
//  ----------------------------------------------------
//  • The joints live in the SAME coordinate space as the preview layer, so the
//    mapping is exact — no SwiftUI ↔ layer coordinate translation.
//  • Poses arrive ~30–60 fps. Pushing them through @Published would re-render
//    the whole SwiftUI tree every frame. Instead the view model holds a weak
//    reference to this view (as `PoseRenderer`) and calls it directly, so only
//    two CAShapeLayers update — the SwiftUI HUD stays still and fluid.
//
//  COORDINATE MAPPING
//  ------------------
//  Vision points are normalized (0...1), origin BOTTOM-LEFT, Y-up, in the same
//  upright+mirrored space the preview shows (we pin the preview connection to
//  .portrait and feed Vision `.leftMirrored` for the front camera, so the two
//  spaces match). `layerPoint(for:)` then replicates `.resizeAspectFill`
//  cropping manually using the upright image aspect ratio.
//

import SwiftUI
import AVFoundation
import Vision

/// Minimal interface the view model uses to push poses without importing UIKit.
protocol PoseRenderer: AnyObject {
    /// Upright image aspect ratio (width / height) needed for aspect-fill mapping.
    var imageAspect: CGFloat { get set }
    func render(_ observation: VNHumanBodyPoseObservation)
    func clear()
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let viewModel: WorkoutViewModel
    var showSkeleton: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        // Pin preview to portrait so its space matches Vision's upright space.
        if let connection = view.videoPreviewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        // The view model drives the skeleton directly through this reference.
        viewModel.poseRenderer = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.skeletonHidden = !showSkeleton
    }

    // MARK: - Backing view + skeleton renderer

    final class PreviewView: UIView, PoseRenderer {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var imageAspect: CGFloat = 0
        var skeletonHidden = false {
            didSet {
                boneLayer.isHidden = skeletonHidden
                jointLayer.isHidden = skeletonHidden
                if skeletonHidden { clear() }
            }
        }

        private let boneLayer = CAShapeLayer()
        private let jointLayer = CAShapeLayer()
        private let confidenceThreshold: VNConfidence = 0.2
        private var clearWork: DispatchWorkItem?

        override init(frame: CGRect) { super.init(frame: frame); configureLayers() }
        required init?(coder: NSCoder) { super.init(coder: coder); configureLayers() }

        private func configureLayers() {
            let neon = UIColor(red: 0.22, green: 1.0, blue: 0.62, alpha: 1)
            boneLayer.strokeColor = neon.withAlphaComponent(0.92).cgColor
            boneLayer.fillColor = UIColor.clear.cgColor
            boneLayer.lineWidth = 4
            boneLayer.lineCap = .round
            boneLayer.lineJoin = .round
            jointLayer.fillColor = UIColor.white.cgColor
            jointLayer.strokeColor = neon.cgColor
            jointLayer.lineWidth = 2
            layer.addSublayer(boneLayer)
            layer.addSublayer(jointLayer)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            boneLayer.frame = bounds
            jointLayer.frame = bounds
        }

        // MARK: PoseRenderer

        func render(_ observation: VNHumanBodyPoseObservation) {
            guard !skeletonHidden, imageAspect > 0,
                  let points = try? observation.recognizedPoints(.all) else { return }

            let bones = UIBezierPath()
            for (a, b) in Self.connections {
                guard let pa = points[a], pa.confidence > confidenceThreshold,
                      let pb = points[b], pb.confidence > confidenceThreshold else { continue }
                bones.move(to: layerPoint(for: pa.location))
                bones.addLine(to: layerPoint(for: pb.location))
            }

            let joints = UIBezierPath()
            for name in Self.jointDots {
                guard let p = points[name], p.confidence > confidenceThreshold else { continue }
                let center = layerPoint(for: p.location)
                joints.append(UIBezierPath(arcCenter: center, radius: 5,
                                           startAngle: 0, endAngle: .pi * 2, clockwise: true))
            }

            // Disable implicit CALayer animation so the skeleton tracks 1:1 with
            // the live video instead of lagging behind with a fade.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            boneLayer.path = bones.cgPath
            jointLayer.path = joints.cgPath
            CATransaction.commit()

            scheduleClear()
        }

        func clear() {
            clearWork?.cancel()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            boneLayer.path = nil
            jointLayer.path = nil
            CATransaction.commit()
        }

        /// Wipe the skeleton if no new pose arrives shortly (body left the frame).
        private func scheduleClear() {
            clearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.clear() }
            clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        // MARK: Vision → layer mapping (replicates .resizeAspectFill)

        private func layerPoint(for visionPoint: CGPoint) -> CGPoint {
            let W = bounds.width, H = bounds.height
            guard W > 0, H > 0, imageAspect > 0 else { return .zero }

            let xFromLeft = visionPoint.x          // mirror-consistent with the preview
            let yFromTop = 1 - visionPoint.y        // Vision Y-up → UIKit Y-down
            let layerAspect = W / H

            var displayW = W, displayH = H, offsetX: CGFloat = 0, offsetY: CGFloat = 0
            if imageAspect > layerAspect {
                // Image relatively wider: fill height, crop the sides.
                displayH = H
                displayW = H * imageAspect
                offsetX = (W - displayW) / 2
            } else {
                // Image relatively taller: fill width, crop top and bottom.
                displayW = W
                displayH = W / imageAspect
                offsetY = (H - displayH) / 2
            }
            return CGPoint(x: offsetX + xFromLeft * displayW,
                           y: offsetY + yFromTop * displayH)
        }

        // MARK: Skeleton topology

        static let connections: [(VNHumanBodyPoseObservation.JointName,
                                  VNHumanBodyPoseObservation.JointName)] = [
            (.neck, .nose),
            (.neck, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
            (.neck, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
            (.neck, .root),
            (.root, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.root, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        ]

        static let jointDots: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .neck, .root,
            .leftShoulder, .leftElbow, .leftWrist,
            .rightShoulder, .rightElbow, .rightWrist,
            .leftHip, .leftKnee, .leftAnkle,
            .rightHip, .rightKnee, .rightAnkle,
        ]
    }
}
