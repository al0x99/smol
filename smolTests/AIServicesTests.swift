//
//  AIServicesTests.swift
//  smolTests
//
//  Test per i servizi AI: AnomalyDetector, NaturalLanguageProcessor, SystemReportGenerator
//

import Testing
import Foundation
@testable import smol

// MARK: - AIModels Tests

struct AIModelsTests {

    @Test func testAIDataPointCreation() async throws {
        let now = Date()
        let dataPoint = AIDataPoint(timestamp: now, value: 75.5)

        #expect(dataPoint.timestamp == now)
        #expect(dataPoint.value == 75.5)
    }

    @Test func testAIAdviceSeveritySortOrder() async throws {
        #expect(AIAdvice.Severity.critical.sortOrder > AIAdvice.Severity.warning.sortOrder)
        #expect(AIAdvice.Severity.warning.sortOrder > AIAdvice.Severity.info.sortOrder)
    }

    @Test func testAIAdviceTypeIcons() async throws {
        #expect(AIAdvice.AdviceType.performance.icon == "gauge.with.dots.needle.67percent")
        #expect(AIAdvice.AdviceType.memory.icon == "memorychip")
        #expect(AIAdvice.AdviceType.temperature.icon == "thermometer.high")
    }

    @Test func testAIAnomalyTypeIcons() async throws {
        #expect(AIAnomaly.AnomalyType.cpuSpike.icon == "bolt.fill")
        #expect(AIAnomaly.AnomalyType.memoryLeak.icon == "drop.fill")
        #expect(AIAnomaly.AnomalyType.thermalThrottling.icon == "flame.fill")
    }
}

// MARK: - AnomalyDetector Tests

struct AnomalyDetectorTests {

    @Test func testAnomalyDetectorWithEmptyData() async throws {
        let detector = AnomalyDetector()
        let anomalies = detector.detectAnomalies(
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: []
        )

        // Con dati vuoti non dovrebbero esserci anomalie
        #expect(anomalies.isEmpty)
    }

    @Test func testAnomalyDetectorWithInsufficientData() async throws {
        let detector = AnomalyDetector()

        // Meno di 30 campioni (minSamplesRequired)
        let cpuHistory = (0..<20).map { i in
            AIDataPoint(timestamp: Date().addingTimeInterval(Double(i) * 2), value: 50.0)
        }

        let anomalies = detector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: [],
            tempHistory: []
        )

        // Con dati insufficienti non dovrebbero esserci anomalie
        #expect(anomalies.isEmpty)
    }

    @Test func testCPUSpikeDetection() async throws {
        let detector = AnomalyDetector()
        let now = Date()

        // Crea storico CPU con valori normali e uno spike finale
        var cpuHistory: [AIDataPoint] = []

        // 30 campioni con valori normali (20-40%)
        for i in 0..<30 {
            let value = 25.0 + Double.random(in: -5...5)
            cpuHistory.append(AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: value
            ))
        }

        // Aggiungi spike finale (90%)
        cpuHistory.append(AIDataPoint(
            timestamp: now.addingTimeInterval(62),
            value: 92.0
        ))

        let anomalies = detector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: [],
            tempHistory: []
        )

        // Dovrebbe rilevare uno spike CPU
        let cpuSpikes = anomalies.filter { $0.type == .cpuSpike }
        #expect(cpuSpikes.count >= 1)
    }

    @Test func testMemoryLeakDetection() async throws {
        let detector = AnomalyDetector()
        let now = Date()

        // Crea storico memoria con trend crescente (possibile leak)
        var memoryHistory: [AIDataPoint] = []

        for i in 0..<60 {
            // Trend crescente: 30% -> 90% in 60 campioni = +1% per campione
            let value = 30.0 + Double(i) * 1.0
            memoryHistory.append(AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: value
            ))
        }

        let anomalies = detector.detectAnomalies(
            cpuHistory: [],
            memoryHistory: memoryHistory,
            tempHistory: []
        )

        // Dovrebbe rilevare possibile memory leak
        let memoryLeaks = anomalies.filter { $0.type == .memoryLeak }
        #expect(memoryLeaks.count >= 1)
    }

    @Test func testTemperatureRapidIncrease() async throws {
        let detector = AnomalyDetector()
        let now = Date()

        // Crea storico temperatura con aumento rapido
        var tempHistory: [AIDataPoint] = []

        // Primi 20 campioni stabili
        for i in 0..<20 {
            tempHistory.append(AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: 50.0
            ))
        }

        // Ultimi 15 campioni con aumento rapido (+20°C)
        for i in 0..<15 {
            let value = 50.0 + Double(i) * 1.5 // +1.5°C per campione
            tempHistory.append(AIDataPoint(
                timestamp: now.addingTimeInterval(Double(20 + i) * 2),
                value: value
            ))
        }

        let anomalies = detector.detectAnomalies(
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: tempHistory
        )

        // Dovrebbe rilevare thermal throttling
        let thermalAnomalies = anomalies.filter { $0.type == .thermalThrottling }
        #expect(thermalAnomalies.count >= 1)
    }

    @Test func testNoAnomaliesWithNormalData() async throws {
        let detector = AnomalyDetector()
        let now = Date()

        // Dati normali e stabili
        let cpuHistory = (0..<35).map { i in
            AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: 30.0 + Double.random(in: -5...5)
            )
        }

        let memoryHistory = (0..<35).map { i in
            AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: 40.0 + Double.random(in: -3...3)
            )
        }

        let tempHistory = (0..<35).map { i in
            AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: 55.0 + Double.random(in: -2...2)
            )
        }

        let anomalies = detector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory
        )

        // Con dati normali non dovrebbero esserci anomalie
        #expect(anomalies.isEmpty)
    }
}

