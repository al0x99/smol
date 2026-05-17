import Foundation
import Security

// MARK: - Input validation

/// Hard caps for XPC-supplied values. Real Macs ship 0–2 fans at most;
/// no commodity Mac fan tops 10000 RPM. We bound aggressively because this
/// process runs as root and writes directly to SMC.
private enum FanLimits {
    static let maxFanIndex: Int = 7      // SMC keys F0..F7, anything beyond corrupts key strings
    static let minRPM: Int = 0
    static let maxRPM: Int = 10000
    static let validModes: Set<Int> = [0, 1]
}

@inline(__always)
private func validIndex(_ index: Int) -> Bool {
    return index >= 0 && index <= FanLimits.maxFanIndex
}

@inline(__always)
private func clampRPM(_ rpm: Int) -> Int {
    return min(max(rpm, FanLimits.minRPM), FanLimits.maxRPM)
}

// MARK: - Fan Helper Service

/// XPC service implementation for fan control
class FanHelperService: NSObject, FanHelperProtocol {
    private let smc = SMCAccess()

    func ping(reply: @escaping (Bool) -> Void) {
        NSLog("smolFanHelper: ping() - helper is alive")
        reply(true)
    }

    func getFanCount(reply: @escaping (Int) -> Void) {
        let count = smc.getFanCount()
        NSLog("smolFanHelper: getFanCount() = %d", count)
        reply(count)
    }

    func getFanRPM(index: Int, reply: @escaping (Int) -> Void) {
        guard validIndex(index) else {
            NSLog("smolFanHelper: getFanRPM rejected out-of-range index %d", index)
            reply(0)
            return
        }
        let rpm = smc.getFanRPM(index: index)
        NSLog("smolFanHelper: getFanRPM(%d) = %d", index, rpm)
        reply(rpm)
    }

    func getFanInfo(reply: @escaping ([String: Any]) -> Void) {
        let count = smc.getFanCount()
        var info: [String: Any] = ["count": count]

        for i in 0..<count {
            info["fan\(i)_rpm"] = smc.getFanRPM(index: i)
            info["fan\(i)_min"] = smc.getFanMinRPM(index: i)
            info["fan\(i)_max"] = smc.getFanMaxRPM(index: i)
            info["fan\(i)_target"] = smc.getFanTargetRPM(index: i)
        }

        NSLog("smolFanHelper: getFanInfo() = %@", info as NSDictionary)
        reply(info)
    }

    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void) {
        guard validIndex(index) else {
            NSLog("smolFanHelper: setFanRPM rejected out-of-range index %d", index)
            reply(false)
            return
        }
        let safeRPM = clampRPM(rpm)
        if safeRPM != rpm {
            NSLog("smolFanHelper: setFanRPM clamped %d to %d (allowed range 0...%d)", rpm, safeRPM, FanLimits.maxRPM)
        }
        NSLog("smolFanHelper: setFanRPM(%d, %d)", index, safeRPM)

        // M-series firmware refuses F*Tg writes when the fan is parked
        // (F*Ac == 0). We get around this by lifting F*Mn, which the
        // thermal controller is required to honour. The lift is cached
        // and restored when the caller flips back to auto.
        let actualRPM = smc.getFanRPM(index: index)
        if actualRPM == 0 && safeRPM > 0 {
            NSLog("smolFanHelper: Fan %d parked (Ac=0) — lifting F%dMn to wake", index, index)
            _ = smc.wakeParkedFan(index: index, rpm: safeRPM)
        }

        let forceOK = smc.setFanForceMode(index: index, forced: true)
        if !forceOK {
            NSLog("smolFanHelper: Force mode failed for fan %d, trying direct target write anyway", index)
        }

        // On Apple Silicon the target write often succeeds even when the
        // force-mode write was rejected, so we try regardless.
        let setOK = smc.setFanTargetRPM(index: index, rpm: safeRPM)

        if setOK {
            NSLog("smolFanHelper: Successfully set fan %d to %d RPM", index, safeRPM)
        } else {
            NSLog("smolFanHelper: Failed to set fan %d target RPM (SMC write blocked on Apple Silicon?)", index)
        }

        reply(setOK)
    }

    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void) {
        guard FanLimits.validModes.contains(mode) else {
            NSLog("smolFanHelper: setFanMode rejected invalid mode %d", mode)
            reply(false)
            return
        }
        NSLog("smolFanHelper: setFanMode(%d)", mode)

        let count = smc.getFanCount()
        var allOK = true

        for i in 0..<count {
            // Restore the F*Mn we raised during any prior wake-up BEFORE
            // releasing manual control. Otherwise the auto controller
            // would inherit our lifted floor and stay at the manual-mode
            // RPM for tens of seconds while it tried to ramp down.
            if mode == 0 && smc.hasCachedMinimum(index: i) {
                _ = smc.restoreFanMinimum(index: i)
            }
            if !smc.setFanForceMode(index: i, forced: mode != 0) {
                allOK = false
            }
        }

        reply(allOK)
    }

    func debugEnumerateKeys(reply: @escaping (String) -> Void) {
        NSLog("smolFanHelper: debugEnumerateKeys() - starting enumeration")

        let count = smc.getFanCount()
        for i in 0..<count {
            smc.debugEnumerateFanKeys(index: i)
        }

        smc.debugSearchFanKeys()

        reply("Enumeration complete — see Console log filtered by process com.smol.fanhelper.")
    }

    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void) {
        NSLog("smolFanHelper: isFanControlAvailable() - checking hardware status")

        let count = smc.getFanCount()
        guard count > 0 else {
            reply(false, "No fans detected")
            return
        }

        // On Apple Silicon the SMC parks fans at 0 RPM when the system
        // is cool; we still report control as "available" in that case
        // because writing F0Tg can spin them up from 0.
        var anyFanRunning = false
        for i in 0..<count {
            let rpm = smc.getFanRPM(index: i)
            if rpm > 0 {
                anyFanRunning = true
                break
            }
        }

        if !anyFanRunning {
            NSLog("smolFanHelper: All fans at 0 RPM — control will spin them up via F0Tg write")
            reply(true, "Fans are idle. Manual control is still available — writing a target RPM will spin them up.")
            return
        }

        // Probe by toggling force-mode and immediately restoring.
        let testResult = smc.setFanForceMode(index: 0, forced: true)
        _ = smc.setFanForceMode(index: 0, forced: false)

        if testResult {
            reply(true, "Fan control available")
        } else {
            reply(false, "Fan control is not available on this Mac. Apple Silicon firmware is blocking SMC writes.")
        }
    }
}

