//
//  Theme.swift
//  ExerciseTracker
//
//  Central design tokens. Dark-first, athletic, high-contrast. Keeping colors
//  and metrics here means every component stays visually consistent and the
//  palette can be retuned in one place.
//
//  NOTE: the SwiftUI layer uses `Material` (glassmorphism), which requires
//  iOS 15.0+. Set the app's deployment target to iOS 15 or later. (The tracking
//  engine itself only needs iOS 14, but the premium glass look needs 15.)
//

import SwiftUI

enum Theme {
    // Backgrounds
    static let background = Color.black

    // Accents
    /// Primary "good / go" neon mint-green.
    static let accent = Color(red: 0.22, green: 1.00, blue: 0.62)
    /// Secondary cool blue used for the "position yourself" guidance state.
    static let accentBlue = Color(red: 0.27, green: 0.72, blue: 1.00)

    // Alerts
    /// Warning amber used for the form-correction flash.
    static let warning = Color(red: 1.00, green: 0.46, blue: 0.18)
    /// Hard error red.
    static let danger = Color(red: 1.00, green: 0.25, blue: 0.33)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)

    // Metrics
    static let cardCornerRadius: CGFloat = 24
    static let hairline = Color.white.opacity(0.10)
}
