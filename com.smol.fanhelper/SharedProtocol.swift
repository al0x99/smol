import Foundation

/// XPC protocol shared between main app and privileged helper
/// This file must be included in both targets
@objc public protocol FanHelperProtocol {
    /// Verify that the helper is reachable (returns true if connected)
    func ping(reply: @escaping (Bool) -> Void)

    /// Gets the number of fans in the system
    func getFanCount(reply: @escaping (Int) -> Void)

    /// Gets the current RPM of a specific fan
    func getFanRPM(index: Int, reply: @escaping (Int) -> Void)

    /// Gets all fan info in a dictionary
    /// Keys: count, fan0_rpm, fan0_min, fan0_max, fan0_target, fan1_rpm, etc.
    func getFanInfo(reply: @escaping ([String: Any]) -> Void)

    /// Sets target RPM for a fan (also enables force mode)
    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)

    /// Sets fan mode: 0 = auto, 1 = manual/forced
    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void)

    /// Debug: enumerates all available SMC keys for fans
    func debugEnumerateKeys(reply: @escaping (String) -> Void)

    /// Checks if fan control is currently available
    /// On Apple Silicon M4, when temperatures are low the hardware disables fans
    /// and manual control is not possible until they warm up
    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void)

    /// Runs exhaustive FOFC sequence tests to find the one that works on M4
    func testFOFCSequences(index: Int, targetRPM: Int, reply: @escaping (Bool, String) -> Void)

    /// Searches all available FOFC-related keys
    func searchFOFCKeys(reply: @escaping (String) -> Void)

    /// Test alternative fan control methods (F0Mn/F0Mx constraints)
    func testAlternativeControl(index: Int, targetRPM: Int, reply: @escaping (String) -> Void)
}

/// Mach service identifier for XPC connection
public let FanHelperMachServiceName = "com.smol.fanhelper"
