import Foundation
import Accelerate

/// Anomaly detector based on statistical analysis and pattern recognition
/// Uses vDSP (Accelerate framework) for vectorized calculations optimized on Apple Silicon
class AnomalyDetector {

    // MARK: - Configuration

    /// Standard deviations beyond which a value is anomalous
    private let anomalyThreshold: Double = 2.5

    /// Minimum number of samples for reliable analysis
    private let minSamplesRequired = 30

    // MARK: - Public API

    /// Detect anomalies in historical data
    func detectAnomalies(
        cpuHistory: [AIDataPoint],
        memoryHistory: [AIDataPoint],
        tempHistory: [AIDataPoint]
    ) -> [AIAnomaly] {
        var anomalies: [AIAnomaly] = []

        // CPU Anomalies
        if let cpuAnomaly = detectCPUAnomaly(cpuHistory) {
            anomalies.append(cpuAnomaly)
        }

        // Memory Anomalies
        if let memoryAnomaly = detectMemoryAnomaly(memoryHistory) {
            anomalies.append(memoryAnomaly)
        }

        // Temperature Anomalies
        if let tempAnomaly = detectTemperatureAnomaly(tempHistory) {
            anomalies.append(tempAnomaly)
        }

        // Pattern-based anomalies
        anomalies.append(contentsOf: detectPatternAnomalies(
            cpu: cpuHistory,
            memory: memoryHistory,
            temp: tempHistory
        ))

        return anomalies
    }

    // MARK: - CPU Analysis

    private func detectCPUAnomaly(_ history: [AIDataPoint]) -> AIAnomaly? {
        guard history.count >= minSamplesRequired else { return nil }

        let values = history.map { $0.value }
        let stats = calculateStats(values)

        guard let lastValue = values.last else { return nil }

        // CPU spike detection
        let zScore = (lastValue - stats.mean) / max(stats.stdDev, 1)

        if zScore > anomalyThreshold && lastValue > 80 {
            return AIAnomaly(
                type: .cpuSpike,
                description: "CPU spike: \(Int(lastValue))% (average: \(Int(stats.mean))%)",
                detectedAt: Date(),
                confidence: min(zScore / 4, 1.0),
                relatedMetric: "CPU Usage",
                currentValue: lastValue,
                expectedRange: max(0, stats.mean - stats.stdDev * 2)...min(100, stats.mean + stats.stdDev * 2)
            )
        }

        return nil
    }

    // MARK: - Memory Analysis

    private func detectMemoryAnomaly(_ history: [AIDataPoint]) -> AIAnomaly? {
        guard history.count >= minSamplesRequired else { return nil }

        let values = history.map { $0.value }

        // Detect memory leak (continuously increasing pattern)
        if let leakConfidence = detectMemoryLeak(values), leakConfidence > 0.7 {
            return AIAnomaly(
                type: .memoryLeak,
                description: "Possible memory leak: memory pressure keeps rising",
                detectedAt: Date(),
                confidence: leakConfidence,
                relatedMetric: "Memory Pressure",
                currentValue: values.last ?? 0,
                expectedRange: 0...50
            )
        }

        return nil
    }

    /// Detect memory leak pattern using linear regression
    private func detectMemoryLeak(_ values: [Double]) -> Double? {
        guard values.count >= 20 else { return nil }

        // Take last N values
        let recentValues = Array(values.suffix(60))

        // Calculate slope using linear regression
        let n = Double(recentValues.count)
        let xMean = (n - 1) / 2
        let yMean = recentValues.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0

        for (i, y) in recentValues.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        let slope = denominator > 0 ? numerator / denominator : 0

        // If slope > 0.1 per sample (0.1% per 2 seconds = 3% per minute), possible leak
        if slope > 0.1 {
            // Confidence based on R-squared
            var ssRes = 0.0
            var ssTot = 0.0
            for (i, y) in recentValues.enumerated() {
                let predicted = slope * Double(i) + (yMean - slope * xMean)
                ssRes += (y - predicted) * (y - predicted)
                ssTot += (y - yMean) * (y - yMean)
            }
            let rSquared = ssTot > 0 ? 1 - (ssRes / ssTot) : 0
            return rSquared
        }

        return nil
    }

    // MARK: - Temperature Analysis

