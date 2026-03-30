import Foundation

/// Protocollo XPC condiviso tra app principale e helper privilegiato
/// Questo file deve essere incluso in entrambi i target
@objc public protocol FanHelperProtocol {
    /// Verifica che l'helper sia raggiungibile (ritorna true se connesso)
    func ping(reply: @escaping (Bool) -> Void)

    /// Ottiene il numero di ventole nel sistema
    func getFanCount(reply: @escaping (Int) -> Void)

    /// Ottiene RPM attuale di una ventola specifica
    func getFanRPM(index: Int, reply: @escaping (Int) -> Void)

    /// Ottiene tutte le info ventole in un dizionario
    /// Chiavi: count, fan0_rpm, fan0_min, fan0_max, fan0_target, fan1_rpm, etc.
    func getFanInfo(reply: @escaping ([String: Any]) -> Void)

    /// Imposta RPM target per una ventola (abilita anche force mode)
    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)

    /// Imposta modalità ventole: 0 = auto, 1 = manual/forced
    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void)

    /// Debug: enumera tutte le chiavi SMC disponibili per le ventole
    func debugEnumerateKeys(reply: @escaping (String) -> Void)

    /// Verifica se il controllo ventole è attualmente disponibile
    /// Su Apple Silicon M4, quando le temperature sono basse l'hardware disabilita le ventole
    /// e il controllo manuale non è possibile finché non si riscaldano
    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void)

    /// Esegue test esaustivi delle sequenze FOFC per trovare quella che funziona su M4
    func testFOFCSequences(index: Int, targetRPM: Int, reply: @escaping (Bool, String) -> Void)

    /// Cerca tutte le chiavi FOFC-related disponibili
    func searchFOFCKeys(reply: @escaping (String) -> Void)

    /// Test alternative fan control methods (F0Mn/F0Mx constraints)
    func testAlternativeControl(index: Int, targetRPM: Int, reply: @escaping (String) -> Void)
}

/// Identificatore del servizio Mach per la connessione XPC
public let FanHelperMachServiceName = "com.smol.fanhelper"
