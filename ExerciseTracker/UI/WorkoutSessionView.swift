//
//  WorkoutSessionView.swift
//  ExerciseTracker
//
//  The top-level workout screen. Composes the live camera background, the
//  positioning guide, header (picker + status), the depth-ring rep counter,
//  the form-feedback card, and the blocking compatibility / permission overlay.
//

import SwiftUI

struct WorkoutSessionView: View {
    @StateObject private var vm = WorkoutViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // 1. Live camera background + skeleton overlay.
            if vm.cameraAuthorized && vm.compatibility.isSupported {
                CameraPreviewView(session: vm.session,
                                  viewModel: vm,
                                  showSkeleton: vm.showSkeleton)
                    .ignoresSafeArea()
            }

            // 2. Legibility dimming (top + bottom).
            dimmingGradient

            // 3. Body-position guide (until a body is detected).
            if vm.compatibility.isSupported && vm.cameraAuthorized && !vm.isBodyTracked {
                SilhouetteGuideView()
                    .transition(.opacity)
            }

            // 4. Foreground HUD.
            content

            // 5. Blocking overlays (take over the whole screen).
            overlays
        }
        .overlay(alignment: .topTrailing) { skeletonToggle }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.3), value: vm.isBodyTracked)
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    // MARK: HUD

    private var content: some View {
        VStack(spacing: 16) {
            StatusBannerView(text: vm.statusText,
                             systemImage: vm.statusIcon,
                             tint: vm.statusColor)
                .animation(.easeInOut(duration: 0.25), value: vm.statusText)

            ExercisePickerView(selection: Binding(
                get: { vm.exercise },
                set: { vm.select($0) }
            ))
            .frame(maxWidth: 320)

            RepCounterRingView(count: vm.repCount,
                               depth: vm.depth,
                               tint: vm.ringTint,
                               pulse: vm.repPulse)
                .padding(.top, 6)

            Spacer()

            FormFeedbackCard(form: vm.form)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    // MARK: Skeleton toggle

    @ViewBuilder
    private var skeletonToggle: some View {
        if vm.compatibility.isSupported && vm.cameraAuthorized {
            Button { vm.toggleSkeleton() } label: {
                Image(systemName: vm.showSkeleton ? "figure.walk" : "eye.slash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(vm.showSkeleton ? Theme.accent : Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline))
            }
            .padding(.trailing, 20)
            .padding(.top, 6)
        }
    }

    // MARK: Dimming

    private var dimmingGradient: some View {
        VStack {
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 280)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        if !vm.compatibility.isSupported {
            BlockingOverlay(
                systemImage: "exclamationmark.triangle.fill",
                title: "Unsupported Device",
                message: vm.compatibility.userMessage ??
                    "This device can't run real-time body tracking."
            )
        } else if !vm.cameraAuthorized {
            BlockingOverlay(
                systemImage: "video.slash.fill",
                title: "Camera Access Needed",
                message: "Enable camera access in Settings so we can see your form.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

struct WorkoutSessionView_Previews: PreviewProvider {
    static var previews: some View {
        WorkoutSessionView()
    }
}
