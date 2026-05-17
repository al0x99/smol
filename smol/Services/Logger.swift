import Foundation
import os

/// Centralized logging for smol app
enum SmolLog {
    static let general = Logger(subsystem: "com.whitepaper.smol", category: "general")
    static let fan = Logger(subsystem: "com.whitepaper.smol", category: "fan")
    static let temperature = Logger(subsystem: "com.whitepaper.smol", category: "temperature")
    static let monitor = Logger(subsystem: "com.whitepaper.smol", category: "monitor")
    static let ai = Logger(subsystem: "com.whitepaper.smol", category: "ai")
    static let cleanup = Logger(subsystem: "com.whitepaper.smol", category: "cleanup")

    /// Returns ~/Library/Application Support/smol/Logs/, creating it if needed
    static var logsDirectory: URL {
        let logsDir = URL.applicationSupportDirectory.appending(path: "smol/Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }

    /// Returns full path for a named debug log file
    static func logPath(_ name: String) -> String {
        logsDirectory.appendingPathComponent(name).path
    }
}
