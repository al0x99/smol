import Foundation
import CoreML
import CreateML
import Accelerate
import Combine
import TabularData
import os

/// ML engine for on-device anomaly detection
/// Uses MLBoostedTreeRegressor (Create ML) for training and Core ML for inference
@MainActor
class MLAnomalyEngine: ObservableObject {
    static let shared = MLAnomalyEngine()

    // MARK: - Published State

    @Published var isModelTrained = false
    @Published var isTraining = false
    @Published var trainingProgress: Double = 0
    @Published var modelAccuracy: Double = 0
    @Published var lastPrediction: AnomalyPrediction?

    // MARK: - ML Models

    private var cpuModel: MLModel?
    private var memoryModel: MLModel?
    private var temperatureModel: MLModel?

    // Training data storage
    private var trainingData: [SystemMetricSample] = []
    private let minTrainingSamples = 500 // ~16 minutes of data at 2s
    private let maxTrainingSamples = 10000

    // Model URLs
    private let modelsDirectory: URL

    // MARK: - Types

    struct SystemMetricSample: Codable {
        let timestamp: Date
        let cpuUsage: Double
        let memoryPressure: Double
        let temperature: Double
        let isAnomaly: Bool // Label for supervised learning
    }

    struct AnomalyPrediction {
        let isAnomaly: Bool
        let confidence: Double
        let anomalyType: AnomalyType?
        let predictedCPU: Double
        let predictedMemory: Double
        let predictedTemp: Double

        enum AnomalyType: String {
            case cpuSpike = "CPU Spike"
            case memoryLeak = "Memory Leak"
            case thermalThrottling = "Thermal"
            case combined = "Multiple"
        }
    }

    // MARK: - Initialization

    init() {
        // Setup models directory in app support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("smol/MLModels", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Load existing models if available
        Task {
            await loadExistingModels()
        }
    }

    // MARK: - Data Collection

    /// Adds a sample for training
    func addSample(cpu: Double, memory: Double, temp: Double, isAnomaly: Bool = false) {
        let sample = SystemMetricSample(
            timestamp: Date(),
            cpuUsage: cpu,
            memoryPressure: memory,
            temperature: temp,
            isAnomaly: isAnomaly
        )

        trainingData.append(sample)

        // Limit the size
        if trainingData.count > maxTrainingSamples {
            trainingData.removeFirst(trainingData.count - maxTrainingSamples)
        }

        // Save periodically
        if trainingData.count % 100 == 0 {
            saveTrainingData()
        }
    }

    /// Number of collected samples
    var samplesCollected: Int {
        trainingData.count
    }

    /// Indicates if there is enough data for training
    var hasEnoughDataForTraining: Bool {
        trainingData.count >= minTrainingSamples
    }

    // MARK: - Training with Create ML Components

    /// Trains the models with collected data using Create ML Components
    func trainModels() async throws {
        guard hasEnoughDataForTraining else {
            throw MLError.insufficientData(required: minTrainingSamples, available: trainingData.count)
        }

        isTraining = true
        trainingProgress = 0

        do {
            // 1. Prepare data as DataFrame
            trainingProgress = 0.1
            let dataFrame = prepareDataFrame()

            // Split 80/20 for training and validation
            let (trainDF, testDF) = splitDataFrame(dataFrame, ratio: 0.8)

            // 2. Train the CPU model
            trainingProgress = 0.3
            cpuModel = try await trainComponentsModel(
                trainingData: trainDF,
                targetColumn: "cpuUsage",
                featureColumns: ["hour", "minute", "dayOfWeek", "memoryPressure", "temperature"]
            )

            // 3. Train the Memory model
            trainingProgress = 0.5
            memoryModel = try await trainComponentsModel(
                trainingData: trainDF,
                targetColumn: "memoryPressure",
                featureColumns: ["hour", "minute", "dayOfWeek", "cpuUsage", "temperature"]
            )

            // 4. Train the Temperature model
            trainingProgress = 0.7
            temperatureModel = try await trainComponentsModel(
                trainingData: trainDF,
                targetColumn: "temperature",
                featureColumns: ["hour", "minute", "dayOfWeek", "cpuUsage", "memoryPressure"]
            )

            // 5. Evaluate accuracy on test data
            trainingProgress = 0.9
            modelAccuracy = evaluateModels(testData: testDF)

            // 6. Save the models
            try saveModels()

            trainingProgress = 1.0
            isModelTrained = true
            isTraining = false

        } catch {
            isTraining = false
            throw error
        }
    }

