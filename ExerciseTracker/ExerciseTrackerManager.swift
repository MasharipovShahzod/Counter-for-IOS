//
//  ExerciseTrackerManager.swift
//  ExerciseTracker
//
//  The public-facing manager. It owns the Vision request, runs inference on a
//  dedicated queue, routes recognized poses into the active rep analyzer, and
//  reports results (counts, state changes, spoken/text feedback) on the main
//  queue via its delegate.
//
//  ─────────────────────────────────────────────────────────────────────────
//  HOW TO FEED THE CAMERA INTO THIS MANAGER
//  ─────────────────────────────────────────────────────────────────────────
//  Set up an AVCaptureSession with a AVCaptureVideoDataOutput and implement
//  AVCaptureVideoDataOutputSampleBufferDelegate. In the delegate callback,
//  hand the buffer straight to the manager:
//
//      func captureOutput(_ output: AVCaptureOutput,
//                         didOutput sampleBuffer: CMSampleBuffer,
//                         from connection: AVCaptureConnection) {
//          // Map the device/camera orientation to a CGImagePropertyOrientation.
//          // For a portrait-held phone using the FRONT camera this is commonly
//          // `.leftMirrored`; for the BACK camera in portrait it's `.right`.
//          tracker.process(sampleBuffer: sampleBuffer, orientation: .leftMirrored)
//      }
//
//  Notes:
//   • Set videoDataOutput.alwaysDiscardsLateVideoFrames = true so Vision always
//     works on the freshest frame and the analyzer state stays in sync with the
//     athlete (dropping stale frames is correct here).
//   • Give the output a serial `setSampleBufferDelegate(_:queue:)` queue; the
//     manager does its own thread hand-off internally, so that delegate queue
//     only needs to stay responsive.
//   • Request camera permission (NSCameraUsageDescription) before starting the
//     session. Call `checkDeviceCompatibility()` first and gate the UI on it.
//

import Foundation
import Vision
import AVFoundation
import CoreMedia

// MARK: - Delegate

public protocol ExerciseTrackerDelegate: AnyObject {
    /// A valid rep was counted. `count` is the new running total.
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didCountValidRep count: Int)

    /// The rep state machine changed phase (useful to drive UI / animations).
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didChangeState state: RepState)

    /// A rep was rejected. `feedback` is a specific, user-facing explanation and
    /// `severity` distinguishes a transient coaching cue (`.warning`) from a hard
    /// posture / anti-cheat block (`.critical`). The count is NOT incremented.
    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didDetectInvalidRep feedback: String,
                         severity: FormSeverity)

    /// Live rep depth, 0 (top) → 1 (target depth). Fires every analyzed frame.
    /// Drive the depth progress ring from this. Called on the main queue. Optional.
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateDepth progress: Double)

    /// A pose was recognized this frame. Points are in Vision's normalized,
    /// bottom-left-origin space — flip Y and scale to draw a skeleton overlay.
    /// Called on the main queue. Optional.
    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didUpdatePose observation: VNHumanBodyPoseObservation)

    /// No usable body was found this frame (out of frame / too low confidence).
    /// Optional — drive a "step back into view" hint from this.
    func exerciseTrackerDidLoseTracking(_ tracker: ExerciseTrackerManager)
}

// Optional methods.
public extension ExerciseTrackerDelegate {
    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didUpdatePose observation: VNHumanBodyPoseObservation) {}
    func exerciseTrackerDidLoseTracking(_ tracker: ExerciseTrackerManager) {}
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateDepth progress: Double) {}
}

// MARK: - Manager

/// Public alias signalling that this manager now enforces the global posture /
/// anti-cheat constraints (torso-horizon pitch + spinal alignment) in its
/// push-up state machine. Use either name interchangeably.
public typealias SecureWorkoutManager = ExerciseTrackerManager

public final class ExerciseTrackerManager {

    // MARK: Public state

    public weak var delegate: ExerciseTrackerDelegate?

    /// The currently tracked exercise. Changing it resets the count and state.
    public private(set) var exercise: ExerciseType

    /// Running total of valid reps for the current exercise.
    public var successfulRepsCount: Int { analyzer.successfulReps }

    /// Current phase of the rep state machine.
    public var currentState: RepState { analyzer.state }

    /// Set false to mute spoken feedback (text feedback via the delegate still
    /// fires). Defaults to true.
    public var isVoiceFeedbackEnabled = true

    // MARK: Tuning

    /// Per-joint confidence floor. Frames where a required joint is less certain
    /// than this are ignored (treated as "tracking lost").
    public var minimumJointConfidence: Float = 0.3

    // MARK: Защита — Слои 1-4

    /// Подключите SecureWorkoutSession до начала захвата камеры.
    /// nil = защита отключена (только для unit-тестов или симулятора).
    public var secureSession: SecureWorkoutSession?

    /// Суставы последнего обработанного кадра — нужны registerRep при событии repCompleted.
    private var lastAnalyzedJoints: BodyJoints?

    // MARK: Private

    private var analyzer: RepAnalyzer
    private let visionQueue = DispatchQueue(label: "com.exercisetracker.vision", qos: .userInitiated)
    private let speech = AVSpeechSynthesizer()
    private var lastSpokenAt: [String: Date] = [:]   // debounce repeated feedback
    private let speechCooldown: TimeInterval = 2.5