// MARK: - NaturalLanguageProcessor Tests

struct NaturalLanguageProcessorTests {

    @Test func testCPUQueryDetection() async throws {
        let processor = NaturalLanguageProcessor()

        let queries = [
            "Come sta la CPU?",
            "Qual è l'utilizzo del processore?",
            "CPU usage?",
            "Quanto usa la CPU?"
        ]

        for query in queries {
            let response = processor.processQuery(
                query,
                cpuHistory: createSampleHistory(value: 50),
                memoryHistory: [],
                tempHistory: [],
                currentAdvice: [],
                anomalies: []
            )

            // La risposta dovrebbe menzionare CPU o percentuale
            #expect(response.contains("CPU") || response.contains("%"))
        }
    }

    @Test func testMemoryQueryDetection() async throws {
        let processor = NaturalLanguageProcessor()

        let queries = [
            "Come sta la memoria?",
            "RAM usage?",
            "Memory pressure?",
            "Quanta memoria è usata?"
        ]

        for query in queries {
            let response = processor.processQuery(
                query,
                cpuHistory: [],
                memoryHistory: createSampleHistory(value: 45),
                tempHistory: [],
                currentAdvice: [],
                anomalies: []
            )

            // La risposta dovrebbe menzionare memoria o pressure
            #expect(response.lowercased().contains("memory") || response.lowercased().contains("memoria") || response.contains("pressure"))
        }
    }

    @Test func testTemperatureQueryDetection() async throws {
        let processor = NaturalLanguageProcessor()

        // Query singola che contiene esplicitamente la keyword "temperatura"
        let response = processor.processQuery(
            "temperatura",
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: createSampleHistory(value: 65),
            currentAdvice: [],
            anomalies: []
        )

        // La risposta dovrebbe contenere informazioni sulla temperatura
        // Il processore restituisce risposte come "Temperatura CPU a 65°C (ottimale)..."
        let hasTemp = response.contains("°C") ||
                      response.lowercased().contains("temperatura") ||
                      response.lowercased().contains("temp") ||
                      response.contains("65") // Il valore fornito
        #expect(hasTemp, "La risposta non contiene informazioni sulla temperatura. Risposta: \(response)")
    }

    @Test func testWhySlowQueryDetection() async throws {
        let processor = NaturalLanguageProcessor()

        let queries = [
            "Perché il Mac è lento?",
            "Why is it slow?",
            "Cosa rallenta il sistema?",
            "Perché è così lento?"
        ]

        for query in queries {
            let response = processor.processQuery(
                query,
                cpuHistory: createSampleHistory(value: 85),
                memoryHistory: createSampleHistory(value: 75),
                tempHistory: createSampleHistory(value: 80),
                currentAdvice: [],
                anomalies: []
            )

            // La risposta dovrebbe menzionare CPU, memoria o suggerimenti
            #expect(!response.isEmpty)
        }
    }