// MARK: - XPC Listener Delegate

/// Delegate to handle incoming XPC connections
class FanHelperDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        NSLog("smolFanHelper: New connection request from PID %d", newConnection.processIdentifier)

        guard verifyClientSignature(connection: newConnection) else {
            NSLog("smolFanHelper: Client verification FAILED for PID %d", newConnection.processIdentifier)
            return false
        }

        NSLog("smolFanHelper: Client verified, accepting connection")

        newConnection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        newConnection.exportedObject = FanHelperService()

        newConnection.interruptionHandler = {
            NSLog("smolFanHelper: Connection interrupted")
        }

        newConnection.invalidationHandler = {
            NSLog("smolFanHelper: Connection invalidated")
        }

        newConnection.resume()
        return true
    }

    /// Verify that the client is signed with the same Team ID
    private func verifyClientSignature(connection: NSXPCConnection) -> Bool {
        #if DEBUG
        NSLog("smolFanHelper: DEBUG build — accepting all connections")
        return true
        #else
        // Use the connection's audit_token_t to avoid the PID-recycling TOCTOU
        // race that affects kSecGuestAttributePid. The audit token is captured
        // when the kernel routes the XPC message and cannot be spoofed by a
        // later exec.
        var auditToken = audit_token_t()
        if connection.responds(to: NSSelectorFromString("auditToken")) {
            auditToken = connection.value(forKey: "auditToken") as! audit_token_t
        } else {
            NSLog("smolFanHelper: NSXPCConnection has no auditToken — refusing connection")
            return false
        }

        let tokenData = withUnsafeBytes(of: &auditToken) { Data($0) }
        var code: SecCode?
        let attributes: [String: Any] = [kSecGuestAttributeAudit as String: tokenData]
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)

        guard status == errSecSuccess, let code = code else {
            NSLog("smolFanHelper: SecCodeCopyGuestWithAttributes failed: %d", status)
            return false
        }

        // Designated requirement: same identifier + Team ID, Developer ID signed.
        let requirement = """
            anchor apple generic
            and identifier "com.whitepaper.smol"
            and (
                certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */
                or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */
                and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */
                and certificate leaf[subject.OU] = "JLTQ5V2UX8"
            )
            """

        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let req = req else {
            NSLog("smolFanHelper: Failed to create SecRequirement")
            return false
        }

        // kSecCSCheckAllArchitectures = 1 << 5 — enforces validity for every
        // slice of a universal binary, not just the running one.
        let flags = SecCSFlags(rawValue: 1 << 5)
        let validationResult = SecCodeCheckValidity(code, flags, req)
        if validationResult != errSecSuccess {
            NSLog("smolFanHelper: Client validation failed: %d", validationResult)
            return false
        }

        NSLog("smolFanHelper: Client signature verified successfully")
        return true
        #endif
    }
}

// MARK: - Entry Point

NSLog("smolFanHelper: Starting (UID %d)", getuid())

let delegate = FanHelperDelegate()
let listener = NSXPCListener(machServiceName: FanHelperMachServiceName)
listener.delegate = delegate

listener.resume()
NSLog("smolFanHelper: Listening on %@", FanHelperMachServiceName)

RunLoop.current.run()
