import Foundation
import IOKit

/// Monitora la temperatura CPU via SMC (System Management Controller)
class TemperatureMonitor {
    private var connection: io_connect_t = 0
    private var isConnected = false

    // Chiavi SMC per temperatura CPU
    // Apple Silicon usa chiavi diverse da Intel
    private let temperatureKeys = [
        "TC0P",  // CPU Proximity (Intel)
        "TC0D",  // CPU Die (Intel)
        "Tp09",  // CPU efficiency core 1 (Apple Silicon)
        "Tp0T",  // CPU performance core 1 (Apple Silicon)
        "Tp01",  // CPU core (Apple Silicon M1)
        "Tp05",  // CPU core (Apple Silicon)
        "Tp0D",  // CPU core (Apple Silicon)
        "Tp0H",  // CPU core (Apple Silicon)
        "Tp0L",  // CPU core (Apple Silicon)
        "Tp0P",  // CPU core (Apple Silicon)
        "Tp0X",  // CPU core (Apple Silicon)
        "Tp0b",  // CPU core (Apple Silicon)
    ]

    init() {
        openSMCConnection()
    }

    deinit {
        closeSMCConnection()
    }

    /// Apre connessione al SMC
    private func openSMCConnection() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )

        guard service != 0 else {
            print("TemperatureMonitor: SMC service not found")
            return
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        if result == kIOReturnSuccess {
            isConnected = true
        } else {
            print("TemperatureMonitor: Failed to open SMC connection")
        }
    }

    /// Chiude connessione SMC
    private func closeSMCConnection() {
        if isConnected {
            IOServiceClose(connection)
            isConnected = false
        }
    }

    /// Ottiene temperatura CPU in gradi Celsius
    func getCPUTemperature() -> Double {
        // Prova prima SMC
        if isConnected {
            for key in temperatureKeys {
                if let temp = readSMCTemperature(key: key), temp > 0 && temp < 150 {
                    return temp
                }
            }
        }

        // Fallback: usa thermal state di sistema
        return getThermalStateFallback()
    }

    /// Legge temperatura da SMC per una specifica chiave
    private func readSMCTemperature(key: String) -> Double? {
        guard isConnected else { return nil }

        // Strutture SMC
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        // Converti chiave a UInt32
        let keyBytes = key.utf8
        var keyInt: UInt32 = 0
        for (i, byte) in keyBytes.enumerated() where i < 4 {
            keyInt = keyInt << 8 | UInt32(byte)
        }

        inputStruct.key = keyInt
        inputStruct.data8 = SMCKeyData.SMCBytes.readCommand

        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCKeyData.SMCBytes.kernelIndexSMC),
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        guard result == kIOReturnSuccess else {
            return nil
        }

        // Converti bytes a temperatura
        // Formato: sp78 (signed fixed point 7.8)
        let bytes = outputStruct.bytes
        if bytes.0 == 0 && bytes.1 == 0 {
            return nil
        }

        // Interpretazione sp78: intero + decimale/256
        let intPart = Double(Int8(bitPattern: bytes.0))
        let decPart = Double(bytes.1) / 256.0

        return intPart + decPart
    }

    /// Fallback usando ProcessInfo thermal state
    private func getThermalStateFallback() -> Double {
        let thermalState = Foundation.ProcessInfo.processInfo.thermalState

        // Stima temperatura basata su thermal state
        switch thermalState {
        case .nominal:
            return 45.0
        case .fair:
            return 65.0
        case .serious:
            return 85.0
        case .critical:
            return 100.0
        @unknown default:
            return 50.0
        }
    }

    /// Restituisce lo stato termico come stringa
    func getThermalStateString() -> String {
        switch Foundation.ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Elevated"
        case .serious: return "High"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - SMC Data Structures

/// Struttura per comunicazione con SMC
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

    struct SMCBytes {
        static let readCommand: UInt8 = 5
        static let kernelIndexSMC: UInt32 = 2
    }
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