    /// Prepare DataFrame from trainingData
    private func prepareDataFrame() -> DataFrame {
        let calendar = Calendar.current

        var hourColumn: [Double] = []
        var minuteColumn: [Double] = []
        var dayOfWeekColumn: [Double] = []
        var cpuUsageColumn: [Double] = []
        var memoryPressureColumn: [Double] = []
        var temperatureColumn: [Double] = []
        var isAnomalyColumn: [Double] = []

        for sample in trainingData {
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: sample.timestamp)
            hourColumn.append(Double(components.hour ?? 0))
            minuteColumn.append(Double(components.minute ?? 0))
            dayOfWeekColumn.append(Double(components.weekday ?? 0))
            cpuUsageColumn.append(sample.cpuUsage)
            memoryPressureColumn.append(sample.memoryPressure)
            temperatureColumn.append(sample.temperature)
            isAnomalyColumn.append(sample.isAnomaly ? 1.0 : 0.0)
        }

        var df = DataFrame()
        df.append(column: Column(name: "hour", contents: hourColumn))
        df.append(column: Column(name: "minute", contents: minuteColumn))
        df.append(column: Column(name: "dayOfWeek", contents: dayOfWeekColumn))
        df.append(column: Column(name: "cpuUsage", contents: cpuUsageColumn))
        df.append(column: Column(name: "memoryPressure", contents: memoryPressureColumn))
        df.append(column: Column(name: "temperature", contents: temperatureColumn))
        df.append(column: Column(name: "isAnomaly", contents: isAnomalyColumn))

