import SwiftUI

// MARK: - Settings Tab

struct SettingsTab: View {
    @StateObject private var localization = LocalizationManager.shared
    @AppStorage("refreshRate") private var refreshRate = 2.0
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("notifyHighCPU") private var notifyHighCPU = true
    @AppStorage("notifyHighMemory") private var notifyHighMemory = true
    @AppStorage("notifyHighTemp") private var notifyHighTemp = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "gear")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    Text("settings.title".localized(localization))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)

                // Language Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("settings.language".localized(localization), systemImage: "globe")
                            .font(.headline)

                        HStack {
                            ForEach(LocalizationManager.Language.allCases) { language in
                                Button {
                                    withAnimation {
                                        localization.currentLanguage = language
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(language.flag)
                                            .font(.title2)
                                        Text(language.displayName)
                                            .fontWeight(localization.currentLanguage == language ? .bold : .regular)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(localization.currentLanguage == language ?
                                                  Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(localization.currentLanguage == language ?
                                                    Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                } label: {
                    Label("settings.general".localized(localization), systemImage: "gearshape")
                }

                // Refresh Rate
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("settings.refresh_rate".localized(localization), systemImage: "clock.arrow.circlepath")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $refreshRate, in: 0.5...10, step: 0.5)
                            Text("\(String(format: "%.1f", refreshRate))s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                } label: {
                    Label("settings.appearance".localized(localization), systemImage: "paintbrush")
                }

                // Notifications
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $enableNotifications) {
                            Label("settings.enable_notifications".localized(localization), systemImage: "bell")
                        }

                        if enableNotifications {
                            Divider()
                            Toggle(isOn: $notifyHighCPU) {
                                Label("settings.notify_high_cpu".localized(localization), systemImage: "cpu")
                            }
                            Toggle(isOn: $notifyHighMemory) {
                                Label("settings.notify_high_memory".localized(localization), systemImage: "memorychip")
                            }
                            Toggle(isOn: $notifyHighTemp) {
                                Label("settings.notify_high_temp".localized(localization), systemImage: "thermometer.high")
                            }
                        }
                    }
                    .padding()
                } label: {
                    Label("settings.notifications".localized(localization), systemImage: "bell.badge")
                }

                // AI Backend
                AIBackendSettingsView()

                // smol Resource Usage
                SmolSelfMonitorView()

                // About
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "leaf.fill")
                                .font(.title)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.green, .mint],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            VStack(alignment: .leading) {
                                Text("smol")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("settings.version".localized(localization) + ": 1.0.0")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Text(localization.currentLanguage == .italian ?
                             "Il monitor di sistema che non diventa il problema." :
                             "The system monitor that doesn't become the problem.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } label: {
                    Label("settings.about".localized(localization), systemImage: "info.circle")
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
    }
}

// MARK: - Smol Self Monitor View

/// Shows smol's own resource consumption in real-time
struct SmolSelfMonitorView: View {
    @State private var cpuUsage: Double = 0
    @State private var memoryUsage: UInt64 = 0
    @State private var threadCount: Int = 0
    @State private var updateTimer: Timer?

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                // Static info
                SystemInfoRow(icon: "app.badge", label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0", color: .indigo)
                Divider().padding(.vertical, 8)
                SystemInfoRow(icon: "doc.text", label: "License", value: "MIT - Open Source", color: .mint)

                Divider().padding(.vertical, 12)

                // Real-time resource monitoring section
                HStack {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundColor(.orange)
                    Text("Real-time resources")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.bottom, 8)

                // CPU Usage
                HStack {
                    Image(systemName: "cpu")
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    Text("CPU")
                        .foregroundColor(.secondary)

                    Spacer()

                    // Mini progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.2))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(cpuColor)
                                .frame(width: geo.size.width * min(cpuUsage / 100, 1))
                        }
                    }
                    .frame(width: 60, height: 8)

