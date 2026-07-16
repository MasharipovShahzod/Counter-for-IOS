//
//  WorkoutComponents.swift
//  ExerciseTracker
//
//  The reusable visual pieces of the workout screen: exercise picker, status
//  banner, depth-ring rep counter, form-feedback card, body-position guide,
//  and the blocking compatibility / permission overlay.
//

import SwiftUI

// MARK: - Exercise picker

/// Horizontally-scrolling segmented control with a sliding selection pill.
///
/// WHY A SCROLLER
/// --------------
/// The earlier version divided a fixed 320pt capsule into equal segments. That
/// worked at two exercises (160pt each) but collapses at five (~64pt each),
/// truncating "Parallel Bars" and friends. Content-sized pills in a horizontal
/// scroll view scale to any number of exercises without ever clipping a label;
/// the partial pill at the trailing edge is the affordance that says "more here".
///
/// The sliding pill (`matchedGeometryEffect`) and its namespace live entirely
/// inside the scrolled `HStack`, which is the configuration where matched
/// geometry behaves predictably across a scroll boundary.
struct ExercisePickerView: View {
    @Binding var selection: ExerciseType
    @Namespace private var pill

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ExerciseType.allCases, id: \.self) { exercise in
                        segment(exercise).id(exercise)
                    }
                }
                .padding(4)
            }
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            // Keep the active exercise in view — both when tapped near an edge
            // and when selection changes programmatically (e.g. a reset).
            .onChange(of: selection) { newValue in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    private func segment(_ exercise: ExerciseType) -> some View {
        let isSelected = selection == exercise
        return Text(exercise.displayName)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundColor(isSelected ? .black : Theme.textSecondary)
            .fixedSize()                       // size to the label; never truncate
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.accent)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selection = exercise
                }
            }
    }
}

// MARK: - Status banner

struct StatusBannerView: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .shadow(color: tint.opacity(0.35), radius: 10)
        // Smoothly cross-fade between status texts.
        .id(text)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}

// MARK: - Rep counter + depth ring

/// Apple-Fitness-style ring: the trim shows live rep depth (0→1) and the bold
/// count sits in the center, popping on each new rep.
struct RepCounterRingView: View {
    let count: Int
    let depth: Double
    let tint: Color
    /// Bumped externally on every counted rep to trigger the pop.
    let pulse: Int

    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 14)

            Circle()
                .trim(from: 0, to: CGFloat(depth))
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.7), radius: 9)
                .animation(.easeOut(duration: 0.12), value: depth)
                .animation(.easeInOut(duration: 0.25), value: tint)

            VStack(spacing: -2) {
                Text("\(count)")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                Text("REPS")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundColor(Theme.textSecondary)
            }
            .scaleEffect(scale)
        }
        .frame(width: 196, height: 196)
        .onChange(of: pulse) { _ in popCounter() }
    }

    private func popCounter() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { scale = 1.18 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { scale = 1 }
        }
    }
}

// MARK: - Plank hold timer ring

/// The plank counterpart to `RepCounterRingView`. Same ring, same 196pt frame,
/// so switching exercises doesn't jump the layout — but it shows accumulated
/// hold time instead of a rep count.
///
/// THE RING SWEEP fills over the FIRST MINUTE, then stays full.
/// `trim = min(1, seconds / 60)`. This is deliberate rather than a per-minute
/// repeating sweep: a repeating sweep resets from ~0.98 back to 0 at each
/// minute boundary, and SwiftUI animates that reset by unwinding the trim
/// backwards around the whole circle — a visible glitch once a minute. Filling
/// once and holding full has no such artifact, and the numeric readout carries
/// the exact time past a minute anyway.
struct HoldTimerRingView: View {
    /// Preformatted "M:SS" (see `WorkoutViewModel.formatHold`).
    let timeText: String
    /// Accumulated hold seconds, driving the ring sweep.
    let seconds: TimeInterval
    let tint: Color
    /// True while the clock is actually running (repState == .holding). Drives
    /// the gentle "alive" pulse; a paused hold sits still.
    let isRunning: Bool

    @State private var pulse = false

    private var sweep: CGFloat {
        guard seconds > 0 else { return 0 }
        return CGFloat(min(1, seconds / 60))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 14)

