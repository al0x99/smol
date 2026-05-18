# Changelog

All notable changes to **smol** are documented here.
This project adheres to [Semantic Versioning](https://semver.org/) and
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [Unreleased]

### Added
- `smolTests/SystemMonitorHealthTests.swift` — 18 tests pinning every
  rule in `SystemMonitor.calculateHealth`'s threshold ladder, every
  boundary condition (1 GB swap exact, 80% pressure exact, 80 °C exact),
  the singular/plural grammar for the suspicious-process count, and the
  priority ordering between competing rules (heavy-swap-beats-pressure,
  critical-memory-beats-hot-at-idle, swap-warning-beats-pressure-warning,
  pressure-warning-beats-suspicious, suspicious-beats-elevated-temperature).
  Suite is now 67 tests.

### Changed
- `SystemMonitor.calculateHealth` was promoted from a private instance
  method to a pure `static` function that takes its inputs explicitly
  (`memoryInfo`, `temperature`, `cpuIdlePercent`,
  `suspiciousProcessCount`). The threshold ladder is now testable
  without standing up a real `SystemMonitor` (which would also kick off
  its 2-second polling Timer). The single in-app caller in
  `updateMetrics()` is otherwise unchanged.
- Moved `import UserNotifications` to the top of `SystemMonitor.swift`.
  It was the only `import` statement floating at the bottom of any
  service file in the project.
- `TemperatureMonitor` is now pinned to `@MainActor`. Every caller (the
  menu-bar `SystemMonitor` timer and the `TemperatureTab` view) already
  runs on the main actor, and the prior implementation had no
  synchronisation on `smcConnection` / `temperatureHistory` — a Swift 6
  hazard waiting to surface as soon as any background caller showed up.
- `TemperatureMonitor.getAllSensors()` now caches its result for 1 s.
  `SystemMonitor` polls every 2 s and the Temperature tab polls every 2 s
  independently; without the cache, opening the tab doubled the SMC scan
  rate (and the IOKit round-trips per scan are non-trivial).
- SMC four-char type codes (`sp78`, `sp87`, `sp5a`, `sp69`, `flt`, `fpe2`)
  are now resolved once at `TemperatureMonitor.init()` instead of via
  `stringToFourCharCode` on every key on every poll. With 70+ sensor keys
  scanned every 2 s that was a measurable per-tick allocation tax.
- `stringToFourCharCode` is now `nonisolated static` so it is callable
  from `init()` before `self` is fully formed.

### Fixed
- **`TemperatureMonitor.getSmartFallback()` no longer feeds itself.** The
  previous code wrote the fallback estimate back into
  `temperatureHistory`, which `getSmartFallback()` then blended into the
  next fallback. The bias compounded: after a few SMC-unavailable ticks
  the displayed temperature drifted asymptotically toward `baseTemp`
  regardless of what the machine was actually doing.
- **Duplicate sensor keys in `sensorDatabase` removed.** `Ts1P`, `Ts0P`,
  `Th0H`, and `Ts0S` were listed in two different categories each. The
  second entry overwrote the first's category in
  `getSensorsByCategory()`, so on M-series machines the labels (e.g. "Right
  Thunderbolt Ports Proximity") appeared under the wrong category.
- `TemperatureMonitor.writeDebugToFile()` no longer triple-walks the
  sensor list. It groups the already-fetched array locally instead of
  calling `getSensorsByCategory()`, which would re-enter `getAllSensors()`
  and re-execute the full SMC scan.
- Translated remaining Italian debug-log strings in `TemperatureMonitor`
  (`SMC connesso`, `Test chiavi`, `non trovata`, `chiavi SMC`, `tipo=`).

### Removed
- `TemperatureMonitor.deinit` / `closeSMCConnection()` — dead code for a
  singleton whose lifetime is the process lifetime. The kernel reclaims
  `io_connect_t` at exit, and the `deinit` would have needed to be
  `nonisolated`, conflicting with the new `@MainActor` boundary.

### Added
- `smolTests/SystemHealthTests.swift` — coverage for `SystemHealth` styling and
  equality, `MemoryInfo` pressure-level thresholds, `ProcessInfo.isAnomaly`
  boundary conditions, and `AlertSettings` presets / `applyPreset` /
  `resetToDefaults`. Brings the suite to 41 tests.
- `smolTests/FanInfoTests.swift` — pins `FanMonitor.FanInfo.rpmPercent`
  edge cases (at min, at max, below min, above max, degenerate `min ==
  max` and `min > max`, negative readings) plus the three
  `SystemMonitor.TemperatureTrend` glyphs. Suite is now 51 tests.
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
- **Menu-bar temperature no longer flickers ±40°C between ticks.**
  `TemperatureMonitor.getCPUTemperature()` now returns the hottest core
  instead of the mean. On Apple Silicon per-core sensors drop in and out
  of the readable set every poll as cores park (`getAllSensors()` drops
  anything reading 0 or out-of-range), so the divisor of the previous
  mean was non-constant and the displayed value jumped 30–40°C. The max
  is stable across that churn and is also the value that drives thermal
  throttling and fan ramp.
- **Parked M-series fans now spin up on Max / Manual.** On Apple Silicon
  the SMC firmware refuses `F*Tg` writes while a fan is parked at 0 RPM,
  which made our "Max" button (and any manual target) a no-op when the
  system was cool. The helper now lifts `F*Mn` (per-fan minimum) before
  the target write — a hard floor the thermal controller is required to
  honour regardless of `F*Md` / `FOFC`. This is the same trick TG Pro and
  Macs Fan Control use on M-series. New methods
  `SMCAccess.wakeParkedFan(index:rpm:)` and
  `SMCAccess.restoreFanMinimum(index:)`; wake-up is invoked from
  `FanHelperService.setFanRPM` only when `F*Ac == 0`.
- **Auto-mode ramp-down no longer hangs for 30+ seconds after Max.** The
  helper now caches the original `F*Mn` on the first wake and restores it
  in `setFanMode(0)` before releasing manual control. Without the
  restore, the lifted floor stayed in effect and the auto controller
  could not actually ramp down. `SMCAccess.hasCachedMinimum(index:)`
  drives the conditional restore so we only touch `F*Mn` for fans we
  actually woke.
- **`SMCAccess.setFanTargetRPM` trusts the IOKit write ack instead of
  failing on the `F*Tg` readback.** Right after a write to a just-woken
  fan, the SMC reports the old (0) target for a few hundred milliseconds
  while the fan transitions out of park mode; the previous code treated
  that delay as a failure and returned `false` even when the write had
  succeeded. We still log the readback for diagnostics and still attempt
  the `F*Fc` belt-and-braces fallback when the readback is suspicious,
  but no longer reject the call.
- **`FanMonitor.installHelper` now calls `service.unregister()` before
  `service.register()` when the daemon is already enabled.** Calling
  `register()` on an enabled service is a no-op, so launchd kept the
  previously-launched helper alive even after the helper binary on disk
  had been replaced by a new build. The unregister/register round-trip
  is the supported way to force a refresh.
- **Auto mode now drops the target to the fan minimum before releasing
  force mode.** `FanMonitor.setFanModeViaHelper(.system)` calls
  `setAllFansToRPM(helper:rpmType: .min)` first, so the SMC auto
  controller takes over with a low target rather than coasting at
  whatever max we just commanded. New `.min` case in the private
  `RPMType` enum.
- Swift 6 main-actor isolation warnings in the test target: added
  `@MainActor` on `SystemHealthTests`, `AIModelsTests`,
  `AnomalyDetectorTests`, `NaturalLanguageProcessorTests`,
  `SystemReportGeneratorTests`, and `AIServicesIntegrationTests`.
- **Crash-safe `F*Mn` restore.** The helper now mirrors any lifted
  per-fan minimum to `/tmp/com.smol.fanhelper/originalMinRPM.<n>` and
  restores it from disk at next start, so a crash between wake and
  restore can no longer leave the fan minimum permanently raised. `/tmp`
  is cleared on reboot — the same lifetime SMC `F*Mn` resets at.
- **Helper concurrency hardening.** `originalMinRPM` and `keyInfoCache`
  are now serialised behind an `NSLock` inside `SMCAccess`. NSXPC
  dispatches incoming method calls from a thread pool, so back-to-back
  `setFanRPM`/`setFanMode` requests could otherwise race the wake/
  restore bookkeeping. `wakeParkedFan` also bails out cleanly when
  `F*Mx` reads 0 (unknown ceiling) instead of clamping against zero.
- **XPC timeouts in `FanMonitor` now have real teeth.** The previous
  code wrapped `synchronousRemoteObjectProxyWithErrorHandler` calls
  with a `DispatchSemaphore.wait(timeout:)`, but the synchronous proxy
  itself blocks until the connection invalidates — the surrounding
  semaphore was already signalled by the time `wait` ran. Mode-change
  and fan-info paths now use the async proxy so the 1–2 s timeouts
  actually fire when the helper hangs.
- **Mode changes routed through a private serial queue.** A rapid
  double-tap on a fan-mode button used to spawn two
  `setFanModeViaHelper` runs on `DispatchQueue.global(.userInitiated)`,
  each pinning a worker thread behind multiple multi-second semaphores
  and starving XPC reply delivery. A dedicated
  `com.smol.fanmonitor.control` serial queue serialises them.
- **Dropped wasteful `debugEnumerateKeys` from helper ping path.** That
  probe enumerates up to 1000 SMC keys synchronously in the root
  daemon, and its `@escaping` reply closure pinned the XPC proxy past
  quit. The ping now only verifies connectivity.

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
