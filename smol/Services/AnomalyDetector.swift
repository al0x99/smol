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
            // Build the expected range defensively: clamping the two
            // endpoints independently to [0, 100] can produce
            // `lower > upper` for pathological inputs (mean > 100 with
            // a small stdDev), which would trap `ClosedRange.init`.
            // We collapse such cases to a single-point range.
            let lower = max(0, stats.mean - stats.stdDev * 2)
            let upper = min(100, stats.mean + stats.stdDev * 2)
            return AIAnomaly(
                type: .cpuSpike,
                description: "CPU spike: \(Int(lastValue))% (average: \(Int(stats.mean))%)",
                detectedAt: Date(),
                confidence: min(zScore / 4, 1.0),
                relatedMetric: "CPU Usage",
                currentValue: lastValue,
                expectedRange: lower...max(lower, upper)
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

    /// Detect memory leak pattern using linear regression on the last
    /// 60 samples (~2 min at the 2 s polling cadence). Returns the
    /// R² goodness-of-fit when the slope crosses the leak threshold,
    /// `nil` otherwise. The threshold (0.1% per sample ≈ 3% per minute
    /// of compression pressure growth) is the same one the live engine
    /// uses to surface a `.memoryLeak` anomaly.
    private func detectMemoryLeak(_ values: [Double]) -> Double? {
        guard values.count >= 20 else { return nil }
        let recentValues = Array(values.suffix(60))

        guard let fit = Self.linearRegressionFit(recentValues), fit.slope > 0.1 else {
            return nil
        }
        return fit.rSquared
    }

    /// Pure least-squares fit over `y` vs the index `0..<n`. Returns
    /// `(slope, rSquared)` or `nil` if there are fewer than two samples.
    /// R² is clamped to [0, 1] to absorb floating-point drift — a
    /// least-squares slope guarantees ssRes ≤ ssTot analytically, but
    /// near-constant series can produce a tiny negative R² in practice.
    /// For a flat input (`ssTot == 0`) we conventionally return R² = 0,
    /// matching the prior implementation.
    static func linearRegressionFit(_ values: [Double]) -> (slope: Double, rSquared: Double)? {
        guard values.count >= 2 else { return nil }

        let n = Double(values.count)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0
        for (i, y) in values.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        // `denominator` is the sum of squared deviations of indices,
        // which is strictly positive for n ≥ 2 — but compute defensively.
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        let intercept = yMean - slope * xMean

        var ssRes = 0.0
        var ssTot = 0.0
        for (i, y) in values.enumerated() {
            let predicted = slope * Double(i) + intercept
            ssRes += (y - predicted) * (y - predicted)
            ssTot += (y - yMean) * (y - yMean)
        }
        let rawRSquared = ssTot > 0 ? 1 - (ssRes / ssTot) : 0
        return (slope, max(0, min(1, rawRSquared)))
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

    /// Detect oscillations in the signal — wraps the pure
    /// `oscillationScore` static with the engine's calibrated 10-unit
    /// "significant change" threshold.
    private func detectOscillation(_ values: [Double]) -> Double {
        guard values.count >= 10 else { return 0 }
        return Self.oscillationScore(values, minChangeMagnitude: 10)
    }

    /// Count direction reversals among "significant" sample-to-sample
    /// jumps (those whose magnitude exceeds `minChangeMagnitude`) and
    /// normalise to [0, 1] — 5+ reversals saturate the score. Smaller
    /// fluctuations are ignored so that micro-noise on a stable signal
    /// doesn't masquerade as oscillation.
    static func oscillationScore(_ values: [Double], minChangeMagnitude: Double) -> Double {
        guard values.count >= 2 else { return 0 }

        var changes = 0
        var previousDirection: Int? = nil

        for i in 1..<values.count {
            let diff = values[i] - values[i - 1]
            if abs(diff) > minChangeMagnitude {
                let direction = diff > 0 ? 1 : -1
                if let prev = previousDirection, prev != direction {
                    changes += 1
                }
                previousDirection = direction
            }
        }

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