            Circle()
                .trim(from: 0, to: sweep)
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.7), radius: 9)
                // Steps once per second (seconds is whole-second quantized), so
                // an ease reads as a clock tick rather than a jump.
                .animation(.easeInOut(duration: 0.3), value: sweep)
                .animation(.easeInOut(duration: 0.25), value: tint)

            VStack(spacing: 0) {
                Text(timeText)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)   // survives "12:30"+
                    .padding(.horizontal, 8)
                Text("HOLD")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundColor(Theme.textSecondary)
            }
            .scaleEffect(isRunning && pulse ? 1.04 : 1.0)
        }
        .frame(width: 196, height: 196)
        .onChange(of: isRunning) { running in updatePulse(running) }
        .onAppear { updatePulse(isRunning) }
    }

    /// Starts a slow breath while the clock runs; settles when it pauses.
    /// Driven off `isRunning` so the repeating animation is always torn down
    /// when the hold stops, never left looping on a paused timer.
    private func updatePulse(_ running: Bool) {
        if running {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}

// MARK: - Form feedback card

struct FormFeedbackCard: View {
    let form: WorkoutViewModel.FormFeedback

    @State private var flash = false

    private var isCritical: Bool { form.isCritical }
    private var isAlert: Bool { !form.isOptimal }   // warning OR critical

    private var icon: String {
        if isCritical { return "figure.fall" }
        if form.isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: isCritical ? 32 : 28, weight: .bold))
                .foregroundColor(isAlert ? .white : Theme.accent)

            Text(form.message)
                .font(.system(size: isAlert ? 23 : 17, weight: .bold, design: .rounded))
                .foregroundColor(isAlert ? .white : Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isCritical ? 20 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                switch form {
                case .optimal:
                    Rectangle().fill(.ultraThinMaterial)
                case .warning:
                    LinearGradient(colors: [Theme.warning, Theme.danger],
                                   startPoint: .leading, endPoint: .trailing)
                case .critical:
                    // Vibrant crimson crisis fill — posture / anti-cheat block.
                    Rectangle().fill(Theme.danger)
                }
                // White flash on entering an alert state (stronger for critical).
                Color.white.opacity(flash && isAlert ? (isCritical ? 0.4 : 0.28) : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(isAlert ? Color.white.opacity(0.35) : Theme.hairline,
                              lineWidth: isCritical ? 2 : 1)
        )
        .shadow(color: shadowColor.opacity(0.45), radius: isCritical ? 18 : 14, y: 6)
        .scaleEffect(isCritical ? 1.02 : (isAlert ? 1.0 : 0.99))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAlert)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCritical)
        .onChange(of: isAlert) { if $0 { triggerFlash() } }
        .onChange(of: isCritical) { if $0 { triggerFlash() } }
    }

    private var shadowColor: Color {
        if isCritical { return Theme.danger }
        if form.isWarning { return Theme.warning }
        return .black
    }

    private func triggerFlash() {
        flash = true
        withAnimation(.easeInOut(duration: 0.16).repeatCount(isCritical ? 5 : 3, autoreverses: true)) {
            flash = false
        }
    }
}

// MARK: - Body position guide

/// A minimalist neon human outline shown until the body is detected, to help
/// the user stand 1–2 m back and fully in frame. Gently pulses to draw the eye.
struct SilhouetteGuideView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            HumanSilhouette()
                .stroke(Theme.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 150, height: 300)
                .shadow(color: Theme.accent.opacity(0.8), radius: 12)
                .opacity(pulse ? 0.9 : 0.45)
                .scaleEffect(pulse ? 1.02 : 0.98)

            Text("Stand 1–2 m back, full body in frame")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .allowsHitTesting(false)
    }
}

/// Stylised stick-figure silhouette drawn as a stroked vector path.
struct HumanSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }

        // Head
        let headR = w * 0.16
        let headCenter = pt(0.5, 0.10)
        p.addEllipse(in: CGRect(x: headCenter.x - headR, y: headCenter.y - headR,
                                width: headR * 2, height: headR * 2))
        // Spine
        p.move(to: pt(0.5, 0.20)); p.addLine(to: pt(0.5, 0.58))
        // Arms (slightly open, relaxed)
        p.move(to: pt(0.5, 0.27)); p.addLine(to: pt(0.18, 0.46))
        p.move(to: pt(0.5, 0.27)); p.addLine(to: pt(0.82, 0.46))
        // Legs
        p.move(to: pt(0.5, 0.58)); p.addLine(to: pt(0.30, 0.98))
        p.move(to: pt(0.5, 0.58)); p.addLine(to: pt(0.70, 0.98))
        return p
    }
}

// MARK: - Blocking overlay (compatibility / permission)

struct BlockingOverlay: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: systemImage)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundColor(Theme.warning)
                    .shadow(color: Theme.warning.opacity(0.5), radius: 18)

                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if let actionTitle = actionTitle, let action = action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .padding(.top, 6)
                }
            }
            .padding(32)
            .frame(maxWidth: 360)
        }
        .transition(.opacity)
    }
}
