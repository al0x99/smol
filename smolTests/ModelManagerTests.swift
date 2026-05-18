import Foundation
import Testing
@testable import smol

// MARK: - ModelManager pure-logic tests
//
// The download / file-management flow needs URLSession, the
// FileManager, the user's Application Support directory, and the
// @MainActor singleton, so we don't drive it end-to-end here.
// Instead we cover:
//   - `evaluateRAMRequirement`: the pure rule extracted from
//     `canRunModel`, including the boundary that used to display
//     a confusing truncated "available N GB" via `Int(totalRAMGB)`.
//   - `LLMModel.formattedSize`: the MB/GB switch the model picker
//     uses for every catalog entry.
//   - The MLX-format gate in `downloadModel`: tests the *outward*
//     contract that an MLX model cannot be downloaded as a single
//     file, without exercising the live URLSession.

// MARK: - evaluateRAMRequirement

struct ModelManagerRAMTests {

    private typealias MM = ModelManager

    private let reqs = ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 25)

    @Test func belowMinRAMReturnsCannotRun() {
        let result = MM.evaluateRAMRequirement(totalRAMGB: 3.9, requirements: reqs)
        #expect(result.canRun == false)
        #expect(result.warning?.contains("Insufficient RAM") == true)
        // The fractional value must be preserved — previously `Int`
        // rounded 3.9 down to 3 and the user saw "available 3 GB".
        #expect(result.warning?.contains("3.9 GB") == true)
    }

    @Test func exactlyAtMinRAMIsRunnable() {
        // The check is `< Double(minRAM)`, so 4.0 satisfies the
        // requirement exactly. A user with a marketed-"4 GB" Mac
        // shouldn't be denied a model that lists 4 GB minimum.
        let result = MM.evaluateRAMRequirement(totalRAMGB: 4.0, requirements: reqs)
        #expect(result.canRun == true)
    }

    @Test func betweenMinAndRecommendedGetsWarning() {
        // Above minRAM but below recommended → can run, but with a
        // "may be slow" warning. The warning mentions the
        // recommended value so the user knows the target.
        let result = MM.evaluateRAMRequirement(totalRAMGB: 5.5, requirements: reqs)
        #expect(result.canRun == true)
        #expect(result.warning?.contains("below recommended") == true)
        #expect(result.warning?.contains("8 GB") == true)
    }

    @Test func exactlyAtRecommendedGetsNoWarning() {
        // 8.0 is at the inclusive lower bound of the "good"
        // bucket — pin so the boundary doesn't drift.
        let result = MM.evaluateRAMRequirement(totalRAMGB: 8.0, requirements: reqs)
        #expect(result.canRun == true)
        #expect(result.warning == nil)
    }

    @Test func wellAboveRecommendedGetsNoWarning() {
        let result = MM.evaluateRAMRequirement(totalRAMGB: 32.0, requirements: reqs)
        #expect(result.canRun == true)
        #expect(result.warning == nil)
    }

    @Test func marketedSixteenGBMacReports149IsRunnable() {
        // The motivating real-world case: a Mac marketed as
        // "16 GB" reports ~14.9 GiB after the OS reservation.
        // With minRAM=8 / recommendedRAM=16 (Mistral 7B), the user
        // should be able to run the model with a "may be slow"
        // warning, *not* be told they have insufficient RAM. And
        // the warning copy must mention 14.9, not 14.
        let mistralReqs = ModelRequirements(minRAM: 8, recommendedRAM: 16, estimatedSpeed: 10)
        let result = MM.evaluateRAMRequirement(totalRAMGB: 14.9, requirements: mistralReqs)
        #expect(result.canRun == true)
        #expect(result.warning?.contains("below recommended") == true)
    }
}

// MARK: - LLMModel.formattedSize

struct LLMModelFormattedSizeTests {

