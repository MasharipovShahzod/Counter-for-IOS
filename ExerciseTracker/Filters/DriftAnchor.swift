//
//  DriftAnchor.swift
//  ExerciseTracker
//
//  The anti-sway layer: a frozen baseline plus a normalized drift bound.
//
//  WHY THE BASELINE MUST FREEZE
//  ----------------------------
//  Measuring drift against a baseline that keeps following the body is circular
//  — the anchor slides along with the athlete, so a steady creep reads as zero
//  drift and the check never fires. The baseline is therefore built ONLY while
//  the athlete is in the reference posture (flat on the floor for a crunch, dead
//  hang for a pull-up) and frozen the instant the active phase begins. Everything
//  after that is measured against where the body actually started.
//
//  WHY EMA HERE AND 1€ THERE
//  -------------------------
//  This is the ONLY place the alpha-0.3 EMA is used. It is appropriate for a
//  baseline precisely because it is laggy: a static anchor wants heavy averaging
//  and does not care about latency. The rep gates want the opposite and read
//  `OneEuroFilter` output directly — layering this EMA on top of them would add
//  ~100ms and detect the apex of a fast rep too late.
//
//  ALLOCATION: value types with scalar/CGPoint storage only.
//

import Foundation
import CoreGraphics

/// A static positional baseline that can be built, frozen, and measured against.
protocol DriftAnchoring {
    /// True once `freeze()` has been called with a seeded baseline.
    var isFrozen: Bool { get }
    /// Feeds a reference-posture sample. Ignored while frozen.
    mutating func updateBaseline(_ p: CGPoint)
    /// Locks the baseline. No-op if nothing has been observed yet.
    mutating func freeze()
    /// Unlocks the baseline so the next reference phase can re-seed it.
    mutating func thaw()
    mutating func reset()
    /// Euclidean distance from the baseline, in normalized units. 0 if unseeded.
    func drift(from p: CGPoint) -> CGFloat
    /// Horizontal-only distance from the baseline. 0 if unseeded.
    func horizontalDrift(from p: CGPoint) -> CGFloat
}

/// The standard `DriftAnchoring` implementation: an alpha-0.3 EMA that stops
/// updating once frozen.
struct FrozenAnchor: DriftAnchoring {

    /// EMA weight for each new sample. 0.3 per spec — heavy averaging, because a
    /// baseline wants stability and has no latency budget to blow.
    private let alpha: CGFloat

    private var baseline: CGPoint?
    private(set) var isFrozen = false

    init(alpha: CGFloat = 0.3) {
        self.alpha = alpha
    }

    mutating func updateBaseline(_ p: CGPoint) {
        guard !isFrozen, PoseGeometry.isFinite(p) else { return }
        guard let current = baseline else {
            baseline = p                      // first sample seeds outright
            return
        }
        baseline = CGPoint(x: alpha * p.x + (1 - alpha) * current.x,
                           y: alpha * p.y + (1 - alpha) * current.y)
    }

    mutating func freeze() {
        guard baseline != nil else { return }
        isFrozen = true
    }

    mutating func thaw() { isFrozen = false }

    mutating func reset() {
        baseline = nil
        isFrozen = false
    }

    /// Returns 0 when unseeded: with no baseline there is no evidence of drift,
    /// and reporting a large value would fire a coaching cue at an athlete we
    /// have not actually measured yet.
    func drift(from p: CGPoint) -> CGFloat {
        guard let baseline = baseline else { return 0 }
        return PoseGeometry.distance(baseline, p)
    }

    func horizontalDrift(from p: CGPoint) -> CGFloat {
        guard let baseline = baseline, PoseGeometry.isFinite(p) else { return 0 }
        return abs(p.x - baseline.x)
    }
}

/// Wraps a `FrozenAnchor` with a skeletally-normalized bound and a once-per-phase
/// latch, which together are what the analyzers actually need.
///
/// NON-BLOCKING BY CONSTRUCTION: `observe` returns a Bool meaning "worth a cue".
/// It has no access to the rep counter or the FSM state and therefore cannot
/// cancel, penalize, or reset a repetition — the spec's requirement is enforced
/// by this type's shape, not by remembering to be careful at each call site.
struct SwayMonitor {

    /// Allowed drift as a fraction of the supplied skeletal scale (thigh length
    /// for crunches, arm span for pull-ups). Normalizing is what makes one number
    /// correct at every camera distance and body size.
    private let maxDriftFraction: CGFloat

    private var anchor = FrozenAnchor()
    private var isActive = false
    private var hasCuedThisPhase = false

    init(maxDriftFraction: CGFloat) {
        self.maxDriftFraction = maxDriftFraction
    }

    /// Call once the active phase (ascent / pull) begins: freezes the baseline
    /// and re-arms the cue.
    mutating func beginActivePhase() {
        anchor.freeze()
        isActive = true
        hasCuedThisPhase = false
    }

    /// Call when the athlete returns to the reference posture: unfreezes so the
    /// baseline re-seeds for the next rep.
    mutating func endActivePhase() {
        anchor.thaw()
        isActive = false
    }

    /// Feeds one frame.
    ///
    /// - Returns: `true` exactly once per active phase, on the first frame whose
    ///   drift exceeds the bound. Always `false` while inactive (the baseline is
    ///   still being built) and always `false` for a degenerate scale.
    @discardableResult
    mutating func observe(_ p: CGPoint, scale: CGFloat) -> Bool {
        guard isActive else {
            anchor.updateBaseline(p)
            return false
        }
        guard scale > 0, scale.isFinite, !hasCuedThisPhase else { return false }
        guard anchor.horizontalDrift(from: p) > maxDriftFraction * scale else { return false }
        hasCuedThisPhase = true
        return true
    }

    mutating func reset() {
        anchor.reset()
        isActive = false
        hasCuedThisPhase = false
    }
}
