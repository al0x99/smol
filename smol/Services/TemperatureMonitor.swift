import Foundation
import IOKit
import os

/// Temperature sensor with name and value
struct TemperatureSensor: Identifiable {
    let id: String  // SMC key
    let name: String
    let category: SensorCategory
    var temperature: Double

    enum SensorCategory: String, CaseIterable {
        case cpuEfficiency = "CPU Efficiency Cores"
        case cpuPerformance = "CPU Performance Cores"
        case gpu = "GPU"
        case memory = "Memory"
        case battery = "Battery"
        case storage = "Storage"
        case airflow = "Airflow"
        case thunderbolt = "Thunderbolt"
        case other = "Other"

        var icon: String {
            switch self {
            case .cpuEfficiency, .cpuPerformance: return "cpu"
            case .gpu: return "square.3.layers.3d"
            case .memory: return "memorychip"
            case .battery: return "battery.100"
            case .storage: return "internaldrive"
            case .airflow: return "wind"
            case .thunderbolt: return "bolt.horizontal"
            case .other: return "thermometer"
            }
        }
    }
}

/// Monitors all system temperatures via SMC and IOKit
class TemperatureMonitor {
    /// Singleton to avoid multiple SMC connections
    static let shared = TemperatureMonitor()

    private var smcConnection: io_connect_t = 0
    private var isSmcConnected = false
    private var lastValidTemperature: Double = 0
    private var temperatureHistory: [Double] = []

