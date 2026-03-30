import SwiftUI
import Charts
import Combine
import UniformTypeIdentifiers
import os

/// AI Assistant tab - conversational interface and insights
struct AIAssistantTab: View {
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var advisor = SmartAdvisor.shared
    @State private var inputText = ""
    @State private var selectedSection: AISection = .chat
    @FocusState private var isInputFocused: Bool

    enum AISection: String, CaseIterable {
        case chat = "Chat"
        case insights = "Insights"
        case models = "Models"
        case report = "Report"

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right"
            case .insights: return "lightbulb"
            case .models: return "cpu"
            case .report: return "doc.text"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with section selector
            AIHeaderView(selectedSection: $selectedSection)

            Divider()

            // Content based on selected section
            switch selectedSection {
            case .chat:
                AIChatSection(
                    advisor: advisor,
                    inputText: $inputText,
                    isInputFocused: _isInputFocused
                )
            case .insights:
                AIInsightsSection(advisor: advisor)
            case .models:
                ModelSelectionView()
            case .report:
                AIReportSection(advisor: advisor)
            }
        }
        .onAppear {
            updateAnalysis()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            updateAnalysis()
        }
    }

    private func updateAnalysis() {
        let analyzer = ProcessAnalyzer()
        let processes = analyzer.getTopProcessesByCPU(limit: 20)

        advisor.analyze(
            cpuUsage: 100 - monitor.cpuIdlePercent,
            memoryPressure: monitor.memoryInfo.pressure,
            memoryUsed: monitor.memoryInfo.used,
            memoryTotal: monitor.memoryInfo.total,
            swapUsed: monitor.memoryInfo.swapUsed,
            temperature: monitor.temperature,
            processes: processes
        )
    }
}

// MARK: - Header View

struct AIHeaderView: View {
    @Binding var selectedSection: AIAssistantTab.AISection

    var body: some View {
        HStack(spacing: 16) {
            // Logo AI
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("AI Assistant")
                    .font(.headline)
            }

            Spacer()

            // Section picker
            Picker("Section", selection: $selectedSection) {
                ForEach(AIAssistantTab.AISection.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
        }
        .padding()
    }
}

// MARK: - Chat Section

struct AIChatSection: View {
    @ObservedObject var advisor: SmartAdvisor
    @Binding var inputText: String
    @FocusState var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Welcome message if conversation is empty
                        if advisor.conversation.messages.isEmpty {
                            WelcomeMessageView()
                        }

                        // Messages
                        ForEach(advisor.conversation.messages) { message in
                            ChatBubble(message: message, resourceCost: message.resourceCost)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: advisor.conversation.messages.count) { _, _ in
                    if let lastMessage = advisor.conversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            ChatInputView(
                inputText: $inputText,
                isInputFocused: _isInputFocused,
                onSend: sendMessage,
                onClear: { advisor.clearConversation() }
            )
        }
    }

    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let query = inputText
        inputText = ""

        _ = advisor.processQuery(query)
    }
}

// MARK: - Welcome Message

struct WelcomeMessageView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Hi! I'm your AI assistant")
                .font(.title2)
                .fontWeight(.semibold)

            Text("I can help you understand your Mac's status.\nTry asking me something!")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Suggestions
            VStack(alignment: .leading, spacing: 8) {
                Text("Example questions:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(["How's the CPU?", "Why is my Mac slow?", "What should I close?", "Are there anomalies?"], id: \.self) { suggestion in
                    SuggestionChip(text: suggestion)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.purple.opacity(0.1))
            )
        }
        .padding(32)
    }
}

