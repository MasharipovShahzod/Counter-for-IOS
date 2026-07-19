//
//  CrunchAnalyzer.swift
//  ExerciseTracker
//
//  The crunch state machine. Side-view framing.
//
//  DRIVEN BY THE HIP ANGLE, ON PURPOSE
//  -----------------------------------
//  Shoulder–hip–knee is rotation-invariant, so it survives the phone being
//  propped at whatever angle the athlete found convenient. See the long note on
//  `CrunchConfig` for why every floor-relative alternative was rejected.
//
//  FILTERING
//  ---------
//  The three driving joints go through `OneEuroFilter` and the FSM gates read
//  that output DIRECTLY. No second EMA pass sits on the rep path — that would
//  add ~100ms and detect the peak of a fast crunch after the athlete had already
//  started back down. The alpha-0.3 EMA appears only inside `SwayMonitor`, whose
//  baseline is frozen at the start of the ascent and never touches the counter.
//
//  ALLOCATION: the filters and the monitor are structs stored inline. The only
//  per-frame allocation is the `[AnalyzerEvent]` return, which is the existing
//  protocol contract shared by every analyzer.
//

import Foundation
import CoreGraphics

final class CrunchAnalyzer: ExerciseAnalyzer {

    private let cfg = CrunchConfig.standard

    private var currentState: RepState = .ready
    private var reps = 0

    /// True once a valid LYING position has been observed. A machine that has
    /// never seen the athlete flat has no business crediting a rep — otherwise
    /// walking into frame already curled up pays out on the way down.
    private var isArmed = false

    /// True between leaving the lying gate and returning to it.
    private var attemptInProgress = false

    /// True once the peak gate has been satisfied during the current attempt.
    private var reachedPeak = false

    /// Smallest hip angle seen this attempt, and the value from the last
    /// credited rep — this is what the security ledger signs.
    private var minHipThisRep: CGFloat = .greatestFiniteMagnitude
    private var lastPeak: CGFloat?

    // Per-joint coordinate filters.
    //
    // BETA IS SCALED FOR NORMALIZED COORDINATES, and that is why it looks huge
    // next to published 1€ values. Those assume pixel- or degree-scale signals
    // moving at hundreds of units per second. Here the whole image is 1.0 wide,
    // so a crunch shoulder travels ~0.13 units in ~0.4s — about 0.33 units/s.
    // At the 1€ default beta the adaptive term would contribute under 9% of the
    // cutoff, leaving a fixed ~157ms lag: worse than the EMA this design
    // rejected for costing ~100ms and finding the peak late.
    //
    // UNVALIDATED ON DEVICE — tuned against synthetic fixtures only.
    private var shoulderFilter = OneEuroPointFilter(minCutoff: 1.2, beta: 10)
    private var hipFilter      = OneEuroPointFilter(minCutoff: 1.2, beta: 10)
    private var kneeFilter     = OneEuroPointFilter(minCutoff: 1.2, beta: 10)

    /// Measures physical hip sliding against a baseline frozen the moment the
    /// ascent begins. Non-blocking by construction — see `SwayMonitor`.
    private var sway = SwayMonitor(maxDriftFraction: CrunchConfig.standard.maxHipDriftThighFraction)

    var state: RepState { currentState }
    var successfulReps: Int { reps }
    var lastRepPeakDepthAngle: Double? { lastPeak.map(Double.init) }