    /// Reused across frames. Building it once is cheaper than per-frame alloc.
    private lazy var poseRequest: VNDetectHumanBodyPoseRequest = {
        let request = VNDetectHumanBodyPoseRequest()
        // Pin the revision so behaviour is stable across OS updates. The 2D body
        // pose request first shipped in iOS 14 with this revision.
        if #available(iOS 14.0, *) {
            request.revision = VNDetectHumanBodyPoseRequestRevision1
        }
        return request
    }()

    // MARK: Init

    public init(exercise: ExerciseType = .pushUp) {
        self.exercise = exercise
        self.analyzer = ExerciseTrackerManager.makeAnalyzer(for: exercise)
    }

    private static func makeAnalyzer(for exercise: ExerciseType) -> RepAnalyzer {
        switch exercise {
        case .pushUp: return PushUpAnalyzer()
        case .squat:  return SquatAnalyzer()
        }
    }

    // MARK: Compatibility

    /// Verifies OS support and that the chip has an ANE fast enough for
    /// real-time pose estimation (A12 Bionic / iPhone XS or newer). Call this
    /// before starting the capture session and surface the message on failure.
    public func checkDeviceCompatibility() -> SafetyCheckResult {
        DeviceCompatibility.check()
    }

    // MARK: Configuration

    /// Switch exercises. Resets the counter and state machine.
    public func configure(exercise: ExerciseType) {
        self.exercise = exercise
        self.analyzer = ExerciseTrackerManager.makeAnalyzer(for: exercise)
    }

    /// Zero the counter and return the state machine to `.ready`.
    public func reset() {
        analyzer.reset()
    }

    // MARK: Frame ingestion

    /// Feed one camera frame. Safe to call from your capture delegate queue;
    /// inference runs on the manager's own queue and callbacks land on main.
    ///
    /// - Parameters:
    ///   - sampleBuffer: the frame from AVCaptureVideoDataOutput.
    ///   - orientation: how to rotate the pixels so the person is upright.
    public func process(sampleBuffer: CMSampleBuffer,
                        orientation: CGImagePropertyOrientation = .up) {
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer,
                                                orientation: orientation,
                                                options: [:])
            do {
                try handler.perform([self.poseRequest])
                self.handleResults(self.poseRequest.results)
            } catch {
                // A single failed frame is non-fatal; just skip it.
                self.notifyTrackingLost()
            }
        }
    }

    /// Convenience overload if you only have a CVPixelBuffer.
    public func process(pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation = .up) {
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            do {
                try handler.perform([self.poseRequest])
                self.handleResults(self.poseRequest.results)
            } catch {
                self.notifyTrackingLost()
            }
        }
    }

    // MARK: Result handling

    private func handleResults(_ results: [VNObservation]?) {
        guard let observation = (results as? [VNHumanBodyPoseObservation])?.first else {
            notifyTrackingLost()
            return
        }

        // Surface the raw pose for any skeleton overlay (on main).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.exerciseTracker(self, didUpdatePose: observation)
        }

        // Слой 1: проверка живости кадра перед любым анализом.
        // Если secureSession блокирует кадр — трактуем как потерю трекинга.
        if let sec = secureSession, !sec.validateFrame(observation: observation) {
            notifyTrackingLost()
            return
        }

        guard let joints = BodyJoints.make(from: observation,
                                           for: exercise,
                                           minConfidence: minimumJointConfidence) else {
            notifyTrackingLost()
            return
        }

        lastAnalyzedJoints = joints

        // Run the state machine and dispatch whatever it produced.
        let events = analyzer.analyze(joints: joints)
        guard !events.isEmpty else { return }
        dispatch(events)
    }

    private func dispatch(_ events: [AnalyzerEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for event in events {
                switch event {
                case .stateChanged(let state):
                    self.delegate?.exerciseTracker(self, didChangeState: state)

                case .repCompleted(let total):
                    // Слои 2 и 3: обфусцированный инкремент + запись в криптореестр.
                    if let sec = self.secureSession, let joints = self.lastAnalyzedJoints {
                        sec.registerRep(
                            joints: joints,
                            peakDepthAngle: Double(self.analyzer.state == .atBottom ? 90 : 0)
                        )
                    }
                    self.delegate?.exerciseTracker(self, didCountValidRep: total)

                case .invalidRep(let feedback, let severity):
                    self.delegate?.exerciseTracker(self, didDetectInvalidRep: feedback,
                                                   severity: severity)
                    self.speak(feedback)

                case .depthProgress(let progress):
                    self.delegate?.exerciseTracker(self, didUpdateDepth: progress)
                }
            }
        }
    }

    private func notifyTrackingLost() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.exerciseTrackerDidLoseTracking(self)
        }
    }

    // MARK: Voice feedback

    /// Speaks a phrase, debounced so the same message can't spam the user.
    private func speak(_ phrase: String) {
        guard isVoiceFeedbackEnabled else { return }
        let now = Date()
        if let last = lastSpokenAt[phrase], now.timeIntervalSince(last) < speechCooldown {
            return
        }
        lastSpokenAt[phrase] = now

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }
}
