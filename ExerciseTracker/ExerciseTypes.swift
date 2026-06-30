//
//  ExerciseTypes.swift
//  ExerciseTracker
//
//  Core value types shared across the tracker: the exercise catalogue,
//  the rep state machine states, the device-compatibility result, and
//  the tuning thresholds for each movement.
//

import Foundation

// MARK: - Exercise

/// The movements the tracker understands.
public enum ExerciseType: String, CaseIterable {
    case pushUp
    case squat

    public var displayName: String {
        switch self {
        case .pushUp: return "Push-ups"
        case .squat:  return "Squats"
        }
    }

    /// Tuning thresholds for this exercise. Centralised here so the geometry
    /// is easy to audit and adjust without touching the state-machine logic.
    var thresholds: ExerciseThresholds {
        switch self {
        case .pushUp:
            return ExerciseThresholds(
                descentStartAngle: 150,   // primary joint must drop below this to begin a rep
                depthAngle:        90,    // "deep enough" — elbow at/under 90°
                lockoutAngle:      165,   // arms locked at the top
                reversalMargin:    12,    // angle must rise this much past the minimum to count as "ascending"
                supportAngleMin:   155,   // shoulder–hip–knee: below this = sagging/arching (anti-cheat)
                torsoLeanMax:      .infinity, // not used for push-ups
                maxTorsoPitch:     30     // shoulder→hip line must stay within 30° of horizontal
            )
        case .squat:
            return ExerciseThresholds(
                descentStartAngle: 160,
                depthAngle:        90,    // thighs ~parallel to floor
                lockoutAngle:      170,   // standing tall
                reversalMargin:    12,
                supportAngleMin:   .infinity, // back-sag check not used for squats
                torsoLeanMax:      55,    // torso angle from vertical; beyond this = forward collapse
                maxTorsoPitch:     .infinity // horizon constraint is push-up-specific
            )
        }
    }
}

/// Geometric tolerances for a single exercise. All angles are in degrees.
struct ExerciseThresholds {
    /// The primary joint angle (elbow for push-ups, knee for squats) must drop
    /// below this to be considered "starting the descent" of a new rep.
    let descentStartAngle: CGFloat
    /// The primary joint must reach at least this depth for the rep to be valid.
    let depthAngle: CGFloat
    /// The primary joint must return above this to "lock out" / stand up.
    let lockoutAngle: CGFloat
    /// How far past the recorded minimum the angle must climb before we treat
    /// the movement as a genuine ascent (debounces jitter at the bottom).
    let reversalMargin: CGFloat
    /// Push-ups: shoulder–hip–knee angle. Falling below this flags a sag/arch.
    let supportAngleMin: CGFloat
    /// Squats: maximum allowed torso lean from vertical before "chest up" fires.
    let torsoLeanMax: CGFloat
    /// Push-ups: maximum allowed absolute pitch of the shoulder→hip (torso)
    /// vector away from the horizontal plane. Beyond this the body is piked or
    /// standing, not in a plank — the rep is rejected. (Anti-cheat constraint.)
    let maxTorsoPitch: CGFloat
}

// MARK: - Rep state machine

/// The phases a single repetition passes through. One machine per exercise.
public enum RepState: String {
    /// Top / start position — arms locked (push-up) or standing tall (squat).
    case ready
    /// Moving down, depth not yet reached.
    case descending
    /// Reached valid depth at the bottom of the rep.
    case atBottom
    /// Moving back up toward the start position.
    case ascending
    /// A rep-level form error was detected (e.g. half-rep); it won't be counted.
    case invalidRepDetected
    /// Global body orientation/alignment is invalid (piked hips, standing, or
    /// spinal sag). The counter is hard-locked until posture is corrected.
    case invalidPosition
}

// MARK: - Form feedback severity

/// Distinguishes a transient coaching cue from a hard posture/anti-cheat block.
/// The UI maps `.critical` to the crimson posture-failure styling.
public enum FormSeverity {
    /// Amber coaching cue (e.g. "Go down lower!"). Auto-clears.
    case warning
    /// Crimson posture / anti-cheat failure. Persists until corrected.
    case critical
}

// MARK: - Device compatibility

/// Result of `ExerciseTrackerManager.checkDeviceCompatibility()`.
public enum SafetyCheckResult: Equatable {
    /// Hardware + OS can run real-time body pose estimation.
    case supported
    /// The OS is too old for the required Vision request revision.
    case unsupportedOS(message: String)
    /// The chip lacks a Neural Engine fast enough for real-time tracking.
    case unsupportedHardware(message: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// User-facing message for the failure cases (nil when supported).
    public var userMessage: String? {
        switch self {
        case .supported:                       return nil
        case .unsupportedOS(let m):            return m
        case .unsupportedHardware(let m):      return m
        }
    }
}
