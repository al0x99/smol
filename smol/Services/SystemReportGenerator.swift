import Foundation

/// System report generator.
/// Produces detailed text reports about the system's recent state.
class SystemReportGenerator {

    // MARK: - Public API

    func generate(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        advice: [AIAdvice],
        anomalies: [AIAnomaly]
    ) -> SystemReport {

        let healthScore = calculateHealthScore(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            anomalies: anomalies
        )

        let summary = generateSummary(healthScore: healthScore, advice: advice, anomalies: anomalies)

        let sections = [
            generateCPUSection(cpuHistory),
            generateMemorySection(memoryHistory),
            generateTemperatureSection(tempHistory),
            generateAnomalySection(anomalies),
            generateAdviceSection(advice)
        ]

        let recommendations = generateRecommendations(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            advice: advice
        )

        return SystemReport(
            generatedAt: Date(),
            summary: summary,
            healthScore: healthScore,
            sections: sections,
            recommendations: recommendations
        )
    }

    // MARK: - Health score

    private func calculateHealthScore(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        anomalies: [AIAnomaly]
    ) -> Int {
        Self.calculateHealthScore(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            anomalies: anomalies
        )
    }

    /// Pure rule extracted from `calculateHealthScore`. Starts at
    /// 100 and deducts: 25/15/5 for avg CPU > 80/60/40 (mirrored
    /// for memory at the same bands and temp at 90/80/70), 10
    /// per anomaly with confidence > 0.8, 5 per anomaly with
    /// confidence in `(0.5, 0.8]`. Clamped to `[0, 100]`.
    /// Empty histories contribute zero deduction.
    static func calculateHealthScore(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        anomalies: [AIAnomaly]
    ) -> Int {
        var score = 100

        if let avgCPU = average(cpuHistory) {
            if avgCPU > 80 { score -= 25 }
            else if avgCPU > 60 { score -= 15 }
            else if avgCPU > 40 { score -= 5 }
        }

        if let avgMemory = average(memoryHistory) {
            if avgMemory > 80 { score -= 25 }
            else if avgMemory > 60 { score -= 15 }
            else if avgMemory > 40 { score -= 5 }
        }

        if let avgTemp = average(tempHistory) {
            if avgTemp > 90 { score -= 25 }
            else if avgTemp > 80 { score -= 15 }
            else if avgTemp > 70 { score -= 5 }
        }

        // Bands are disjoint by the `<= 0.8` upper bound on
        // warning — an anomaly at exactly 0.8 is counted once as
        // a warning, never as a critical. Flipping this to `< 0.8`
        // would silently drop the at-the-boundary anomaly entirely.
        let criticalAnomalies = anomalies.filter { $0.confidence > 0.8 }.count
        let warningAnomalies = anomalies.filter { $0.confidence > 0.5 && $0.confidence <= 0.8 }.count
        score -= criticalAnomalies * 10
        score -= warningAnomalies * 5

        return max(0, min(100, score))
    }

    /// Maps a numeric health score to the textual band the
    /// summary line uses. Boundaries are inclusive-low: 90 is
    /// "excellent", 70 is "good", 50 is "moderate", 30 is "poor",
    /// anything below 30 is "critical".
    static func healthStatusLabel(forScore score: Int) -> String {
        switch score {
        case 90...100: return "excellent"
        case 70..<90:  return "good"
        case 50..<70:  return "moderate"
        case 30..<50:  return "poor"
        default:       return "critical"
        }
    }

    private static func average(_ dataPoints: [AIDataPoint]) -> Double? {
        guard !dataPoints.isEmpty else { return nil }
        return dataPoints.map { $0.value }.reduce(0, +) / Double(dataPoints.count)
    }

    private func average(_ dataPoints: [AIDataPoint]) -> Double? {
        Self.average(dataPoints)
    }

    // MARK: - Summary

