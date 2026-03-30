import Foundation

/// System report generator
/// Creates detailed text reports on system status
class SystemReportGenerator {

    // MARK: - Public API

    /// Generate a comprehensive system report
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

    // MARK: - Health Score

    private func calculateHealthScore(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint],
        anomalies: [AIAnomaly]
    ) -> Int {
        var score = 100

        // CPU factor (max -25 points)
        if let avgCPU = average(cpuHistory) {
            if avgCPU > 80 { score -= 25 }
            else if avgCPU > 60 { score -= 15 }
            else if avgCPU > 40 { score -= 5 }
        }

        // Memory factor (max -25 points)
        if let avgMemory = average(memoryHistory) {
            if avgMemory > 80 { score -= 25 }
            else if avgMemory > 60 { score -= 15 }
            else if avgMemory > 40 { score -= 5 }
        }

        // Temperature factor (max -25 points)
        if let avgTemp = average(tempHistory) {
            if avgTemp > 90 { score -= 25 }
            else if avgTemp > 80 { score -= 15 }
            else if avgTemp > 70 { score -= 5 }
        }

        // Anomalies factor (max -25 points)
        let criticalAnomalies = anomalies.filter { $0.confidence > 0.8 }.count
        let warningAnomalies = anomalies.filter { $0.confidence > 0.5 && $0.confidence <= 0.8 }.count
        score -= criticalAnomalies * 10
        score -= warningAnomalies * 5

        return max(0, min(100, score))
    }

    private func average(_ dataPoints: [AIDataPoint]) -> Double? {
        guard !dataPoints.isEmpty else { return nil }
        return dataPoints.map { $0.value }.reduce(0, +) / Double(dataPoints.count)
    }

    // MARK: - Summary

    private func generateSummary(healthScore: Int, advice: [AIAdvice], anomalies: [AIAnomaly]) -> String {
        let healthStatus: String
        switch healthScore {
        case 90...100: healthStatus = "eccellente"
        case 70..<90: healthStatus = "buono"
        case 50..<70: healthStatus = "moderato"
        case 30..<50: healthStatus = "problematico"
        default: healthStatus = "critico"
        }

        var summary = "Stato sistema: \(healthStatus) (punteggio: \(healthScore)/100). "

        let criticalCount = advice.filter { $0.severity == .critical }.count
        let warningCount = advice.filter { $0.severity == .warning }.count

        if criticalCount > 0 {
            summary += "\(criticalCount) problema/i critico/i richiede/ono attenzione immediata. "
        }
        if warningCount > 0 {
            summary += "\(warningCount) avviso/i da monitorare. "
        }
        if anomalies.count > 0 {
            summary += "\(anomalies.count) anomalia/e rilevata/e. "
        }
        if criticalCount == 0 && warningCount == 0 && anomalies.isEmpty {
            summary += "Nessun problema rilevato."
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
        L'utilizzo CPU medio nel periodo di monitoraggio è stato del \(Int(avg))%.
        Il picco massimo ha raggiunto \(Int(max))%, mentre il minimo è stato \(Int(min))%.
        \(avg > 70 ? "L'utilizzo elevato potrebbe indicare processi intensivi o problemi." : "L'utilizzo è nella norma.")
        """

        return SystemReport.ReportSection(
            title: "CPU",
            content: content,
            metrics: [
                .init(name: "Media", value: "\(Int(avg))%", status: status),
                .init(name: "Massimo", value: "\(Int(max))%", status: max > 90 ? .critical : .good),
                .init(name: "Minimo", value: "\(Int(min))%", status: .good)
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
        La memory pressure media è stata del \(Int(avg))%.
        \(avg > 70 ? "Il sistema sta gestendo attivamente la memoria. Considera chiudere app non necessarie." : "La memoria è gestita correttamente.")
        Picco massimo: \(Int(max))%.
        """

        return SystemReport.ReportSection(
            title: "Memoria",
            content: content,
            metrics: [
                .init(name: "Pressure Media", value: "\(Int(avg))%", status: status),
                .init(name: "Pressure Max", value: "\(Int(max))%", status: max > 80 ? .critical : .good)
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
        Temperatura CPU media: \(Int(avg))°C, con picco a \(Int(max))°C.
        \(avg > 80 ? "Temperature elevate possono causare throttling e ridurre le prestazioni." : "Le temperature sono nella norma.")
        Range normale per Apple Silicon: 35-75°C a riposo, fino a 100°C sotto carico intenso.
        """

        return SystemReport.ReportSection(
            title: "Temperatura",
            content: content,
            metrics: [
                .init(name: "Media", value: "\(Int(avg))°C", status: status),
                .init(name: "Massima", value: "\(Int(max))°C", status: max > 95 ? .critical : (max > 85 ? .warning : .good)),
                .init(name: "Minima", value: "\(Int(min))°C", status: .good)
            ]
        )
    }

    private func generateAnomalySection(_ anomalies: [AIAnomaly]) -> SystemReport.ReportSection {
        if anomalies.isEmpty {
            return SystemReport.ReportSection(
                title: "Anomalie",
                content: "Nessuna anomalia rilevata nel periodo di monitoraggio.",
                metrics: [
                    .init(name: "Stato", value: "Normale", status: .good)
                ]
            )
        }

        let descriptions = anomalies.map { "• \($0.type.rawValue): \($0.description)" }
        let content = "Anomalie rilevate:\n" + descriptions.joined(separator: "\n")

        return SystemReport.ReportSection(
            title: "Anomalie",
            content: content,
            metrics: [
                .init(name: "Rilevate", value: "\(anomalies.count)", status: anomalies.count > 2 ? .critical : .warning)
            ]
        )
    }

    private func generateAdviceSection(_ advice: [AIAdvice]) -> SystemReport.ReportSection {
        if advice.isEmpty {
            return SystemReport.ReportSection(
                title: "Consigli",
                content: "Nessun consiglio particolare. Il sistema funziona bene.",
                metrics: []
            )
        }

        let critical = advice.filter { $0.severity == .critical }
        let warnings = advice.filter { $0.severity == .warning }
        let info = advice.filter { $0.severity == .info }

        var content = ""
        if !critical.isEmpty {
            content += "CRITICI:\n" + critical.map { "• \($0.title): \($0.description)" }.joined(separator: "\n") + "\n\n"
        }
        if !warnings.isEmpty {
            content += "AVVISI:\n" + warnings.map { "• \($0.title): \($0.description)" }.joined(separator: "\n") + "\n\n"
        }
        if !info.isEmpty {
            content += "INFO:\n" + info.map { "• \($0.title)" }.joined(separator: "\n")
        }

        return SystemReport.ReportSection(
            title: "Consigli",
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            metrics: [
                .init(name: "Critici", value: "\(critical.count)", status: critical.isEmpty ? .good : .critical),
                .init(name: "Avvisi", value: "\(warnings.count)", status: warnings.isEmpty ? .good : .warning),
                .init(name: "Info", value: "\(info.count)", status: .good)
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

        // CPU recommendations
        if let avgCPU = average(cpuHistory), avgCPU > 70 {
            recommendations.append("Considera identificare e chiudere i processi che usano molta CPU usando Activity Monitor.")
        }

        // Memory recommendations
        if let avgMemory = average(memoryHistory), avgMemory > 60 {
            recommendations.append("Libera memoria chiudendo app non utilizzate o riavviando il browser se ha troppe tab aperte.")
        }

        // Temperature recommendations
        if let avgTemp = average(tempHistory), avgTemp > 80 {
            recommendations.append("Migliora la ventilazione del Mac o riduci il carico di lavoro per abbassare la temperatura.")
        }

        // General recommendations based on advice
        if advice.contains(where: { $0.type == .process }) {
            recommendations.append("Controlla i processi segnalati - potrebbero essere bloccati o avere memory leak.")
        }

        // Default recommendation
        if recommendations.isEmpty {
            recommendations.append("Continua a monitorare le prestazioni regolarmente per identificare trend negativi.")
        }

        return recommendations
    }

    // MARK: - Export

    /// Export the report as formatted text
    func exportAsText(_ report: SystemReport) -> String {
        var text = """
        ═══════════════════════════════════════
        REPORT SISTEMA - smol
        ═══════════════════════════════════════
        Generato: \(formatDate(report.generatedAt))

        SOMMARIO
        ────────
        \(report.summary)
        Punteggio Salute: \(report.healthScore)/100

        """

        for section in report.sections {
            text += """

            \(section.title.uppercased())
            ────────
            \(section.content)

            """
            if !section.metrics.isEmpty {
                text += "Metriche:\n"
                for metric in section.metrics {
                    let statusIcon = metric.status == .good ? "✓" : (metric.status == .warning ? "⚠" : "✗")
                    text += "  \(statusIcon) \(metric.name): \(metric.value)\n"
                }
            }
        }

        text += """

        RACCOMANDAZIONI
        ────────────────
        """
        for (i, rec) in report.recommendations.enumerated() {
            text += "\(i + 1). \(rec)\n"
        }

        text += """

        ═══════════════════════════════════════
        Report generato da smol - System Monitor
        """

        return text
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "it_IT")
        return formatter.string(from: date)
    }
}