    // Complete SMC key database for Apple Silicon and Intel
    // Based on TG Pro and other monitoring tools
    // M4 Pro uses Tp01-Tp0c for E-cores and Tp0D-Tp0Z for P-cores
    private let sensorDatabase: [(key: String, name: String, category: TemperatureSensor.SensorCategory)] = [
        // CPU Efficiency Cores (Apple Silicon M4)
        ("Tp01", "E-Core 1", .cpuEfficiency),
        ("Tp02", "E-Core 2", .cpuEfficiency),
        ("Tp03", "E-Core 3", .cpuEfficiency),
        ("Tp04", "E-Core 4", .cpuEfficiency),
        ("Tp05", "E-Core 5", .cpuEfficiency),
        ("Tp06", "E-Core 6", .cpuEfficiency),
        ("Tp07", "E-Core 7", .cpuEfficiency),
        ("Tp08", "E-Core 8", .cpuEfficiency),
        ("Tp09", "E-Core 9", .cpuEfficiency),
        ("Tp0a", "E-Core 10", .cpuEfficiency),
        ("Tp0b", "E-Core 11", .cpuEfficiency),
        ("Tp0c", "E-Core 12", .cpuEfficiency),

        // CPU Performance Cores (Apple Silicon M4)
        ("Tp0D", "P-Core 1", .cpuPerformance),
        ("Tp0E", "P-Core 2", .cpuPerformance),
        ("Tp0F", "P-Core 3", .cpuPerformance),
        ("Tp0G", "P-Core 4", .cpuPerformance),
        ("Tp0H", "P-Core 5", .cpuPerformance),
        ("Tp0J", "P-Core 6", .cpuPerformance),
        ("Tp0K", "P-Core 7", .cpuPerformance),
        ("Tp0L", "P-Core 8", .cpuPerformance),
        ("Tp0M", "P-Core 9", .cpuPerformance),
        ("Tp0N", "P-Core 10", .cpuPerformance),
        ("Tp0P", "P-Core 11", .cpuPerformance),
        ("Tp0Q", "P-Core 12", .cpuPerformance),
        ("Tp0R", "P-Core 13", .cpuPerformance),
        ("Tp0S", "P-Core 14", .cpuPerformance),
        ("Tp0T", "P-Core 15", .cpuPerformance),
        ("Tp0U", "P-Core 16", .cpuPerformance),
        ("Tp0V", "P-Core 17", .cpuPerformance),
        ("Tp0W", "P-Core 18", .cpuPerformance),
        ("Tp0X", "P-Core 19", .cpuPerformance),
        ("Tp0Y", "P-Core 20", .cpuPerformance),
        ("Tp0Z", "P-Core 21", .cpuPerformance),

        // Intel CPU
        ("TC0P", "CPU Proximity", .cpuPerformance),
        ("TC0D", "CPU Die", .cpuPerformance),
        ("TC0E", "CPU Die 2", .cpuPerformance),
        ("TC0F", "CPU Die 3", .cpuPerformance),
        ("TC1C", "CPU Core 1", .cpuPerformance),
        ("TC2C", "CPU Core 2", .cpuPerformance),
        ("TC3C", "CPU Core 3", .cpuPerformance),
        ("TC4C", "CPU Core 4", .cpuPerformance),
        ("TC5C", "CPU Core 5", .cpuPerformance),
        ("TC6C", "CPU Core 6", .cpuPerformance),
        ("TC7C", "CPU Core 7", .cpuPerformance),
        ("TC8C", "CPU Core 8", .cpuPerformance),
        ("TCXC", "PECI CPU", .cpuPerformance),

        // GPU
        ("Tg0P", "GPU Cluster 1", .gpu),
        ("Tg0D", "GPU Cluster 2", .gpu),
        ("Tg0f", "GPU Cluster 3", .gpu),
        ("Tg0j", "GPU Cluster 4", .gpu),
        ("Tg1P", "GPU Cluster 5", .gpu),
        ("Tg1D", "GPU Cluster 6", .gpu),
        ("TG0P", "GPU Proximity", .gpu),
        ("TG0D", "GPU Die", .gpu),
        ("TG0T", "GPU Transistor", .gpu),
        ("TG1D", "GPU Die 2", .gpu),
        ("TGDD", "GPU Discrete Die", .gpu),

        // Memory
        ("Tm0P", "Memory Proximity", .memory),
        ("Tm1P", "Memory Proximity 2", .memory),
        ("Tm0p", "Memory Module 1", .memory),
        ("Tm1p", "Memory Module 2", .memory),
        ("TM0P", "Memory Controller", .memory),
        ("TM0S", "Memory Slot", .memory),

        // Battery
        ("TB0T", "Battery", .battery),
        ("TB1T", "Battery 2", .battery),
        ("TB2T", "Battery 3", .battery),
        ("TBXT", "Battery Max", .battery),
        ("Tb0P", "Battery Proximity", .battery),
        ("Tb1P", "Battery Proximity 2", .battery),
        ("Tb2P", "Battery Proximity 3", .battery),
        ("TBat", "Battery", .battery),
        ("TbGG", "Battery Gas Gauge", .battery),
        ("Ts1P", "Battery Management Unit", .battery),

        // Storage / SSD
        ("TH0P", "SSD Proximity", .storage),
        ("TH0a", "SSD", .storage),
        ("TH0b", "SSD 2", .storage),
        ("TH0c", "SSD 3", .storage),
        ("TH0x", "SSD NAND", .storage),
        ("TH1P", "SSD Proximity 2", .storage),
        ("Th0H", "HDD Proximity", .storage),
        ("Ts0P", "SSD", .storage),
        ("Ts0S", "SSD SMART", .storage),
        ("TN0P", "SSD (NAND I/O)", .storage),
        ("TN1P", "SSD (NAND I/O) 2", .storage),

        // Airflow
        ("TA0P", "Airflow Left", .airflow),
        ("TA1P", "Airflow Right", .airflow),
        ("TA0p", "Airflow 1", .airflow),
        ("TA1p", "Airflow 2", .airflow),
        ("Th0H", "Heatsink", .airflow),
        ("Th1H", "Heatsink 2", .airflow),
        ("TaLP", "Airflow Left Proximity", .airflow),
        ("TaRP", "Airflow Right Proximity", .airflow),

        // Thunderbolt / Ports
        ("TTLD", "Thunderbolt Left", .thunderbolt),
        ("TTRD", "Thunderbolt Right", .thunderbolt),
        ("TI0P", "Thunderbolt 1", .thunderbolt),
        ("TI1P", "Thunderbolt 2", .thunderbolt),
        ("Ts0P", "Left Thunderbolt Ports Proximity", .thunderbolt),
        ("Ts1P", "Right Thunderbolt Ports Proximity", .thunderbolt),

        // Other
        ("TC0H", "CPU Heatsink", .other),
        ("TCGC", "PECI GPU", .other),
        ("Tp0C", "Power Supply", .other),
        ("TPCD", "Platform Controller Hub Die", .other),
        ("TW0P", "Wireless Proximity", .other),
        ("Tw0P", "WiFi Module", .other),
        ("Te0P", "Trackpad", .other),
        ("Te0p", "Trackpad Proximity", .other),
        ("Te0T", "Trackpad Actuator", .other),
        ("Ts2P", "Palm Rest Left", .other),
        ("Ts3P", "Palm Rest Right", .other),
        ("TL0P", "LCD Proximity", .other),
        ("TL1P", "LCD Proximity 2", .other),
        ("Ts0S", "Charger Proximity", .other),
        ("TZ0P", "Thermal Zone 1", .other),
        ("TZ1P", "Thermal Zone 2", .other),
    ]

