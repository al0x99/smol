import SwiftUI
import Charts
import Combine

/// Dashboard window with sidebar navigation
struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var localization = LocalizationManager.shared
    @State private var selectedSection: DashboardSection = .overview
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                // Monitoring
                Section("Monitoring") {
                    sidebarItem(.overview)
                    sidebarItem(.processes)
                    sidebarItem(.alerts)
                }

                // Hardware
                Section("Hardware") {
                    sidebarItem(.temperature)
                    sidebarItem(.fans)
                    sidebarItem(.system)
                }

                // AI
                Section("AI") {
                    sidebarItem(.ai)
                }

                // App
                Section {
                    sidebarItem(.settings)
                    sidebarItem(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 750, minHeight: 500)
        .sheet(isPresented: .init(
            get: { !hasSeenIntro },
            set: { if !$0 { hasSeenIntro = true } }
        )) {
            IntroTab(hasSeenIntro: $hasSeenIntro, selectedTab: .constant(0))
                .frame(width: 550, height: 650)
        }
    }

    // MARK: - Sidebar Item

    private func sidebarItem(_ section: DashboardSection) -> some View {
        Label(section.title(localization), systemImage: section.icon)
            .tag(section)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .overview:
            OverviewTab(monitor: monitor)
        case .processes:
            ProcessesTab(monitor: monitor)
        case .alerts:
            AlertsTab(monitor: monitor)
        case .temperature:
            TemperatureTab(monitor: monitor)
        case .fans:
            FansTab(monitor: monitor)
        case .ai:
            AIAssistantTab(monitor: monitor)
        case .settings:
            SettingsTab()
        case .system:
            SystemInfoTab()
        case .about:
            IntroTab(hasSeenIntro: $hasSeenIntro, selectedTab: .constant(0))
        }
    }
}

// MARK: - Dashboard Sections

enum DashboardSection: String, CaseIterable, Hashable, Identifiable {
    case overview
    case processes
    case alerts
    case temperature
    case fans
    case system
    case ai
    case settings
    case about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .processes: return "list.bullet.rectangle"
        case .alerts: return "bell.badge"
        case .temperature: return "thermometer"
        case .fans: return "fan"
        case .system: return "info.circle"
        case .ai: return "brain"
        case .settings: return "gear"
        case .about: return "leaf"
        }
    }

    func title(_ localization: LocalizationManager) -> String {
        switch self {
        case .overview: return "tab.dashboard".localized(localization)
        case .processes: return "tab.processes".localized(localization)
        case .alerts: return "tab.alerts".localized(localization)
        case .temperature: return "tab.temperature".localized(localization)
        case .fans: return "tab.fans".localized(localization)
        case .system: return "tab.system".localized(localization)
        case .ai: return "tab.ai".localized(localization)
        case .settings: return "tab.settings".localized(localization)
        case .about: return "smol"
        }
    }
}

// MARK: - Preview

#Preview {
    DashboardView(monitor: SystemMonitor())
}
