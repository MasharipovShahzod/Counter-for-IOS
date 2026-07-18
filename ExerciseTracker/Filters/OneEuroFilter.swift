//
//  OneEuroFilter.swift
//  ExerciseTracker
//
//  The adaptive 1€ filter (Casiez, Roussel & Vogel, CHI 2012) applied to Vision
//  landmark coordinates.
//
//  WHY THIS RATHER THAN A PLAIN EMA
//  --------------------------------
//  A fixed-alpha EMA forces one choice for two opposite problems: enough
//  smoothing to kill jitter while the athlete is still, and enough
//  responsiveness to catch the apex of a fast rep. Pick a low alpha and the peak
//  arrives ~100ms late, so the rep is credited after the athlete has already
//  started back down. Pick a high alpha and a stationary hand jitters through
//  the gate.
//
//  The 1€ filter resolves that by making the cutoff frequency a function of the
//  signal's own speed: nearly still → low cutoff → heavy smoothing; moving fast
//  → high cutoff → the filter gets out of the way. That is exactly the tradeoff
//  the FSM gates need, which is why they read this filter's output DIRECTLY and
//  no second smoothing pass is applied on top (see `FrozenAnchor`, which is for
//  the drift baseline only and is deliberately NOT in the rep path).
//
//  ALLOCATION: these are structs with only scalar stored properties, mutated in
//  place. Holding one as a stored property costs nothing per frame.
//

import Foundation
import CoreGraphics

/// A one-dimensional adaptive low-pass filter.
struct OneEuroFilter {

    /// Cutoff frequency (Hz) at zero speed. Lower = smoother when still.
    private let minCutoff: CGFloat

    /// How aggressively the cutoff rises with speed. Higher = less lag when fast.
    private let beta: CGFloat

    /// Cutoff (Hz) for the derivative estimate itself, which also needs
    /// smoothing or the adaptive term chases its own noise.
    private let derivativeCutoff: CGFloat

    private var lastValue: CGFloat?
    private var lastDerivative: CGFloat = 0
    private var lastTime: TimeInterval?

    /// - Parameters:
    ///   - minCutoff: tuned for normalized (0...1) Vision coordinates at ~30–60fps.
    ///   - beta: 0 disables speed adaptation, degrading this to a fixed low-pass.
    init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007, derivativeCutoff: CGFloat = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// The standard exponential smoothing factor for a given cutoff and timestep.
    private static func smoothingFactor(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// Filters one sample. `t` must be monotonic; samples that do not advance
    /// time are passed through unchanged rather than dividing by a zero dt.
    ///
    /// FAIL-SAFE: a non-finite input resets the filter and is returned as-is, so
    /// a bad Vision coordinate cannot poison the state permanently. The callers'
    /// own fail-closed guards (see `PoseGeometry.isFinite`) still reject the frame.
    mutating func apply(_ x: CGFloat, at t: TimeInterval) -> CGFloat {
        guard x.isFinite else {
            reset()
            return x
        }
        guard let previous = lastValue, let previousTime = lastTime, t > previousTime else {
            // First sample, or time did not advance: nothing to blend with.
            lastValue = x
            lastTime = t
            lastDerivative = 0
            return x
        }

        let dt = CGFloat(t - previousTime)
        guard dt > 0, dt.isFinite else {
            lastValue = x
            return x
        }

        // Smoothed derivative → the speed estimate that drives the cutoff.
        let derivative = (x - previous) / dt
        let dAlpha = Self.smoothingFactor(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = dAlpha * derivative + (1 - dAlpha) * lastDerivative

        // THE ADAPTIVE STEP: faster movement → higher cutoff → less lag.
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let alpha = Self.smoothingFactor(cutoff: cutoff, dt: dt)
        let filtered = alpha * x + (1 - alpha) * previous

        lastValue = filtered
        lastDerivative = smoothedDerivative
        lastTime = t
        return filtered
    }

    /// Clears all history. Call when a rep attempt is abandoned or tracking is
    /// lost, so the next attempt does not inherit the previous one's tail.
    mutating func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }
}

/// Two independent `OneEuroFilter`s, one per axis. Landmark coordinates are
/// filtered per-axis because x and y jitter independently.
struct OneEuroPointFilter {

    private var x: OneEuroFilter
    private var y: OneEuroFilter

    init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007, derivativeCutoff: CGFloat = 1.0) {
        self.x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        self.y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    mutating func apply(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        CGPoint(x: x.apply(p.x, at: t), y: y.apply(p.y, at: t))
    }

    mutating func reset() {
        x.reset()
        y.reset()
    }
}
