//
//  WorkoutViewModel.swift
//  ExerciseTracker
//
//  The bridge between the delegate-based `ExerciseTrackerManager` and SwiftUI.
//  It owns the capture session and the tracker, republishes the tracker's
//  callbacks as `@Published` state, and centralises haptics.
//
//  THREADING
//  ---------
//  • `captureOutput` runs on the camera queue → forwards frames to the tracker,
//    which does Vision work on its own queue. Nothing touches @Published there.
//  • Every `ExerciseTrackerDelegate` callback is delivered by the manager on the
//    MAIN queue, so we mutate @Published directly and safely from them.
//  • Session start/stop happens on a dedicated serial queue so the UI never
//    blocks on AVFoundation configuration.
//

import SwiftUI
import AVFoundation
import Vision

final class WorkoutViewModel: NSObject, ObservableObject {

    // MARK: Form feedback model

    enum FormFeedback: Equatable {
        case optimal
        case warning(String)    // amber coaching cue (auto-clears)
        case critical(String)   // crimson posture / anti-cheat block (persists)

        var isOptimal: Bool {
            if case .optimal = self { return true }
            return false
        }
        var isWarning: Bool {
            if case .warning = self { return true }
            return false
        }
        var isCritical: Bool {
            if case .critical = self { return true }
            return false
        }
        var message: String {
            switch self {
            case .optimal:            return "Form: Optimal"
            case .warning(let m):     return m
            case .critical(let m):    return m
            }
        }
    }

    // MARK: Published UI state

    @Published private(set) var exercise: ExerciseType = .pushUp
    @Published private(set) var repCount: Int = 0
    @Published private(set) var repState: RepState = .ready
    @Published private(set) var depth: Double = 0           // 0...1, drives the ring
    @Published private(set) var form: FormFeedback = .optimal
    @Published private(set) var isBodyTracked: Bool = false
    @Published private(set) var compatibility: SafetyCheckResult = .supported
    @Published private(set) var cameraAuthorized: Bool = true

    /// Toggles the live skeleton overlay on the camera preview.
    @Published var showSkeleton: Bool = true

    /// Increments on every counted rep — views observe it to fire the pop/haptic
    /// without coupling to the absolute count value.
    @Published private(set) var repPulse: Int = 0

    // MARK: Capture

    let session = AVCaptureSession()

    /// The camera preview view, which draws the skeleton. Held weakly and called
    /// directly (off the @Published path) to keep the high-frequency pose stream
    /// from re-rendering the SwiftUI tree.
    weak var poseRenderer: PoseRenderer?

    /// Upright image aspect (width / height), captured once from the video frames.
    private var imageAspect: CGFloat = 0

    private let tracker = ExerciseTrackerManager(exercise: .pushUp)
    private let sessionQueue = DispatchQueue(label: "com.exercisetracker.session")
    private let sampleQueue = DispatchQueue(label: "com.exercisetracker.samples",
                                            qos: .userInitiated)
    private let usingFrontCamera = true
    private var isConfigured = false

    // MARK: Haptics

    private let repHaptic = UINotificationFeedbackGenerator()
    private let warnHaptic = UIImpactFeedbackGenerator(style: .rigid)

    // MARK: Misc

    private var formResetWork: DispatchWorkItem?

    override init() {
        super.init()
        tracker.delegate = self
    }

    // MARK: Lifecycle (called from the View)

    func onAppear() {
        compatibility = tracker.checkDeviceCompatibility()
        guard compatibility.isSupported else { return }
        prepareHaptics()
        requestCameraAndStart()
    }

    func onDisappear() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Exercise selection

    func select(_ newExercise: ExerciseType) {
        guard newExercise != exercise else { return }
        exercise = newExercise
        tracker.configure(exercise: newExercise)
        repCount = 0
        repState = .ready
        depth = 0
        setFormOptimal()
    }

    func toggleSkeleton() {
        showSkeleton.toggle()
    }

