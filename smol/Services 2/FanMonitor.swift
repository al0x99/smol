import Foundation
import IOKit

/// Monitora e controlla le ventole via SMC e IOKit
/// Nota: Su Apple Silicon (M1/M2/M3/M4), il controllo diretto delle ventole
/// richiede privilegi speciali. Questa implementazione usa un helper
/// privilegiato (smolFanHelper) quando disponibile, altrimenti
/// fornisce stime basate su thermal state.
class FanMonitor {
    private var connection: io_connect_t = 0
    private var isConnected = false
    private var isAppleSilicon: Bool = false

    // MARK: - XPC Helper Connection

    private var xpcConnection: NSXPCConnection?
    private var helperAvailable = false
    private var helperCheckDone = false

    enum FanMode {
        case system     // Controllo automatico macOS
        case max        // Ventole al massimo
        case autoMax    // Auto ma più aggressivo
        case manual(rpm: Int) // RPM specifico
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
        // Su Apple Silicon, prova a connettersi all'helper
        if isAppleSilicon {
            connectToHelper()
        }
    }

    deinit {
        closeSMCConnection()
        xpcConnection?.invalidate()
    }

    // MARK: - XPC Helper Methods

    /// Tenta connessione all'helper privilegiato
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

    /// Verifica se l'helper è disponibile e funzionante
    private func checkHelperAvailability() {
        guard let helper = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.helperAvailable = false
            self?.helperCheckDone = true
        }) as? FanHelperProtocol else {
            helperAvailable = false
            helperCheckDone = true
            return
        }

        helper.getFanCount { [weak self] count in
            self?.helperAvailable = count > 0
            self?.helperCheckDone = true
            if count > 0 {
                print("smol: Helper connected, found \(count) fan(s)")
            }
        }
    }

    /// Ottiene info ventole via helper XPC
    private func getAppleSiliconFanInfoViaHelper() -> [FanInfo]? {
        guard helperAvailable else { return nil }

        guard let helper = xpcConnection?.synchronousRemoteObjectProxyWithErrorHandler({ error in
            print("smol: XPC Error: \(error)")
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

        // Timeout 1 secondo
        let result = semaphore.wait(timeout: .now() + 1.0)
        if result == .timedOut {
            print("smol: Helper timeout")
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
            // Su Apple Silicon, prova AppleSMCKeysEndpoint
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

    /// Ottiene info su tutte le ventole
    func getAllFans() -> [FanInfo] {
        // Su Apple Silicon, prova prima l'helper privilegiato
        if isAppleSilicon {
            // Prova helper XPC (RPM reali)
            if let helperFans = getAppleSiliconFanInfoViaHelper() {
                return helperFans
            }
            // Fallback: stima da thermal state
            return getAppleSiliconFanInfo()
        }

        // Su Intel, prova SMC tradizionale
        var fans = getAllFansViaSMC()
        if !fans.isEmpty {
            return fans
        }

        // Fallback: ioreg parsing
        fans = getAllFansViaIOReg()
        return fans
    }

    /// Indica se l'helper privilegiato è disponibile
    var isHelperAvailable: Bool {
        return helperAvailable
    }

    // MARK: - Apple Silicon Method

    /// Su Apple Silicon, le ventole sono gestite interamente dal sistema.
    /// Questa funzione fornisce una stima basata sul thermal state.
    private func getAppleSiliconFanInfo() -> [FanInfo] {
        var fans: [FanInfo] = []

        // Ottieni thermal state del sistema
        let thermalState = Foundation.ProcessInfo.processInfo.thermalState

        // MacBook Pro M4 Max ha tipicamente 2 ventole
        // Stima RPM basata su thermal state
        let (rpm, minRPM, maxRPM) = estimateRPMFromThermalState(thermalState)

        // Ventola sinistra
        fans.append(FanInfo(
            id: 0,
            name: "Left Side",
            currentRPM: rpm,
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: rpm
        ))

        // Ventola destra
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
        // M4 Max fan specs (approssimativo)
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

        // Fallback: prova a leggere F0Ac
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

        // Usa ioreg per trovare info sulle ventole
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

            // Parse per trovare info ventole
            fans = parseIORegForFans(output)

        } catch {
            // Silenzioso
        }

        return fans
    }

    private func parseIORegForFans(_ output: String) -> [FanInfo] {
        var fans: [FanInfo] = []

        // Cerca pattern come "F0Ac" = 1234 nel output
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
            // Regex fallito
        }

        return fans
    }

    // MARK: - Fan Control

    func setFanMode(_ mode: FanMode) {
        // Su Apple Silicon, usa helper se disponibile
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

    /// Imposta modalità ventole via helper privilegiato (Apple Silicon)
    private func setFanModeViaHelper(_ mode: FanMode) {
        guard helperAvailable,
              let helper = xpcConnection?.remoteObjectProxyWithErrorHandler({ error in
                  print("smol: XPC Error setting mode: \(error)")
              }) as? FanHelperProtocol else {
            print("smol: Helper not available for setting fan mode")
            return
        }

        switch mode {
        case .system:
            // Mode 0 = auto (disabilita force mode)
            helper.setFanMode(mode: 0) { success in
                if !success {
                    print("smol: Failed to set auto fan mode")
                }
            }

        case .max:
            // Imposta tutte le ventole al massimo
            helper.getFanInfo { [weak self] info in
                guard let count = info["count"] as? Int else { return }
                for i in 0..<count {
                    let maxRPM = info["fan\(i)_max"] as? Int ?? 6000
                    self?.setFanRPMViaHelper(index: i, rpm: maxRPM)
                }
            }

        case .autoMax:
            // Imposta RPM minimo aggressivo
            helper.getFanInfo { [weak self] info in
                guard let count = info["count"] as? Int else { return }
                for i in 0..<count {
                    let minRPM = info["fan\(i)_min"] as? Int ?? 1200
                    let maxRPM = info["fan\(i)_max"] as? Int ?? 6000
                    let aggressiveMin = minRPM + (maxRPM - minRPM) / 2
                    self?.setFanRPMViaHelper(index: i, rpm: aggressiveMin)
                }
            }

        case .manual(let rpm):
            helper.getFanInfo { [weak self] info in
                guard let count = info["count"] as? Int else { return }
                for i in 0..<count {
                    self?.setFanRPMViaHelper(index: i, rpm: rpm)
                }
            }
        }
    }

    func setFanRPM(index: Int, rpm: Int) {
        // Su Apple Silicon, usa helper se disponibile
        if isAppleSilicon {
            setFanRPMViaHelper(index: index, rpm: rpm)
            return
        }

        // Su Intel, usa SMC diretto
        guard isConnected else { return }

        let modeKey = "F\(index)Md"
        let targetKey = "F\(index)Tg"

        writeSMCInt(key: modeKey, value: 1)
        writeSMCFloat(key: targetKey, value: Float(rpm))
    }

    /// Imposta RPM via helper privilegiato (Apple Silicon)
    private func setFanRPMViaHelper(index: Int, rpm: Int) {
        guard helperAvailable,
              let helper = xpcConnection?.remoteObjectProxyWithErrorHandler({ error in
                  print("smol: XPC Error setting RPM: \(error)")
              }) as? FanHelperProtocol else {
            print("smol: Helper not available for setting fan RPM")
            return
        }

        helper.setFanRPM(index: index, rpm: rpm) { success in
            if !success {
                print("smol: Failed to set fan \(index) to \(rpm) RPM")
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
