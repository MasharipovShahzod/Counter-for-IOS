//
//  CaptureConfiguration.swift
//  ExerciseTracker
//
//  The capture-resolution policy, in one place.
//
//  THE PROBLEM THIS SOLVES
//  -----------------------
//  A single `sessionPreset` sets the resolution for BOTH the preview the athlete
//  watches and the buffers Vision analyses, but those two consumers want
//  opposite things. The preview wants pixels: it is composited full-screen and a
//  720p feed on a 6.7" display looks soft. The analyser wants none of them: pose
//  estimation gains nothing measurable above 720p and every extra pixel is
//  memory bandwidth spent on the hot path, at 30fps, next to a Neural Engine
//  request that is already the frame budget's largest line item.
//
//  Setting the preset to `.high` — as this project did — resolves that conflict
//  in favour of the preview and hands the analyser a needlessly large buffer on
//  every single frame.
//
//  THE SPLIT
//  ---------
//  `sessionPreset` drives the PREVIEW. `AVCaptureVideoDataOutput.videoSettings`
//  independently requests scaled buffers for ANALYSIS, which is the supported
//  way to have the two differ within one session.
//
//                      preview        analysis
//      high tier       1080p          720p
//      low tier        720p           540p
//
//  WHY EVERY ENTRY IS 16:9
//  -----------------------
//  Vision reports landmarks in NORMALIZED (0...1) coordinates, so scaling the
//  analysis buffer changes no threshold, no distance and no angle anywhere in
//  the tracker — every spatial bound is already a fraction of the athlete's own
//  body. That invariance holds ONLY while the aspect ratio is fixed: normalized
//  coordinates are per-axis, so a preview and an analysis buffer of different
//  shapes would disagree about where a joint is, and an overlay drawn from one
//  would not land on the body in the other. 1920×1080, 1280×720 and 960×540 are
//  all exactly 16:9, which is what makes the tiers interchangeable.
//
//  NOTE ON SMOOTHING: nothing here adds a temporal filter. Jitter is handled by
//  `OneEuroPointFilter` where it is needed and by a single angle EMA in the
//  rep analyzers; stacking another moving average on top would add latency to
//  the rep trigger and buy nothing.
//

import AVFoundation

/// Resolution policy for the capture session, split by device tier.
enum CaptureConfiguration {

    /// A 16:9 analysis buffer size in pixels.
    struct AnalysisResolution: Equatable {
        let width: Int
        let height: Int
    }

    /// Preview resolution: 1080p where there is headroom, 720p where there isn't.
    ///
    /// The low tier exists to avoid GPU compositing and memory-bandwidth
    /// overhead on A12/A13 hardware, which is supported but has nothing to
    /// spare once pose estimation is running.
    static func previewPreset(for tier: DeviceCompatibility.PerformanceTier) -> AVCaptureSession.Preset {
        switch tier {
        case .high: return .hd1920x1080
        case .low:  return .hd1280x720
        }
    }

    /// Analysis resolution: 720p / 540p. Strictly capped below the preview on
    /// both tiers, because this is the buffer that runs through Vision 30 times
    /// a second and it is where FPS headroom is won.
    static func analysisResolution(for tier: DeviceCompatibility.PerformanceTier) -> AnalysisResolution {
        switch tier {
        case .high: return AnalysisResolution(width: 1280, height: 720)
        case .low:  return AnalysisResolution(width: 960,  height: 540)
        }
    }

    /// Applies the preview half of the policy, falling back if the device cannot
    /// honour the preset.
    ///
    /// `canSetSessionPreset` is consulted rather than assumed: not every capture
    /// device supports every preset, and assigning an unsupported one throws at
    /// runtime. A device that cannot do 1080p drops to 720p, and one that cannot
    /// do 720p keeps whatever it had.
    ///
    /// Call inside a `beginConfiguration()` / `commitConfiguration()` pair.
    static func applyPreviewPreset(to session: AVCaptureSession,
                                   tier: DeviceCompatibility.PerformanceTier) {
        let preferred = previewPreset(for: tier)
        if session.canSetSessionPreset(preferred) {
            session.sessionPreset = preferred
            return
        }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
    }

    /// Applies the analysis half: requests scaled buffers from the data output.
    ///
    /// The existing pixel-format entry is PRESERVED rather than overwritten —
    /// only the dimensions are added. Replacing `videoSettings` wholesale would
    /// silently drop the format the output had negotiated, and Vision would then
    /// be handed buffers in a format the rest of the pipeline did not expect.
    ///
    /// Call inside a `beginConfiguration()` / `commitConfiguration()` pair, and
    /// only after the output has been added to the session.
    static func applyAnalysisResolution(to output: AVCaptureVideoDataOutput,
                                        tier: DeviceCompatibility.PerformanceTier) {
        let target = analysisResolution(for: tier)
        var settings = output.videoSettings ?? [:]
        settings[kCVPixelBufferWidthKey as String]  = target.width
        settings[kCVPixelBufferHeightKey as String] = target.height
        if settings[kCVPixelBufferPixelFormatTypeKey as String] == nil,
           let format = output.availableVideoPixelFormatTypes.first {
            settings[kCVPixelBufferPixelFormatTypeKey as String] = format
        }
        output.videoSettings = settings
    }
}
