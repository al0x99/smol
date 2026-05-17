import Foundation
import IOKit

/// Helper function to log to both NSLog and a file (supports format strings)
private func smcLog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    NSLog("%@", message)
    let logFile = "/tmp/smol_helper_debug.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "\(timestamp): \(message)\n"
    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data, attributes: nil)
        }
    }
}

/// Direct SMC access for privileged helper
/// This class reads/writes SMC keys for fan control
class SMCAccess {
    private var connection: io_connect_t = 0
    private var isConnected = false

    // SMC selectors (as in SMCKit)
    private let KERNEL_INDEX_SMC: UInt32 = 2
    private let SMC_CMD_READ_BYTES: UInt8 = 5
    private let SMC_CMD_WRITE_BYTES: UInt8 = 6
    private let SMC_CMD_READ_KEYINFO: UInt8 = 9

    // Cache for key info (reduces SMC calls)
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    // Cache of F*Mn (per-fan minimum RPM) at the moment we first raised
    // it to wake a parked fan. M-series firmware ignores F*Tg when the
    // fan is parked at 0 RPM, so we lift F*Mn instead — but that becomes
    // a permanent floor unless we restore it when the user switches back
    // to auto mode. Keyed by fan index. Mirrored to /tmp so a helper
    // crash between wake and restore doesn't leave the fan minimum
    // permanently raised — `restoreFromCrashIfNeeded` reads it back at
    // startup. /tmp is cleared on reboot, which is exactly the right
    // lifetime: SMC F*Mn also resets on reboot.
    private var originalMinRPM: [Int: Int] = [:]

    /// Path of the per-fan crash-safety mirror for `originalMinRPM`.
    private static let crashSafetyDir = "/tmp/com.smol.fanhelper"
    private static func crashSafetyPath(index: Int) -> String {
        return "\(crashSafetyDir)/originalMinRPM.\(index)"
    }

    init() {
        openConnection()
        restoreFromCrashIfNeeded()
    }

    deinit {
        closeConnection()
    }

    // MARK: - Connection

    private func openConnection() {
        // Try AppleSMC (Intel) first, then AppleSMCKeysEndpoint (Apple Silicon)
        var service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )

        if service == 0 {
            smcLog("smolFanHelper: AppleSMC not found, trying AppleSMCKeysEndpoint")
            service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("AppleSMCKeysEndpoint")
            )
        }

        guard service != 0 else {
            smcLog("smolFanHelper: No SMC service found")
            return
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        if result == kIOReturnSuccess {
            isConnected = true
            smcLog("smolFanHelper: SMC connection opened successfully")
        } else {
            smcLog("smolFanHelper: Failed to open SMC connection: 0x%x", result)
        }
    }

    private func closeConnection() {
        if isConnected {
            IOServiceClose(connection)
            isConnected = false
            smcLog("smolFanHelper: SMC connection closed")
        }
    }

    // MARK: - Public API

    /// Gets the number of fans from SMC
    func getFanCount() -> Int {
        guard let val = readKey("FNum") else {
            smcLog("smolFanHelper: Failed to read FNum key")
            return 0
        }
        let count = Int(val.bytes.0)
        smcLog("smolFanHelper: FNum = %d (dataSize=%d, dataType=%@)",
              count, val.dataSize, fourCharToString(val.dataType))
        return count
    }

    /// Gets the current RPM of a fan
    func getFanRPM(index: Int) -> Int {
        let key = "F\(index)Ac"
        guard let val = readKey(key) else { return 0 }
        let rpm = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ = %d RPM (type=%@)", key, rpm, fourCharToString(val.dataType))
        return rpm
    }

    /// Gets the minimum RPM of a fan
    func getFanMinRPM(index: Int) -> Int {
        let key = "F\(index)Mn"
        guard let val = readKey(key) else {
            smcLog("smolFanHelper: %@ key not found, using default 1200", key)
            return 1200
        }
        let rpm = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ = %d RPM (type=%@)", key, rpm, fourCharToString(val.dataType))
        return rpm
    }

    /// Gets the maximum RPM of a fan
    func getFanMaxRPM(index: Int) -> Int {
        let key = "F\(index)Mx"
        guard let val = readKey(key) else {
            smcLog("smolFanHelper: %@ key not found, using default 6000", key)
            return 6000
        }
        let rpm = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ = %d RPM (type=%@)", key, rpm, fourCharToString(val.dataType))
        return rpm
    }

    /// Gets the target RPM of a fan
    func getFanTargetRPM(index: Int) -> Int {
        let key = "F\(index)Tg"
        guard let val = readKey(key) else {
            smcLog("smolFanHelper: %@ key not found", key)
            return 0
        }
        let rpm = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ = %d RPM (type=%@)", key, rpm, fourCharToString(val.dataType))
        return rpm
    }

    /// Enable/disable force mode for a fan
    /// On Apple Silicon (M1/M2/M3/M4) the per-fan key is `F%dMd`, not the
    /// Intel-era `FS!` bitmask. Mode values: 0=off?, 1=manual?, 2=?, 3=auto (default)
    ///
    /// On M4, the sequence appears to be:
    /// 1. Write to FOFC to enable force control mode globally
    /// 2. Write to F0Md to set fan-specific manual mode
    /// 3. Then F0Tg can be written to set target RPM
    func setFanForceMode(index: Int, forced: Bool) -> Bool {
        smcLog("smolFanHelper: setFanForceMode(index=%d, forced=%d)", index, forced)

        // === STRATEGY 1: Try FOFC FIRST (M4 Mac specific) ===
        // FOFC appears to be a global "Force Fan Control" enable key
        if let fofcVal = readKey("FOFC") {
            smcLog("smolFanHelper: FOFC exists! current value=0x%02x (dataSize=%d, type=%@)",
                  fofcVal.bytes.0, fofcVal.dataSize, fourCharToString(fofcVal.dataType))

            // Try different values to enable force mode
            // The key might need 0x01, 0xFF, or a bitmask
            let valuesToTry: [UInt8] = forced ? [0x01, 0xFF, 0x02, 0x03] : [0x00]

            for tryValue in valuesToTry {
                smcLog("smolFanHelper: Trying FOFC = 0x%02x", tryValue)
                let writeSuccess = writeKey("FOFC", dataSize: fofcVal.dataSize, dataType: fofcVal.dataType,
                                            byte0: tryValue, byte1: 0)

                if writeSuccess {
                    // Read back to verify
                    if let newFofc = readKey("FOFC") {
                        smcLog("smolFanHelper: FOFC after write: 0x%02x (wanted 0x%02x)",
                              newFofc.bytes.0, tryValue)

                        if newFofc.bytes.0 == tryValue {
                            smcLog("smolFanHelper: FOFC write SUCCESS with value 0x%02x", tryValue)

                            // Now try to write F0Md after FOFC is set
                            let modeKey = "F\(index)Md"
                            if let mdVal = readKey(modeKey) {
                                let modeValue: UInt8 = forced ? 1 : 3
                                smcLog("smolFanHelper: After FOFC, trying %@ = %d", modeKey, modeValue)
                                _ = writeKey(modeKey, dataSize: mdVal.dataSize, dataType: mdVal.dataType,
                                            byte0: modeValue, byte1: 0)

                                // Verify F0Md
                                if let newMd = readKey(modeKey) {
                                    smcLog("smolFanHelper: %@ after write: %d", modeKey, newMd.bytes.0)
                                }
                            }
                            return true
                        }
                    }
                } else {
                    smcLog("smolFanHelper: FOFC write failed at IOKit level")
                }
            }
            smcLog("smolFanHelper: All FOFC values failed to stick")
        }

        // === STRATEGY 2: Try FS! (Intel style) ===
        if let val = readKey("FS! ") {
            var currentValue = (UInt16(val.bytes.0) << 8) | UInt16(val.bytes.1)
            smcLog("smolFanHelper: Current FS! value: 0x%x", currentValue)

            if forced {
                currentValue |= UInt16(1 << index)
            } else {
                currentValue &= ~UInt16(1 << index)
            }

            let success = writeKey("FS! ", dataSize: val.dataSize, dataType: val.dataType,
                                   byte0: UInt8((currentValue >> 8) & 0xFF),
                                   byte1: UInt8(currentValue & 0xFF))
            smcLog("smolFanHelper: Set FS! to 0x%x, success: %d", currentValue, success)
            return success
        }

        // === STRATEGY 3: Try F%dMd alone (Apple Silicon) ===
        let modeKey = "F\(index)Md"
        if let val = readKey(modeKey) {
            let currentMode = Int(val.bytes.0)
            // Mode 1 = manual/forced, Mode 3 = auto (observed on M4 Max)
            let modeValue: UInt8 = forced ? 1 : 3

            smcLog("smolFanHelper: F%dMd current=%d, setting to %d", index, currentMode, modeValue)

            let success = writeKey(modeKey, dataSize: val.dataSize, dataType: val.dataType,
                                   byte0: modeValue, byte1: 0)

            // Verify if the write took effect
            if success {
                if let newVal = readKey(modeKey) {
                    let newMode = Int(newVal.bytes.0)
                    smcLog("smolFanHelper: F%dMd after write: %d (wanted %d)", index, newMode, modeValue)
                    if newMode != Int(modeValue) {
                        smcLog("smolFanHelper: WARNING: F%dMd write was ignored by SMC")
                    }
                }
            } else {
                smcLog("smolFanHelper: F%dMd write failed", index)
            }

            return success
        }

        // If no key exists, on Apple Silicon it may work without force mode
        smcLog("smolFanHelper: No force mode key found (FOFC, FS!, or F%dMd). Will try direct target write.", index)
        return false
    }


    /// Sets target RPM for a fan.
    ///
    /// On M-series Macs the F*Tg readback right after a write is unreliable
    /// when the fan is parked at 0 RPM: the firmware queues the new target
    /// but keeps reporting the old (0) value until the fan physically starts
    /// spinning, which can take 1–3 seconds. We therefore trust the IOKit
    /// write acknowledgement instead of failing on the readback. The
    /// parked-fan wake-up itself is done by raising F*Mn — see
    /// `wakeParkedFan` and the call site in main.swift.
    func setFanTargetRPM(index: Int, rpm: Int) -> Bool {
        let key = "F\(index)Tg"

        // First read to get dataSize and dataType
        guard let val = readKey(key) else {
            smcLog("smolFanHelper: Failed to read %@ for write", key)
            return false
        }

        let currentRPM = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ current=%d RPM, setting to %d RPM", key, currentRPM, rpm)

        let bytes = rpmToBytes(rpm, dataType: val.dataType)
        let success = writeKey(key, dataSize: val.dataSize, dataType: val.dataType,
                               bytes: bytes)

        if !success {
            smcLog("smolFanHelper: %@ write failed at IOKit level", key)
            return false
        }

        // Best-effort readback log. We don't fail the call on a mismatch
        // here because for parked fans the new target isn't reflected for
        // hundreds of milliseconds.
        if let newVal = readKey(key) {
            let newRPM = bytesToRPM(newVal.bytes, dataType: newVal.dataType)
            smcLog("smolFanHelper: %@ after write: %d RPM (wanted %d)", key, newRPM, rpm)

            // If we hit a parked-fan delay (readback still 0 right after a
            // non-zero target), also force F*Fc=1 as a belt-and-braces nudge.
            // Don't read back again — we already trust the IOKit ack.
            if newRPM == 0 && rpm > 0 {
                let fcKey = "F\(index)Fc"
                if let fcVal = readKey(fcKey) {
                    _ = writeKey(fcKey, dataSize: fcVal.dataSize, dataType: fcVal.dataType,
                                 byte0: 1, byte1: 0)
                    _ = writeKey(key, dataSize: val.dataSize, dataType: val.dataType, bytes: bytes)
                    smcLog("smolFanHelper: %@ + F%dFc=1 belt-and-braces nudge issued", key, index)
                }
            }
        }

        return true
    }

    /// Wake a parked fan by writing F*Mn (per-fan minimum RPM).
    ///
    /// M-series firmware ignores F*Tg writes while a fan is parked at 0 RPM
    /// but always honours F*Mn — it's a hard floor that the thermal controller
    /// must respect regardless of F*Md (manual/auto) or FOFC. Raising F*Mn
    /// therefore forces the fan to spin up immediately, which is the trick TG
    /// Pro and Macs Fan Control use on Apple Silicon.
    ///
    /// We cache the previous F*Mn on the first wake so `restoreFanMinimum`
    /// can put it back when the user returns to auto mode. Without that
    /// restore the fan would keep running at the elevated floor permanently.
    @discardableResult
    func wakeParkedFan(index: Int, rpm: Int) -> Bool {
        let mnKey = "F\(index)Mn"
        guard let mnVal = readKey(mnKey) else {
            smcLog("smolFanHelper: %@ not readable — cannot wake parked fan %d", mnKey, index)
            return false
        }

        let currentMin = bytesToRPM(mnVal.bytes, dataType: mnVal.dataType)

        // Cache on first wake only; subsequent wakes shouldn't clobber the
        // true factory minimum with a previously-raised wake value.
        if originalMinRPM[index] == nil {
            originalMinRPM[index] = currentMin
            persistOriginalMinRPM(index: index, value: currentMin)
            smcLog("smolFanHelper: Cached original F%dMn=%d for later restore", index, currentMin)
        }

        // Clamp to the physical fan ceiling so we don't ask SMC to set a
        // minimum above the maximum (firmware would reject the whole write).
        let fanMax = getFanMaxRPM(index: index)
        guard fanMax > 0 else {
            smcLog("smolFanHelper: F%dMx returned 0 — refusing to wake fan with unknown ceiling", index)
            return false
        }
        let wakeRPM = max(min(rpm, fanMax), currentMin)

        if wakeRPM == currentMin {
            // Nothing to do — the requested wake floor is already in place.
            return true
        }

        let bytes = rpmToBytes(wakeRPM, dataType: mnVal.dataType)
        let success = writeKey(mnKey, dataSize: mnVal.dataSize, dataType: mnVal.dataType, bytes: bytes)
        smcLog("smolFanHelper: F%dMn wake %d→%d result=%d (will be restored on auto)",
               index, currentMin, wakeRPM, success ? 1 : 0)
        return success
    }

    /// Restore the cached F*Mn for `index` after a `wakeParkedFan` call.
    ///
    /// Called when switching back to auto mode so the firmware-managed
    /// floor returns to its factory value. If nothing was ever cached
    /// (the fan was never parked when control started) this is a no-op
    /// and returns true.
    @discardableResult
    func restoreFanMinimum(index: Int) -> Bool {
        guard let originalMin = originalMinRPM[index] else {
            return true
        }

        let mnKey = "F\(index)Mn"
        guard let mnVal = readKey(mnKey) else {
            smcLog("smolFanHelper: %@ not readable — leaving cached restore %d in place", mnKey, originalMin)
            return false
        }

        let currentMin = bytesToRPM(mnVal.bytes, dataType: mnVal.dataType)
        if currentMin == originalMin {
            originalMinRPM[index] = nil
            clearPersistedOriginalMinRPM(index: index)
            return true
        }

        let bytes = rpmToBytes(originalMin, dataType: mnVal.dataType)
        let success = writeKey(mnKey, dataSize: mnVal.dataSize, dataType: mnVal.dataType, bytes: bytes)
        smcLog("smolFanHelper: F%dMn restore %d→%d result=%d", index, currentMin, originalMin, success ? 1 : 0)

        if success {
            originalMinRPM[index] = nil
            clearPersistedOriginalMinRPM(index: index)
        }
        return success
    }

    /// Whether `index` currently has a raised F*Mn cached for restore.
    /// Used by the dispatcher to know whether the fan was woken by us.
    func hasCachedMinimum(index: Int) -> Bool {
        return originalMinRPM[index] != nil
    }

    // MARK: - Crash-safe F*Mn persistence

    /// Mirror `originalMinRPM[index]` to `/tmp` so the restore can run
    /// even after the helper crashes and is respawned by launchd.
    private func persistOriginalMinRPM(index: Int, value: Int) {
        try? FileManager.default.createDirectory(atPath: Self.crashSafetyDir,
                                                 withIntermediateDirectories: true)
        let path = Self.crashSafetyPath(index: index)
        try? "\(value)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func clearPersistedOriginalMinRPM(index: Int) {
        try? FileManager.default.removeItem(atPath: Self.crashSafetyPath(index: index))
    }

    /// On startup, read any persisted `originalMinRPM` files and immediately
    /// restore the floors before the listener accepts XPC traffic. This
    /// recovers from the helper-crashed-between-wake-and-restore case in
    /// which the in-memory cache was lost but the SMC was still holding a
    /// lifted F*Mn.
    private func restoreFromCrashIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: Self.crashSafetyDir) else {
            return
        }
        for entry in entries where entry.hasPrefix("originalMinRPM.") {
            let suffix = entry.replacingOccurrences(of: "originalMinRPM.", with: "")
            guard let index = Int(suffix),
                  let contents = try? String(contentsOfFile: "\(Self.crashSafetyDir)/\(entry)", encoding: .utf8),
                  let value = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            smcLog("smolFanHelper: Recovered persisted original F%dMn=%d from prior session — restoring", index, value)
            originalMinRPM[index] = value
            _ = restoreFanMinimum(index: index)
        }
    }

    /// Debug: Try to read various fan keys to find those that work on Apple Silicon
    func debugEnumerateFanKeys(index: Int) {
        smcLog("smolFanHelper: === Enumerating fan keys for fan %d ===", index)

        // Common fan keys
        let keys = [
            "F\(index)Ac", // Actual RPM
            "F\(index)Mn", // Minimum RPM
            "F\(index)Mx", // Maximum RPM
            "F\(index)Tg", // Target RPM
            "F\(index)Md", // Mode
            "F\(index)Sf", // Safe speed
            "F\(index)ID", // Fan ID
            "F\(index)Sp", // Speed (alternativo)
            "F\(index)Ds", // Description
            "F\(index)St", // Status
            "F\(index)Ct", // Control
            "F\(index)Lm", // Limit
            "F\(index)Lv", // Level
        ]

        for key in keys {
            if let val = readKey(key) {
                let typeStr = fourCharToString(val.dataType)
                let intVal: Int
                if typeStr == "flt " {
                    intVal = Int(bytesToFloat(val.bytes.0, val.bytes.1, val.bytes.2, val.bytes.3))
                } else {
                    intVal = Int(val.bytes.0)
                }
                smcLog("smolFanHelper: %@ EXISTS: type=%@, size=%d, value=%d", key, typeStr, val.dataSize, intVal)
            } else {
                smcLog("smolFanHelper: %@ NOT FOUND", key)
            }
        }

        // Also try global keys
        let globalKeys = ["FS! ", "FS!!", "FSCL", "FMod", "FsSm", "FSct"]
        for key in globalKeys {
            if let val = readKey(key) {
                smcLog("smolFanHelper: %@ EXISTS: type=%@, size=%d", key, fourCharToString(val.dataType), val.dataSize)
            } else {
                smcLog("smolFanHelper: %@ NOT FOUND", key)
            }
        }

        smcLog("smolFanHelper: === End fan key enumeration ===")
    }

    /// Counts the total number of available SMC keys
    func getKeyCount() -> Int {
        guard let val = readKey("#KEY") else {
            smcLog("smolFanHelper: Failed to read #KEY (key count)")
            return 0
        }
        // #KEY returns ui32 (4 bytes, big-endian)
        let count = (Int(val.bytes.0) << 24) | (Int(val.bytes.1) << 16) |
                    (Int(val.bytes.2) << 8) | Int(val.bytes.3)
        smcLog("smolFanHelper: Total SMC keys available: %d", count)
        return count
    }

    /// Reads the key name at the given index
    func getKeyAtIndex(_ index: Int) -> String? {
        guard isConnected else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()

        input.data8 = 8  // kSMCGetKeyFromIndex command
        input.data32 = UInt32(index)

        guard callSMC(input: &input, output: &output) else {
            return nil
        }

        return keyToString(output.key)
    }

    /// Debug: search for keys starting with "F" (fan-related)
    func debugSearchFanKeys() {
        smcLog("smolFanHelper: === Searching for all fan keys (F*) ===")

        let keyCount = getKeyCount()
        guard keyCount > 0 else {
            smcLog("smolFanHelper: No keys available to enumerate")
            return
        }

        var fanKeys: [String] = []

        // Note: enumerating all keys requires getKeyAtIndex
        // which may not be supported on all devices
        // Try only the first 200 keys for speed
        let maxToCheck = min(keyCount, 1000)

        for i in 0..<maxToCheck {
            if let key = getKeyAtIndex(i) {
                if key.hasPrefix("F") || key.hasPrefix("f") {
                    fanKeys.append(key)
                    smcLog("smolFanHelper: Found key: %@", key)
                }
            }
        }

        smcLog("smolFanHelper: Found %d fan-related keys out of %d checked", fanKeys.count, maxToCheck)
        smcLog("smolFanHelper: === End fan key search ===")
    }

    // MARK: - Low-level SMC Operations

    /// Reads an SMC key (first gets keyInfo, then reads bytes)
    private func readKey(_ key: String) -> SMCValue? {
        guard isConnected else { return nil }

        let keyCode = fourCharCode(key)

        // Step 1: Get key info (dataSize, dataType)
        guard let keyInfo = getKeyInfo(keyCode) else {
            smcLog("smolFanHelper: Failed to get key info for %@", key)
            return nil
        }

        // Step 2: Read actual data
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = keyCode
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMC_CMD_READ_BYTES

        guard callSMC(input: &input, output: &output) else {
            return nil
        }

        // Log first 8 bytes for debugging
        smcLog("smolFanHelper: Read %@: bytes=[0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x]",
              key,
              output.bytes.0, output.bytes.1, output.bytes.2, output.bytes.3,
              output.bytes.4, output.bytes.5, output.bytes.6, output.bytes.7)

        return SMCValue(
            dataSize: keyInfo.dataSize,
            dataType: keyInfo.dataType,
            bytes: output.bytes
        )
    }

    /// Writes an SMC key (legacy version with 2 bytes)
    private func writeKey(_ key: String, dataSize: UInt32, dataType: UInt32,
                          byte0: UInt8, byte1: UInt8 = 0) -> Bool {
        return writeKey(key, dataSize: dataSize, dataType: dataType,
                        bytes: (byte0, byte1, 0, 0))
    }

    /// Writes an SMC key (version with 4 bytes to support flt)
    private func writeKey(_ key: String, dataSize: UInt32, dataType: UInt32,
                          bytes: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        guard isConnected else { return false }

        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCharCode(key)
        input.keyInfo.dataSize = dataSize
        input.keyInfo.dataType = dataType  // CRITICAL: SMC needs to know the data format
        input.data8 = SMC_CMD_WRITE_BYTES
        input.bytes.0 = bytes.0
        input.bytes.1 = bytes.1
        input.bytes.2 = bytes.2
        input.bytes.3 = bytes.3

        smcLog("smolFanHelper: Writing %@: bytes=[0x%02x 0x%02x 0x%02x 0x%02x]",
               key, bytes.0, bytes.1, bytes.2, bytes.3)

        return callSMC(input: &input, output: &output)
    }

    /// Gets information about an SMC key (with cache)
    private func getKeyInfo(_ keyCode: UInt32) -> SMCKeyInfoData? {
        // Check cache first
        if let cached = keyInfoCache[keyCode] {
            return cached
        }

        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = keyCode
        input.data8 = SMC_CMD_READ_KEYINFO

        guard callSMC(input: &input, output: &output) else {
            return nil
        }

        let keyInfo = output.keyInfo
        keyInfoCache[keyCode] = keyInfo

        smcLog("smolFanHelper: KeyInfo for %@: size=%d, type=%@",
              keyToString(keyCode), keyInfo.dataSize, fourCharToString(keyInfo.dataType))

        return keyInfo
    }

    /// Calls IOConnectCallStructMethod to communicate with SMC
    private func callSMC(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        // Verify that the struct is 80 bytes as required by AppleSMC
        assert(inputSize == 80, "SMCKeyData must be 80 bytes, got \(inputSize)")

        let result = IOConnectCallStructMethod(
            connection,
            KERNEL_INDEX_SMC,
            &input,
            inputSize,
            &output,
            &outputSize
        )

        if result != kIOReturnSuccess {
            let keyStr = keyToString(input.key)
            smcLog("smolFanHelper: SMC call failed for key %@: IOReturn=0x%x, result=%d",
                  keyStr, result, output.result)
            return false
        }

        // Check SMC result code
        if output.result != 0 {
            let keyStr = keyToString(input.key)
            smcLog("smolFanHelper: SMC returned error for key %@: result=%d",
                  keyStr, output.result)
            return false
        }

        return true
    }

    // MARK: - Type Conversions

    /// Converts fpe2 (fixed point 14.2) to Int
    private func fpe2ToInt(_ byte0: UInt8, _ byte1: UInt8) -> Int {
        // FPE2: 14 bit integer part, 2 bit fractional part
        // Value = (byte0 << 6) + (byte1 >> 2)
        return (Int(byte0) << 6) + (Int(byte1) >> 2)
    }

    /// Converts Int to fpe2
    private func intToFPE2(_ value: Int) -> (UInt8, UInt8) {
        // Reverse of fpe2ToInt
        let byte0 = UInt8(value >> 6)
        let byte1 = UInt8((value << 2) ^ ((value >> 6) << 8))
        return (byte0, byte1)
    }

    /// Converts 4 bytes (little-endian) to Float IEEE 754
    private func bytesToFloat(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Float {
        // Little-endian: b0 is LSB, b3 is MSB
        let bits: UInt32 = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
        return Float(bitPattern: bits)
    }

    /// Converts Float to 4 bytes (little-endian)
    private func floatToBytes(_ value: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let bits = value.bitPattern
        return (
            UInt8(bits & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        )
    }

    /// Converts SMC bytes to RPM based on data type
    private func bytesToRPM(_ bytes: SMCBytes, dataType: UInt32) -> Int {
        let typeStr = fourCharToString(dataType)

        switch typeStr {
        case "flt ":
            // IEEE 754 float (Apple Silicon)
            let value = bytesToFloat(bytes.0, bytes.1, bytes.2, bytes.3)
            return Int(value)

        case "fpe2":
            // Fixed point 14.2 (Intel)
            return fpe2ToInt(bytes.0, bytes.1)

        default:
            // Try fpe2 as default
            smcLog("smolFanHelper: Unknown RPM type '%@', trying fpe2", typeStr)
            return fpe2ToInt(bytes.0, bytes.1)
        }
    }

    /// Converts RPM to SMC bytes based on data type
    private func rpmToBytes(_ rpm: Int, dataType: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        let typeStr = fourCharToString(dataType)

        switch typeStr {
        case "flt ":
            // IEEE 754 float (Apple Silicon)
            return floatToBytes(Float(rpm))

        case "fpe2":
            // Fixed point 14.2 (Intel)
            let fpe2 = intToFPE2(rpm)
            return (fpe2.0, fpe2.1, 0, 0)

        default:
            smcLog("smolFanHelper: Unknown RPM type '%@', using fpe2", typeStr)
            let fpe2 = intToFPE2(rpm)
            return (fpe2.0, fpe2.1, 0, 0)
        }
    }

    /// Converts 4-character string to UInt32 (FourCC)
    private func fourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        let bytes = Array(str.utf8)

        for i in 0..<min(4, bytes.count) {
            result = result << 8 | UInt32(bytes[i])
        }

        // Pad with spaces if less than 4 characters
        for _ in bytes.count..<4 {
            result = result << 8 | UInt32(0x20) // space
        }

        return result
    }

    /// Converts UInt32 FourCC to string
    private func keyToString(_ key: UInt32) -> String {
        // UInt8 init of UnicodeScalar is non-failing (every 0...255 byte is a scalar)
        let bytes: [UInt8] = [
            UInt8((key >> 24) & 0xff),
            UInt8((key >> 16) & 0xff),
            UInt8((key >>  8) & 0xff),
            UInt8( key        & 0xff)
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// Converts UInt32 dataType to string for debug
    private func fourCharToString(_ val: UInt32) -> String {
        return keyToString(val)
    }

    // MARK: - Alternative Fan Control (Min/Max Constraint Approach)

    /// Test writing to F0Mn (minimum RPM) to force fan speed floor
    /// Hypothesis: Thermal management respects minimum RPM constraint
    func testWriteMinimumRPM(index: Int, minimumRPM: Int) -> Bool {
        smcLog("smolFanHelper: === TEST: Write to F%dMn (minimum RPM) ===", index)

        let key = "F\(index)Mn"
        guard let val = readKey(key) else {
            smcLog("smolFanHelper: %@ key not found", key)
            return false
        }

        let currentMin = bytesToRPM(val.bytes, dataType: val.dataType)
        smcLog("smolFanHelper: %@ current value: %d RPM", key, currentMin)

        // Write the desired minimum
        let bytes = rpmToBytes(minimumRPM, dataType: val.dataType)
        let writeSuccess = writeKey(key, dataSize: val.dataSize, dataType: val.dataType, bytes: bytes)

        if writeSuccess {
            usleep(50000) // 50ms delay

            if let newVal = readKey(key) {
                let newMin = bytesToRPM(newVal.bytes, dataType: newVal.dataType)
                smcLog("smolFanHelper: %@ after write: %d RPM (wanted %d)", key, newMin, minimumRPM)

                let tolerance = 50
                if abs(newMin - minimumRPM) <= tolerance {
                    smcLog("smolFanHelper: SUCCESS: F%dMn write accepted!", index)

                    // Wait and check if actual RPM increases
                    usleep(500000) // 500ms for fan to respond
                    if let actualVal = readKey("F\(index)Ac") {
                        let actualRPM = bytesToRPM(actualVal.bytes, dataType: actualVal.dataType)
                        smcLog("smolFanHelper: F%dAc after min change: %d RPM", index, actualRPM)

                        if actualRPM >= minimumRPM - tolerance {
                            smcLog("smolFanHelper: Fan responded to minimum constraint!")
                            return true
                        }
                    }
                    return true // Write stuck even if fan didn't respond yet
                } else {
                    smcLog("smolFanHelper: F%dMn write was ignored", index)
                }
            }
        } else {
            smcLog("smolFanHelper: F%dMn write failed at IOKit level", index)
        }

        return false
    }

}

// MARK: - SMC Data Structures

/// Value read from SMC
private struct SMCValue {
    var dataSize: UInt32
    var dataType: UInt32
    var bytes: SMCBytes
}

/// Data structure for communication with SMC via IOKit
/// Exact copy from the SMCKit definition that works
/// IMPORTANT: Must be exactly 80 bytes to work with AppleSMC
private struct SMCKeyData {
    /// FourCharCode indicating which key we want
    var key: UInt32 = 0

    var vers = SMCVersion()

    var pLimitData = SMCPLimitData()

    var keyInfo = SMCKeyInfoData()

    /// Padding for struct alignment when passed to C
    var padding: UInt16 = 0

    /// Operation result
    var result: UInt8 = 0

    var status: UInt8 = 0

    /// Method selector
    var data8: UInt8 = 0

    var data32: UInt32 = 0

    /// Data returned by SMC
    var bytes: SMCBytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0))
}

private struct SMCVersion {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    /// How many bytes written in SMCKeyData.bytes
    var dataSize: UInt32 = 0

    /// Data type written in SMCKeyData.bytes
    var dataType: UInt32 = 0

    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