    // MARK: Camera setup

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraAuthorized = granted
                    if granted { self?.startSession() }
                }
            }
        default:
            cameraAuthorized = false
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isConfigured { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true   // always analyze the freshest frame
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        isConfigured = true
    }

    // MARK: Haptics helpers

    private func prepareHaptics() {
        repHaptic.prepare()
        warnHaptic.prepare()
    }

    private func doubleBuzz() {
        warnHaptic.impactOccurred(intensity: 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.warnHaptic.impactOccurred(intensity: 0.7)
        }
    }

    /// Distinct posture / anti-cheat alert, per spec — felt without looking.
    private func criticalBuzz() {
        repHaptic.notificationOccurred(.warning)
    }

    // MARK: Form feedback helpers

    private func setFormOptimal() {
        formResetWork?.cancel()
        form = .optimal
    }

    /// Routes an invalid-rep callback to the right severity. The analyzer already
    /// debounces emissions (one per episode), so we can buzz on every call.
    private func showFeedback(_ message: String, severity: FormSeverity) {
        formResetWork?.cancel()
        switch severity {
        case .warning:
            // Amber coaching cue — buzz, then auto-revert if nothing else arrives.
            form = .warning(message)
            doubleBuzz()
            let work = DispatchWorkItem { [weak self] in self?.form = .optimal }
            formResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        case .critical:
            // Crimson posture block — distinct haptic, PERSISTS (no auto-revert);
            // cleared only when posture recovers (see didChangeState).
            form = .critical(message)
            criticalBuzz()
        }
    }

    // MARK: Derived presentation state (consumed by the status banner)

    var statusText: String {
        if !cameraAuthorized { return "Camera unavailable" }
        if !isBodyTracked { return "Position your body" }
        if form.isCritical { return "Fix your posture!" }
        if form.isWarning { return "Adjust your form" }
        switch repState {
        case .ready:              return "Ready!"
        case .descending:         return exercise == .pushUp ? "Lower down…" : "Squat down…"
        case .atBottom:           return "Looking good!"
        case .ascending:          return exercise == .pushUp ? "Press up!" : "Stand up!"
        case .invalidRepDetected: return "Adjust your form"
        case .invalidPosition:    return "Fix your posture!"
        }
    }

    var statusIcon: String {
        if !isBodyTracked { return "figure.stand" }
        if form.isCritical { return "figure.fall" }
        if form.isWarning { return "exclamationmark.triangle.fill" }
        return repState == .ready ? "checkmark.circle.fill" : "flame.fill"
    }

    var statusColor: Color {
        if !isBodyTracked { return Theme.accentBlue }
        if form.isCritical { return Theme.danger }
        if form.isWarning { return Theme.warning }
        return Theme.accent
    }

    /// Ring tint follows form state so the depth ring itself flags bad reps.
    var ringTint: Color {
        if form.isCritical { return Theme.danger }
        if form.isWarning { return Theme.warning }
        return Theme.accent
    }
}

// MARK: - Camera frames → tracker

extension WorkoutViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Capture the upright image aspect once (the .portrait preview rotates the
        // landscape buffer 90°, so width/height swap → aspect = bufferH / bufferW).
        if imageAspect == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            if w > 0 { imageAspect = h / w }
        }

        // Portrait phone: front frames are mirrored, back frames are rotated right.
        let orientation: CGImagePropertyOrientation = usingFrontCamera ? .leftMirrored : .right
        tracker.process(sampleBuffer: sampleBuffer, orientation: orientation)
    }
}

// MARK: - Tracker callbacks → published state (all on main)

extension WorkoutViewModel: ExerciseTrackerDelegate {

    func exerciseTracker(_ tracker: ExerciseTrackerManager, didCountValidRep count: Int) {
        repCount = count
        repPulse &+= 1
        repHaptic.notificationOccurred(.success)
        setFormOptimal()
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager, didChangeState state: RepState) {
        repState = state
        // Posture recovered: the analyzer leaves .invalidPosition once the body
        // is realigned, which clears the persistent crimson block.
        if form.isCritical && state != .invalidPosition {
            setFormOptimal()
        }
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didDetectInvalidRep feedback: String,
                         severity: FormSeverity) {
        showFeedback(feedback, severity: severity)
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateDepth progress: Double) {
        // A valid analyzed frame implies the body is in view.
        if !isBodyTracked { isBodyTracked = true }
        // Quantize to ~1% steps so a held position doesn't spam view updates.
        let stepped = (progress * 100).rounded() / 100
        if stepped != depth { depth = stepped }
    }

    func exerciseTrackerDidLoseTracking(_ tracker: ExerciseTrackerManager) {
        if isBodyTracked { isBodyTracked = false }
    }

    func exerciseTracker(_ tracker: ExerciseTrackerManager,
                         didUpdatePose observation: VNHumanBodyPoseObservation) {
        // Drive the skeleton directly (already on main); bypasses @Published so
        // the SwiftUI HUD doesn't re-render on every frame.
        poseRenderer?.imageAspect = imageAspect
        poseRenderer?.render(observation)
    }
}
