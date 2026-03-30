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

    init() {
        openConnection()
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
    /// Su Apple Silicon (M1/M2/M3/M4), usa F%dMd invece di FS!
    /// Mode values: 0=off?, 1=manual?, 2=?, 3=auto (default)
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

    // MARK: - M4 Fan Control Test Functions

    /// Test function to try different FOFC sequences and values
    /// This helps discover which combination works on M4 Macs
    func testFOFCSequences(index: Int, targetRPM: Int) -> Bool {
        smcLog("smolFanHelper: === BEGIN FOFC SEQUENCE TESTING ===")
        smcLog("smolFanHelper: Testing fan %d, target RPM: %d", index, targetRPM)

        // First, read all relevant keys to understand current state
        let modeKey = "F\(index)Md"
        let targetKey = "F\(index)Tg"

        var fofcInfo: SMCValue?
        var mdInfo: SMCValue?
        var tgInfo: SMCValue?

        if let val = readKey("FOFC") {
            fofcInfo = val
            smcLog("smolFanHelper: FOFC: current=0x%02x, type=%@, size=%d",
                  val.bytes.0, fourCharToString(val.dataType), val.dataSize)
        } else {
            smcLog("smolFanHelper: FOFC key NOT FOUND")
            return false
        }

        if let val = readKey(modeKey) {
            mdInfo = val
            smcLog("smolFanHelper: %@: current=%d, type=%@, size=%d",
                  modeKey, val.bytes.0, fourCharToString(val.dataType), val.dataSize)
        }

        if let val = readKey(targetKey) {
            tgInfo = val
            let currentRPM = bytesToRPM(val.bytes, dataType: val.dataType)
            smcLog("smolFanHelper: %@: current=%d RPM, type=%@, size=%d",
                  targetKey, currentRPM, fourCharToString(val.dataType), val.dataSize)
        }

        // ============ TEST SEQUENCE 1: FOFC=0x01, then F0Md=1, then F0Tg ============
        smcLog("smolFanHelper: --- Sequence 1: FOFC=0x01 -> F0Md=1 -> F0Tg ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x01, byte1: 0)
            usleep(10000) // 10ms delay
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
                verifyKey(modeKey)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 1 SUCCEEDED!")
                    return true
                }
            }
        }

        // Reset for next test
        usleep(50000) // 50ms

        // ============ TEST SEQUENCE 2: FOFC=0xFF (all bits set) ============
        smcLog("smolFanHelper: --- Sequence 2: FOFC=0xFF -> F0Md=1 -> F0Tg ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0xFF, byte1: 0)
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
                verifyKey(modeKey)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 2 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 3: FOFC with bitmask for fan index ============
        smcLog("smolFanHelper: --- Sequence 3: FOFC=(1<<index) bitmask ---")
        if let fofc = fofcInfo {
            let bitmask = UInt8(1 << index)
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: bitmask, byte1: 0)
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
                verifyKey(modeKey)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 3 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 4: F0Md FIRST, then FOFC, then F0Tg ============
        smcLog("smolFanHelper: --- Sequence 4: F0Md=1 -> FOFC=0x01 -> F0Tg ---")
        if let md = mdInfo {
            _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
            usleep(10000)
            verifyKey(modeKey)
        }

        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x01, byte1: 0)
            usleep(10000)
            verifyKey("FOFC")
        }

        if let tg = tgInfo {
            let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
            _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
            usleep(10000)
            if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                smcLog("smolFanHelper: Sequence 4 SUCCEEDED!")
                return true
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 5: FOFC=0x02 (maybe 2 = force mode enabled?) ============
        smcLog("smolFanHelper: --- Sequence 5: FOFC=0x02 -> F0Md=1 -> F0Tg ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x02, byte1: 0)
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
                verifyKey(modeKey)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 5 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 6: F0Md=0 (maybe 0 is manual?) ============
        smcLog("smolFanHelper: --- Sequence 6: FOFC=0x01 -> F0Md=0 -> F0Tg ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x01, byte1: 0)
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 0, byte1: 0)
                usleep(10000)
                verifyKey(modeKey)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 6 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 7: Multi-byte FOFC (if size > 1) ============
        if let fofc = fofcInfo, fofc.dataSize > 1 {
            smcLog("smolFanHelper: --- Sequence 7: FOFC multi-byte (size=%d) ---", fofc.dataSize)
            // Try setting multiple bytes
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x01, 0x01, 0x00, 0x00))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 7 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 8: Try F0Fc (Force Control per-fan) before FOFC ============
        smcLog("smolFanHelper: --- Sequence 8: F0Fc -> FOFC -> F0Md -> F0Tg ---")
        let fcKey = "F\(index)Fc"
        if let fcVal = readKey(fcKey) {
            smcLog("smolFanHelper: %@ exists! value=%d", fcKey, fcVal.bytes.0)
            _ = writeKey(fcKey, dataSize: fcVal.dataSize, dataType: fcVal.dataType, byte0: 1, byte1: 0)
            usleep(10000)
            verifyKey(fcKey)
        }

        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x01, byte1: 0)
            usleep(10000)
        }

        if let md = mdInfo {
            _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
            usleep(10000)
        }

        if let tg = tgInfo {
            let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
            _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
            usleep(10000)
            if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                smcLog("smolFanHelper: Sequence 8 SUCCEEDED!")
                return true
            }
        }

        // ============ TEST SEQUENCE 9: OR enable bit with base value ============
        // FOFC initial value is 0x000001d5 (bytes: 0x00 0x00 0x01 0xd5)
        // Try adding 0x01000000 to enable: 0x010001d5
        smcLog("smolFanHelper: --- Sequence 9: FOFC=0x010001d5 (OR enable bit with base 0x01d5) ---")
        if let fofc = fofcInfo {
            // 0x010001d5 in big-endian: byte0=0x01, byte1=0x00, byte2=0x01, byte3=0xd5
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x01, 0x00, 0x01, 0xd5))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 9 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 10: Modify low byte while preserving 0x01d5 base ============
        smcLog("smolFanHelper: --- Sequence 10: FOFC=0x000001d6 (increment low byte) ---")
        if let fofc = fofcInfo {
            // 0x000001d6 in big-endian
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x00, 0x00, 0x01, 0xd6))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 10 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 11: Set low byte to 0xdf (maybe flags?) ============
        smcLog("smolFanHelper: --- Sequence 11: FOFC=0x000001df (set flag bits in low byte) ---")
        if let fofc = fofcInfo {
            // 0x000001df in big-endian
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x00, 0x00, 0x01, 0xdf))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 11 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 12: Try 0x020001d5 (different enable bit) ============
        smcLog("smolFanHelper: --- Sequence 12: FOFC=0x020001d5 (0x02 in high byte) ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x02, 0x00, 0x01, 0xd5))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 12 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 13: Try 0xFF0001d5 (all bits in high byte) ============
        smcLog("smolFanHelper: --- Sequence 13: FOFC=0xFF0001d5 (0xFF in high byte) ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0xFF, 0x00, 0x01, 0xd5))
            usleep(10000)
            verifyKey("FOFC")

            if let md = mdInfo {
                _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                usleep(10000)
            }

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 13 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 14: Write F0Tg FIRST, then FOFC, then check F0Tg ============
        smcLog("smolFanHelper: --- Sequence 14: F0Tg -> FOFC=0x010001d5 -> verify F0Tg ---")
        if let tg = tgInfo {
            let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
            smcLog("smolFanHelper: Writing F0Tg FIRST to %d RPM", targetRPM)
            _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
            usleep(10000)
            verifyKey(targetKey)
        }

        if let fofc = fofcInfo {
            smcLog("smolFanHelper: Then writing FOFC=0x010001d5")
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                        bytes: (0x01, 0x00, 0x01, 0xd5))
            usleep(10000)
            verifyKey("FOFC")
        }

        smcLog("smolFanHelper: Checking if F0Tg stuck after FOFC write...")
        if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
            smcLog("smolFanHelper: Sequence 14 SUCCEEDED!")
            return true
        }

        usleep(50000)

        // ============ TEST SEQUENCE 15: Read FOFC -> Write F0Tg -> Check F0Tg ============
        smcLog("smolFanHelper: --- Sequence 15: Read FOFC -> Write F0Tg -> Check ---")
        if let fofc = readKey("FOFC") {
            smcLog("smolFanHelper: Read FOFC current: 0x%02x 0x%02x 0x%02x 0x%02x",
                  fofc.bytes.0, fofc.bytes.1, fofc.bytes.2, fofc.bytes.3)
        }

        if let tg = tgInfo {
            let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
            smcLog("smolFanHelper: Writing F0Tg to %d RPM after reading FOFC", targetRPM)
            _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
            usleep(10000)

            smcLog("smolFanHelper: Checking if F0Tg changed...")
            if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                smcLog("smolFanHelper: Sequence 15 SUCCEEDED!")
                return true
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 16: Try second byte variations (0x00XX01d5) ============
        smcLog("smolFanHelper: --- Sequence 16: FOFC=0x00010001d5 variations (second byte) ---")
        let secondByteValues: [UInt8] = [0x01, 0x02, 0xFF]
        for secondByte in secondByteValues {
            if let fofc = fofcInfo {
                smcLog("smolFanHelper: Trying FOFC=0x00%02x01d5", secondByte)
                _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                            bytes: (0x00, secondByte, 0x01, 0xd5))
                usleep(10000)
                verifyKey("FOFC")

                if let md = mdInfo {
                    _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                    usleep(10000)
                }

                if let tg = tgInfo {
                    let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                    _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                    usleep(10000)
                    if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                        smcLog("smolFanHelper: Sequence 16 with 0x00%02x01d5 SUCCEEDED!", secondByte)
                        return true
                    }
                }
            }
            usleep(20000)
        }

        usleep(50000)

        // ============ TEST SEQUENCE 17: Try third byte variations (0x00000Xd5) ============
        smcLog("smolFanHelper: --- Sequence 17: FOFC third byte variations ---")
        let thirdByteValues: [UInt8] = [0x00, 0x02, 0x03, 0xFF]
        for thirdByte in thirdByteValues {
            if let fofc = fofcInfo {
                smcLog("smolFanHelper: Trying FOFC=0x0000%02xd5", thirdByte)
                _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType,
                            bytes: (0x00, 0x00, thirdByte, 0xd5))
                usleep(10000)
                verifyKey("FOFC")

                if let md = mdInfo {
                    _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 1, byte1: 0)
                    usleep(10000)
                }

                if let tg = tgInfo {
                    let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                    _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                    usleep(10000)
                    if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                        smcLog("smolFanHelper: Sequence 17 with 0x0000%02xd5 SUCCEEDED!", thirdByte)
                        return true
                    }
                }
            }
            usleep(20000)
        }

        // ============ TEST SEQUENCE 18: FS!! with value 0x01, then F0Tg ============
        smcLog("smolFanHelper: --- Sequence 18: FS!!=0x01 -> F0Tg ---")
        if let fsVal = readKey("FS!!") {
            smcLog("smolFanHelper: FS!! exists! current=0x%02x 0x%02x, type=%@, size=%d",
                  fsVal.bytes.0, fsVal.bytes.1, fourCharToString(fsVal.dataType), fsVal.dataSize)

            // Write 0x01 to enable force mode
            _ = writeKey("FS!!", dataSize: fsVal.dataSize, dataType: fsVal.dataType, byte0: 0x01, byte1: 0)
            usleep(10000)
            verifyKey("FS!!")

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 18 SUCCEEDED!")
                    return true
                }
            }
        } else {
            smcLog("smolFanHelper: FS!! key NOT FOUND")
        }

        usleep(50000)

        // ============ TEST SEQUENCE 19: FS!! with value 0xFF, then F0Tg ============
        smcLog("smolFanHelper: --- Sequence 19: FS!!=0xFF -> F0Tg ---")
        if let fsVal = readKey("FS!!") {
            // Write 0xFF (all bits set) to enable force mode
            _ = writeKey("FS!!", dataSize: fsVal.dataSize, dataType: fsVal.dataType, byte0: 0xFF, byte1: 0xFF)
            usleep(10000)
            verifyKey("FS!!")

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 19 SUCCEEDED!")
                    return true
                }
            }
        }

        usleep(50000)

        // ============ TEST SEQUENCE 20: FS!! with bitmask for fan index, then F0Tg ============
        smcLog("smolFanHelper: --- Sequence 20: FS!! bitmask (1<<index) -> F0Tg ---")
        if let fsVal = readKey("FS!!") {
            // Use bitmask like Intel FS! key: bit N = fan N forced
            let bitmask = UInt16(1 << index)
            let byte0 = UInt8((bitmask >> 8) & 0xFF)
            let byte1 = UInt8(bitmask & 0xFF)
            smcLog("smolFanHelper: Writing FS!! bitmask=0x%04x (byte0=0x%02x, byte1=0x%02x)", bitmask, byte0, byte1)
            _ = writeKey("FS!!", dataSize: fsVal.dataSize, dataType: fsVal.dataType, byte0: byte0, byte1: byte1)
            usleep(10000)
            verifyKey("FS!!")

            if let tg = tgInfo {
                let bytes = rpmToBytes(targetRPM, dataType: tg.dataType)
                _ = writeKey(targetKey, dataSize: tg.dataSize, dataType: tg.dataType, bytes: bytes)
                usleep(10000)
                if verifyTargetRPM(targetKey, expected: targetRPM, tolerance: 100) {
                    smcLog("smolFanHelper: Sequence 20 SUCCEEDED!")
                    return true
                }
            }
        }

        // ============ RESET: Try to restore auto mode ============
        smcLog("smolFanHelper: --- Resetting to auto mode ---")
        if let fofc = fofcInfo {
            _ = writeKey("FOFC", dataSize: fofc.dataSize, dataType: fofc.dataType, byte0: 0x00, byte1: 0)
        }
        if let md = mdInfo {
            _ = writeKey(modeKey, dataSize: md.dataSize, dataType: md.dataType, byte0: 3, byte1: 0) // 3 = auto
        }
        // Also reset FS!! if it exists
        if let fsVal = readKey("FS!!") {
            _ = writeKey("FS!!", dataSize: fsVal.dataSize, dataType: fsVal.dataType, byte0: 0x00, byte1: 0x00)
        }

        smcLog("smolFanHelper: === END FOFC SEQUENCE TESTING - NO SEQUENCE WORKED ===")
        return false
    }

    /// Helper to verify a key was written successfully
    private func verifyKey(_ key: String) {
        if let val = readKey(key) {
            smcLog("smolFanHelper: VERIFY %@: 0x%02x 0x%02x 0x%02x 0x%02x",
                  key, val.bytes.0, val.bytes.1, val.bytes.2, val.bytes.3)
        }
    }

    /// Helper to verify target RPM was written successfully
    private func verifyTargetRPM(_ key: String, expected: Int, tolerance: Int) -> Bool {
        if let val = readKey(key) {
            let actualRPM = bytesToRPM(val.bytes, dataType: val.dataType)
            let diff = abs(actualRPM - expected)
            smcLog("smolFanHelper: VERIFY %@: %d RPM (expected %d, diff=%d, tolerance=%d)",
                  key, actualRPM, expected, diff, tolerance)
            return diff <= tolerance
        }
        return false
    }

    /// Exhaustive search for FOFC-related keys
    func debugSearchFOFCKeys() {
        smcLog("smolFanHelper: === Searching for FOFC-related keys ===")

        // Keys that might be related to force fan control
        let keysToTry = [
            "FOFC",  // Force Override Fan Control?
            "FOF0", "FOF1", "FOF2",  // Per-fan force override?
            "FFC0", "FFC1", "FFC2",  // Fan Force Control?
            "FFCE",  // Force Fan Control Enable?
            "FFCM",  // Force Fan Control Mode?
            "FFCt",  // Force Fan Control Target?
            "FcOv",  // Force Override?
            "FfOv",  // Fan force Override?
            "FCnt",  // Fan Control?
            "FMod",  // Fan Mode global?
            "FMCt",  // Fan Manual Control?
            "FMEn",  // Fan Manual Enable?
            "FMan",  // Fan Manual?
            "FFor",  // Fan Force?
            "FFrc",  // Fan Force?
            "FCtl",  // Fan Control?
            "FsCl",  // Fan Speed Control?
            "FsLk",  // Fan Speed Lock?
            "FLck",  // Fan Lock?
            "FsOv",  // Fan Speed Override?
            "FSpd",  // Fan Speed?
            "FSCt",  // Fan Speed Control?
            "FS!!",  // Force Set (Intel style with !)
        ]

        for key in keysToTry {
            if let val = readKey(key) {
                smcLog("smolFanHelper: FOUND %@: type=%@, size=%d, bytes=[0x%02x 0x%02x 0x%02x 0x%02x]",
                      key, fourCharToString(val.dataType), val.dataSize,
                      val.bytes.0, val.bytes.1, val.bytes.2, val.bytes.3)
            }
        }

        smcLog("smolFanHelper: === End FOFC key search ===")
    }

    /// Sets target RPM for a fan
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

        // Verify if the write took effect
        if success {
            if let newVal = readKey(key) {
                let newRPM = bytesToRPM(newVal.bytes, dataType: newVal.dataType)
                smcLog("smolFanHelper: %@ after write: %d RPM (wanted %d)", key, newRPM, rpm)

                // Tolerate minor differences (< 50 RPM) dovute ad arrotondamenti
                let tolerance = 50
                if abs(newRPM - rpm) > tolerance {
                    smcLog("smolFanHelper: WARNING: %@ write was ignored by SMC", key)
                    // Try writing to F0Fc/F1Fc (Force Control) as well
                    let fcKey = "F\(index)Fc"
                    if let fcVal = readKey(fcKey) {
                        smcLog("smolFanHelper: Trying %@ (Force Control), current=%d", fcKey, fcVal.bytes.0)
                        // F*Fc might be a force enable bit - try setting to 1
                        _ = writeKey(fcKey, dataSize: fcVal.dataSize, dataType: fcVal.dataType,
                                    byte0: 1, byte1: 0)
                        // Then try target again
                        _ = writeKey(key, dataSize: val.dataSize, dataType: val.dataType, bytes: bytes)
                        if let retryVal = readKey(key) {
                            let retryRPM = bytesToRPM(retryVal.bytes, dataType: retryVal.dataType)
                            smcLog("smolFanHelper: %@ after Fc+retry: %d RPM", key, retryRPM)
                            // Return true only if retry succeeded
                            return abs(retryRPM - rpm) <= tolerance
                        }
                    }
                    // Write was ignored and no Fc key exists
                    return false
                }
                // Write succeeded (value matches within tolerance)
                return true
            }
        } else {
            smcLog("smolFanHelper: %@ write failed at IOKit level", key)
        }

        return success
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
        var chars: [Character] = []
        chars.append(Character(UnicodeScalar((key >> 24) & 0xff)!))
        chars.append(Character(UnicodeScalar((key >> 16) & 0xff)!))
        chars.append(Character(UnicodeScalar((key >> 8) & 0xff)!))
        chars.append(Character(UnicodeScalar(key & 0xff)!))
        return String(chars)
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

    /// Test clamping F0Mn and F0Mx to same value to force exact RPM
    func testClampMinMax(index: Int, targetRPM: Int) -> Bool {
        smcLog("smolFanHelper: === TEST: Clamp F%dMn = F%dMx = %d RPM ===", index, index, targetRPM)

        let minKey = "F\(index)Mn"
        let maxKey = "F\(index)Mx"

        guard let minVal = readKey(minKey), let maxVal = readKey(maxKey) else {
            smcLog("smolFanHelper: Min/Max keys not found")
            return false
        }

        let originalMin = bytesToRPM(minVal.bytes, dataType: minVal.dataType)
        let originalMax = bytesToRPM(maxVal.bytes, dataType: maxVal.dataType)
        smcLog("smolFanHelper: Original: F%dMn=%d, F%dMx=%d", index, originalMin, index, originalMax)

        let bytes = rpmToBytes(targetRPM, dataType: minVal.dataType)

        // Write max first (so min doesn't exceed max)
        smcLog("smolFanHelper: Writing F%dMx = %d", index, targetRPM)
        _ = writeKey(maxKey, dataSize: maxVal.dataSize, dataType: maxVal.dataType, bytes: bytes)
        usleep(20000)

        // Then write min
        smcLog("smolFanHelper: Writing F%dMn = %d", index, targetRPM)
        _ = writeKey(minKey, dataSize: minVal.dataSize, dataType: minVal.dataType, bytes: bytes)
        usleep(50000)

        // Verify values
        var minStuck = false
        var maxStuck = false

        if let newMin = readKey(minKey) {
            let newMinRPM = bytesToRPM(newMin.bytes, dataType: newMin.dataType)
            smcLog("smolFanHelper: F%dMn after write: %d (wanted %d)", index, newMinRPM, targetRPM)
            minStuck = abs(newMinRPM - targetRPM) <= 50
        }

        if let newMax = readKey(maxKey) {
            let newMaxRPM = bytesToRPM(newMax.bytes, dataType: newMax.dataType)
            smcLog("smolFanHelper: F%dMx after write: %d (wanted %d)", index, newMaxRPM, targetRPM)
            maxStuck = abs(newMaxRPM - targetRPM) <= 50
        }

        // Wait for fan to respond
        usleep(1000000) // 1 second for fan stabilization

        if let actualVal = readKey("F\(index)Ac") {
            let actualRPM = bytesToRPM(actualVal.bytes, dataType: actualVal.dataType)
            smcLog("smolFanHelper: F%dAc after clamp: %d RPM (target %d)", index, actualRPM, targetRPM)

            let tolerance = 200 // Wider tolerance for actual RPM
            if abs(actualRPM - targetRPM) <= tolerance {
                smcLog("smolFanHelper: SUCCESS: Min/Max clamp achieved target RPM!")
                return true
            }
        }

        smcLog("smolFanHelper: minStuck=%@, maxStuck=%@", minStuck ? "YES" : "NO", maxStuck ? "YES" : "NO")
        return minStuck || maxStuck
    }

    /// Comprehensive alternative fan control test
    func testAlternativeFanControl(index: Int, targetRPM: Int) -> String {
        smcLog("smolFanHelper: ╔════════════════════════════════════════════════════════════╗")
        smcLog("smolFanHelper: ║   ALTERNATIVE FAN CONTROL TEST SUITE FOR APPLE SILICON M4  ║")
        smcLog("smolFanHelper: ╠════════════════════════════════════════════════════════════╣")
        smcLog("smolFanHelper: ║   Fan Index: %d   Target RPM: %d                          ║", index, targetRPM)
        smcLog("smolFanHelper: ╚════════════════════════════════════════════════════════════╝")

        // Record initial state
        let initialActual = getFanRPM(index: index)
        let initialMin = getFanMinRPM(index: index)
        let initialMax = getFanMaxRPM(index: index)
        let initialTarget = getFanTargetRPM(index: index)

        smcLog("smolFanHelper: Initial State:")
        smcLog("smolFanHelper:   F%dAc (actual) = %d RPM", index, initialActual)
        smcLog("smolFanHelper:   F%dMn (min)    = %d RPM", index, initialMin)
        smcLog("smolFanHelper:   F%dMx (max)    = %d RPM", index, initialMax)
        smcLog("smolFanHelper:   F%dTg (target) = %d RPM", index, initialTarget)

        var results: [String] = []

        // Test 1: Write to F0Mn (minimum)
        smcLog("smolFanHelper: ")
        smcLog("smolFanHelper: ┌─ TEST 1: Write to F%dMn (Minimum RPM) ────────────────────┐", index)
        let test1Result = testWriteMinimumRPM(index: index, minimumRPM: targetRPM)
        smcLog("smolFanHelper: └─ Result: %@ ────────────────────────────────────────────┘",
              test1Result ? "SUCCESS" : "FAILED")
        results.append("F0Mn write: \(test1Result ? "SUCCESS" : "FAILED")")

        // Restore minimum
        let origMinBytes = rpmToBytes(initialMin, dataType: fourCharCode("flt "))
        if let minVal = readKey("F\(index)Mn") {
            _ = writeKey("F\(index)Mn", dataSize: minVal.dataSize, dataType: minVal.dataType, bytes: origMinBytes)
        }

        usleep(500000)

        // Test 2: Clamp min/max to same value
        smcLog("smolFanHelper: ")
        smcLog("smolFanHelper: ┌─ TEST 2: Clamp F%dMn = F%dMx = %d ─────────────────────┐", index, index, targetRPM)
        let test2Result = testClampMinMax(index: index, targetRPM: targetRPM)
        smcLog("smolFanHelper: └─ Result: %@ ────────────────────────────────────────────┘",
              test2Result ? "SUCCESS" : "FAILED")
        results.append("Min/Max clamp: \(test2Result ? "SUCCESS" : "FAILED")")

        // Restore original min/max
        let origMaxBytes = rpmToBytes(initialMax, dataType: fourCharCode("flt "))
        if let minVal = readKey("F\(index)Mn"), let maxVal = readKey("F\(index)Mx") {
            _ = writeKey("F\(index)Mx", dataSize: maxVal.dataSize, dataType: maxVal.dataType, bytes: origMaxBytes)
            usleep(10000)
            _ = writeKey("F\(index)Mn", dataSize: minVal.dataSize, dataType: minVal.dataType, bytes: origMinBytes)
        }

        // Summary
        smcLog("smolFanHelper: ")
        smcLog("smolFanHelper: ╔════════════════════════════════════════════════════════════╗")
        smcLog("smolFanHelper: ║                     TEST SUMMARY                           ║")
        smcLog("smolFanHelper: ╠════════════════════════════════════════════════════════════╣")
        smcLog("smolFanHelper: ║   Test 1 (F0Mn minimum):   %@                            ║", test1Result ? "PASS" : "FAIL")
        smcLog("smolFanHelper: ║   Test 2 (Min/Max clamp):  %@                            ║", test2Result ? "PASS" : "FAIL")
        smcLog("smolFanHelper: ╚════════════════════════════════════════════════════════════╝")

        // Final state
        smcLog("smolFanHelper: ")
        smcLog("smolFanHelper: Final State (after tests):")
        smcLog("smolFanHelper:   F%dAc = %d RPM", index, getFanRPM(index: index))
        smcLog("smolFanHelper:   F%dMn = %d RPM", index, getFanMinRPM(index: index))
        smcLog("smolFanHelper:   F%dMx = %d RPM", index, getFanMaxRPM(index: index))

        return results.joined(separator: "; ")
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
