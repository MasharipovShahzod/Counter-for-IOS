//
//  DeviceCompatibility.swift
//  ExerciseTracker
//
//  Decides whether the current device + OS can run real-time 2D human body
//  pose estimation smoothly.
//
//  WHY A MODEL-MAP INSTEAD OF A DIRECT "HAS ANE?" QUERY
//  ----------------------------------------------------
//  There is no public API that reports the presence/speed of the Apple Neural
//  Engine. The practical, App-Store-safe approach is to map the hardware model
//  identifier to its SoC generation. Body pose estimation runs acceptably on the
//  A12 Bionic (first ANE generation Apple exposed broadly) and newer, which is
//  iPhone XS / XR and later, and the 2018 iPad Pro / A12 iPads and later.
//

import Foundation
import Vision

enum DeviceCompatibility {

    private static let osMessage =
        "iOS 14 or later is required for real-time body tracking. Please update your software."

    private static let hardwareMessage =
        "Your device does not support real-time body tracking. An iPhone XS or newer is required."

    /// The full compatibility verdict (OS first, then hardware).
    static func check() -> SafetyCheckResult {
        // 1. OS / framework revision support. VNDetectHumanBodyPoseRequest and the
        //    2D body-pose revision both require iOS 14.0+.
        guard #available(iOS 14.0, *) else {
            return .unsupportedOS(message: osMessage)
        }

        // 2. Hardware: needs an A12 Bionic (ANE) or newer.
        guard hasNeuralEngineClassChip() else {
            return .unsupportedHardware(message: hardwareMessage)
        }

        return .supported
    }

    // MARK: - Hardware classification

    /// Raw model identifier, e.g. "iPhone14,2", "iPad8,1", or "arm64"/"x86_64"
    /// on the Simulator.
    static var modelIdentifier: String {
        // The Simulator exposes the host arch via an env var; fall back to uname.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = Mirror(reflecting: systemInfo.machine)
        return machine.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// True when the device's SoC is an A12 Bionic or newer (i.e. has an ANE
    /// generation capable of real-time pose estimation).
    static func hasNeuralEngineClassChip() -> Bool {
        let id = modelIdentifier

        // Treat the Simulator as capable so development on Macs isn't blocked.
        // (On Apple Silicon Macs the Simulator easily runs the model anyway.)
        #if targetEnvironment(simulator)
        return true
        #else
        guard let (family, major) = parse(id) else {
            // Unknown identifier: almost certainly a device newer than this build
            // knows about, so fail open rather than locking out future hardware.
            return true
        }

        switch family {
        case "iPhone":
            // iPhone11,x == XS / XS Max / XR (A12). iPhone10,x == 8/8+/X (A11).
            return major >= 11
        case "iPad":
            // iPad8,x == 2018 iPad Pro (A12X); iPad11,x == Air 3 / mini 5 (A12).
            // iPad7,x and earlier are A10/A10X or older.
            return major >= 8
        case "iPod":
            // iPod touch tops out at the A10 (iPod9,1) — never sufficient.
            return false
        default:
            return true
        }
        #endif
    }

    /// Splits "iPhone14,2" into ("iPhone", 14). Returns nil for non-device ids.
    private static func parse(_ identifier: String) -> (family: String, major: Int)? {
        // Find where the family name ends and the major number begins.
        guard let firstDigit = identifier.firstIndex(where: { $0.isNumber }) else { return nil }
        let family = String(identifier[identifier.startIndex..<firstDigit])
        let rest = identifier[firstDigit...]
        let majorString = rest.prefix { $0.isNumber }
        guard let major = Int(majorString) else { return nil }
        return (family, major)
    }
}
