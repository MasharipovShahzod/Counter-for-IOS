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

    /// Accumulated plank time, in seconds. Only meaningful when
    /// `exercise.kind == .hold`; stays 0 for rep-counting exercises.
    @Published private(set) var holdSeconds: TimeInterval = 0
    @Published private(set) var isBodyTracked: Bool = false
    @Published private(set) var compatibility: SafetyCheckResult = .supported
    @Published private(set) var cameraAuthorized: Bool = true

    /// Non-nil when a security layer has blocked the session. The workout is
    /// over at that point — the HUD surfaces this as a blocking overlay rather
    /// than letting the athlete keep repping into a counter nobody will honour.
    @Published private(set) var securityBlock: String?

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

    /// Which camera films the workout.
    ///
    /// FALSE — the BACK camera. The whole tracker is designed around filming the
    /// athlete from behind: `PullUpAnalyzer` measures both wrists against a
    /// locked bar line and deliberately consults no facial landmark, because
    /// from behind there are none. This was hardcoded `true` (and, being a
    /// `let`, unswitchable), so the app ran the selfie camera and that entire
    /// design was unreachable.
    ///
    /// Three things must move together if this changes: the capture `position`,
    /// the `CGImagePropertyOrientation` handed to Vision, and
    /// `tracker.isFrontCamera` — see `configureSession()` and `captureOutput`.
    private var usingFrontCamera = false
    private var isConfigured = false

    // MARK: Security (Layers 1–4)

    private var security: SecureWorkoutSession?
    private var securityTask: Task<Void, Never>?

    // MARK: Haptics

    private let repHaptic = UINotificationFeedbackGenerator()
    private let warnHaptic = UIImpactFeedbackGenerator(style: .rigid)

    // MARK: Misc

    private var formResetWork: DispatchWorkItem?

    override init() {
        super.init()
        tracker.delegate = self
        tracker.isFrontCamera = usingFrontCamera
    }

    // MARK: Lifecycle (called from the View)

    func onAppear() {
        compatibility = tracker.checkDeviceCompatibility()
        guard compatibility.isSupported else { return }
        prepareHaptics()
        // CoreMotion feeds the orientation anti-cheat. Bracketed by the screen's
        // lifetime, not the tracker's — the tracker outlives this screen being
        // visible, so starting it in `init` left the sensor sampling at 30Hz
        // after the user had navigated away.
        tracker.startSensors()
        startSecurity()
        requestCameraAndStart()
    }

    func onDisappear() {
        tracker.stopSensors()
        finishSecurity()
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
        holdSeconds = 0
        setFormOptimal()
    }

    func toggleSkeleton() {
        showSkeleton.toggle()
    }

    // MARK: Security lifecycle

    /// Security configuration for the project AS IT ACTUALLY STANDS TODAY.
    ///
    /// Being blunt about what is on and why, because the honest answer is "less
    /// than the file names suggest":
    ///
    ///  • L1 anti-spoofing — ON. Fully local, no dependencies, works today.
    ///  • L2 process integrity — ON, but see `softMode`.
    ///  • L3 crypto ledger + ECDH — OFF. It needs a live backend, and
    ///    `SecurityConfiguration` still ships the placeholder host
    ///    `api.yourfitnessapp.com`. Enabled, `startSession()` would fail on the
    ///    handshake and take the whole workout down with it.
    ///  • L4 SSL pinning — OFF alongside L3. There is nothing to pin until
    ///    there are requests to make.
    ///  • `softMode` — ON, because `expectedTeamID` and `expectedBundleID` are
    ///    placeholders (`"ВАШЕ_TEAM_ID"`, `com.yourcompany.exercisetracker`)
    ///    while the real bundle id is `com.example.fitnesstracker`. In hard mode
    ///    `AppIntegrityChecker` would spot the mismatch and block every build,
    ///    including honest ones.
    ///
    /// TO GO LIVE, IN THIS ORDER:
    ///   1. Real `sessionInitURL` / `workoutVerifyURL`.
    ///   2. Real `expectedTeamID` / `expectedBundleID`.
    ///   3. Real SPKI hashes in `pinConfig`.
    ///   4. Then `enableStateLedger = true`, `enableSSLPinning = true`,
    ///      `softMode = false`.
    ///
    /// Until step 4 lands, treat this layer as telemetry rather than protection:
    /// with no server verifying the ledger, the rep count is still just the
    /// client's word.
    private static func makeSecurityConfiguration() -> SecurityConfiguration {
        var config = SecurityConfiguration()
        config.enableAntiSpoofing     = true
        config.enableProcessIntegrity = true
        config.enableStateLedger      = false
        config.enableSSLPinning       = false
        config.softMode               = true
        return config
    }

    private func startSecurity() {
        guard security == nil else { return }
        let session = SecureWorkoutSession(configuration: Self.makeSecurityConfiguration())
        session.delegate = self
        security = session

        securityTask = Task { [weak self] in
            do {
                try await session.startSession()
            } catch {
                // Read the message out here: `Error` isn't Sendable, and hopping
                // one across the actor boundary is a needless fight to pick.
                let message = error.localizedDescription
                await MainActor.run {
                    // A failed start must not fail silently — the athlete would
                    // otherwise train a whole set believing they were covered.
                    self?.securityBlock = message
                }
                return
            }
            await MainActor.run {
                // Attached only AFTER a successful start, never before: until
                // the session is active `validateFrame` refuses every frame, and
                // the tracker reads a refusal as lost tracking. Wiring it up
                // front would park the HUD on "Position your body" for the whole
                // handshake.
                self?.tracker.secureSession = session
            }
        }
    }

    private func finishSecurity() {
        securityTask?.cancel()
        securityTask = nil
        guard let session = security else { return }
        security = nil
        tracker.secureSession = nil
        // Fire-and-forget: the screen is already going away, and with the ledger
        // disabled this just returns the local count. The task holds the last
        // strong reference, so the session deinits — and invalidates its
        // URLSession — once this completes.
        Task { try? await session.finishSession() }
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

        // Preview and analysis get DIFFERENT resolutions, split by device tier —
        // 1080p/720p for the preview, 720p/540p for Vision. `.high` used to set
        // both, which handed the analyser a full-size buffer on every frame for
        // no accuracy gain. See `CaptureConfiguration`.
        let tier = DeviceCompatibility.performanceTier
        CaptureConfiguration.applyPreviewPreset(to: session, tier: tier)

        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true   // always analyze the freshest frame
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            // After `addOutput`: the output must belong to the session before
            // its video settings can be negotiated.
            CaptureConfiguration.applyAnalysisResolution(to: output, tier: tier)
        }

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
        case .ready:              return readyCue
        case .barLocked:          return "Hang and pull!"
        case .holding:            return "Hold it!"
        case .descending:         return descendingCue
        // `.atBottom` is the APEX for the two exercises that pull/curl upward.
        // The pull-up cue used to say "Chin over the bar!", naming a landmark the
        // tracker deliberately never reads — `BilateralJoints` carries no facial
        // joints, and a rep is judged on shoulder travel against the locked bar
        // line. Coaching the athlete toward a cue the machine cannot see invites
        // them to chase it and wonder why nothing counts.
        case .atBottom:
            switch exercise {
            case .pullUp:   return "Shoulders to the bar!"
            case .crunches: return "Hold the squeeze!"
            default:        return "Looking good!"
            }
        case .ascending:          return ascendingCue
        case .invalidRepDetected: return "Adjust your form"
        case .invalidPosition:    return "Fix your posture!"
        }
    }

    /// `.ready` means different things per exercise: at the top of a push-up,
    /// standing for a squat — but for a pull-up it means "not on the bar yet",
    /// and for a plank "not in position yet". A flat "Ready!" would be wrong.
    private var readyCue: String {
        switch exercise {
        case .pullUp:   return "Face the camera, then grab the bar"
        case .crunches: return "Lie down side-on to the camera"
        case .dips:     return "Stand side-on to the camera"
        case .plank:    return "Get into position"
        default:        return "Ready!"
        }
    }

    private var descendingCue: String {
        switch exercise {
        case .pushUp: return "Lower down…"
        case .squat:  return "Squat down…"
        case .dips:   return "Dip down…"
        case .pullUp: return "Lower…"
        // A crunch never enters `.descending` — its FSM curls up from lying via
        // `.ascending`. This branch exists only to keep the switch exhaustive.
        case .crunches: return "Lower back down…"
        case .plank:  return "Hold…"
        }
    }

    private var ascendingCue: String {
        switch exercise {
        case .pushUp, .dips: return "Press up!"
        case .squat:         return "Stand up!"
        case .pullUp:        return "Pull!"
        case .crunches:      return "Curl up!"
        case .plank:         return "Hold…"
        }
    }

    /// True when the HUD should show the plank timer instead of the rep ring.
    var showsHoldTimer: Bool { exercise.kind == .hold }

    /// True while the plank clock is actively running (not arming or paused).
    var timerIsRunning: Bool { repState == .holding }

    /// Plank time as `M:SS`, for the HUD.
    var holdText: String { Self.formatHold(holdSeconds) }

    /// Formats a hold duration as `M:SS` with a zero-padded seconds field.
    /// Pure and static so it can be tested without standing up the view model
    /// or a camera. Negative input is clamped to zero.
    static func formatHold(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
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

// MARK: - Security callbacks (all delivered on main)

extension WorkoutViewModel: SecureWorkoutSessionDelegate {

    func secureSession(_ session: SecureWorkoutSession,
                       wasBlockedBy error: SecuritySessionError) {
        securityBlock = error.localizedDescription
    }

    func secureSession(_ session: SecureWorkoutSession, detectedThreat description: String) {
        // Soft mode: the session carries on, but saying nothing would make the
        // whole layer indistinguishable from it being switched off.
        showFeedback(description, severity: .warning)
    }

    func secureSession(_ session: SecureWorkoutSession, didReceiveReceipt receipt: ServerReceipt) {
        // The server is the authority on the count once a ledger round-trip
        // exists. Until `enableStateLedger` is on there is no round-trip, so
        // this never fires — see `makeSecurityConfiguration()`.
        repCount = receipt.verifiedRepCount
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

    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateHold seconds: TimeInterval) {
        if !isBodyTracked { isBodyTracked = true }
        // The HUD renders whole seconds, so only republish when that changes —
        // otherwise a plank re-renders the SwiftUI tree 30 times a second to
        // show the same string.
        if Int(seconds) != Int(holdSeconds) { holdSeconds = seconds }
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
