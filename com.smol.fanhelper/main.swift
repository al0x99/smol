import Foundation
import Security

// MARK: - Fan Helper Service

/// Implementazione del servizio XPC per controllo ventole
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
        // Log to file directly
        logToFile("setFanRPM called: index=\(index), rpm=\(rpm)")
        NSLog("smolFanHelper: setFanRPM(%d, %d)", index, rpm)

        // Prova ad abilitare force mode (potrebbe fallire su Apple Silicon)
        logToFile("Calling setFanForceMode...")
        let forceOK = smc.setFanForceMode(index: index, forced: true)
        logToFile("setFanForceMode result: \(forceOK)")
        if !forceOK {
            NSLog("smolFanHelper: Force mode failed for fan %d, trying direct target write anyway", index)
        }

        // Prova comunque a impostare RPM target
        // Su Apple Silicon potrebbe funzionare anche senza force mode
        logToFile("Calling setFanTargetRPM...")
        let setOK = smc.setFanTargetRPM(index: index, rpm: rpm)
        logToFile("setFanTargetRPM result: \(setOK)")

        if setOK {
            NSLog("smolFanHelper: Successfully set fan %d to %d RPM", index, rpm)
        } else {
            NSLog("smolFanHelper: Failed to set fan %d target RPM (SMC write blocked on Apple Silicon?)", index)
        }

        logToFile("Replying with: \(setOK)")
        reply(setOK)
    }

    private func logToFile(_ message: String) {
        let logPath = "/tmp/smol_helper_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "\(timestamp): smolFanHelper: \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void) {
        NSLog("smolFanHelper: setFanMode(%d)", mode)

        // mode 0 = auto (disabilita force), mode 1+ = manual
        let count = smc.getFanCount()
        var allOK = true

        for i in 0..<count {
            if !smc.setFanForceMode(index: i, forced: mode != 0) {
                allOK = false
            }
        }

        reply(allOK)
    }

    func debugEnumerateKeys(reply: @escaping (String) -> Void) {
        NSLog("smolFanHelper: debugEnumerateKeys() - starting enumeration")

        // Enumera chiavi per ogni ventola
        let count = smc.getFanCount()
        for i in 0..<count {
            smc.debugEnumerateFanKeys(index: i)
        }

        // Cerca tutte le chiavi F*
        smc.debugSearchFanKeys()

        reply("Check /tmp/smol_helper_debug.log for results")
    }

    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void) {
        NSLog("smolFanHelper: isFanControlAvailable() - checking hardware status")

        let count = smc.getFanCount()
        guard count > 0 else {
            reply(false, "No fans detected")
            return
        }

        // Su Apple Silicon M4, quando le ventole sono a 0 RPM,
        // l'hardware le ha disabilitate e non è possibile controllarle
        var anyFanRunning = false
        for i in 0..<count {
            let rpm = smc.getFanRPM(index: i)
            if rpm > 0 {
                anyFanRunning = true
                break
            }
        }

        if !anyFanRunning {
            NSLog("smolFanHelper: All fans at 0 RPM - hardware has disabled fan control")
            reply(false, "Le ventole sono state spente dall'hardware (temperatura bassa). Il controllo manuale sarà disponibile quando la temperatura aumenterà e le ventole si riattiveranno.")
            return
        }

        // Prova a scrivere un valore per vedere se il controllo è accettato
        let testResult = smc.setFanForceMode(index: 0, forced: true)
        // Ripristina subito
        _ = smc.setFanForceMode(index: 0, forced: false)

        if testResult {
            reply(true, "Fan control disponibile")
        } else {
            // SMC ha rifiutato la scrittura - controllo non disponibile
            reply(false, "Il controllo delle ventole non è disponibile su questo Mac. L'hardware Apple Silicon protegge l'accesso SMC in scrittura.")
        }
    }

    func testFOFCSequences(index: Int, targetRPM: Int, reply: @escaping (Bool, String) -> Void) {
        NSLog("smolFanHelper: testFOFCSequences(index=%d, targetRPM=%d)", index, targetRPM)
        logToFile("testFOFCSequences called: index=\(index), targetRPM=\(targetRPM)")

        let success = smc.testFOFCSequences(index: index, targetRPM: targetRPM)

        let logPath = "/tmp/smol_helper_debug.log"

        if success {
            reply(true, "SUCCESS! Check \(logPath) for the working sequence.")
        } else {
            reply(false, "All sequences failed. Check \(logPath) for details.")
        }
    }

    func searchFOFCKeys(reply: @escaping (String) -> Void) {
        NSLog("smolFanHelper: searchFOFCKeys()")
        logToFile("searchFOFCKeys called")

        smc.debugSearchFOFCKeys()

        reply("Check /tmp/smol_helper_debug.log for results")
    }

    func testAlternativeControl(index: Int, targetRPM: Int, reply: @escaping (String) -> Void) {
        NSLog("smolFanHelper: testAlternativeControl(index=%d, targetRPM=%d)", index, targetRPM)
        logToFile("testAlternativeControl called: index=\(index), targetRPM=\(targetRPM)")

        let result = smc.testAlternativeFanControl(index: index, targetRPM: targetRPM)

        reply(result)
    }
}

