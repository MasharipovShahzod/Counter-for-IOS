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
//          // For a portrait-held phone using the BACK camera — the framing this
//          // tracker is designed around — that is `.right`. A FRONT camera is
//          // mirrored and needs `.leftMirrored` instead.
//          tracker.process(sampleBuffer: sampleBuffer, orientation: .right)
//      }
//
//  THE ORIENTATION AND `isFrontCamera` MUST AGREE WITH THE ACTUAL CAMERA.
//  They are two halves of one fact, and nothing catches a mismatch at runtime:
//  the orientation tells Vision how to make the athlete upright, while
//  `isFrontCamera` tells the gravity maths whether the image is mirrored. Get
//  the second one wrong and the orientation anti-cheat silently inverts the
//  moment the phone is tilted — while looking perfectly fine on a phone stood
//  straight up, which is exactly when nobody notices.
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
//   • Call `startSensors()` when the workout screen appears and `stopSensors()`
//     when it goes away, or CoreMotion runs for the tracker's whole lifetime.
//
//  THREADING
//  ---------
//  Everything public here is safe to call from the main queue while Vision is
//  mid-frame on `visionQueue`. That is not free: `stateLock` guards the
//  configuration and the analyzer, because the two queues genuinely do touch
//  the same fields (see the note on `stateLock`).
//

import Foundation
import Vision
import CoreMedia
// AVFoundation is deliberately NOT imported: every AV* symbol moved into
// `VoiceCoach` with the voice refactor. CMSampleBuffer comes from CoreMedia and
// CGImagePropertyOrientation from Vision's re-exports.

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

    /// Timed-hold exercises only (plank): accumulated hold time in seconds.
    /// Fires every analyzed frame while a hold is being judged, and once when it
    /// pauses. Rep-counting exercises never call this. Called on the main queue.
    /// Optional.
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateHold seconds: TimeInterval)

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
    func exerciseTracker(_ tracker: ExerciseTrackerManager, didUpdateHold seconds: TimeInterval) {}
}

// MARK: - Manager

/// Public alias signalling that this manager now enforces the global posture /
/// anti-cheat constraints (torso-horizon pitch + spinal alignment) in its
/// push-up state machine. Use either name interchangeably.
public typealias SecureWorkoutManager = ExerciseTrackerManager

public final class ExerciseTrackerManager {

    // MARK: Public state

    public weak var delegate: ExerciseTrackerDelegate?

    /// Guards everything the main queue and `visionQueue` both touch: the
    /// exercise, the analyzer, the confidence floor, the camera facing and the
    /// security session.
    ///
    /// WHY THIS EXISTS
    /// ---------------
    /// Only `frameInFlight` was ever guarded; the rest were bare `var`s written
    /// from main (`configure`, `reset`, the property setters) and read from
    /// `visionQueue` on every frame. The sharpest edge was `analyzer`:
    /// `configure(exercise:)` swapped the object out from under `visionQueue`
    /// while it was *inside* `analyzer.analyze(frame:)`. `exercise` and
    /// `analyzer` were also two separate reads, so a swap landing between them
    /// paired one exercise's frame with another's state machine — e.g. a
    /// `bilateral` pull-up frame handed to a `PushUpAnalyzer`, which reads
    /// `frame.unilateral`, finds nil, and returns no events forever after.
    ///
    /// The lock is held across `analyze` — pure trig on six points, measured in
    /// microseconds. Vision inference, the genuinely expensive part, runs
    /// outside it.
    private let stateLock = NSLock()

    /// The currently tracked exercise. Changing it resets the count and state.
    public var exercise: ExerciseType {
        stateLock.lock(); defer { stateLock.unlock() }
        return _exercise
    }
    private var _exercise: ExerciseType