    private func detectTemperatureAnomaly(_ history: [AIDataPoint]) -> AIAnomaly? {
        guard history.count >= minSamplesRequired else { return nil }

        let values = history.map { $0.value }

        guard let lastValue = values.last else { return nil }

        // Rapid temperature increase
        let recentValues = Array(values.suffix(15)) // ~30 seconds
        if recentValues.count >= 10 {
            let tempIncrease = (recentValues.last ?? 0) - (recentValues.first ?? 0)
            if tempIncrease > 15 { // +15°C in 30 seconds
                return AIAnomaly(
                    type: .thermalThrottling,
                    description: "Temperature rising fast: +\(Int(tempIncrease))°C in 30 seconds",
                    detectedAt: Date(),
                    confidence: min(tempIncrease / 25, 1.0),
                    relatedMetric: "Temperature",
                    currentValue: lastValue,
                    expectedRange: 40...75
                )
            }
        }

        return nil
    }

    // MARK: - Pattern Analysis

    private func detectPatternAnomalies(
        cpu: [AIDataPoint],
        memory: [AIDataPoint],
        temp: [AIDataPoint]
    ) -> [AIAnomaly] {
        var anomalies: [AIAnomaly] = []

        // CPU/Temperature correlation anomaly
        if let lastCPU = cpu.last?.value, let lastTemp = temp.last?.value {
            if lastTemp > 80 && lastCPU < 30 {
                anomalies.append(AIAnomaly(
                    type: .thermalThrottling,
                    description: "Elevated temperature (\(Int(lastTemp))°C) with low CPU (\(Int(lastCPU))%). Possible hardware issue or hidden process.",
                    detectedAt: Date(),
                    confidence: 0.8,
                    relatedMetric: "Temperature/CPU Correlation",
                    currentValue: lastTemp,
                    expectedRange: 40...70
                ))
            }
        }

        // CPU oscillation (flip-flop between high and low)
        if cpu.count >= 20 {
            let recentCPU = Array(cpu.suffix(20))
            let oscillation = detectOscillation(recentCPU.map { $0.value })
            if oscillation > 0.7 {
                anomalies.append(AIAnomaly(
                    type: .unusualProcess,
                    description: "Oscillating CPU pattern. A process may be repeatedly starting and stopping.",
                    detectedAt: Date(),
                    confidence: oscillation,
                    relatedMetric: "CPU Pattern",
                    currentValue: cpu.last?.value ?? 0,
                    expectedRange: 0...50
                ))
            }
        }

        return anomalies
    }

    /// Detect oscillations in the signal
    private func detectOscillation(_ values: [Double]) -> Double {
        guard values.count >= 10 else { return 0 }

        var changes = 0
        var previousDirection: Int? = nil

        for i in 1..<values.count {
            let diff = values[i] - values[i-1]
            if abs(diff) > 10 { // Minimum 10% change
                let direction = diff > 0 ? 1 : -1
                if let prev = previousDirection, prev != direction {
                    changes += 1
                }
                previousDirection = direction
            }
        }

        // Normalize: more than 5 direction changes in 20 samples = oscillation
        return min(Double(changes) / 5.0, 1.0)
    }

    // MARK: - Statistics Helpers

    struct Stats {
        let mean: Double
        let stdDev: Double
        let min: Double
        let max: Double
    }

    /// Calculate statistics using Accelerate for performance
    private func calculateStats(_ values: [Double]) -> Stats {
        guard !values.isEmpty else {
            return Stats(mean: 0, stdDev: 0, min: 0, max: 0)
        }

        var mean: Double = 0
        var stdDev: Double = 0
        var minVal: Double = 0
        var maxVal: Double = 0

        // Use vDSP for optimized calculations on Apple Silicon
        vDSP_meanvD(values, 1, &mean, vDSP_Length(values.count))
        vDSP_minvD(values, 1, &minVal, vDSP_Length(values.count))
        vDSP_maxvD(values, 1, &maxVal, vDSP_Length(values.count))

        // Standard deviation
        var squaredDiffs = [Double](repeating: 0, count: values.count)
        var meanNeg = -mean
        vDSP_vsaddD(values, 1, &meanNeg, &squaredDiffs, 1, vDSP_Length(values.count))
        vDSP_vsqD(squaredDiffs, 1, &squaredDiffs, 1, vDSP_Length(values.count))
        var variance: Double = 0
        vDSP_meanvD(squaredDiffs, 1, &variance, vDSP_Length(values.count))
        stdDev = sqrt(variance)

        return Stats(mean: mean, stdDev: stdDev, min: minVal, max: maxVal)
    }
}
