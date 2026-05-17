import Foundation
import IOKit
import ServiceManagement
import Security
import os

/// Monitors and controls fans via SMC and IOKit
/// Note: On Apple Silicon (M1/M2/M3/M4), direct fan control
/// requires special privileges. This implementation uses a privileged
/// helper (smolFanHelper) when available, otherwise
/// provides estimates based on thermal state.
class FanMonitor {
    private var connection: io_connect_t = 0
    private var isConnected = false
    private var isAppleSilicon: Bool = false

    // MARK: - XPC Helper Connection

    private var xpcConnection: NSXPCConnection?
    private var helperAvailable = false
    private var helperCheckDone = false

    enum FanMode {
        case system            // macOS automatic control
        case max               // Fans at maximum
        case autoMax           // Auto but more aggressive
        case manual(rpm: Int)  // Specific target RPM
    }

    struct FanInfo: Identifiable {
        let id: Int
        let name: String
        var currentRPM: Int
        var minRPM: Int
        var maxRPM: Int
        var targetRPM: Int

        var rpmPercent: Double {
            guard maxRPM > minRPM else { return 0 }
            let percent = Double(currentRPM - minRPM) / Double(maxRPM - minRPM) * 100
            return max(0, min(100, percent))
        }
    }

    init() {
        detectArchitecture()
        openSMCConnection()
        // On Apple Silicon, try to connect to the helper
        if isAppleSilicon {
            connectToHelper()
        }
    }

    deinit {
        closeSMCConnection()
        xpcConnection?.invalidate()
    }

    // MARK: - XPC Helper Methods

    /// Attempts connection to the privileged helper
    private func connectToHelper() {
        xpcConnection = NSXPCConnection(machServiceName: "com.smol.fanhelper",
                                         options: .privileged)
        xpcConnection?.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)

        xpcConnection?.interruptionHandler = { [weak self] in
            self?.helperAvailable = false
        }

        xpcConnection?.invalidationHandler = { [weak self] in
            self?.helperAvailable = false
            self?.xpcConnection = nil
        }

        xpcConnection?.resume()

