import Foundation

/// XPC protocol shared between main app and privileged helper.
/// This file is kept in sync with `smol/SharedProtocol.swift` — keep both
/// matching exactly or the XPC interface will refuse to bind at runtime.
@objc public protocol FanHelperProtocol {
    /// Round-trip check: returns true if the helper is reachable.
    func ping(reply: @escaping (Bool) -> Void)

    /// Number of fans the SMC exposes (0 if unsupported).
    func getFanCount(reply: @escaping (Int) -> Void)

    /// Current RPM for a specific fan (index in `0..<getFanCount`).
    func getFanRPM(index: Int, reply: @escaping (Int) -> Void)

    /// Snapshot of every fan in a single dictionary call.
    /// Keys: `count`, `fan{N}_rpm`, `fan{N}_min`, `fan{N}_max`, `fan{N}_target`.
    func getFanInfo(reply: @escaping ([String: Any]) -> Void)

    /// Sets the target RPM and enables force-mode for one fan.
    /// `rpm` is clamped to a hardware-safe range inside the helper.
    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)

    /// Switches every fan into a mode. 0 = auto, 1 = manual/forced.
    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void)

    /// Diagnostic: logs every fan-related SMC key to the system log.
    /// Useful when porting to a new Apple Silicon family.
    func debugEnumerateKeys(reply: @escaping (String) -> Void)

    /// Reports whether SMC writes are accepted on this hardware.
    /// On Apple Silicon, fans parked at 0 RPM still report as controllable
    /// because writing `F{N}Tg` spins them up.
    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void)
}

/// Mach service identifier for the XPC connection.
public let FanHelperMachServiceName = "com.smol.fanhelper"
