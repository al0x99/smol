import SwiftUI
import AppKit
import os

@main
struct smolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var systemMonitor = SystemMonitor()

    var body: some Scene {
        // Menu Bar
        MenuBarExtra {
            MenuBarView(monitor: systemMonitor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemMonitor.health.iconName)
                    .foregroundColor(systemMonitor.health.color)
                Text(systemMonitor.menuBarText)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)

        // Dashboard Window
        Window("smol", id: "dashboard") {
            DashboardView(monitor: systemMonitor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 700, height: 500)

        // Cleanup Window
        Window("smol cleanup", id: "cleanup") {
            CleanupView(monitor: systemMonitor)
        }
        .defaultSize(width: 500, height: 400)
    }
}

// MARK: - App Delegate for single instance

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Close other instances of smol
        killOtherInstances()
    }

    private func killOtherInstances() {
        let currentPID = Foundation.ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            // Look for other instances of smol
            if app.bundleIdentifier == Bundle.main.bundleIdentifier,
               app.processIdentifier != currentPID {
                SmolLog.general.info("Terminating other instance (PID \(app.processIdentifier))")
                app.terminate()
            }
        }
    }
}