    func analyze(frame: PoseFrame) -> [AnalyzerEvent] {
        guard let raw = frame.unilateral else { return [] }

        var events: [AnalyzerEvent] = []

        // ---- Confidence floor ----
        // This analyzer wants 0.4 while `BodyJoints.make` admits frames at the
        // tracker's global 0.3, so frames in [0.3, 0.4) arrive here and must be
        // declined. Returning `[]` was wrong: the manager treats an empty event
        // list as "nothing happened", NOT as tracking loss, so the ring froze at
        // its last value and the athlete stared at a stale HUD with no
        // explanation. A lying athlete self-occludes badly, so this band is hit
        // routinely rather than rarely.
        //
        // `PlankAnalyzer` already learned this exact lesson — it keeps emitting
        // progress on invalid frames for the same reason.
        guard raw.minConfidence >= cfg.minConfidence else {
            events.append(.depthProgress(0))
            return events
        }

        // ---- Filtered coordinates, straight into the gates ----
        let shoulder = shoulderFilter.apply(raw.shoulder, at: frame.time)
        let hip      = hipFilter.apply(raw.hip, at: frame.time)
        let knee     = kneeFilter.apply(raw.knee, at: frame.time)

        let hipAngle = PoseGeometry.angle(shoulder, hip, knee)
        let thigh = PoseGeometry.distance(hip, knee)
        guard thigh > 0 else { return events }

        let isLying = hipAngle >= cfg.lyingHipAngle
        let isAtPeak = hipAngle <= cfg.peakHipAngle

        // ---- Progress ring: 0 flat, 1 at peak contraction ----
        let span = cfg.lyingHipAngle - cfg.peakHipAngle
        if span > 0 {
            let progress = (cfg.lyingHipAngle - hipAngle) / span
            events.append(.depthProgress(Double(max(0, min(1, progress)))))
        }

        // ---- Anti-sway ----
        // While lying, the monitor is accumulating its EMA baseline. Once the
        // ascent starts it is frozen, and everything after is measured against
        // where the hip actually was. The cue is advisory: note that nothing in
        // this block touches `reps`, `reachedPeak`, or `currentState`.
        if sway.observe(hip, scale: thigh) {
            events.append(.coachingCue(.swing))
        }

        // ---- Lying: arm the machine and close any attempt in flight ----
        if isLying {
            if attemptInProgress {
                if reachedPeak {
                    reps += 1
                    lastPeak = minHipThisRep
                    events.append(.repCompleted(totalCount: reps))
                } else {
                    events.append(.invalidRep(feedback: "Curl up higher!",
                                              severity: .warning))
                }
                attemptInProgress = false
                reachedPeak = false
                minHipThisRep = .greatestFiniteMagnitude
            }
            isArmed = true
            sway.endActivePhase()          // re-baseline for the next rep
            transition(to: .ready, sink: &events)
            return events
        }

        // ---- Ascent begins ----
        if !attemptInProgress {
            guard isArmed else { return events }   // never seen flat: no rep to open
            attemptInProgress = true
            reachedPeak = false
            minHipThisRep = .greatestFiniteMagnitude
            sway.beginActivePhase()        // FREEZE the baseline here
            transition(to: .ascending, sink: &events)
        }

        minHipThisRep = min(minHipThisRep, hipAngle)

        if isAtPeak {
            reachedPeak = true
            transition(to: .atBottom, sink: &events)   // apex of the contraction
        }

        return events
    }

    /// A tracking gap cannot be judged: the apex is exactly what would have been
    /// missed, so an attempt in flight is voided rather than credited on the next
    /// flat frame. The machine also disarms — the athlete must be seen lying
    /// again before reps resume.
    func trackingLost() -> [AnalyzerEvent] {
        var events: [AnalyzerEvent] = []
        attemptInProgress = false
        reachedPeak = false
        minHipThisRep = .greatestFiniteMagnitude
        isArmed = false
        shoulderFilter.reset()
        hipFilter.reset()
        kneeFilter.reset()
        sway.reset()
        transition(to: .ready, sink: &events)
        return events
    }

    private func transition(to newState: RepState, sink: inout [AnalyzerEvent]) {
        guard newState != currentState else { return }
        currentState = newState
        sink.append(.stateChanged(newState))
    }

    func reset() {
        currentState = .ready
        reps = 0
        isArmed = false
        attemptInProgress = false
        reachedPeak = false
        minHipThisRep = .greatestFiniteMagnitude
        lastPeak = nil
        shoulderFilter.reset()
        hipFilter.reset()
        kneeFilter.reset()
        sway.reset()
    }
}