    private func model(sizeBytes: UInt64) -> LLMModel {
        LLMModel(
            id: "t",
            name: "t",
            description: "t",
            size: .tiny,
            sizeBytes: sizeBytes,
            downloadURL: "https://example.com/t.gguf",
            requirements: ModelRequirements(minRAM: 1, recommendedRAM: 1, estimatedSpeed: 1),
            capabilities: [.chat],
            format: .gguf
        )
    }

    @Test func subGigabyteShowsInMegabytes() {
        // 350 MB (one of the catalog's tiny models, Qwen2 0.5B).
        // sizeGB = 0.326... < 1 → falls into the MB branch.
        #expect(model(sizeBytes: 350_000_000).formattedSize == "334 MB")
    }

    @Test func justUnderOneGigabyteShowsInMegabytes() {
        // 1,073,741,823 bytes = 1 byte under 1 GiB. The `>= 1`
        // check is strict at the GiB boundary so this is still MB.
        let almostOneGB: UInt64 = 1_073_741_823
        let formatted = model(sizeBytes: almostOneGB).formattedSize
        #expect(formatted.hasSuffix(" MB"))
    }

    @Test func exactlyOneGibibyteShowsAsOneGigabyte() {
        // 1 GiB exactly hits the threshold. Pin both the format
        // and that the unit is "GB" (not "GiB").
        #expect(model(sizeBytes: 1_073_741_824).formattedSize == "1.0 GB")
    }

    @Test func multiGigabyteModelShowsOneDecimal() {
        // Mistral 7B at 4.1 GB. The format is "%.1f GB" so the
        // trailing decimal is preserved even when it's a clean
        // multiple of 100 MB.
        let formatted = model(sizeBytes: 4_100_000_000).formattedSize
        #expect(formatted.hasSuffix(" GB"))
        // 4_100_000_000 / 1_073_741_824 ≈ 3.82
        #expect(formatted == "3.8 GB")
    }

    @Test func zeroSizedModelShowsZeroMB() {
        // Edge: degenerate metadata. We expect "0 MB", not a
        // crash or "0.0 GB".
        #expect(model(sizeBytes: 0).formattedSize == "0 MB")
    }
}

// MARK: - MLX-format download gate

struct ModelManagerMLXDownloadTests {

    private func mlxModel() -> LLMModel {
        LLMModel(
            id: "qwen3-4b-mlx",
            name: "Qwen3 4B (MLX)",
            description: "test",
            size: .medium,
            sizeBytes: 2_500_000_000,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
            requirements: ModelRequirements(minRAM: 4, recommendedRAM: 8, estimatedSpeed: 40),
            capabilities: [.chat],
            format: .mlx
        )
    }

    @Test @MainActor func mlxModelDownloadThrowsFormatNotSupported() async {
        // The pre-fix flow silently downloaded the HuggingFace repo
        // *webpage* and saved it as `<id>.gguf`, marking the model
        // as "downloaded" until inference time caught the lie. The
        // gate is checked before any state mutation in
        // `downloadModel`, so calling it on the singleton is safe
        // for tests.
        let model = mlxModel()
        let manager = ModelManager.shared

        do {
            try await manager.downloadModel(model)
            Issue.record("Expected downloadModel(mlxModel) to throw, but it returned normally")
        } catch let error as ModelError {
            // We check for the exact case rather than just any
            // error — a bug that changed the gate to throw
            // `.invalidURL` (e.g. because the MLX repo URL parses
            // fine but the file under it doesn't) would still feel
            // like a "download failed" from the user's seat but
            // would lose the specific copy explaining MLX isn't
            // supported yet.
            switch error {
            case .formatNotSupported(let message):
                #expect(message.contains("MLX"))
            default:
                Issue.record("Expected .formatNotSupported, got \(error)")
            }
        } catch {
            Issue.record("Expected ModelError, got \(error)")
        }

        // The singleton's downloading state must be untouched —
        // the gate runs before any `isDownloading = true`.
        #expect(manager.isDownloading == false)
    }
}