struct SuggestionChip: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "text.bubble")
                .font(.caption)
                .foregroundColor(.purple)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.1))
        .cornerRadius(16)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: AIConversation.Message
    var resourceCost: ResourceTracker.ResourceCost? = nil

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }

                    Text(message.role == .user ? "You" : "Assistant")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(message.content)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.1))
                    )
                    .foregroundColor(message.role == .user ? .white : .primary)

                // Show resource cost for AI responses
                if message.role == .assistant, let cost = resourceCost {
                    ResourceCostBadge(cost: cost)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Resource Cost Badge

struct ResourceCostBadge: View {
    let cost: ResourceTracker.ResourceCost
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: impactIcon)
                    .font(.caption2)

                Text(cost.userFriendlyDescription)
                    .font(.caption2)

                if isExpanded {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .foregroundColor(impactColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(impactColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)

        if isExpanded {
            ResourceCostDetails(cost: cost)
        }
    }

    private var impactIcon: String {
        switch cost.impactLevel {
        case .low: return "leaf"
        case .medium: return "bolt"
        case .high: return "flame"
        }
    }

    private var impactColor: Color {
        switch cost.impactLevel {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}

struct ResourceCostDetails: View {
    let cost: ResourceTracker.ResourceCost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(String(format: "%.1fs", cost.duration), systemImage: "clock")
                Spacer()
                Label(String(format: "%.0f%% avg", cost.avgCPU), systemImage: "cpu")
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            HStack {
                let memMB = Double(abs(cost.memoryDelta)) / 1_048_576
                Label(String(format: "%.1f MB", memMB), systemImage: "memorychip")
                Spacer()
                Label(String(format: "~%.2f mWh", cost.estimatedEnergy), systemImage: "bolt.fill")
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            if let tokens = cost.tokenCount, cost.duration > 0 {
                let tokensPerSec = Double(tokens) / cost.duration
                Text(String(format: "%d tokens (%.1f/s)", tokens, tokensPerSec))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}

// MARK: - Chat Input

struct ChatInputView: View {
    @Binding var inputText: String
    @FocusState var isInputFocused: Bool
    let onSend: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Clear button
            Button(action: onClear) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")

            // Text field
            TextField("Ask something about your Mac...", text: $inputText)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(20)
                .focused($isInputFocused)
                .onSubmit(onSend)

            // Send button
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        inputText.isEmpty ? Color.secondary : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty)
        }
        .padding()
    }
}

// MARK: - Insights Section

struct AIInsightsSection: View {
    @ObservedObject var advisor: SmartAdvisor

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Analysis state
                if advisor.isAnalyzing {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Analyzing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                // Anomalies
                if !advisor.anomalies.isEmpty {
                    AnomaliesCard(anomalies: advisor.anomalies)
                }

                // Advice by severity
                if !advisor.currentAdvice.isEmpty {
                    AdviceListView(advice: advisor.currentAdvice)
                } else {
                    NoIssuesView()
                }
            }
            .padding()
        }
    }
}

// MARK: - Anomalies Card

struct AnomaliesCard: View {
    let anomalies: [AIAnomaly]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Anomalies Detected")
                    .font(.headline)
                Spacer()
                Text("\(anomalies.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(8)
            }

            ForEach(anomalies) { anomaly in
                AnomalyRow(anomaly: anomaly)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.1))
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