        return df
    }

    /// Split DataFrame into training and test
    private func splitDataFrame(_ df: DataFrame, ratio: Double) -> (DataFrame, DataFrame) {
        let shuffled = df.randomSplit(by: ratio)
        // Convert slices to complete DataFrames
        return (DataFrame(shuffled.0), DataFrame(shuffled.1))
    }

    /// Train a model using Create ML with MLBoostedTreeRegressor
    private func trainComponentsModel(
        trainingData: DataFrame,
        targetColumn: String,
        featureColumns: [String]
    ) async throws -> MLModel {

        // Use MLBoostedTreeRegressor which is the stable API for training
        // Note: the warning about deprecated init is a known Apple API issue
        // that has no complete non-deprecated init. We use the recommended approach.
        var params = MLBoostedTreeRegressor.ModelParameters(validation: .none)
        params.maxDepth = 6
        params.maxIterations = 100
        params.minLossReduction = 0.0
        params.minChildWeight = 1.0
        params.stepSize = 0.3
        params.earlyStoppingRounds = nil
        params.rowSubsample = 1.0
        params.columnSubsample = 1.0

        let regressor = try MLBoostedTreeRegressor(
            trainingData: trainingData,
            targetColumn: targetColumn,
            featureColumns: featureColumns,
            parameters: params
        )

        // Export as Core ML model
        let modelPath = modelsDirectory.appendingPathComponent("\(targetColumn)_temp.mlmodel")

        // Write the model
        try regressor.write(to: modelPath)

        // Compile for runtime
        let compiledURL = try await MLModel.compileModel(at: modelPath)
        return try MLModel(contentsOf: compiledURL)
    }

    /// Evaluate model accuracy
    private func evaluateModels(testData: DataFrame) -> Double {
        guard let cpuModel = cpuModel,
              let memoryModel = memoryModel,
              let temperatureModel = temperatureModel else {
            return 0
        }

        var totalError = 0.0
        var count = 0

        // Extract columns (DataFrame columns are not optional)
        let cpuCol = testData["cpuUsage", Double.self]
        let memCol = testData["memoryPressure", Double.self]
        let tempCol = testData["temperature", Double.self]
        let hourCol = testData["hour", Double.self]
        let minCol = testData["minute", Double.self]
        let dayCol = testData["dayOfWeek", Double.self]

        for i in 0..<testData.rows.count {
            guard let actualCPU = cpuCol[i],
                  let actualMemory = memCol[i],
                  let actualTemp = tempCol[i],
                  let hour = hourCol[i],
                  let minute = minCol[i],
                  let dayOfWeek = dayCol[i] else {
                continue
            }

            let input: [String: Any] = [
                "hour": hour,
                "minute": minute,
                "dayOfWeek": dayOfWeek,
                "cpuUsage": actualCPU,
                "memoryPressure": actualMemory,
                "temperature": actualTemp
            ]

            let modelInput = prepareModelInput(from: input)

            do {
                let cpuPred = try cpuModel.prediction(from: modelInput)
                let memPred = try memoryModel.prediction(from: modelInput)
                let tempPred = try temperatureModel.prediction(from: modelInput)

                if let predCPU = cpuPred.featureValue(for: targetColumn(for: "cpu"))?.doubleValue,
                   let predMem = memPred.featureValue(for: targetColumn(for: "memory"))?.doubleValue,
                   let predTemp = tempPred.featureValue(for: targetColumn(for: "temp"))?.doubleValue {

                    let cpuError = abs(actualCPU - predCPU) / 100.0
                    let memError = abs(actualMemory - predMem) / 100.0
                    let tempError = abs(actualTemp - predTemp) / 100.0

                    totalError += (cpuError + memError + tempError) / 3.0
                    count += 1
                }
            } catch {
                continue
            }
        }

        let accuracy = count > 0 ? max(0, 1 - totalError / Double(count)) * 100 : 0
        return accuracy
    }

    private func targetColumn(for type: String) -> String {
        switch type {
        case "cpu": return "cpuUsage"
        case "memory": return "memoryPressure"
        case "temp": return "temperature"
        default: return type
        }
    }

    // MARK: - Prediction

    /// Predicts whether current values are anomalous
    func predict(cpu: Double, memory: Double, temp: Double) -> AnomalyPrediction {
        guard isModelTrained,
              let cpuModel = cpuModel,
              let memoryModel = memoryModel,
              let temperatureModel = temperatureModel else {
            return heuristicPrediction(cpu: cpu, memory: memory, temp: temp)
        }

        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)

        let input: [String: Any] = [
            "hour": Double(components.hour ?? 0),
            "minute": Double(components.minute ?? 0),
            "dayOfWeek": Double(components.weekday ?? 0),
            "cpuUsage": cpu,
            "memoryPressure": memory,
            "temperature": temp
        ]

        let modelInput = prepareModelInput(from: input)

        do {
            let cpuPred = try cpuModel.prediction(from: modelInput)
            let memPred = try memoryModel.prediction(from: modelInput)
            let tempPred = try temperatureModel.prediction(from: modelInput)

            let predictedCPU = cpuPred.featureValue(for: "cpuUsage")?.doubleValue ?? cpu
            let predictedMem = memPred.featureValue(for: "memoryPressure")?.doubleValue ?? memory
            let predictedTemp = tempPred.featureValue(for: "temperature")?.doubleValue ?? temp

            let cpuDeviation = abs(cpu - predictedCPU)
            let memDeviation = abs(memory - predictedMem)
            let tempDeviation = abs(temp - predictedTemp)

            let cpuAnomaly = cpuDeviation > 25 && cpu > 70
            let memAnomaly = memDeviation > 20 && memory > 60
            let tempAnomaly = tempDeviation > 15 && temp > 75

            let isAnomaly = cpuAnomaly || memAnomaly || tempAnomaly

            var anomalyType: AnomalyPrediction.AnomalyType?
            var anomalyCount = 0
            if cpuAnomaly { anomalyType = .cpuSpike; anomalyCount += 1 }
            if memAnomaly { anomalyType = .memoryLeak; anomalyCount += 1 }
            if tempAnomaly { anomalyType = .thermalThrottling; anomalyCount += 1 }
            if anomalyCount > 1 { anomalyType = .combined }

            let maxDeviation = max(cpuDeviation / 100, memDeviation / 100, tempDeviation / 100)
            let confidence = isAnomaly ? min(maxDeviation * 2, 1.0) : 1 - maxDeviation

            let prediction = AnomalyPrediction(
                isAnomaly: isAnomaly,
                confidence: confidence,
                anomalyType: anomalyType,
                predictedCPU: predictedCPU,
                predictedMemory: predictedMem,
                predictedTemp: predictedTemp
            )

            lastPrediction = prediction
            return prediction

        } catch {
            return heuristicPrediction(cpu: cpu, memory: memory, temp: temp)
        }
    }

    /// Heuristic prediction (fallback without model)
    private func heuristicPrediction(cpu: Double, memory: Double, temp: Double) -> AnomalyPrediction {
        let cpuAnomaly = cpu > 85
        let memAnomaly = memory > 80
        let tempAnomaly = temp > 90

        let isAnomaly = cpuAnomaly || memAnomaly || tempAnomaly

        var anomalyType: AnomalyPrediction.AnomalyType?
        if cpuAnomaly { anomalyType = .cpuSpike }
        if memAnomaly { anomalyType = .memoryLeak }
        if tempAnomaly { anomalyType = .thermalThrottling }
        if [cpuAnomaly, memAnomaly, tempAnomaly].filter({ $0 }).count > 1 {
            anomalyType = .combined
        }

        return AnomalyPrediction(
            isAnomaly: isAnomaly,
            confidence: isAnomaly ? 0.6 : 0.8,
            anomalyType: anomalyType,
            predictedCPU: cpu,
            predictedMemory: memory,
            predictedTemp: temp
        )
    }

    // MARK: - Persistence

    private func prepareModelInput(from sample: [String: Any]) -> MLDictionaryFeatureProvider {
        let features: [String: MLFeatureValue] = sample.compactMapValues { value in
            if let doubleValue = value as? Double {
                return MLFeatureValue(double: doubleValue)
            }
            return nil
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features) else {
            // Return empty provider as fallback — prediction will fail gracefully
            return (try? MLDictionaryFeatureProvider(dictionary: [:])) ?? MLDictionaryFeatureProvider()
        }
        return provider
    }

    private func saveModels() throws {
        let metadata = ModelMetadata(
            trainedAt: Date(),
            samplesUsed: trainingData.count,
            accuracy: modelAccuracy
        )

        let metadataURL = modelsDirectory.appendingPathComponent("metadata.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL)
    }

    private func loadExistingModels() async {
        let metadataURL = modelsDirectory.appendingPathComponent("metadata.json")

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            loadTrainingData()
            return
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(ModelMetadata.self, from: data)

            let cpuURL = modelsDirectory.appendingPathComponent("cpuUsage_temp.mlmodelc")
            let memURL = modelsDirectory.appendingPathComponent("memoryPressure_temp.mlmodelc")
            let tempURL = modelsDirectory.appendingPathComponent("temperature_temp.mlmodelc")

            if FileManager.default.fileExists(atPath: cpuURL.path) {
                cpuModel = try MLModel(contentsOf: cpuURL)
            }
            if FileManager.default.fileExists(atPath: memURL.path) {
                memoryModel = try MLModel(contentsOf: memURL)
            }
            if FileManager.default.fileExists(atPath: tempURL.path) {
                temperatureModel = try MLModel(contentsOf: tempURL)
            }

            isModelTrained = cpuModel != nil && memoryModel != nil && temperatureModel != nil
            modelAccuracy = metadata.accuracy

        } catch {
            SmolLog.ai.error("Failed to load models: \(error.localizedDescription)")
        }

        loadTrainingData()
    }

    private func saveTrainingData() {
        let url = modelsDirectory.appendingPathComponent("training_data.json")
        do {
            let data = try JSONEncoder().encode(trainingData)
            try data.write(to: url)
        } catch {
            SmolLog.ai.error("Failed to save training data: \(error.localizedDescription)")
        }
    }

    private func loadTrainingData() {
        let url = modelsDirectory.appendingPathComponent("training_data.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            trainingData = try JSONDecoder().decode([SystemMetricSample].self, from: data)
        } catch {
            SmolLog.ai.error("Failed to load training data: \(error.localizedDescription)")
        }
    }

    /// Resets all data and models
    func reset() {
        trainingData = []
        cpuModel = nil
        memoryModel = nil
        temperatureModel = nil
        isModelTrained = false
        modelAccuracy = 0
        lastPrediction = nil

        try? FileManager.default.removeItem(at: modelsDirectory)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Types

    struct ModelMetadata: Codable {
        let trainedAt: Date
        let samplesUsed: Int
        let accuracy: Double
    }

    enum MLError: LocalizedError {
        case insufficientData(required: Int, available: Int)
        case trainingFailed(String)
        case modelNotFound

        var errorDescription: String? {
            switch self {
            case .insufficientData(let required, let available):
                return "Insufficient data: \(available)/\(required) samples"
            case .trainingFailed(let reason):
                return "Training failed: \(reason)"
            case .modelNotFound:
                return "Model not found"
            }
        }
    }
}