    /// Running total of valid reps for the current exercise.
    public var successfulRepsCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _analyzer.successfulReps
    }

    /// Current phase of the rep state machine.
    public var currentState: RepState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _analyzer.state
    }

    /// Set false to mute spoken feedback (text feedback via the delegate still
    /// fires). Defaults to true. Main-queue only — `speak` runs there.
    public var isVoiceFeedbackEnabled = true

    // MARK: Tuning

    /// Per-joint confidence floor. Frames where a required joint is less certain
    /// than this are ignored (treated as "tracking lost").
    public var minimumJointConfidence: Float {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _minimumJointConfidence }
        set { stateLock.lock(); defer { stateLock.unlock() }; _minimumJointConfidence = newValue }
    }
    private var _minimumJointConfidence: Float = 0.3

    // MARK: Защита — Слои 1-4

    /// Подключите SecureWorkoutSession до начала захвата камеры.
    /// nil = защита отключена (только для unit-тестов или симулятора).
    public var secureSession: SecureWorkoutSession? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _secureSession }
        set { stateLock.lock(); defer { stateLock.unlock() }; _secureSession = newValue }
    }
    private var _secureSession: SecureWorkoutSession?

    // MARK: Private

    private var _analyzer: ExerciseAnalyzer
    private let visionQueue = DispatchQueue(label: "com.exercisetracker.vision", qos: .userInitiated)

    // MARK: Frame backpressure

    /// Guards `frameInFlight`. A plain lock is enough: the critical section is a
    /// bool flip, and it's taken once per camera frame from the capture queue.
    private let frameGate = NSLock()
    /// True while a frame is being processed on `visionQueue`.
    private var frameInFlight = false

    /// Frames skipped because Vision was still busy. Diagnostic only — a steady
    /// climb means inference can't keep up with the capture rate on this device.
    /// Written under `frameGate`; read without it, which is fine for a counter
    /// nothing branches on. Don't promote this to a control signal as-is.
    public private(set) var droppedFrameCount: Int = 0
    /// Spoken/tonal coaching. Owns voice selection, the terse fallback for harsh
    /// legacy voices, TONE-mode chimes, the audio session, and per-phrase
    /// debouncing — all of which used to be three ad-hoc properties and a
    /// hand-rolled cooldown here.
    public let voiceCoach = VoiceCoach()

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

    /// True when the active camera is the front (selfie) camera. Determines how
    /// the device gravity vector maps into the mirrored image plane, since a
    /// front camera's image is mirrored and a back camera's is not.
    ///
    /// DEFAULTS TO FALSE (back camera) because that is the framing the tracker
    /// is built for — `PullUpAnalyzer` and `BilateralJoints` only work from
    /// behind the athlete, where both arms are visible and no facial landmark is
    /// needed. It previously defaulted to `true`.
    ///
    /// This MUST match the `orientation` passed to `process(...)` and the actual
    /// capture device. Nothing detects a mismatch: with the phone upright the
    /// gravity vector's x-component is ≈0, so the mirror sign cancels and a
    /// wrong value looks completely healthy — right up until someone props the
    /// phone at an angle and the anti-cheat starts reading tilt backwards.
    public var isFrontCamera: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isFrontCamera }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isFrontCamera = newValue }
    }
    private var _isFrontCamera = false

    /// Supplies gravity for the orientation anti-cheat. `nil` on platforms with
    /// no motion hardware, in which case orientation checks fall back to the
    /// image-space "phone is upright" assumption.
    private let gravitySource: GravitySource?

    // MARK: Init

    /// - Parameter gravitySource: injectable for tests; when omitted, a
    ///   CoreMotion-backed source is used on device (and none in environments
    ///   without CoreMotion).
    public init(exercise: ExerciseType = .pushUp, gravitySource: GravitySource? = nil) {
        self._exercise = exercise
        self._analyzer = ExerciseTrackerManager.makeAnalyzer(for: exercise)
        if let gravitySource = gravitySource {
            self.gravitySource = gravitySource
        } else {
            #if canImport(CoreMotion)
            self.gravitySource = CoreMotionGravitySource()
            #else
            self.gravitySource = nil
            #endif
        }
    }

    deinit { gravitySource?.stop() }

    // MARK: Sensors

    /// Start the motion sensor that feeds the orientation anti-cheat. Call when
    /// the workout screen appears.
    ///
    /// The sensor is NOT started by `init`: this manager is owned by a view
    /// model that outlives the screen being visible, so starting on init left
    /// CoreMotion sampling at 30Hz long after the user had navigated away.
    public func startSensors() { gravitySource?.start() }

    /// Stop the motion sensor. Call when the workout screen goes away. Safe to
    /// call without a matching `startSensors()`.
    public func stopSensors() { gravitySource?.stop() }

    private static func makeAnalyzer(for exercise: ExerciseType) -> ExerciseAnalyzer {
        switch exercise {
        case .pushUp: return PushUpAnalyzer()
        case .squat:  return SquatAnalyzer()
        case .dips:   return DipsAnalyzer()
        case .pullUp: return PullUpAnalyzer()
        case .crunches: return CrunchAnalyzer()
        case .plank:  return PlankAnalyzer()
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
    ///
    /// The exercise and its analyzer are swapped under one lock: they are a
    /// single fact, and `visionQueue` reads both on every frame.
    public func configure(exercise: ExerciseType) {
        stateLock.lock()
        _exercise = exercise
        _analyzer = ExerciseTrackerManager.makeAnalyzer(for: exercise)
        stateLock.unlock()
    }

    /// Zero the counter and return the state machine to `.ready`.
    public func reset() {
        stateLock.lock()
        _analyzer.reset()
        stateLock.unlock()
        // Under the same lock `beginFrame()` increments it on the capture queue.
        frameGate.lock()
        droppedFrameCount = 0
        frameGate.unlock()
    }

    // MARK: Frame ingestion

    /// Claims the single processing slot. Returns false if a frame is already in
    /// flight, meaning the caller should drop this one.
    ///
    /// WHY DROP RATHER THAN QUEUE
    /// --------------------------
    /// The capture delegate fires at 30–60fps. If Vision inference is slower
    /// than the frame interval — which it is on older A12/A13 devices — an
    /// unguarded `visionQueue.async` per frame grows an unbounded backlog, and
    /// every queued work item retains its frame from AVFoundation's FINITE
    /// buffer pool. That is what spikes memory and eventually stalls capture
    /// outright when the pool is exhausted.
    ///
    /// It also defeats `alwaysDiscardsLateVideoFrames = true`: discarding at the
    /// source only helps if the delegate releases buffers promptly, and a
    /// backlog holding them does the opposite. Worse, the analyzer would then be
    /// judging frames from seconds ago while the athlete has moved on.
    ///
    /// Dropping is the correct behaviour, not a compromise — the state machine
    /// wants the freshest frame, never a queued stale one.
    ///
    /// (Note: Swift's ARC does retain `CMSampleBuffer`/`CVPixelBuffer` across the
    /// async hop automatically, so this is about pool exhaustion and staleness,
    /// not a use-after-free. The manual `CFRetain` in Apple's docs is an
    /// Objective-C concern, where ARC does not manage CF types.)
    private func beginFrame() -> Bool {
        frameGate.lock()
        defer { frameGate.unlock() }
        guard !frameInFlight else {
            droppedFrameCount &+= 1
            return false
        }
        frameInFlight = true
        return true
    }

    /// Releases the processing slot. Must run on every exit path from a claimed
    /// frame, or the tracker deadlocks itself into dropping everything forever.
    private func endFrame() {
        frameGate.lock()
        frameInFlight = false
        frameGate.unlock()
    }

    /// Feed one camera frame. Safe to call from your capture delegate queue;
    /// inference runs on the manager's own queue and callbacks land on main.
    ///
    /// Frames arriving while Vision is still busy are DROPPED, not queued — see
    /// `beginFrame()`. Call this on every frame and let the tracker decide.
    ///
    /// - Parameters:
    ///   - sampleBuffer: the frame from AVCaptureVideoDataOutput.
    ///   - orientation: how to rotate the pixels so the person is upright.
    public func process(sampleBuffer: CMSampleBuffer,
                        orientation: CGImagePropertyOrientation = .up) {
        guard beginFrame() else { return }
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endFrame() }
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer,
                                                orientation: orientation,
                                                options: [:])
            self.perform(with: handler)
        }
    }

    /// Convenience overload if you only have a CVPixelBuffer.
    /// Same backpressure contract as the `CMSampleBuffer` overload.
    public func process(pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation = .up) {
        guard beginFrame() else { return }
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.endFrame() }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            self.perform(with: handler)
        }
    }

    /// Runs the pose request and routes the result. Assumes it is already on
    /// `visionQueue` and that the caller releases the frame slot.
    private func perform(with handler: VNImageRequestHandler) {
        do {
            try handler.perform([poseRequest])
            handleResults(poseRequest.results)
        } catch {
            // A single failed frame is non-fatal; just skip it.
            notifyTrackingLost()
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

        // One locked read of the whole configuration. Reading these one at a
        // time would let `configure(exercise:)` land between two of them.
        stateLock.lock()
        let exercise = _exercise
        let session  = _secureSession
        let minConf  = _minimumJointConfidence
        let front    = _isFrontCamera
        stateLock.unlock()

        // Слой 1: проверка живости кадра перед любым анализом.
        // Если secureSession блокирует кадр — трактуем как потерю трекинга.
        // Вызывается БЕЗ нашего замка: у сессии свой, и удерживать оба разом
        // незачем.
        if let session = session,
           !session.validateFrame(observation: observation, exerciseKind: exercise.kind) {
            notifyTrackingLost()
            return
        }

        guard let frame = Self.makeFrame(from: observation,
                                         exercise: exercise,
                                         minConfidence: minConf,
                                         usingFrontCamera: front,
                                         gravity: gravitySource?.deviceGravity) else {
            notifyTrackingLost()
            return
        }

        // Run the state machine, and take the achieved depth in the SAME locked
        // window that produced the events — `lastRepPeakDepthAngle` belongs to
        // the rep these events describe, and reading it later (on main, as this
        // used to) races the next frame overwriting it.
        stateLock.lock()
        let events = _analyzer.analyze(frame: frame)
        let peakDepthAngle = _analyzer.lastRepPeakDepthAngle
        stateLock.unlock()

        guard !events.isEmpty else { return }

        // Слои 2 и 3: обфусцированный инкремент + запись в криптореестр.
        //
        // Записывается здесь, на visionQueue, а не в `dispatch` на main: это не
        // работа UI, и, что важнее, здесь ещё под рукой ИМЕННО тот кадр, который
        // породил повтор. Раньше main-обработчик читал `self.lastFrame` и
        // `analyzer.lastRepPeakDepthAngle` уже после того, как visionQueue
        // уходил обрабатывать следующий кадр, — то есть подписывал в реестр
        // данные соседнего кадра.
        if let session = session,
           events.contains(where: { if case .repCompleted = $0 { return true } else { return false } }),
           let confidences = Self.confidences(from: frame) {
            session.registerRep(confidences: confidences,
                                peakDepthAngle: peakDepthAngle ?? 0)
        }

        dispatch(events)
    }

    /// Builds the frame the active exercise needs.
    ///
    /// Pull-ups are the odd one out: they're judged on BOTH arms against a
    /// locked bar line, which a single-side `BodyJoints` cannot express. Every
    /// other exercise is judged from a side profile where the far limbs are
    /// occluded anyway, so the one-sided snapshot is the right model there.
    /// Static and fully parameterised: every input is passed in from the single
    /// locked snapshot the caller took, so this can never read a field that has
    /// changed since.
    private static func makeFrame(from observation: VNHumanBodyPoseObservation,
                                  exercise: ExerciseType,
                                  minConfidence: Float,
                                  usingFrontCamera: Bool,
                                  gravity: GravityVector?) -> PoseFrame? {
        // Monotonic. Wall-clock time would let an NTP correction rewind a plank
        // mid-hold, corrupting the duration the ledger later signs.
        let time = ProcessInfo.processInfo.systemUptime

        // Real-world "down" in the image plane, for the orientation anti-cheat.
        // nil when gravity is unavailable or the phone is too flat to trust.
        let imageDown = gravity.flatMap {
            PoseGeometry.imageDown(deviceGravity: (x: $0.x, y: $0.y, z: $0.z),
                                   usingFrontCamera: usingFrontCamera)
        }

        switch exercise {
        case .pullUp:
            guard let bilateral = BilateralJoints.make(from: observation,
                                                       minConfidence: minConfidence)
            else { return nil }
            return PoseFrame(bilateral: bilateral, time: time, imageDown: imageDown)

        case .pushUp, .squat, .dips, .crunches, .plank:
            // Plank applies its own, stricter confidence floor internally
            // (`PlankConfig.minConfidence`) — the spec asks for the timer to
            // start only under high confidence.
            guard let unilateral = BodyJoints.make(from: observation,
                                                   for: exercise,
                                                   minConfidence: minConfidence)
            else { return nil }
            return PoseFrame(unilateral: unilateral, time: time, imageDown: imageDown)
        }
    }

    /// Vision confidence map written into the signed ledger entry — direct
    /// evidence a real skeleton was tracked when the rep was credited.
    private static func confidences(from frame: PoseFrame) -> [String: Float]? {
        if let u = frame.unilateral {
            return ["minConfidence": u.minConfidence,
                    "side": u.side == .left ? 1.0 : 0.0]
        }
        if let b = frame.bilateral {
            // No "side" key: a pull-up is judged on both arms at once. The
            // backend treats jointConfidences as a free-form dict, so omitting
            // it is schema-compatible.
            return ["minConfidence": b.minConfidence]
        }
        return nil
    }

    private func dispatch(_ events: [AnalyzerEvent]) {
        DispatchQueue.main.async { [weak self] in
            self?.deliver(events)
        }
    }

    /// Fans events out to the delegate. Main queue only.
    private func deliver(_ events: [AnalyzerEvent]) {
        for event in events {
            switch event {
            case .stateChanged(let state):
                delegate?.exerciseTracker(self, didChangeState: state)

            case .repCompleted(let total):
                // The ledger write already happened on `visionQueue`, next to
                // the frame that earned it. All that's left here is the UI.
                delegate?.exerciseTracker(self, didCountValidRep: total)

            case .invalidRep(let feedback, let severity):
                delegate?.exerciseTracker(self, didDetectInvalidRep: feedback,
                                          severity: severity)
                speak(feedback)

            case .coachingCue(let cue, let severity):
                // The delegate gets the same wording the athlete hears, and
                // `say(_: VoiceCue)` — unlike the String overload — honours the
                // terse fallback and TONE mode. Severity now comes FROM the
                // event: most cues are advisory, but `.grounded` is a rep-voiding
                // anti-cheat fault and must render as one.
                delegate?.exerciseTracker(self, didDetectInvalidRep: voiceCoach.phrase(for: cue),
                                          severity: severity)
                if isVoiceFeedbackEnabled { voiceCoach.say(cue) }

            case .depthProgress(let progress):
                delegate?.exerciseTracker(self, didUpdateDepth: progress)

            case .holdProgress(let seconds):
                delegate?.exerciseTracker(self, didUpdateHold: seconds)
            }
        }
    }

    /// No usable body this frame. Tells the analyzer to stand down and forwards
    /// whatever that produced, then reports the loss.
    ///
    /// Both go out in ONE main-queue block, in this order, on purpose: the
    /// analyzer's parting events can include `.holdProgress`, which the view
    /// model reads as "a body is in view". Delivered as two separate blocks,
    /// SwiftUI could render the moment in between and flash the HUD back to
    /// "tracked" on the very frame we lost the athlete.
    private func notifyTrackingLost() {
        stateLock.lock()
        let events = _analyzer.trackingLost()
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.deliver(events)
            self.delegate?.exerciseTrackerDidLoseTracking(self)
        }
    }

    // MARK: Voice feedback

    /// Speaks a phrase through the coach, unless voice feedback is switched off.
    ///
    /// The audio session, voice selection, prosody and per-phrase debouncing all
    /// live in `VoiceCoach` now. This used to build an `AVSpeechUtterance` here
    /// with the default rate and a bare `en-US` voice, which meant taking
    /// whatever the system handed back — often a compact legacy voice — and
    /// reading full sentences through it at a flat, robotic cadence.
    private func speak(_ phrase: String) {
        guard isVoiceFeedbackEnabled else { return }
        voiceCoach.say(phrase)
    }
}