                    Text(String(format: "%.1f%%", cpuUsage))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 4)

                // Memory Usage
                HStack {
                    Image(systemName: "memorychip")
                        .foregroundColor(.green)
                        .frame(width: 24)

                    Text("Memory")
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(formatMemory(memoryUsage))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(memoryColor)
                }
                .padding(.vertical, 4)

                // Thread count
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.purple)
                        .frame(width: 24)

                    Text("Thread")
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(threadCount)")
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.vertical, 4)

                // PID
                HStack {
                    Image(systemName: "number")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("PID")
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(Foundation.ProcessInfo.processInfo.processIdentifier)")
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.vertical, 4)
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Label("smol", systemImage: "leaf")
                    .font(.headline)
                Spacer()
                // "Live" indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
            }
        }
        .onAppear {
            updateResourceUsage()
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }

    private var cpuColor: Color {
        if cpuUsage > 50 { return .red }
        if cpuUsage > 20 { return .orange }
        return .blue
    }

    private var memoryColor: Color {
        if memoryUsage > 500_000_000 { return .red }
        if memoryUsage > 200_000_000 { return .orange }
        return .primary
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.1f MB", mb)
    }

    private func startTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateResourceUsage()
        }
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateResourceUsage() {
        // Get CPU usage using task_info
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        if result == KERN_SUCCESS, let threads = threadList {
            var totalCPU: Double = 0

            for i in 0..<Int(threadCount) {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

                let kr = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                        thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }

                if kr == KERN_SUCCESS {
                    if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                        totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100
                    }
                }
            }

            // Deallocate thread list
            let threadListSize = vm_size_t(MemoryLayout<thread_t>.size * Int(threadCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), threadListSize)

            DispatchQueue.main.async {
                self.cpuUsage = totalCPU
                self.threadCount = Int(threadCount)
            }
        }

        // Get memory usage using task_info
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let memResult = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        if memResult == KERN_SUCCESS {
            DispatchQueue.main.async {
                self.memoryUsage = taskInfo.phys_footprint
            }
        }
    }
}

// MARK: - AI Backend Settings

struct AIBackendSettingsView: View {
    @State private var apiKey: String = ""
    @State private var selectedProvider: AIProvider = .openRouter
    @State private var customBaseURL: String = ""
    @State private var modelID: String = ""
    @State private var connectionStatus: String = ""
    @State private var isTesting = false
    @State private var isConnected = false
    @State private var showKey = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Provider selector
                VStack(alignment: .leading, spacing: 8) {
                    Label("Provider", systemImage: "cloud")
                        .font(.headline)

                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Label(provider.rawValue, systemImage: provider.icon)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedProvider) { _, provider in
                        if provider != .custom {
                            customBaseURL = provider.baseURL
                            modelID = provider.defaultModel
                        }
                    }
                }

                Divider()

                // API Key
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        if showKey {
                            TextField("sk-or-v1-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("sk-or-v1-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)

                        Button("Save") {
                            saveConfig()
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.isEmpty)
                    }
                }

                // Model ID
                HStack {
                    Text("Model:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("google/gemini-2.5-flash", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                // Custom URL (only for custom provider)
                if selectedProvider == .custom {
                    HStack {
                        Text("Base URL:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("https://api.example.com/v1", text: $customBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                Divider()

                // Test + Status
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text("Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(apiKey.isEmpty || isTesting)

                    if !connectionStatus.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isConnected ? .green : .red)
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundColor(isConnected ? .green : .red)
                        }
                    }

                    Spacer()

                    if KeychainHelper.hasAPIKey {
                        Button("Clear Key") {
                            KeychainHelper.delete(account: KeychainHelper.apiKeyAccount)
                            apiKey = ""
                            connectionStatus = ""
                            isConnected = false
                        }
                        .foregroundColor(.red)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
        } label: {
            HStack {
                Label("AI Backend", systemImage: "brain")
                    .font(.headline)
                Spacer()
                if KeychainHelper.hasAPIKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Active")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .onAppear {
            loadConfig()
        }
    }

    private func loadConfig() {
        apiKey = KeychainHelper.apiKey ?? ""
        modelID = KeychainHelper.modelID

        let savedURL = KeychainHelper.providerBaseURL
        if let provider = AIProvider.allCases.first(where: { $0.baseURL == savedURL }) {
            selectedProvider = provider
        } else {
            selectedProvider = .custom
            customBaseURL = savedURL
        }
    }

    private func saveConfig() {
        KeychainHelper.save(account: KeychainHelper.apiKeyAccount, value: apiKey)
        KeychainHelper.save(account: KeychainHelper.modelIDAccount, value: modelID)

        let url = selectedProvider == .custom ? customBaseURL : selectedProvider.baseURL
        KeychainHelper.save(account: KeychainHelper.providerURLAccount, value: url)

        // Reload the engine config
        Task {
            try? await LLMInferenceManager.shared.initializeCloudBackend()
        }
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = ""

        let url = selectedProvider == .custom ? customBaseURL : selectedProvider.baseURL

        Task {
            let result = await OpenRouterEngine.validateAPIKey(apiKey, baseURL: url)
            isTesting = false
            isConnected = result.valid
            connectionStatus = result.message
        }
    }
}