struct AnomalyRow: View {
    let anomaly: AIAnomaly

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: anomaly.type.icon)
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(anomaly.type.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(anomaly.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Confidence: \(Int(anomaly.confidence * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(anomaly.detectedAt, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Advice List

struct AdviceListView: View {
    let advice: [AIAdvice]

    private var criticalAdvice: [AIAdvice] {
        advice.filter { $0.severity == .critical }
    }

    private var warningAdvice: [AIAdvice] {
        advice.filter { $0.severity == .warning }
    }

    private var infoAdvice: [AIAdvice] {
        advice.filter { $0.severity == .info }
    }

    var body: some View {
        VStack(spacing: 16) {
            if !criticalAdvice.isEmpty {
                AdviceSectionGroup(
                    title: "Critical",
                    advice: criticalAdvice,
                    color: .red
                )
            }

            if !warningAdvice.isEmpty {
                AdviceSectionGroup(
                    title: "Warnings",
                    advice: warningAdvice,
                    color: .yellow
                )
            }

            if !infoAdvice.isEmpty {
                AdviceSectionGroup(
                    title: "Info",
                    advice: infoAdvice,
                    color: .blue
                )
            }
        }
    }
}

struct AdviceSectionGroup: View {
    let title: String
    let advice: [AIAdvice]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(advice.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.2))
                    .cornerRadius(8)
            }

            ForEach(advice) { item in
                AdviceRow(advice: item)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(color.opacity(0.05))
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct AdviceRow: View {
    let advice: AIAdvice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: advice.type.icon)
                .font(.title3)
                .foregroundColor(severityColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(advice.title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(advice.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let action = advice.action {
                ActionButton(action: action)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var severityColor: Color {
        switch advice.severity {
        case .critical: return .red
        case .warning: return .yellow
        case .info: return .blue
        }
    }
}

struct ActionButton: View {
    let action: AIAdvice.AdviceAction

    var body: some View {
        Button {
            performAction()
        } label: {
            Image(systemName: actionIcon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var actionIcon: String {
        switch action {
        case .terminateProcess: return "xmark.circle"
        case .openActivityMonitor: return "gauge"
        case .clearCache: return "trash"
        case .restartApp: return "arrow.clockwise"
        case .none: return "ellipsis"
        }
    }

    private func performAction() {
        switch action {
        case .terminateProcess(let pid, let name):
            let result = kill(pid, SIGTERM)
            if result != 0 {
                SmolLog.general.warning("Failed to terminate \(name, privacy: .public) (PID \(pid)): errno \(errno)")
            } else {
                SmolLog.general.info("Sent SIGTERM to \(name, privacy: .public) (PID \(pid))")
            }
        case .openActivityMonitor:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .clearCache, .restartApp, .none:
            break
        }
    }
}

// MARK: - No Issues View

struct NoIssuesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("All Good!")
                .font(.title2)
                .fontWeight(.semibold)

            Text("No issues or advice at the moment.\nThe system is running well.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Report Section

struct AIReportSection: View {
    @ObservedObject var advisor: SmartAdvisor
    @State private var showExportSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header report
                if let report = advisor.lastReport {
                    ReportHeaderView(report: report)

                    // Health score
                    HealthScoreView(score: report.healthScore)

                    // Sections
                    ForEach(report.sections) { section in
                        ReportSectionView(section: section)
                    }

                    // Recommendations
                    RecommendationsView(recommendations: report.recommendations)

                    // Export button
                    Button {
                        exportReport()
                    } label: {
                        Label("Export Report", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top)

                } else {
                    // Generate report
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("No Report Generated")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Generate a complete system status report")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button {
                            _ = advisor.generateReport()
                        } label: {
                            Label("Generate Report", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                }
            }
            .padding()
        }
    }

    private func exportReport() {
        guard let text = advisor.exportReportAsText() else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "smol-report-\(Date().ISO8601Format()).txt"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Report Components

struct ReportHeaderView: View {
    let report: SystemReport

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Report")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Generated: \(report.generatedAt, style: .date) at \(report.generatedAt, style: .time)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                // Regenerate
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.1))
        )
    }
}

struct HealthScoreView: View {
    let score: Int

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))

                VStack {
                    Text("\(score)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor)
                    Text("/ 100")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(scoreLabel)
                .font(.headline)
                .foregroundColor(scoreColor)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(scoreColor.opacity(0.1))
        )
    }

    private var scoreColor: Color {
        if score >= 80 { return .green }
        else if score >= 60 { return .yellow }
        else if score >= 40 { return .orange }
        else { return .red }
    }

    private var scoreLabel: String {
        if score >= 80 { return "Excellent" }
        else if score >= 60 { return "Good" }
        else if score >= 40 { return "Moderate" }
        else { return "Critical" }
    }
}

struct ReportSectionView: View {
    let section: SystemReport.ReportSection
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(section.title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.content)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if !section.metrics.isEmpty {
                        Divider()

                        ForEach(section.metrics, id: \.name) { metric in
                            HStack {
                                Circle()
                                    .fill(metricColor(metric.status))
                                    .frame(width: 8, height: 8)

                                Text(metric.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text(metric.value)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
                .padding([.horizontal, .bottom])
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func metricColor(_ status: SystemReport.ReportSection.Metric.Status) -> Color {
        switch status {
        case .good: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

struct RecommendationsView: View {
    let recommendations: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Recommendations")
                    .font(.headline)
            }

            ForEach(Array(recommendations.enumerated()), id: \.offset) { index, rec in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)

                    Text(rec)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.yellow.opacity(0.1))
        )
    }
}

// MARK: - Preview

#Preview {
    AIAssistantTab(monitor: SystemMonitor())
        .frame(width: 700, height: 600)
}
