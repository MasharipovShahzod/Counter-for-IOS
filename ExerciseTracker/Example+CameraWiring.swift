//
//  Example+CameraWiring.swift
//  ExerciseTracker
//
//  A minimal, copy-paste reference showing how to drive ExerciseTrackerManager
//  from a live camera. This is illustrative — adapt to your own UI/layer setup.
//
//  Remember to add `NSCameraUsageDescription` to Info.plist.
//

#if canImport(UIKit)
import UIKit
import AVFoundation
import Vision

final class WorkoutViewController: UIViewController {

    // MARK: Tracker

    private let tracker = ExerciseTrackerManager(exercise: .pushUp)

    // MARK: Capture

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.exercisetracker.camera")
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: session)

    /// Which camera the user is using — drives the orientation we pass to Vision.
    private var usingFrontCamera = true

    // MARK: UI

    private let countLabel = UILabel()
    private let feedbackLabel = UILabel()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker.delegate = self

        // 1. GATE ON COMPATIBILITY before touching the camera.
        let compatibility = tracker.checkDeviceCompatibility()
        guard compatibility.isSupported else {
            presentUnsupported(message: compatibility.userMessage ?? "Device not supported.")
            return
        }

        configurePreview()
        configureLabels()
        requestCameraAccessAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    // MARK: Setup

    private func configurePreview() {
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    private func requestCameraAccessAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            self?.sampleQueue.async { self?.startSession() }
        }
    }

    private func startSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true   // always work on the freshest frame
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        session.startRunning()
    }

    private func configureLabels() {
        countLabel.font = .systemFont(ofSize: 64, weight: .bold)
        countLabel.textColor = .white
        countLabel.text = "0"
        feedbackLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        feedbackLabel.textColor = .systemYellow
        feedbackLabel.numberOfLines = 0
        [countLabel, feedbackLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            countLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            feedbackLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            feedbackLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            feedbackLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func presentUnsupported(message: String) {
        let alert = UIAlertController(title: "Unsupported Device",
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Camera → Vision

extension WorkoutViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Portrait-held phone: front camera frames are mirrored, back camera isn't.
        let orientation: CGImagePropertyOrientation = usingFrontCamera ? .leftMirrored : .right
        tracker.process(sampleBuffer: sampleBuffer, orientation: orientation)
    }
}

// MARK: - Tracker delegate

extension WorkoutViewController: ExerciseTrackerDelegate {
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didCountValidRep count: Int) {
        countLabel.text = "\(count)"
        feedbackLabel.text = nil
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager, didChangeState state: RepState) {
        // Optionally drive UI (e.g. a depth ring) from the phase here.
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didDetectInvalidRep feedback: String,
                         severity: FormSeverity) {
        feedbackLabel.text = feedback   // voice is handled inside the manager
        feedbackLabel.textColor = (severity == .critical) ? .systemRed : .systemYellow
    }

    func exerciseTrackerDidLoseTracking(_ tracker: ExerciseTrackerManager) {
        feedbackLabel.text = "Step back so your whole body is in frame."
    }
}

// MARK: - Overlay coordinate conversion

extension AVCaptureVideoPreviewLayer {
    /// Converts a Vision point (normalized, BOTTOM-LEFT origin, Y-up) into a
    /// layer coordinate (UIKit, TOP-LEFT origin, Y-down) suitable for drawing a
    /// skeleton joint on top of the preview. This is where the Y-flip matters.
    func pointForVision(_ visionPoint: CGPoint) -> CGPoint {
        let flipped = CGPoint(x: visionPoint.x, y: 1 - visionPoint.y)
        return layerPointConverted(fromCaptureDevicePoint: flipped)
    }
}
#endif