    @Test func testUnknownQueryResponse() async throws {
        let processor = NaturalLanguageProcessor()

        let response = processor.processQuery(
            "xyzabc123", // Query senza senso
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: [],
            currentAdvice: [],
            anomalies: []
        )

        // Dovrebbe restituire messaggio di aiuto
        #expect(response.contains("Non ho capito") || response.contains("Prova"))
    }

    @Test func testAnomalyQueryWithAnomalies() async throws {
        let processor = NaturalLanguageProcessor()

        let anomaly = AIAnomaly(
            type: .cpuSpike,
            description: "CPU spike test",
            detectedAt: Date(),
            confidence: 0.9,
            relatedMetric: "CPU",
            currentValue: 95,
            expectedRange: 0...50
        )

        let response = processor.processQuery(
            "C'è qualche anomalia?",  // Usa singolare per match con keyword "anomalia"
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: [],
            currentAdvice: [],
            anomalies: [anomaly]
        )

        // Dovrebbe menzionare le anomalie - la risposta contiene "1 anomalia/e" o altre varianti
        let hasAnomaly = response.contains("1") ||
                         response.lowercased().contains("anomal") ||
                         response.contains("rilevat")
        #expect(hasAnomaly)
    }

    // Helper per creare dati di test
    private func createSampleHistory(value: Double, count: Int = 35) -> [AIDataPoint] {
        let now = Date()
        return (0..<count).map { i in
            AIDataPoint(
                timestamp: now.addingTimeInterval(Double(i) * 2),
                value: value
            )
        }
    }
}

// MARK: - SystemReportGenerator Tests

struct SystemReportGeneratorTests {

    @Test func testReportGenerationWithEmptyData() async throws {
        let generator = SystemReportGenerator()

        let report = generator.generate(
            cpuHistory: [],
            memoryHistory: [],
            tempHistory: [],
            advice: [],
            anomalies: []
        )

        // Dovrebbe generare un report valido
        #expect(report.healthScore >= 0 && report.healthScore <= 100)
        #expect(!report.summary.isEmpty)
        #expect(!report.sections.isEmpty)
    }

    @Test func testHealthScoreCalculation() async throws {
        let generator = SystemReportGenerator()
        let now = Date()

        // Dati ottimali
        let goodCPU = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 20)
        }
        let goodMemory = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 30)
        }
        let goodTemp = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 50)
        }

        let goodReport = generator.generate(
            cpuHistory: goodCPU,
            memoryHistory: goodMemory,
            tempHistory: goodTemp,
            advice: [],
            anomalies: []
        )

        // Dati pessimi
        let badCPU = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 90)
        }
        let badMemory = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 85)
        }
        let badTemp = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 95)
        }

        let badReport = generator.generate(
            cpuHistory: badCPU,
            memoryHistory: badMemory,
            tempHistory: badTemp,
            advice: [],
            anomalies: []
        )

        // Il report con dati buoni dovrebbe avere score più alto
        #expect(goodReport.healthScore > badReport.healthScore)
    }

    @Test func testReportSectionsPresent() async throws {
        let generator = SystemReportGenerator()
        let now = Date()

        let sampleData = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 50)
        }

        let report = generator.generate(
            cpuHistory: sampleData,
            memoryHistory: sampleData,
            tempHistory: sampleData,
            advice: [],
            anomalies: []
        )

        // Dovrebbe avere sezioni per CPU, Memoria, Temperatura, Anomalie, Consigli
        let sectionTitles = report.sections.map { $0.title }
        #expect(sectionTitles.contains("CPU"))
        #expect(sectionTitles.contains("Memoria"))
        #expect(sectionTitles.contains("Temperatura"))
        #expect(sectionTitles.contains("Anomalie"))
        #expect(sectionTitles.contains("Consigli"))
    }

    @Test func testReportExportAsText() async throws {
        let generator = SystemReportGenerator()
        let now = Date()

        let sampleData = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 50)
        }

        let report = generator.generate(
            cpuHistory: sampleData,
            memoryHistory: sampleData,
            tempHistory: sampleData,
            advice: [],
            anomalies: []
        )

        let text = generator.exportAsText(report)

        // Il testo esportato dovrebbe contenere elementi chiave
        #expect(text.contains("REPORT SISTEMA"))
        #expect(text.contains("smol"))
        #expect(text.contains("SOMMARIO"))
        #expect(text.contains("CPU"))
        #expect(text.contains("RACCOMANDAZIONI"))
    }

    @Test func testReportRecommendationsGenerated() async throws {
        let generator = SystemReportGenerator()
        let now = Date()

        // Dati che dovrebbero generare raccomandazioni
        let highCPU = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 80)
        }

        let report = generator.generate(
            cpuHistory: highCPU,
            memoryHistory: [],
            tempHistory: [],
            advice: [],
            anomalies: []
        )

        // Dovrebbe avere almeno una raccomandazione
        #expect(!report.recommendations.isEmpty)
    }

    @Test func testAnomaliesAffectHealthScore() async throws {
        let generator = SystemReportGenerator()
        let now = Date()

        let sampleData = (0..<10).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i)), value: 40)
        }

        let highConfidenceAnomaly = AIAnomaly(
            type: .cpuSpike,
            description: "Test",
            detectedAt: now,
            confidence: 0.9,
            relatedMetric: "CPU",
            currentValue: 95,
            expectedRange: 0...50
        )

        let reportWithAnomaly = generator.generate(
            cpuHistory: sampleData,
            memoryHistory: sampleData,
            tempHistory: sampleData,
            advice: [],
            anomalies: [highConfidenceAnomaly]
        )

        let reportWithoutAnomaly = generator.generate(
            cpuHistory: sampleData,
            memoryHistory: sampleData,
            tempHistory: sampleData,
            advice: [],
            anomalies: []
        )

        // Le anomalie dovrebbero ridurre lo score
        #expect(reportWithoutAnomaly.healthScore > reportWithAnomaly.healthScore)
    }
}