// MARK: - XPC Listener Delegate

/// Delegato per gestire connessioni XPC in arrivo
class FanHelperDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        NSLog("smolFanHelper: New connection request from PID %d", newConnection.processIdentifier)

        // Verifica firma del client (IMPORTANTE per sicurezza!)
        guard verifyClientSignature(connection: newConnection) else {
            NSLog("smolFanHelper: Client verification FAILED for PID %d", newConnection.processIdentifier)
            return false
        }

        NSLog("smolFanHelper: Client verified, accepting connection")

        // Configura interfaccia XPC
        newConnection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        newConnection.exportedObject = FanHelperService()

        // Handler per interruzione connessione
        newConnection.interruptionHandler = {
            NSLog("smolFanHelper: Connection interrupted")
        }

        // Handler per invalidazione connessione
        newConnection.invalidationHandler = {
            NSLog("smolFanHelper: Connection invalidated")
        }

        newConnection.resume()
        return true
    }

    /// Verifica che il client sia firmato con lo stesso Team ID
    private func verifyClientSignature(connection: NSXPCConnection) -> Bool {
        #if DEBUG
        // In debug, accetta tutte le connessioni per facilitare sviluppo
        NSLog("smolFanHelper: DEBUG mode - accepting all connections")
        return true
        #else
        let pid = connection.processIdentifier

        var code: SecCode?
        let attributes: [String: Any] = [kSecGuestAttributePid as String: pid]
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)

        guard status == errSecSuccess, let code = code else {
            NSLog("smolFanHelper: Failed to get SecCode for PID %d: %d", pid, status)
            return false
        }

        // Verifica che sia firmato con lo stesso Team ID dell'helper
        // Sostituire JLTQ5V2UX8 con il vero Team ID
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

        let validationResult = SecCodeCheckValidity(code, [], req)
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

NSLog("smolFanHelper: Starting version 1.1 with FOFC testing...")
NSLog("smolFanHelper: Running as UID %d", getuid())

// Run FOFC tests at startup
do {
    let smc = SMCAccess()

    // First, search for all FOFC-related keys
    NSLog("smolFanHelper: === STARTUP: Searching for FOFC keys ===")
    smc.debugSearchFOFCKeys()

    // Then run the exhaustive sequence tests
    NSLog("smolFanHelper: === STARTUP: Running FOFC sequence tests ===")
    let success = smc.testFOFCSequences(index: 0, targetRPM: 3000)
    NSLog("smolFanHelper: FOFC test result: %@", success ? "SUCCESS" : "FAILED")

    // Run alternative control tests (F0Mn/F0Mx constraints)
    NSLog("smolFanHelper: === STARTUP: Running alternative control tests ===")
    let altResult = smc.testAlternativeFanControl(index: 0, targetRPM: 3000)
    NSLog("smolFanHelper: Alternative control result: %@", altResult)
}

// Crea delegato e listener
let delegate = FanHelperDelegate()
let listener = NSXPCListener(machServiceName: FanHelperMachServiceName)
listener.delegate = delegate

// Avvia listener
listener.resume()
NSLog("smolFanHelper: Listening on %@", FanHelperMachServiceName)

// Mantieni processo attivo
RunLoop.current.run()