    private func generateSummary(healthScore: Int, advice: [AIAdvice], anomalies: [AIAnomaly]) -> String {
        let healthStatus = Self.healthStatusLabel(forScore: healthScore)
        var summary = "System status: \(healthStatus) (score: \(healthScore)/100). "

        let criticalCount = advice.filter { $0.severity == .critical }.count
        let warningCount = advice.filter { $0.severity == .warning }.count

        if criticalCount > 0 {
            let noun = criticalCount == 1 ? "critical issue requires" : "critical issues require"
            summary += "\(criticalCount) \(noun) immediate attention. "
        }
        if warningCount > 0 {
            let noun = warningCount == 1 ? "warning" : "warnings"
            summary += "\(warningCount) \(noun) to monitor. "
        }
        if !anomalies.isEmpty {
            let noun = anomalies.count == 1 ? "anomaly detected" : "anomalies detected"
            summary += "\(anomalies.count) \(noun). "
        }
        if criticalCount == 0 && warningCount == 0 && anomalies.isEmpty {
            summary += "No problems detected."
        }

        return summary
    }

    // MARK: - Sections

    private func generateCPUSection(_ history: [AIDataPoint]) -> SystemReport.ReportSection {
        let avg = average(history) ?? 0
        let max = history.map { $0.value }.max() ?? 0
        let min = history.map { $0.value }.min() ?? 0

        let status: SystemReport.ReportSection.Metric.Status
        if avg > 80 { status = .critical }
        else if avg > 50 { status = .warning }
        else { status = .good }

        let content = """
        Average CPU usage over the monitoring window was \(Int(avg))%.
        Peak reached \(Int(max))%, low was \(Int(min))%.
        \(avg > 70 ? "High usage may point to heavy workloads or stuck processes." : "Usage is within the normal range.")
        """

        return SystemReport.ReportSection(
            title: "CPU",
            content: content,
            metrics: [
                .init(name: "Average", value: "\(Int(avg))%", status: status),
                .init(name: "Peak",    value: "\(Int(max))%", status: max > 90 ? .critical : .good),
                .init(name: "Low",     value: "\(Int(min))%", status: .good)
            ]
        )
    }

    private func generateMemorySection(_ history: [AIDataPoint]) -> SystemReport.ReportSection {
        let avg = average(history) ?? 0
        let max = history.map { $0.value }.max() ?? 0

        let status: SystemReport.ReportSection.Metric.Status
        if avg > 80 { status = .critical }
        else if avg > 50 { status = .warning }
        else { status = .good }

        let content = """
        Average memory pressure was \(Int(avg))%.
        \(avg > 70 ? "The system is actively managing memory. Consider closing apps you don't need." : "Memory is being managed normally.")
        Peak: \(Int(max))%.
        """

        return SystemReport.ReportSection(
            title: "Memory",
            content: content,
            metrics: [
                .init(name: "Avg pressure",  value: "\(Int(avg))%", status: status),
                .init(name: "Peak pressure", value: "\(Int(max))%", status: max > 80 ? .critical : .good)
            ]
        )
    }

    private func generateTemperatureSection(_ history: [AIDataPoint]) -> SystemReport.ReportSection {
        let avg = average(history) ?? 0
        let max = history.map { $0.value }.max() ?? 0
        let min = history.map { $0.value }.min() ?? 0

        let status: SystemReport.ReportSection.Metric.Status
        if avg > 85 { status = .critical }
        else if avg > 70 { status = .warning }
        else { status = .good }

        let content = """
        Average CPU temperature: \(Int(avg))°C, peak at \(Int(max))°C.
        \(avg > 80 ? "Sustained high temperatures can trigger throttling and degrade performance." : "Temperatures are within the normal range.")
        Apple Silicon typical range: 35–75°C at idle, up to 100°C under heavy load.
        """

        return SystemReport.ReportSection(
            title: "Temperature",
            content: content,
            metrics: [
                .init(name: "Average", value: "\(Int(avg))°C", status: status),
                .init(name: "Peak",    value: "\(Int(max))°C", status: max > 95 ? .critical : (max > 85 ? .warning : .good)),
                .init(name: "Low",     value: "\(Int(min))°C", status: .good)
            ]
        )
    }

