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

    /// This athlete's observed rest hip angle, from which both gates are derived.
    ///
    /// WHY THE GATES ARE NOT FIXED ANGLES
    /// ----------------------------------
    /// Rest posture varies enormously with knee position: knees drawn close can
    /// rest near 110°, legs straight near 180°. Fixed gates of 126/116 assume a
    /// 135° rest, so an athlete who sets up with knees close never reaches the
    /// lying gate, never arms, and counts ZERO forever — while the progress ring
    /// keeps moving, so nothing looks broken. One with straight legs faces the
    /// opposite problem and must perform a full sit-up to register.
    ///
    /// Every other spatial threshold in this tracker is normalized to the
    /// athlete (arm span at the dead hang, thigh length for drift). These two
    /// were the exception, and this closes that gap: the required CLOSURE
    /// (`peakClosure`) is a property of the movement and stays constant, while
    /// the absolute angles float with the body.
    ///
    /// `nil` until a trustworthy angle has been seen; the config's fixed values
    /// are the bootstrap.
    private var restHipAngle: CGFloat?

    /// Slow, because rest is a posture rather than an event and a fast filter
    /// here would let the gates chase the curl they are supposed to judge.
    private static let restAlpha: CGFloat = 0.1

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

        // ---- Learn this athlete's rest posture ----
        // Sampled only while no attempt is open, which after the first rep means
        // genuinely-lying frames. Before the first arm it samples whatever it
        // sees, which is the bootstrap: a low reading there makes the lying gate
        // EASIER to reach, so the machine arms and then self-corrects on the
        // next real rest frame. Erring toward arming is the right direction —
        // the failure this replaces was never arming at all.
        // RATCHETS UPWARD ONLY, and that is the whole subtlety.
        //
        // Rest is the EXTENDED position; a crunch closes from it and never opens
        // past it, so the largest angle seen is the rest posture by definition.
        // An earlier revision used a plain EMA over every non-attempt frame,
        // which quietly broke the gates: the first frames of a descent are still
        // above the lying gate, so they fed the average and dragged rest down —
        // and since `peakGate = rest - peakClosure`, the target moved DOWN as the
        // athlete curled toward it. A spec-conformant rep then missed the gate by
        // a degree and scored nothing. A descent is the start of a rep, not a new
        // resting posture.
        //
        // Downward adaptation is handled by `reset()` and `trackingLost()`
        // clearing the estimate, so repositioning between sets re-learns cleanly.
        if !attemptInProgress, PoseGeometry.isTrustworthyAngle(hipAngle) {
            if let current = restHipAngle {
                if hipAngle > current {
                    restHipAngle = current + Self.restAlpha * (hipAngle - current)
                }
            } else {
                // Bootstrap. Seeding from the first reading — rather than from a
                // fixed constant — is what lets an athlete whose rest sits below
                // the config default arm at all.
                restHipAngle = hipAngle
            }
        }

        let lyingGate = restHipAngle.map { $0 - cfg.lyingMargin } ?? cfg.lyingHipAngle
        let peakGate  = restHipAngle.map { $0 - cfg.peakClosure } ?? cfg.peakHipAngle

        let isLying = hipAngle >= lyingGate
        // `isTrustworthyAngle` FIRST. A degenerate frame yields 0, and
        // `0 <= peakGate` is true — so the sentinel that rejects a broken frame
        // everywhere else would here certify the deepest possible contraction,
        // and one such frame mid-curl is enough to pay out a half-rep.
        let isAtPeak = PoseGeometry.isTrustworthyAngle(hipAngle) && hipAngle <= peakGate

        // ---- Progress ring: 0 at rest, 1 at peak contraction ----
        let span = lyingGate - peakGate
        if span > 0 {
            let progress = (lyingGate - hipAngle) / span
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
        restHipAngle = nil
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
        // Re-learn rest from scratch: a reset means a new set, and the athlete
        // may well have repositioned. A stale rest that is too LOW would lower
        // the peak gate and over-count, so the conservative move is to forget it.
        restHipAngle = nil
        shoulderFilter.reset()
        hipFilter.reset()
        kneeFilter.reset()
        sway.reset()
    }
}
