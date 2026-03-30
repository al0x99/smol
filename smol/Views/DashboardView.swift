import SwiftUI
import Charts
import Combine

/// Dashboard window with full system details
struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared
    @State private var selectedTab = 0
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab Intro/About
            IntroTab(hasSeenIntro: $hasSeenIntro, selectedTab: $selectedTab)
                .tabItem {
                    Label("smol", systemImage: "leaf")
                }
                .tag(0)

            // Tab Overview
            OverviewTab(monitor: monitor)
                .tabItem {
                    Label("tab.dashboard".localized(localization), systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .tag(1)

            // Tab Processes
            ProcessesTab(monitor: monitor)
                .tabItem {
                    Label("tab.processes".localized(localization), systemImage: "list.bullet.rectangle")
                }
                .tag(2)

            // Tab Alerts
            AlertsTab(monitor: monitor)
                .tabItem {
                    Label("Alert", systemImage: "bell.badge")
                }
                .tag(3)

            // Tab Temperature
            TemperatureTab(monitor: monitor)
                .tabItem {
                    Label("tab.temperature".localized(localization), systemImage: "thermometer")
                }
                .tag(4)

            // Tab Fans
            FansTab(monitor: monitor)
                .tabItem {
                    Label(localization.currentLanguage == .italian ? "Ventole" : "Fans", systemImage: "fan")
                }
                .tag(5)

            // Tab AI Assistant
            AIAssistantTab(monitor: monitor)
                .tabItem {
                    Label("tab.ai".localized(localization), systemImage: "brain")
                }
                .tag(6)

            // Tab Settings
            SettingsTab()
                .tabItem {
                    Label("tab.settings".localized(localization), systemImage: "gear")
                }
                .tag(7)

            // Tab System Info
            SystemInfoTab()
                .tabItem {
                    Label(localization.currentLanguage == .italian ? "Sistema" : "System", systemImage: "info.circle")
                }
                .tag(8)
        }
        .frame(minWidth: 650, minHeight: 500)
        .onAppear {
            // On first launch show intro, otherwise go to Overview
            if hasSeenIntro {
                selectedTab = 1
            }
        }
    }
}

// MARK: - Preview

#Preview {
    DashboardView(monitor: SystemMonitor())
}