    // SMC services
    private let smcServices = [
        "AppleSMC",
        "AppleSMCKeysEndpoint",
    ]

    /// Private init for singleton
    private init() {
        openSMCConnection()
    }

    /// Writes debug log to file
    private func writeDebugToFile() {
        var log = "=== SMC Debug Log ===\n"
        log += "Timestamp: \(Date())\n"
        log += "SMC connesso: \(isSmcConnected)\n\n"

        // Test common keys with debug bytes
        let testKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "TB0T"]
        log += "--- Test chiavi con debug byte ---\n"
        for key in testKeys {
            if let result = debugReadSMCKeyWithBytes(key) {
                log += "[\(key)] tipo=\(result.typeStr) size=\(result.dataSize)\n"
                log += "  bytes: \(result.bytesHex)\n"
                log += "  valore: \(String(format: "%.1f", result.value))°C\n"
            } else {
                log += "[\(key)] non trovata\n"
            }
        }

        // Show all sensors found by getAllSensors()
        log += "\n--- Sensori trovati da getAllSensors() ---\n"
        let allSensors = getAllSensors()
        log += "Totale sensori: \(allSensors.count)\n\n"

        let grouped = getSensorsByCategory()
        for category in TemperatureSensor.SensorCategory.allCases {
            if let sensors = grouped[category], !sensors.isEmpty {
                log += "[\(category.rawValue)]\n"
                for sensor in sensors {
                    log += "  \(sensor.name): \(String(format: "%.1f", sensor.temperature))°C (\(sensor.id))\n"
                }
                log += "\n"
            }
        }