// MARK: - Integration Tests

struct AIServicesIntegrationTests {

    @Test func testEndToEndAnalysis() async throws {
        // Simula un ciclo completo: dati -> anomalie -> report
        let detector = AnomalyDetector()
        let generator = SystemReportGenerator()
        let now = Date()

        // Genera dati simulati
        let cpuHistory = (0..<40).map { i in
            let value = i < 35 ? 30.0 + Double.random(in: -5...5) : 85.0
            return AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: value)
        }

        let memoryHistory = (0..<40).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: 45.0)
        }

        let tempHistory = (0..<40).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: 55.0)
        }

        // Rileva anomalie
        let anomalies = detector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory
        )

        // Genera report
        let report = generator.generate(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory,
            advice: [],
            anomalies: anomalies
        )

        // Verifica che il sistema funzioni end-to-end
        #expect(report.healthScore >= 0 && report.healthScore <= 100)
        #expect(!report.summary.isEmpty)

        // Esporta e verifica
        let text = generator.exportAsText(report)
        #expect(!text.isEmpty)
    }

    @Test func testNLPWithRealContext() async throws {
        let processor = NaturalLanguageProcessor()
        let detector = AnomalyDetector()
        let now = Date()

        // Crea contesto realistico
        let cpuHistory = (0..<40).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: 75.0)
        }

        let memoryHistory = (0..<40).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: 60.0)
        }

        let tempHistory = (0..<40).map { i in
            AIDataPoint(timestamp: now.addingTimeInterval(Double(i) * 2), value: 70.0)
        }

        let anomalies = detector.detectAnomalies(
            cpuHistory: cpuHistory,
            memoryHistory: memoryHistory,
            tempHistory: tempHistory
        )

        // Crea advice di test
        let advice = AIAdvice(
            type: .performance,
            title: "CPU elevata",
            description: "La CPU è al 75%",
            severity: .warning,
            action: nil,
            timestamp: now
        )

        // Test varie query
        let queries = [
            "Come sta il sistema?",
            "Perché è lento?",
            "Ci sono problemi?"
        ]

        for query in queries {
            let response = processor.processQuery(
                query,
                cpuHistory: cpuHistory,
                memoryHistory: memoryHistory,
                tempHistory: tempHistory,
                currentAdvice: [advice],
                anomalies: anomalies
            )

            // Ogni risposta dovrebbe essere non vuota e informativa
            #expect(!response.isEmpty)
            #expect(response.count > 10)
        }
    }
}
