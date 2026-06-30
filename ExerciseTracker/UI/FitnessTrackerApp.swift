//
//  FitnessTrackerApp.swift
//  ExerciseTracker
//
//  App entry point. Make WorkoutSessionView the root and you're running.
//
//  REQUIRED Info.plist KEY
//  -----------------------
//  Add `NSCameraUsageDescription` (Privacy – Camera Usage Description), e.g.:
//      "Used to watch your form and count your push-ups and squats."
//  The app will crash the instant the camera starts without it.
//
//  DEPLOYMENT TARGET: iOS 15.0+ (Material glassmorphism). The tracker engine
//  itself only needs iOS 14, but the UI uses `.ultraThinMaterial`.
//

import SwiftUI

@main
struct FitnessTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            WorkoutSessionView()
        }
    }
}
