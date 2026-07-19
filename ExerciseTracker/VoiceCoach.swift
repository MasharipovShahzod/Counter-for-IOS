//
//  VoiceCoach.swift
//  ExerciseTracker
//
//  Spoken and tonal coaching feedback.
//
//  THE TERSE FALLBACK, AND WHY IT EXISTS
//  -------------------------------------
//  iOS does not guarantee a good voice. On a device where the enhanced/premium
//  English voices were never downloaded, `AVSpeechSynthesisVoice` falls back to
//  a compact legacy voice that is genuinely unpleasant to listen to — and a bad
//  voice reading "Keep your body steady and controlled" mid-set is worse
//  feedback than no feedback, because the athlete turns the audio off and then
//  gets none of it. So the engine measures what it actually got and, on a legacy
//  voice, shortens every cue to one soft word. `.tone` mode drops speech
//  entirely in favour of a chime for users who want neither.
//

import Foundation
import AVFoundation
#if os(iOS)
import AudioToolbox
#endif

// MARK: - Cues

/// A single coaching moment. Each carries a full sentence, a one-word fallback,
/// and a chime, so the delivery strategy can be chosen at speak time rather than
/// duplicated at every call site.
///
/// NAMING: the spec writes these as `VoiceCue.SWING`. Swift enum cases are
/// lowerCamelCase, and the spec also asks for idiomatic Swift; the idiom wins.
public enum VoiceCue: String, CaseIterable {
    /// Structural drift / pendulum sway. Advisory — never voids a rep.
    case swing
    /// Insufficient range of motion at the top.
    case higher
    /// Insufficient depth at the bottom.
    case lower
    /// Posture / alignment failure.
    case posture
    /// A rep was credited.
    case goodRep
    /// The feet were carrying the body — a dip performed with the feet planted
    /// on the floor. Unlike `.swing` this one VOIDS the rep; it is emitted at
    /// `.critical` severity.
    case grounded

    /// Full natural sentence, used with a high-fidelity voice.
    public var defaultPhrase: String {
        switch self {
        case .swing:    return "Keep your body steady."
        case .higher:   return "Try to come up a little higher."
        case .lower:    return "Go a little deeper on the next one."
        case .posture:  return "Straighten up and keep your body aligned."
        case .goodRep:  return "Nice rep."
        case .grounded: return "Lift your feet — let your arms take the weight."
        }
    }

    /// Single soft word, used when the system fell back to a harsh legacy voice.
    public var tersePhrase: String {
        switch self {
        case .swing:    return "Steady"
        case .higher:   return "Higher"
        case .lower:    return "Deeper"
        case .posture:  return "Align"
        case .goodRep:  return "Good"
        case .grounded: return "Feet up"
        }
    }

    /// System sound used in `.tone` mode. These are short, soft, built-in chimes
    /// — no bundled audio assets, so nothing to ship or fail to load.
    public var systemSoundID: UInt32 {
        switch self {
        case .swing:    return 1103
        case .higher:   return 1113
        case .lower:    return 1114
        case .posture:  return 1073
        case .goodRep:  return 1057
        // Shares the posture chime: both are hard faults that void a rep, and a
        // sixth distinct tone is one more than an athlete can tell apart mid-set.
        case .grounded: return 1073
        }
    }
}

// MARK: - Coach

public final class VoiceCoach {

    /// How feedback is delivered.
    public enum Mode {
        /// Spoken cues, full or terse depending on the voice we got.
        case speech
        /// The spec's `TONE` flag: chimes only, no speech at all.
        case tone
        /// Nothing.
        case silent
    }

    /// How good the voice we actually got is.
    public enum Fidelity {
        /// Enhanced or premium — natural enough for full sentences.
        case neural
        /// Compact/default OEM voice, or none at all. Triggers terse speech.
        case legacy
    }

    public var mode: Mode

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    public private(set) var fidelity: Fidelity

    /// True when cues must be shortened to a single word.
    public var isTerse: Bool { fidelity == .legacy }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Debounce: the same cue cannot repeat inside this window. A form fault
    /// persists for many frames and would otherwise be spoken on every one.
    private var lastSpokenAt: [String: Date] = [:]
    private let cooldown: TimeInterval = 2.5

    public init(mode: Mode = .speech) {
        self.mode = mode
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        self.voice = Self.selectVoice(from: candidates)
        self.fidelity = Self.fidelity(of: self.voice)
    }

    // MARK: Voice selection

