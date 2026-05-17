# Changelog

All notable changes to **smol** are documented here.
This project adheres to [Semantic Versioning](https://semver.org/) and
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [Unreleased]

### Added
- `smolTests/SystemHealthTests.swift` — coverage for `SystemHealth` styling and
  equality, `MemoryInfo` pressure-level thresholds, `ProcessInfo.isAnomaly`
  boundary conditions, and `AlertSettings` presets / `applyPreset` /
  `resetToDefaults`. Brings the suite to 41 tests.
- VoiceOver labels on the `MenuBarExtra` widget (announces system health,
  CPU%, and temperature), on the top-processes refresh button, on each
  suspicious-process terminate button (named after the target process), on
  fan-mode buttons (with `.isSelected` trait), and on each fan row
  (announces RPM and percent of max).
- `SystemMonitor.menuBarAccessibilityLabel` — VoiceOver-friendly summary
  string built from the same live state as the visible widget.

### Changed
- Translated remaining user-visible Italian strings to English:
  - `SystemHealth.description` ("Sistema OK" → "System healthy", etc.).
  - `SystemMonitor.calculateHealth` reason strings (swap, memory pressure,
    temperature, suspicious-process counts).
  - Notification title and body in `SystemMonitor.sendNotification`.
  - All `SmartAdvisor` advice titles and descriptions.
  - `SystemReportGenerator` section titles, summaries, recommendations, and
    exported-text headers.
  - `NaturalLanguageProcessor` responses (CPU, memory, temperature,
    why-slow, what-to-close, anomaly, general). Bilingual keyword matching
    is preserved so Italian queries still resolve to the correct intent.
  - `LocalLLMEngine` health descriptors and response text; default
    `NLEmbedding` language preference is now English with Italian fallback.
  - `AnomalyDetector` anomaly descriptions and in-code comments.
  - `TemperatureTab` inline comments.
- `FanMonitor.debugLog` no longer writes a parallel `/tmp/smol_app_debug.log`
  file. Logging goes through unified `SmolLog.fan` only. This also removes the
  last `data(using: .utf8)!` force unwrap in the app target.
- `LocalLLMEngine.saveContext`/`loadContext` route through a guarded
  `contextFileURL` computed property, eliminating two
  `FileManager.urls(...).first!` force unwraps.
- `KnownBloatware.json` reasons translated to English so user-visible
  bloatware alerts no longer leak Italian.
- `LocalLLMEngine.buildLearningResponse` no longer force-unwraps
  `prediction.anomalyType` (replaced with optional `map`).
- `SMCAccess.keyToString` uses the non-failing `UnicodeScalar(UInt8)`
  initializer instead of force-unwrapping `UnicodeScalar(UInt32)`. Every
  masked byte is a valid Unicode scalar; the previous `!` was technically
  safe but type-system noise.
- `AlertSettings.presets` and `cpu*/minRunning*` tip strings translated to
  English. The "Balanced" preset still matches the documented defaults
  (regression-tested in `AlertSettingsTests.balancedPresetMatchesDefaults`).

### Removed
- `AIAdvice.Severity.color` (returned a String like "blue" / "red") —
  unused. `AIAssistantView.severityColor` produces SwiftUI `Color` values
  directly via its own switch.

### Fixed
- Swift 6 main-actor isolation warnings in the test target: added
  `@MainActor` on `SystemHealthTests`, `AIModelsTests`,
  `AnomalyDetectorTests`, `NaturalLanguageProcessorTests`,
  `SystemReportGeneratorTests`, and `AIServicesIntegrationTests`.

### Security
- **Privileged helper input validation.** Every XPC method that accepts a fan
  `index` now rejects out-of-range values (cap = 7) before any SMC key is
  constructed. `setFanRPM` clamps the requested RPM to `0...10000` to keep a
  hostile or buggy caller from writing arbitrary floats to the fan
  controller firmware.
- **Code-signing check switched from PID to audit token.** The XPC listener
  used to call `SecCodeCopyGuestWithAttributes` with the caller's PID, which
  is a TOCTOU race (PIDs are recycled). It now uses the connection's
  `audit_token_t`, which the kernel captures when the message is routed and
  cannot be spoofed by a later `exec`.
- **`SecCodeCheckValidity` now enforces `kSecCSCheckAllArchitectures`** so a
  crafted universal binary cannot bypass validation by signing only the
  inactive slice.
- **Removed startup self-tests.** The daemon no longer runs 20+ SMC write
  sequences at every process start, which removes the risk of leaving fan
  parameters in an abnormal state if the process crashed mid-sequence.
- **Removed three debug XPC methods** (`testFOFCSequences`, `searchFOFCKeys`,
  `testAlternativeControl`) that exposed exhaustive SMC mutation suites as
  first-class production endpoints. Nothing in the smol app called them.

### Changed
- `LLMInferenceManager` engines are now `private let` instead of optional
  `var`. This removes five force-unwraps and three no-op conditional casts,
  and turns "engine missing" from a runtime crash into a type-system
  impossibility.
- `FoundationModelEngine.cancelGeneration` uses `NSLock.withLock`, which is
  async-safe (the bare `lock()/unlock()` pair will be a hard error in the
  Swift 6 language mode).
- `CleanupView` now moves selected items to the **Trash** via
  `FileManager.trashItem(at:resultingItemURL:)` instead of permanently
  deleting with `removeItem`, and prompts for confirmation first.
- `CleanupView` system-folder filter now matches by **prefix**, not
  substring, so a third-party folder containing `"Apple"` in its name no
  longer slips through as system-owned.

### Removed
- ~750 lines of dead M4 reverse-engineering scaffolding in
  `com.smol.fanhelper/SMCAccess.swift` (`testFOFCSequences`,
  `debugSearchFOFCKeys`, `testClampMinMax`, `testAlternativeFanControl`,
  plus their `verifyKey`/`verifyTargetRPM` helpers). The file is now 790
  lines, down from 1568.

### Added
- `.github/workflows/ci.yml` — macOS GitHub Actions runner: build, fail on
  any new warning, run `smolTests`.
- `CONTRIBUTING.md` — ground rules, PR checklist, log subsystem reference.
- `CHANGELOG.md` (this file).

### Fixed
- `scripts/release.sh` no longer swallows `xcodebuild` errors when
  `xcpretty` is installed, and falls back to plain output when it is not.

## [1.0.0] — 2026-04-16

Initial public release.

- Menu-bar widget with colour-coded system health (CPU, memory pressure,
  swap, temperature).
- Dashboard tabs: Overview, Processes, Alerts, Temperature, Fans, System,
  AI Assistant, Settings.
- Privileged XPC helper for SMC fan read/write (Apple Silicon + Intel).
- AI Assistant with three backends: Apple FoundationModels (macOS 26+),
  MLX (Apple Silicon), OpenRouter (cloud).
- CoreML-based anomaly detection.
- Bloatware database, ghost-process detection, cleanup tool.
- Signed and notarised DMG pipeline (`scripts/release.sh`).

[Unreleased]: https://github.com/al0x99/smol/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/al0x99/smol/releases/tag/v1.0.0