    private func generateAnomalySection(_ anomalies: [AIAnomaly]) -> SystemReport.ReportSection {
        if anomalies.isEmpty {
            return SystemReport.ReportSection(
                title: "Anomalies",
                content: "No anomalies detected during the monitoring window.",
                metrics: [
                    .init(name: "Status", value: "Normal", status: .good)
                ]
            )
        }

        let descriptions = anomalies.map { "• \($0.type.rawValue): \($0.description)" }
        let content = "Detected anomalies:\n" + descriptions.joined(separator: "\n")

        return SystemReport.ReportSection(
            title: "Anomalies",
            content: content,
            metrics: [
                .init(name: "Detected", value: "\(anomalies.count)", status: anomalies.count > 2 ? .critical : .warning)
            ]
        )
    }

    private func generateAdviceSection(_ advice: [AIAdvice]) -> SystemReport.ReportSection {
        if advice.isEmpty {
            return SystemReport.ReportSection(
                title: "Advice",
                content: "Nothing flagged. The system is running smoothly.",
                metrics: []
            )
        }

        let critical = advice.filter { $0.severity == .critical }
        let warnings = advice.filter { $0.severity == .warning }
        let info     = advice.filter { $0.severity == .info }

        var content = ""
        if !critical.isEmpty {
            content += "CRITICAL:\n" + critical.map { "• \($0.title): \($0.description)" }.joined(separator: "\n") + "\n\n"
        }
        if !warnings.isEmpty {
            content += "WARNINGS:\n" + warnings.map { "• \($0.title): \($0.description)" }.joined(separator: "\n") + "\n\n"
        }
        if !info.isEmpty {
            content += "INFO:\n" + info.map { "• \($0.title)" }.joined(separator: "\n")
        }

        return SystemReport.ReportSection(
            title: "Advice",
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            metrics: [
                .init(name: "Critical", value: "\(critical.count)", status: critical.isEmpty ? .good : .critical),
                .init(name: "Warnings", value: "\(warnings.count)", status: warnings.isEmpty ? .good : .warning),
                .init(name: "Info",     value: "\(info.count)",     status: .good)
            ]
        )
    }

    // MARK: - Recommendations

    private func generateRecommendations(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        advice: [AIAdvice]
    ) -> [String] {
        var recommendations: [String] = []

        if let avgCPU = average(cpuHistory), avgCPU > 70 {
            recommendations.append("Identify and close CPU-heavy processes using Activity Monitor.")
        }

        if let avgMemory = average(memoryHistory), avgMemory > 60 {
            recommendations.append("Free up memory by closing apps you don't need, or restart the browser if it has many tabs open.")
        }

        if let avgTemp = average(tempHistory), avgTemp > 80 {
            recommendations.append("Improve ventilation around the Mac or reduce the workload to bring the temperature down.")
        }

        if advice.contains(where: { $0.type == .process }) {
            recommendations.append("Inspect the flagged processes — they may be stuck or leaking memory.")
        }

        if recommendations.isEmpty {
            recommendations.append("Keep an eye on performance over time to catch any negative trends early.")
        }

        return recommendations
    }

    // MARK: - Export

    /// Export the report as plain text.
    func exportAsText(_ report: SystemReport) -> String {
        var text = """
        ═══════════════════════════════════════
        SYSTEM REPORT — smol
        ═══════════════════════════════════════
        Generated: \(formatDate(report.generatedAt))

        SUMMARY
        ────────
        \(report.summary)
        Health score: \(report.healthScore)/100

        """

        for section in report.sections {
            text += """

            \(section.title.uppercased())
            ────────
            \(section.content)

            """
            if !section.metrics.isEmpty {
                text += "Metrics:\n"
                for metric in section.metrics {
                    let statusIcon = metric.status == .good ? "✓" : (metric.status == .warning ? "⚠" : "✗")
                    text += "  \(statusIcon) \(metric.name): \(metric.value)\n"
                }
            }
        }

        // The trailing newline below is load-bearing — Swift's
        // multi-line literals strip the newline immediately before
        // the closing `"""`, so without an explicit blank line the
        // first recommendation rendered as
        // "────────────────1. First rec" glued to the underline.
        text += """

        RECOMMENDATIONS
        ────────────────

        """
        for (i, rec) in report.recommendations.enumerated() {
            text += "\(i + 1). \(rec)\n"
        }

        text += """

        ═══════════════════════════════════════
        Report generated by smol — System Monitor
        """

        return text
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