        // Test connessione asincrono
        checkHelperAvailability()
    }

    /// Checks if the helper is available and functioning
    private func checkHelperAvailability() {
        guard let helper = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            SmolLog.fan.error("Helper XPC error: \(error.localizedDescription)")
            self?.helperAvailable = false
            self?.helperCheckDone = true
        }) as? FanHelperProtocol else {
            SmolLog.fan.error("Failed to get helper proxy")
            helperAvailable = false
            helperCheckDone = true
            return
        }

        // Use ping to verify connectivity (does not depend on SMC)
        helper.ping { [weak self] success in
            if success {
                SmolLog.fan.info("Helper ping successful - helper is available")
                self?.helperAvailable = true
                self?.helperCheckDone = true

                // Also try to get fan count for debug
                helper.getFanCount { count in
                    SmolLog.fan.info("Helper reports \(count) fan(s)")
                }

                // Debug: enumerate available SMC keys
                helper.debugEnumerateKeys { result in
                    SmolLog.fan.debug("Debug enumeration: \(result, privacy: .public)")
                }
            } else {
                SmolLog.fan.warning("Helper ping failed")
                self?.helperAvailable = false
                self?.helperCheckDone = true
            }
        }
    }

    /// Installs the privileged helper via SMAppService (macOS 13+)
    /// Requires admin authorization. If the daemon is already registered but
    /// pending the user's approval in Login Items, opens System Settings.
    ///
    /// We always call unregister() before register(). Without that, calling
    /// register() on an already-enabled service is a no-op and launchd keeps
    /// the previously-launched helper alive — even after the app bundle's
    /// helper binary has been replaced by a new build. The unregister/register
    /// round-trip is the supported way to make launchd pick up a refreshed
    /// helper.
    @discardableResult
    func installHelper() -> Bool {
        let service = SMAppService.daemon(plistName: "com.smol.fanhelper.plist")

        // If macOS has already registered the daemon and is just waiting for
        // the user to flip the switch in Login Items, jump straight there.
        if service.status == .requiresApproval {
            SmolLog.fan.info("Helper registered but pending user approval — opening System Settings")
            SMAppService.openSystemSettingsLoginItems()
            return false
        }

        // Best-effort unregister so register() actually refreshes the binary.
        if service.status == .enabled {
            do {
                try service.unregister()
                SmolLog.fan.info("Helper unregistered before re-register (force-refresh binary)")
            } catch {
                SmolLog.fan.warning("Helper unregister before refresh failed: \((error as NSError).localizedDescription, privacy: .public)")
            }
        }

        do {
            try service.register()
            SmolLog.fan.info("Helper registered successfully — status=\(service.status.rawValue, privacy: .public)")

            // After register() the status is usually .requiresApproval on first
            // install — bring the user to Login Items so they can enable it.
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }

            // Reconnect to the helper (will succeed once the user approves)
            xpcConnection?.invalidate()
            xpcConnection = nil
            helperAvailable = false
            helperCheckDone = false
            connectToHelper()
            return true
        } catch {
            let ns = error as NSError
            SmolLog.fan.error(
                "SMAppService.register failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) status=\(service.status.rawValue, privacy: .public)"
            )

            // Even on "Operation not permitted", the daemon may already be
            // registered in `.requiresApproval` — surface Login Items so the
            // user has somewhere to click.
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return false
            }

            // Fallback: try with the old SMJobBless method (macOS < 13 only)
            return installHelperLegacy()
        }
    }

    /// Legacy method to install helper (pre-macOS 13)
    /// Uses SMJobBless - deprecated but needed for compatibility with macOS < 13
    private func installHelperLegacy() -> Bool {
        // On macOS 13+ SMAppService should be used first
        // This is only a fallback for older versions
        guard #unavailable(macOS 13.0) else {
            SmolLog.fan.warning("installHelperLegacy called on macOS 13+, should use SMAppService")
            return false
        }

        var authRef: AuthorizationRef?
        let authFlags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]

        let status = withUnsafeMutablePointer(to: &authRef) { authRefPtr in
            AuthorizationCreate(nil, nil, authFlags, authRefPtr)
        }

        guard status == errAuthorizationSuccess else {
            SmolLog.fan.error("AuthorizationCreate failed: \(status)")
            return false
        }

        defer {
            if let authRef = authRef {
                AuthorizationFree(authRef, [])
            }
        }

        var error: Unmanaged<CFError>?
        // SMJobBless is deprecated in macOS 13 but SMAppService does not support
        // installing privileged helpers for SMC access, so it is necessary.
        // This code runs only on macOS < 13 thanks to the guard #unavailable above.
        let success = SMJobBless(kSMDomainSystemLaunchd,
                                  "com.smol.fanhelper" as CFString,
                                  authRef,
                                  &error)

        if success {
            SmolLog.fan.info("Helper installed successfully (legacy)")
            xpcConnection?.invalidate()
            xpcConnection = nil
            helperAvailable = false
            helperCheckDone = false
            connectToHelper()
            return true
        } else {
            if let error = error?.takeRetainedValue() {
                SmolLog.fan.error("SMJobBless failed: \(error)")
            }
            return false
        }
    }

    /// Checks if the helper needs to be installed/updated
    var needsHelperInstallation: Bool {
        return isAppleSilicon && !helperAvailable && helperCheckDone
    }

    /// Gets fan info via XPC helper
    private func getAppleSiliconFanInfoViaHelper() -> [FanInfo]? {
        guard helperAvailable else { return nil }

        guard let helper = xpcConnection?.synchronousRemoteObjectProxyWithErrorHandler({ error in
            SmolLog.fan.error("XPC error: \(error.localizedDescription)")
        }) as? FanHelperProtocol else {
            return nil
        }

        var fans: [FanInfo] = []
        let semaphore = DispatchSemaphore(value: 0)

        helper.getFanInfo { info in
            defer { semaphore.signal() }

            guard let count = info["count"] as? Int, count > 0 else { return }

            for i in 0..<count {
                let rpm = info["fan\(i)_rpm"] as? Int ?? 0
                let minRPM = info["fan\(i)_min"] as? Int ?? 1200
                let maxRPM = info["fan\(i)_max"] as? Int ?? 6000
                let targetRPM = info["fan\(i)_target"] as? Int ?? rpm

                let name = i == 0 ? "Left Side" : (i == 1 ? "Right Side" : "Fan \(i + 1)")

                fans.append(FanInfo(
                    id: i,
                    name: name,
                    currentRPM: rpm,
                    minRPM: minRPM,
                    maxRPM: maxRPM,
                    targetRPM: targetRPM
                ))
            }
        }

        // Timeout 1 second
        let result = semaphore.wait(timeout: .now() + 1.0)
        if result == .timedOut {
            SmolLog.fan.warning("Helper timeout")
            return nil
        }

        return fans.isEmpty ? nil : fans
    }

    // MARK: - Architecture Detection

    private func detectArchitecture() {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        isAppleSilicon = machine.contains("arm64")
    }

    // MARK: - Connection

    private func openSMCConnection() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )

        guard service != 0 else {
            // On Apple Silicon, try AppleSMCKeysEndpoint
            openAppleSiliconSMCConnection()
            return
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        if result == kIOReturnSuccess {
            isConnected = true
        }
    }

    private func openAppleSiliconSMCConnection() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMCKeysEndpoint")
        )

        guard service != 0 else {
            return
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        if result == kIOReturnSuccess {
            isConnected = true
        }
    }

    private func closeSMCConnection() {
        if isConnected {
            IOServiceClose(connection)
            isConnected = false
        }
    }

    // MARK: - Public Methods

    /// Gets info on all fans
    func getAllFans() -> [FanInfo] {
        // On Apple Silicon, try the privileged helper first.
        if isAppleSilicon {
            // Try XPC helper (real RPM)
            if let helperFans = getAppleSiliconFanInfoViaHelper() {
                return helperFans
            }
            // Fallback: estimate from thermal state
            return getAppleSiliconFanInfo()
        }

        // On Intel, try traditional SMC
        var fans = getAllFansViaSMC()
        if !fans.isEmpty {
            return fans
        }

        // Fallback: ioreg parsing
        fans = getAllFansViaIOReg()
        return fans
    }

    /// Indicates if the privileged helper is available
    var isHelperAvailable: Bool {
        return helperAvailable
    }

    // MARK: - Apple Silicon Method

    /// On Apple Silicon, fans are entirely managed by the system.
    /// This function provides an estimate based on thermal state.
    private func getAppleSiliconFanInfo() -> [FanInfo] {
        var fans: [FanInfo] = []

        // Get system thermal state
        let thermalState = Foundation.ProcessInfo.processInfo.thermalState

        // MacBook Pro M4 Max typically has 2 fans
        // Estimate RPM based on thermal state
        let (rpm, minRPM, maxRPM) = estimateRPMFromThermalState(thermalState)

        // Left fan
        fans.append(FanInfo(
            id: 0,
            name: "Left Side",
            currentRPM: rpm,
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: rpm
        ))

        // Right fan
        fans.append(FanInfo(
            id: 1,
            name: "Right Side",
            currentRPM: rpm,
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: rpm
        ))

        return fans
    }

    private func estimateRPMFromThermalState(_ state: Foundation.ProcessInfo.ThermalState) -> (rpm: Int, min: Int, max: Int) {
        // M4 Max fan specs (approximate)
        let minRPM = 1200
        let maxRPM = 6000

        switch state {
        case .nominal:
            return (minRPM, minRPM, maxRPM)
        case .fair:
            return (Int(Double(maxRPM - minRPM) * 0.3) + minRPM, minRPM, maxRPM)
        case .serious:
            return (Int(Double(maxRPM - minRPM) * 0.6) + minRPM, minRPM, maxRPM)
        case .critical:
            return (maxRPM, minRPM, maxRPM)
        @unknown default:
            return (minRPM, minRPM, maxRPM)
        }
    }

    // MARK: - SMC Method (Intel)

    private func getAllFansViaSMC() -> [FanInfo] {
        var fans: [FanInfo] = []
        let count = getFanCountSMC()

        for i in 0..<count {
            if let fan = getFanInfoSMC(index: i) {
                fans.append(fan)
            }
        }

        return fans
    }

    private func getFanCountSMC() -> Int {
        if let value = readSMCInt(key: "FNum") {
            return value
        }

        // Fallback: try to read F0Ac
        for i in 0..<4 {
            if readSMCFloat(key: "F\(i)Ac") == nil {
                return i
            }
        }
        return 0
    }

    private func getFanInfoSMC(index: Int) -> FanInfo? {
        let actualKey = "F\(index)Ac"
        let minKey = "F\(index)Mn"
        let maxKey = "F\(index)Mx"
        let targetKey = "F\(index)Tg"

        guard let currentRPM = readSMCFloat(key: actualKey), currentRPM > 0 else {
            return nil
        }

        let minRPM = readSMCFloat(key: minKey) ?? 1000
        let maxRPM = readSMCFloat(key: maxKey) ?? 6000
        let targetRPM = readSMCFloat(key: targetKey) ?? currentRPM

        let name: String
        switch index {
        case 0: name = "Left Side"
        case 1: name = "Right Side"
        default: name = "Fan \(index + 1)"
        }

        return FanInfo(
            id: index,
            name: name,
            currentRPM: Int(currentRPM),
            minRPM: Int(minRPM),
            maxRPM: Int(maxRPM),
            targetRPM: Int(targetRPM)
        )
    }

    // MARK: - ioreg Parsing Method (Fallback)

    private func getAllFansViaIOReg() -> [FanInfo] {
        var fans: [FanInfo] = []

        // Use ioreg to find fan info
        let task = Process()
        let pipe = Pipe()

        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-r", "-c", "AppleSMC", "-d", "1"]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse to find fan info
            fans = parseIORegForFans(output)

        } catch {
            // Silent
        }

        return fans
    }

    private func parseIORegForFans(_ output: String) -> [FanInfo] {
        var fans: [FanInfo] = []

        // Search for patterns like "F0Ac" = 1234 in output
        let pattern = #""F(\d)Ac"\s*=\s*(\d+)"#

        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(output.startIndex..., in: output)
            let matches = regex.matches(in: output, range: range)

            for match in matches {
                if let indexRange = Range(match.range(at: 1), in: output),
                   let rpmRange = Range(match.range(at: 2), in: output),
                   let index = Int(output[indexRange]),
                   let rpm = Int(output[rpmRange]) {

                    let name = index == 0 ? "Left Side" : (index == 1 ? "Right Side" : "Fan \(index + 1)")

                    fans.append(FanInfo(
                        id: index,
                        name: name,
                        currentRPM: rpm,
                        minRPM: 1000,
                        maxRPM: 6000,
                        targetRPM: rpm
                    ))
                }
            }
        } catch {
            // Regex failed
        }

        return fans
    }

    // MARK: - Fan Control

    func setFanMode(_ mode: FanMode) {
        // On Apple Silicon, use helper if available
        if isAppleSilicon {
            setFanModeViaHelper(mode)
            return
        }

        guard isConnected else { return }

        let fanCount = getFanCountSMC()

        switch mode {
        case .system:
            for i in 0..<fanCount {
                setFanAutomatic(index: i)
            }

        case .max:
            for i in 0..<fanCount {
                if let fan = getFanInfoSMC(index: i) {
                    setFanRPM(index: i, rpm: fan.maxRPM)
                }
            }

        case .autoMax:
            for i in 0..<fanCount {
                if let fan = getFanInfoSMC(index: i) {
                    let aggressiveMin = fan.minRPM + (fan.maxRPM - fan.minRPM) / 2
                    setFanMinRPM(index: i, rpm: aggressiveMin)
                }
            }

        case .manual(let rpm):
            for i in 0..<fanCount {
                setFanRPM(index: i, rpm: rpm)
            }
        }
    }

    private func debugLog(_ message: String) {
        SmolLog.fan.debug("\(message)")
    }

    /// Sets fan mode via privileged helper (Apple Silicon)
    private func setFanModeViaHelper(_ mode: FanMode) {
        debugLog("setFanModeViaHelper called with mode: \(mode)")

        guard helperAvailable else {
            debugLog("Helper not available for setting fan mode (helperAvailable=false)")
            return
        }

        guard let connection = xpcConnection else {
            debugLog("XPC connection is nil")
            return
        }

        // Execute on background thread to avoid deadlock
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let helper = connection.synchronousRemoteObjectProxyWithErrorHandler({ error in
                SmolLog.fan.error("XPC error setting mode: \(error.localizedDescription)")
            }) as? FanHelperProtocol else {
                SmolLog.fan.error("Failed to get helper proxy for setting fan mode")
                return
            }

            switch mode {
            case .system:
                // Mode 0 = auto (disables force mode). Before releasing the
                // force, drive the target RPM down to the fan minimum so the
                // SMC auto controller takes over with a low target rather
                // than coasting at whatever max we just commanded. Without
                // this step the fan stays high for tens of seconds after the
                // user switches back to Auto.
                SmolLog.fan.info("Setting fan mode to system (auto)")
                self.setAllFansToRPM(helper: helper, rpmType: .min)

                let semaphore = DispatchSemaphore(value: 0)
                helper.setFanMode(mode: 0) { success in
                    SmolLog.fan.info("setFanMode(0) result: \(success)")
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 2.0)

            case .max:
                // Set all fans to maximum
                SmolLog.fan.info("Setting fan mode to max")
                self.setAllFansToRPM(helper: helper, rpmType: .max)

            case .autoMax:
                // Set aggressive minimum RPM (50% of range)
                SmolLog.fan.info("Setting fan mode to autoMax")
                self.setAllFansToRPM(helper: helper, rpmType: .autoMax)

            case .manual(let rpm):
                SmolLog.fan.info("Setting fan mode to manual RPM: \(rpm)")
                self.setAllFansToRPM(helper: helper, rpmType: .manual(rpm))
            }
        }
    }

    private enum RPMType {
        case min
        case max
        case autoMax
        case manual(Int)
    }

    private func setAllFansToRPM(helper: FanHelperProtocol, rpmType: RPMType) {
        let semaphore = DispatchSemaphore(value: 0)
        var fanInfo: [String: Any] = [:]

        SmolLog.fan.debug("Fetching fan info...")
        helper.getFanInfo { info in
            fanInfo = info
            SmolLog.fan.debug("getFanInfo returned: \(info as NSDictionary)")
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            SmolLog.fan.warning("getFanInfo timed out")
            return
        }

        guard let count = fanInfo["count"] as? Int, count > 0 else {
            SmolLog.fan.warning("No fans found in getFanInfo response")
            return
        }

        for i in 0..<count {
            let minRPM = fanInfo["fan\(i)_min"] as? Int ?? 1350
            let maxRPM = fanInfo["fan\(i)_max"] as? Int ?? 5777

            let targetRPM: Int
            switch rpmType {
            case .min:
                targetRPM = minRPM
            case .max:
                targetRPM = maxRPM
            case .autoMax:
                targetRPM = minRPM + (maxRPM - minRPM) / 2
            case .manual(let rpm):
                targetRPM = rpm
            }

            SmolLog.fan.info("Setting fan \(i) to \(targetRPM) RPM")

            let fanSemaphore = DispatchSemaphore(value: 0)
            helper.setFanRPM(index: i, rpm: targetRPM) { success in
                SmolLog.fan.info("setFanRPM(\(i), \(targetRPM)) result: \(success)")
                fanSemaphore.signal()
            }
            _ = fanSemaphore.wait(timeout: .now() + 2.0)
        }

        SmolLog.fan.info("Finished setting all fans")
    }

    func setFanRPM(index: Int, rpm: Int) {
        // On Apple Silicon, use helper if available
        if isAppleSilicon {
            setFanRPMViaHelper(index: index, rpm: rpm)
            return
        }

        // On Intel, use direct SMC
        guard isConnected else { return }

        let modeKey = "F\(index)Md"
        let targetKey = "F\(index)Tg"

        writeSMCInt(key: modeKey, value: 1)
        writeSMCFloat(key: targetKey, value: Float(rpm))
    }

    /// Sets RPM via privileged helper (Apple Silicon)
    private func setFanRPMViaHelper(index: Int, rpm: Int) {
        guard helperAvailable,
              let helper = xpcConnection?.remoteObjectProxyWithErrorHandler({ error in
                  SmolLog.fan.error("XPC error setting RPM: \(error.localizedDescription)")
              }) as? FanHelperProtocol else {
            SmolLog.fan.warning("Helper not available for setting fan RPM")
            return
        }

        helper.setFanRPM(index: index, rpm: rpm) { success in
            if !success {
                SmolLog.fan.error("Failed to set fan \(index) to \(rpm) RPM")
            }
        }
    }

    func setFanMinRPM(index: Int, rpm: Int) {
        guard !isAppleSilicon, isConnected else { return }
        let minKey = "F\(index)Mn"
        writeSMCFloat(key: minKey, value: Float(rpm))
    }

    func setFanAutomatic(index: Int) {
        guard !isAppleSilicon, isConnected else { return }
        let modeKey = "F\(index)Md"
        writeSMCInt(key: modeKey, value: 0)
    }

    // MARK: - SMC Read/Write

    private func readSMCFloat(key: String) -> Float? {
        guard isConnected else { return nil }

        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.key = stringToKey(key)
        inputStruct.data8 = 5  // Read command

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            connection,
            2,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }

        let bytes = outputStruct.bytes
        let intValue = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
        return Float(intValue) / 4.0
    }

    private func readSMCInt(key: String) -> Int? {
        guard isConnected else { return nil }

        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.key = stringToKey(key)
        inputStruct.data8 = 5

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            connection,
            2,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }

        return Int(outputStruct.bytes.0)
    }

    private func writeSMCFloat(key: String, value: Float) {
        guard isConnected else { return }

        var inputStruct = SMCKeyData()

        inputStruct.key = stringToKey(key)
        inputStruct.data8 = 6

        let intValue = UInt16(value * 4.0)
        inputStruct.bytes.0 = UInt8((intValue >> 8) & 0xFF)
        inputStruct.bytes.1 = UInt8(intValue & 0xFF)

        var outputStruct = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        IOConnectCallStructMethod(
            connection,
            2,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )
    }

    private func writeSMCInt(key: String, value: Int) {
        guard isConnected else { return }

        var inputStruct = SMCKeyData()

        inputStruct.key = stringToKey(key)
        inputStruct.data8 = 6
        inputStruct.bytes.0 = UInt8(value & 0xFF)

        var outputStruct = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        IOConnectCallStructMethod(
            connection,
            2,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )
    }

    private func stringToKey(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for (i, char) in str.utf8.enumerated() where i < 4 {
            result = result << 8 | UInt32(char)
        }
        return result
    }
}

// MARK: - SMC Data Structure

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var padding: UInt16 = 0  // IMPORTANT: padding for struct alignment (must be 80 bytes)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}
