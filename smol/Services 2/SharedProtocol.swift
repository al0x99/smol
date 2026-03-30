import Foundation

/// Protocollo XPC condiviso tra app principale e helper privilegiato
/// Questo file deve essere incluso in entrambi i target
@objc public protocol FanHelperProtocol {
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
}

/// Identificatore del servizio Mach per la connessione XPC
public let FanHelperMachServiceName = "com.smol.fanhelper"
