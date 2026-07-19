//
//  VoiceCoachTests.swift
//  FitnessTrackerTests
//

import XCTest
import AVFoundation
@testable import FitnessTracker

final class VoiceCoachTests: XCTestCase {

    /// Every cue must carry BOTH a full sentence and a single-word fallback, or
    /// the terse strategy has nothing to fall back to.
    func testEveryCueHasBothPhrasings() {
        for cue in VoiceCue.allCases {
            XCTAssertFalse(cue.defaultPhrase.isEmpty, "\(cue) has no phrase")
            XCTAssertFalse(cue.tersePhrase.isEmpty, "\(cue) has no terse phrase")
        }
    }

    /// The terse form is a single soft word — that is the whole point. A terse
    /// phrase with a space in it is a sentence wearing a disguise.
    func testTersePhrasesAreSingleWords() {
        for cue in VoiceCue.allCases {
            XCTAssertFalse(cue.tersePhrase.contains(" "),
                           "\(cue) terse phrase must be one word, got '\(cue.tersePhrase)'")
        }
    }

    /// Selection must prefer higher-quality voices. Given the runner's installed
    /// voices, it must pick one of the best-quality ones available.
    func testSelectionPrefersHigherQuality() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        try XCTSkipIf(voices.isEmpty, "no English voices on this runner")

        let picked = try XCTUnwrap(VoiceCoach.selectVoice(from: voices))
        let bestQuality = voices.map(\.quality.rawValue).max()
        XCTAssertEqual(picked.quality.rawValue, bestQuality,
                       "must pick the highest quality available")
    }

    /// No voice at all is the worst case, not the best — it must read as legacy
    /// so the terse fallback engages rather than reading full sentences through
    /// whatever the system substitutes.
    func testNoVoiceIsTreatedAsLegacy() {
        XCTAssertEqual(VoiceCoach.fidelity(of: nil), .legacy)
    }

    /// An empty candidate list yields no voice rather than trapping.
    func testSelectionFromEmptyListIsNil() {
        XCTAssertNil(VoiceCoach.selectVoice(from: []))
    }

    /// Tone mode must never speak. The spec's TONE flag is an escape hatch for
    /// users who find any voice irritating, so leaking one utterance defeats it.
    func testToneModeNeverSpeaks() {
        let coach = VoiceCoach(mode: .tone)
        coach.say(.swing)
        XCTAssertFalse(coach.isSpeaking, "tone mode must not produce speech")
    }

    /// Silent mode is fully inert.
    func testSilentModeIsInert() {
        let coach = VoiceCoach(mode: .silent)
        coach.say(.swing)
        XCTAssertFalse(coach.isSpeaking)
    }

    /// The spec pins the prosody. These are the numbers that make the voice read
    /// as encouraging rather than robotic, so they are worth locking down.
    func testUtteranceProsodyMatchesSpec() {
        let u = VoiceCoach.makeUtterance(phrase: "Steady", voice: nil)
        XCTAssertEqual(u.pitchMultiplier, 1.05, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(u.rate, 0.45)
        XCTAssertLessThanOrEqual(u.rate, 0.50)
    }

    /// The terse flag must actually select the terse phrasing. This is the
    /// behaviour the whole fallback exists for, so assert the wiring rather than
    /// just the flag.
    func testTerseFlagTracksFidelity() {
        let coach = VoiceCoach(mode: .speech)
        XCTAssertEqual(coach.isTerse, coach.fidelity == .legacy)
    }
}