    /// Picks the best available voice: highest quality first, then a female
    /// profile where the platform reports gender, then a stable name order so
    /// the choice does not wander between launches.
    ///
    /// Pure and `static` so it can be tested against a supplied list rather than
    /// whatever voices happen to be installed on the CI runner.
    public static func selectVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        guard !voices.isEmpty else { return nil }
        return voices.max { a, b in
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue < b.quality.rawValue
            }
            let aFemale = Self.isFemale(a), bFemale = Self.isFemale(b)
            if aFemale != bFemale { return bFemale }
            return a.name > b.name          // stable tiebreak
        }
    }

    private static func isFemale(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 13.0, *) { return v.gender == .female }
        return false
    }

    /// Enhanced and premium voices are the neural ones; anything else (including
    /// the absence of a voice) is treated as legacy and triggers terse speech.
    public static func fidelity(of voice: AVSpeechSynthesisVoice?) -> Fidelity {
        guard let voice = voice else { return .legacy }
        if #available(iOS 16.0, *), voice.quality == .premium { return .neural }
        return voice.quality == .enhanced ? .neural : .legacy
    }

    // MARK: Speaking

    /// Prepares the audio session once, lazily. `.duckOthers` is the right
    /// shape: a cue is a second long and should dip the athlete's music, not
    /// end it.
    private static let prepareAudioSession: Void = {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])
        #endif
    }()

    /// Builds the utterance with the spec's prosody. `static` and pure so the
    /// numbers can be asserted without a synthesizer.
    public static func makeUtterance(phrase: String,
                                     voice: AVSpeechSynthesisVoice?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: phrase)
        u.voice = voice
        // Spec: warmer, encouraging, less robotic.
        u.pitchMultiplier = 1.05
        u.rate = 0.47                       // inside the specified 0.45...0.50
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        return u
    }

    /// The text form of a cue under the current fidelity — full sentence on a
    /// neural voice, one soft word on a legacy one. Exposed so callers that also
    /// need to DISPLAY the cue (the delegate's on-screen warning) show the same
    /// wording the athlete hears, rather than the two drifting apart.
    public func phrase(for cue: VoiceCue) -> String {
        isTerse ? cue.tersePhrase : cue.defaultPhrase
    }

    /// Delivers a cue through whichever channel the current mode selects.
    /// Thread-safe; see `onMain`.
    public func say(_ cue: VoiceCue) {
        onMain { [weak self] in
            guard let self = self else { return }
            switch self.mode {
            case .silent:
                return
            case .tone:
                self.playTone(cue)
            case .speech:
                self.speakOnMain(self.isTerse ? cue.tersePhrase : cue.defaultPhrase)
            }
        }
    }

    /// Hops to the main queue when it isn't already there.
    ///
    /// WHY THIS IS NOT OPTIONAL
    /// -----------------------
    /// `VoiceCoach` is public API reached through
    /// `ExerciseTrackerManager.voiceCoach`, so callers outside this module can —
    /// and eventually will — call `say` from whatever thread they are on.
    /// `lastSpokenAt` is a plain `Dictionary`: concurrent mutation is undefined
    /// behaviour and can corrupt its internal storage, not merely drop a
    /// debounce. `AVSpeechSynthesizer` also expects main-thread use.
    ///
    /// The in-tree caller (`ExerciseTrackerManager.deliver`) is already on main,
    /// so this is a no-op hop there and costs nothing on the hot path.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Speaks a raw phrase. Debounced per-phrase. Thread-safe.
    public func say(_ phrase: String) {
        onMain { [weak self] in self?.speakOnMain(phrase) }
    }

    private func speakOnMain(_ phrase: String) {
        guard mode == .speech else { return }
        let now = Date()
        if let last = lastSpokenAt[phrase], now.timeIntervalSince(last) < cooldown {
            return
        }
        lastSpokenAt[phrase] = now

        _ = Self.prepareAudioSession
        synthesizer.speak(Self.makeUtterance(phrase: phrase, voice: voice))
    }

    private func playTone(_ cue: VoiceCue) {
        #if os(iOS)
        let now = Date()
        let key = "tone-\(cue.rawValue)"
        if let last = lastSpokenAt[key], now.timeIntervalSince(last) < cooldown { return }
        lastSpokenAt[key] = now
        _ = Self.prepareAudioSession
        AudioServicesPlaySystemSound(SystemSoundID(cue.systemSoundID))
        #endif
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