        // Write to file
        let path = SmolLog.logPath("smol_smc_debug.txt")
        try? log.write(toFile: path, atomically: true, encoding: .utf8)
        SmolLog.temperature.debug("SMC debug log written to: \(path, privacy: .public)")
    }

    deinit {
        closeSMCConnection()
    }

    /// Opens connection to SMC
    private func openSMCConnection() {
        for serviceName in smcServices {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(serviceName)
            )

            if service != 0 {
                let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)
                IOObjectRelease(service)

                if result == kIOReturnSuccess {
                    isSmcConnected = true
                    SmolLog.temperature.info("SMC connected via \(serviceName, privacy: .public)")
                    return
                }
            }
        }
        SmolLog.temperature.warning("SMC not available")
    }

    private func closeSMCConnection() {
        if isSmcConnected {
            IOServiceClose(smcConnection)
            isSmcConnected = false
        }
    }

    // MARK: - Public API

    /// Gets main CPU temperature in degrees Celsius
    func getCPUTemperature() -> Double {
        // Try to read CPU sensors
        let cpuSensors = getAllSensors().filter {
            $0.category == .cpuPerformance || $0.category == .cpuEfficiency
        }

        if !cpuSensors.isEmpty {
            // Return the average of CPU sensors
            let avgTemp = cpuSensors.map { $0.temperature }.reduce(0, +) / Double(cpuSensors.count)
            updateHistory(avgTemp)
            return avgTemp
        }

        // Fallback
        let fallbackTemp = getSmartFallback()
        updateHistory(fallbackTemp)
        return fallbackTemp
    }

    /// Gets all available temperature sensors
    /// Returns empty array if SMC is not available (no simulated data)
    func getAllSensors() -> [TemperatureSensor] {
        var sensors: [TemperatureSensor] = []
        var seenNames: [String: Int] = [:]  // To number sensors with the same name

        // If SMC is not connected, return empty array (no simulation)
        guard isSmcConnected else {
            return []
        }

        for sensorInfo in sensorDatabase {
            if let temp = readSMCKey(sensorInfo.key), temp > 0 && temp < 150 {
                // Handle duplicate names
                var finalName = sensorInfo.name
                if let count = seenNames[sensorInfo.name] {
                    seenNames[sensorInfo.name] = count + 1
                    // Do not modify the name if it already has a number
                    if !sensorInfo.name.contains(where: { $0.isNumber }) {
                        finalName = "\(sensorInfo.name) \(count + 1)"
                    }
                } else {
                    seenNames[sensorInfo.name] = 1
                }

                let sensor = TemperatureSensor(
                    id: sensorInfo.key,
                    name: finalName,
                    category: sensorInfo.category,
                    temperature: temp
                )
                sensors.append(sensor)
            }
        }

        // Sort by category and name
        return sensors.sorted { sensor1, sensor2 in
            if sensor1.category.rawValue == sensor2.category.rawValue {
                return sensor1.name < sensor2.name
            }
            return sensor1.category.rawValue < sensor2.category.rawValue
        }
    }

    /// Gets sensors grouped by category
    func getSensorsByCategory() -> [TemperatureSensor.SensorCategory: [TemperatureSensor]] {
        let allSensors = getAllSensors()
        var grouped: [TemperatureSensor.SensorCategory: [TemperatureSensor]] = [:]

        for sensor in allSensors {
            if grouped[sensor.category] == nil {
                grouped[sensor.category] = []
            }
            grouped[sensor.category]?.append(sensor)
        }

        return grouped
    }

    // MARK: - SMC Reading

    /// Converts key string to UInt32
    private func stringToFourCharCode(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for (i, char) in key.utf8.enumerated() where i < 4 {
            result = result << 8 | UInt32(char)
        }
        // Pad with spaces if less than 4 characters
        let padding = 4 - min(key.utf8.count, 4)
        for _ in 0..<padding {
            result = result << 8 | UInt32(0x20) // spazio
        }
        return result
    }

    /// Step 1: Gets key info (dataType, dataSize)
    private func getKeyInfo(_ key: String) -> (dataType: UInt32, dataSize: UInt32)? {
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.key = stringToFourCharCode(key)
        inputStruct.data8 = SMCCommand.getKeyInfo

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            SMCSelector.kernelIndex,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }
        guard outputStruct.keyInfo.dataSize > 0 else { return nil }

        return (outputStruct.keyInfo.dataType, outputStruct.keyInfo.dataSize)
    }

    /// Step 2: Reads the key value
    private func readSMCKey(_ key: String) -> Double? {
        guard isSmcConnected else { return nil }

        // Step 1: Get key info
        guard let keyInfo = getKeyInfo(key) else { return nil }

        // Step 2: Read the value
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.key = stringToFourCharCode(key)
        inputStruct.data8 = SMCCommand.readKey
        inputStruct.keyInfo.dataSize = keyInfo.dataSize

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            SMCSelector.kernelIndex,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }

        // Decode based on data type
        let dataType = keyInfo.dataType
        let bytes = outputStruct.bytes

        // Verify there is valid data
        if keyInfo.dataSize == 0 { return nil }

        // sp78: signed fixed point 7.8 (most common for temperatures)
        // flt: float 32-bit
        // ui8: unsigned int 8
        // ui16: unsigned int 16
        // ui32: unsigned int 32

        let sp78Type = stringToFourCharCode("sp78")
        let fltType = stringToFourCharCode("flt ")
        let fpeType = stringToFourCharCode("fpe2")
        let sp5aType = stringToFourCharCode("sp5a")
        let sp69Type = stringToFourCharCode("sp69")
        let sp87Type = stringToFourCharCode("sp87")

        if dataType == sp78Type || dataType == sp87Type {
            // sp78: signed 7.8 fixed point
            // sp87: signed 8.7 fixed point
            let intPart = Double(Int8(bitPattern: bytes.0))
            let decPart = Double(bytes.1) / 256.0
            return intPart + decPart
        } else if dataType == sp5aType {
            // sp5a: signed 5.10 fixed point
            let raw = Int16(bytes.0) << 8 | Int16(bytes.1)
            return Double(raw) / 1024.0
        } else if dataType == sp69Type {
            // sp69: signed 6.9 fixed point
            let raw = Int16(bytes.0) << 8 | Int16(bytes.1)
            return Double(raw) / 512.0
        } else if dataType == fltType {
            // float 32-bit - SMC uses big-endian on Apple Silicon
            // Try big-endian first (SMC convention), then little-endian as fallback

            // Big-endian (SMC convention for M4)
            let bigEndianBits = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
            let bigEndianFloat = Float(bitPattern: bigEndianBits)

            // Validate reasonable temperature range (>10°C to exclude erroneous values like 2°C)
            if bigEndianFloat > 10 && bigEndianFloat < 150 {
                return Double(bigEndianFloat)
            }

            // Fallback: little-endian
            let littleEndianBits = UInt32(bytes.3) << 24 | UInt32(bytes.2) << 16 | UInt32(bytes.1) << 8 | UInt32(bytes.0)
            let littleEndianFloat = Float(bitPattern: littleEndianBits)

            if littleEndianFloat > 10 && littleEndianFloat < 150 {
                return Double(littleEndianFloat)
            }

            // No valid value
            return nil
        } else if dataType == fpeType {
            // fpe2: unsigned 14.2 fixed point
            let raw = UInt16(bytes.0) << 8 | UInt16(bytes.1)
            return Double(raw) / 4.0
        } else {
            // Fallback: try sp78 format
            if bytes.0 == 0 && bytes.1 == 0 { return nil }
            let intPart = Double(Int8(bitPattern: bytes.0))
            let decPart = Double(bytes.1) / 256.0
            let temp = intPart + decPart
            // Validate reasonable temperature range
            if temp > 0 && temp < 150 {
                return temp
            }
            return nil
        }
    }

    // MARK: - Fallback

    /// Smart fallback based on thermal state
    private func getSmartFallback() -> Double {
        let thermalState = Foundation.ProcessInfo.processInfo.thermalState

        let baseTemp: Double
        switch thermalState {
        case .nominal: baseTemp = 42.0
        case .fair: baseTemp = 62.0
        case .serious: baseTemp = 82.0
        case .critical: baseTemp = 98.0
        @unknown default: baseTemp = 50.0
        }

        if !temperatureHistory.isEmpty {
            let avgHistory = temperatureHistory.reduce(0, +) / Double(temperatureHistory.count)
            return baseTemp * 0.7 + avgHistory * 0.3
        }

        return baseTemp + Double.random(in: -3...3)
    }

    private func updateHistory(_ temp: Double) {
        temperatureHistory.append(temp)
        if temperatureHistory.count > 10 {
            temperatureHistory.removeFirst()
        }
        lastValidTemperature = temp
    }

    /// Returns the thermal state as a string
    func getThermalStateString() -> String {
        switch Foundation.ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Elevated"
        case .serious: return "High"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// True if SMC is connected (real sensors available)
    var hasSMCAccess: Bool {
        isSmcConnected
    }

    // MARK: - Debug

    /// Enumerates all available SMC keys (for debug)
    func debugEnumerateKeys() {
        guard isSmcConnected else {
            SmolLog.temperature.debug("DEBUG: SMC not connected")
            return
        }

        // Get total number of keys
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.data8 = SMCCommand.getKeyCount

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            SMCSelector.kernelIndex,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        if result == kIOReturnSuccess {
            let keyCount = outputStruct.data32
            SmolLog.temperature.debug("DEBUG: Found \(keyCount) chiavi SMC")

            // Try to read the first 20 temperature keys
            var tempKeysFound = 0
            for i in 0..<min(keyCount, 500) {
                if let keyName = getKeyAtIndex(UInt32(i)) {
                    // Look for temperature keys (start with T)
                    if keyName.hasPrefix("T") {
                        if let temp = readSMCKey(keyName) {
                            SmolLog.temperature.debug("  [\(keyName, privacy: .public)] = \(String(format: "%.1f", temp))°C")
                            tempKeysFound += 1
                        }
                    }
                }
                if tempKeysFound >= 30 { break }
            }
            SmolLog.temperature.debug("DEBUG: Found \(tempKeysFound) temperature sensors")
        } else {
            SmolLog.temperature.error("DEBUG: Unable to get key count (error \(result))")
        }
    }

    /// Gets key name from index
    private func getKeyAtIndex(_ index: UInt32) -> String? {
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.data8 = SMCCommand.getKeyFromIndex
        inputStruct.data32 = index

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            SMCSelector.kernelIndex,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }

        // Convert UInt32 to 4-character string
        let key = outputStruct.key
        let chars: [UInt8] = [
            UInt8((key >> 24) & 0xFF),
            UInt8((key >> 16) & 0xFF),
            UInt8((key >> 8) & 0xFF),
            UInt8(key & 0xFF)
        ]
        return String(bytes: chars, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    /// Quick SMC read test for debug
    func debugTestRead() {
        SmolLog.temperature.debug("DEBUG: Test lettura SMC")
        SmolLog.temperature.debug("  SMC connesso: \(self.isSmcConnected)")

        // Try some common keys
        let testKeys = ["TC0P", "TC0D", "Tp01", "Tp0D", "TG0P", "TB0T"]
        for key in testKeys {
            if let info = getKeyInfo(key) {
                let typeChars = [
                    UInt8((info.dataType >> 24) & 0xFF),
                    UInt8((info.dataType >> 16) & 0xFF),
                    UInt8((info.dataType >> 8) & 0xFF),
                    UInt8(info.dataType & 0xFF)
                ]
                let typeStr = String(bytes: typeChars, encoding: .ascii) ?? "????"
                SmolLog.temperature.debug("  [\(key, privacy: .public)] tipo=\(typeStr, privacy: .public) size=\(info.dataSize)")

                if let temp = readSMCKey(key) {
                    SmolLog.temperature.debug("       valore=\(String(format: "%.1f", temp))°C")
                }
            } else {
                SmolLog.temperature.debug("  [\(key, privacy: .public)] non trovata")
            }
        }
    }

    /// SMC read with byte-level debug
    struct SMCDebugResult {
        let typeStr: String
        let dataSize: UInt32
        let bytesHex: String
        let value: Double
    }

    private func debugReadSMCKeyWithBytes(_ key: String) -> SMCDebugResult? {
        guard isSmcConnected else { return nil }

        // Step 1: Get key info
        guard let keyInfo = getKeyInfo(key) else { return nil }

        // Step 2: Read the value
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        inputStruct.key = stringToFourCharCode(key)
        inputStruct.data8 = SMCCommand.readKey
        inputStruct.keyInfo.dataSize = keyInfo.dataSize

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            smcConnection,
            SMCSelector.kernelIndex,
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else { return nil }

        // Type string
        let typeChars = [
            UInt8((keyInfo.dataType >> 24) & 0xFF),
            UInt8((keyInfo.dataType >> 16) & 0xFF),
            UInt8((keyInfo.dataType >> 8) & 0xFF),
            UInt8(keyInfo.dataType & 0xFF)
        ]
        let typeStr = String(bytes: typeChars, encoding: .ascii) ?? "????"

        // Extract all bytes from tuple
        let bytes = outputStruct.bytes
        let allBytes: [UInt8] = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
        let bytesHex = allBytes.prefix(Int(keyInfo.dataSize)).map { String(format: "%02X", $0) }.joined(separator: " ")

        // Decode value based on type
        let fltType = stringToFourCharCode("flt ")
        var value: Double = 0

        if keyInfo.dataType == fltType {
            // Big-endian (SMC convention for Apple Silicon)
            let bigEndianBits = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
            let bigEndianFloat = Float(bitPattern: bigEndianBits)

            if bigEndianFloat > 10 && bigEndianFloat < 150 {
                value = Double(bigEndianFloat)
            } else {
                // Fallback little-endian
                let littleEndianBits = UInt32(bytes.3) << 24 | UInt32(bytes.2) << 16 | UInt32(bytes.1) << 8 | UInt32(bytes.0)
                value = Double(Float(bitPattern: littleEndianBits))
            }
        }

        return SMCDebugResult(typeStr: typeStr, dataSize: keyInfo.dataSize, bytesHex: bytesHex, value: value)
    }
}

// MARK: - SMC Data Structures

// SMC Commands - used for data8 field
private enum SMCCommand {
    static let readKey: UInt8 = 5      // Read key value
    static let writeKey: UInt8 = 6     // Write key value
    static let getKeyCount: UInt8 = 1  // Get total key count
    static let getKeyFromIndex: UInt8 = 8  // Get key from index
    static let getKeyInfo: UInt8 = 9   // Get key info (type, size)
}

// SMC Selectors - used for IOConnectCallStructMethod
private enum SMCSelector {
    static let kernelIndex: UInt32 = 2  // Kernel index for struct method
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var padding: UInt16 = 0
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
