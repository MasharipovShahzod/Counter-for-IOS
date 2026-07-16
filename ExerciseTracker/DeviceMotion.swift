//
//  DeviceMotion.swift
//  ExerciseTracker
//
//  A thin, testable seam over CoreMotion. The tracker reads the current gravity
//  vector each frame to tell real-world horizontal from vertical (floor push-up
//  vs wall push-up / bar dip) even when the phone is tilted. Abstracted behind a
//  protocol so:
//    • unit tests can drive the analyzers with synthetic gravity, and
//    • a simulator or a device with no motion hardware degrades cleanly to nil,
//      which the geometry treats as "assume the phone is upright".
//

import Foundation

/// Gravity in the DEVICE reference frame: a unit-ish vector pointing toward
/// Earth. x = right edge of the device, y = top edge, z = out of the screen.
public struct GravityVector: Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) {
        self.x = x; self.y = y; self.z = z
    }
}

/// Supplies the latest gravity reading, or `nil` when none is available.
///
/// `start()`/`stop()` bracket the sensor's active window. They default to no-ops
/// so a synthetic test source only has to provide `deviceGravity`.
public protocol GravitySource: AnyObject {
    var deviceGravity: GravityVector? { get }

    /// Begin producing readings. Idempotent.
    func start()
    /// Stop producing readings and release the sensor. Idempotent.
    func stop()
}

public extension GravitySource {
    func start() {}
    func stop()  {}
}

#if canImport(CoreMotion)
import CoreMotion

/// CoreMotion-backed gravity, polled on demand from the shared device-motion
/// stream.
///
/// LIFECYCLE
/// ---------
/// The sensor runs only between `start()` and `stop()`, which the workout screen
/// brackets around its appearance. It deliberately does NOT start on `init`: the
/// tracker is created when the screen's view model is, and outlives the screen
/// being visible, so starting here would leave the accelerometer running (and
/// draining) long after the user navigated away.
///
/// THREADING
/// ---------
/// `deviceGravity` is read from the tracker's Vision queue, while `start`/`stop`
/// are called from the main queue. `CMMotionManager` is not documented as
/// thread-safe, so all three go through `lock`. The lock is uncontended in
/// practice — one read per analyzed frame — and never held across a callout.
public final class CoreMotionGravitySource: GravitySource {
    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var isRunning = false

    public init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        // No handler: we pull `motion.deviceMotion` when we need it rather than
        // being pushed a value per update, which keeps the read on our own
        // frame cadence instead of CoreMotion's.
        motion.startDeviceMotionUpdates()
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        isRunning = false
    }

    public var deviceGravity: GravityVector? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, let g = motion.deviceMotion?.gravity else { return nil }
        return GravityVector(x: g.x, y: g.y, z: g.z)
    }

    deinit { motion.stopDeviceMotionUpdates() }
}
#endif
