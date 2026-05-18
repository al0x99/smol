# Changelog

All notable changes to **smol** are documented here.
This project adheres to [Semantic Versioning](https://semver.org/) and
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [Unreleased]

### Added
- `smolTests/SystemReportGeneratorTests.swift` — 19 tests across
  three structs: `SystemReportHealthScoreTests` (10) pins each CPU /
  memory / temp deduction band at the exact boundary (40/60/80 for
  CPU and memory, 70/80/90 for temp), the disjoint critical/warning
  anomaly bands including the load-bearing `<= 0.8` upper bound on
  warning and the `> 0.5` lower bound, and the `[0, 100]` clamp;
  `SystemReportHealthStatusLabelTests` (6) pins every excellent /
  good / moderate / poor / critical label at its inclusive low
  bound, including the 89 → "good" inclusive upper bound below
  "excellent"; `SystemReportExportAsTextTests` (3) covers the
  RECOMMENDATIONS-underline regression (see Fixed below), 1-based
  recommendation numbering, and the "Health score: N/100" line that
  ships in user-copy-pastable exports. Suite is now 222 tests.

### Fixed
- **`SystemReportGenerator.exportAsText` no longer glues the first
  recommendation to the underline.** The RECOMMENDATIONS heading
  was emitted via a triple-quoted literal whose closing `"""` sat on
  the line immediately after `────────────────`. Swift strips the
  newline before the closing `"""`, so the literal ended without a
  trailing `\n` and the next `text += "1. \(rec)\n"` produced
  `────────────────1. First rec` on the same line. The fix is an
  explicit blank line before the closing `"""`, with a comment
  flagging the load-bearing whitespace.

### Changed
- `SystemReportGenerator.calculateHealthScore` is now a static so
  the rule can be exercised without instantiating the generator.
  The instance method remains for source-compat with the existing
  `generate(...)` call site and forwards to the static.
- `SystemReportGenerator.healthStatusLabel(forScore:)` is the new
  home for the summary line's bucket boundaries (90/70/50/30). The
  inline `switch` in `generateSummary` was the only place these
  boundaries lived; pulling them out lets the band edges be pinned
  directly.

### Added
- `smolTests/MLAnomalyEngineTests.swift` — 23 tests across three
  structs covering the pure decision logic that runs around the Core
  ML / Create ML inference: `MLAnomalyEngineClassifyTests` (8) pins
  every combination of the three boolean anomaly flags through
  `classifyAnomaly`, including the four `.combined` cases where the
  prior sequential-overwrite implementation would have landed on the
  wrong type before the count-based fix kicked in;
  `MLAnomalyEngineConfidenceTests` (7) pins `mlConfidence` at both
  ends of the deviation axis for the anomaly and non-anomaly
  branches, with the headline test being the regression check for
  deviations > 1.0 in the non-anomaly branch (the bug fixed below);
  `MLAnomalyEngineHeuristicTests` (8) pins the strict-`>` boundary at
  CPU=85, memory=80, temp=90, the `.combined` collapse for any 2+
  signals, and the predicted-values-echo-inputs contract that
  downstream expected-range badges depend on. Suite is now 184 tests.

### Fixed
- **`MLAnomalyEngine.predict` no longer publishes negative confidence
  values when the trained model misfires.** The formula was
  `isAnomaly ? min(maxDeviation*2, 1) : 1 - maxDeviation`. When the
  model produced a wildly-off prediction whose absolute deviation
  was above 1.0 but the actual metric didn't cross the anomaly
  threshold (e.g. predicted CPU 200%, actual 0% → deviation 200/100
  = 2.0, but `cpu > 70` is false so `isAnomaly = false`), the
  non-anomaly branch evaluated to `1 - 2.0 = -1.0` and that negative
  value flowed into `AnomalyPrediction.confidence` and eventually
  into the `AIAnomaly.confidence` shown to the user. The confidence
  is now clamped to `[0, 1]` via the extracted `mlConfidence` static.

### Changed
- `MLAnomalyEngine`'s anomaly-type priority rule lives in one place
  now. The ML path (lines ~370) and the heuristic path (lines ~405)
  both used the same sequential-overwrite-then-fix-with-`.combined`
  pattern, which was hard to read and impossible to test without
  spinning up the full `predict` flow. Both paths now call the same
  `classifyAnomaly(cpuAnomaly:memAnomaly:tempAnomaly:)` static.
- `MLAnomalyEngine.heuristicPrediction` is `nonisolated static`, so
  unit tests don't have to hop to `@MainActor` or carry the
  engine's training-data state.

### Added
- `smolTests/ResourceTrackerTests.swift` — 22 tests across three
  structs covering the parts of `ResourceTracker` that don't depend on
  the live sampling Timer: `ResourceCostImpactLevelTests` (11) pins
  every boundary of the low/medium/high rule including the strict-`<`
  semantics that make 30%, 70%, 0.5 mWh, and 2.0 mWh fall into the
  *next* bucket; `ResourceTrackerLLMCostTests` (8) pins the per-`ModelSize`
  table (CPU%, MB, warning copy), the monotonic slowdown across sizes,
  and the spot-check arithmetic so the energy formula can't silently
  drift; `ResourceCostFormattingTests` (5) pins the sign handling in
  `description` (positive/negative/zero `memoryDelta` and absence of a
  `--` double-minus), the conditional `tokens` segment, and the
  emoji + label in `userFriendlyDescription`. Suite is now 161 tests.

### Fixed
- **`ResourceTracker.startTracking` no longer leaks the previous
  sampling timer when called re-entrantly.** Two services
  (`SmartAdvisor.analyze`, `LocalLLMEngine.process`) both grab
  `ResourceTracker.shared` and call `startTracking()`. If the second
  call landed before the first finished, the old `Timer` was simply
  overwritten — the runloop kept a strong reference so it stayed alive
  and kept appending samples to the post-reset array until the app
  exited. The implementation now invalidates the existing timer at the
  top of `startTracking()`.

### Changed
- `ResourceTracker.takeSnapshot` no longer runs the Mach kernel calls
  twice per sample. Previously it computed `cpuUsage` and
  `memoryPressure` once for the snapshot's own fields, then
  `estimateEnergyImpact()` re-ran `getCurrentCPUUsage()` and
  `getCurrentMemoryPressure()` to derive the energy estimate from the
  same numbers. At 100 ms sampling rate that doubled the measurement
  overhead — ironic for a resource *tracker*. The values are now
  computed once and passed through. `estimateEnergyImpact()` is gone.
- `ResourceTracker.ResourceCost.impactLevel` is now backed by a pure
  static `impactLevel(avgCPU:estimatedEnergy:)` so the bucket boundaries
  can be pinned without constructing a full `ResourceCost`. The
  computed property delegates to it — same rule, same output.

### Added
- `smolTests/NaturalLanguageProcessorIntentTests.swift` — 19 tests
  pinning the bilingual (EN/IT) keyword classifier and, critically,
  the question-mark fallback path (see Fixed below). Coverage:
  English/Italian phrasing for each of CPU / memory / temperature /
  why-slow / what-to-close / anomaly / process intents, the proper-
  noun extraction in the process branch, the case-insensitive "how"
  fallback for `.generalStatus`, the `?`-detection on a query whose
  body matches none of the keyword sets, and the gibberish fallback
  that emits the help prompt. Suite is now 139 tests.

### Fixed
- **`NaturalLanguageProcessor.analyzeWithNLP` now detects `?`
  questions.** The previous implementation walked NLTagger's
  lexical-class stream looking for `case .particle where word.contains("?")`
  to set `hasQuestion`, but `?` is tagged as `.punctuation`, never
  `.particle` — so the flag was dead code and Italian questions
  without a literal "come" keyword silently routed to `.unknown`.
  The detection is now a direct `query.contains("?")` against the
  raw string. The "how" / "come" keyword fallback also lowercases
  the query first, so `"How are we doing"` (capital H, no question
  mark) now correctly resolves to `.generalStatus`.

### Changed
- `NaturalLanguageProcessor.analyzeWithNLP` no longer collects the
  `topics` array of nouns it never read. The function dropped from
  ~25 lines of NLTagger enumeration to a three-line string check.

### Added
- `smolTests/SmartAdvisorTrendTests.swift` — 8 tests pinning the
  `SmartAdvisor.trend(in:windowMinutes:now:)` windowing logic
  (empty/single-sample → nil; descending series returns a negative
  delta so the live `trend > 10` filter behaves correctly; samples at
  the exact `windowMinutes` boundary are included; flat-in-window
  series returns 0 distinctly from nil; all-out-of-window returns
  nil). The static is `nonisolated`, so the tests don't need to hop
  to `@MainActor`. Suite is now 120 tests.

### Fixed
- **`SmartAdvisor.analyze` no longer risks trapping on a malformed
  `ClosedRange` in the ML-anomaly branch.** Three sites built
  `expectedRange` as `0 ... prediction.predictedX + margin` (or
  `30 ... ...` for temperature). An under-trained model can briefly
  emit negative or implausibly low predictions, in which case
  `predictedX + margin` falls below the lower bound and
  `ClosedRange.init` would trap. The upper bound is now clamped to be
  at least the lower bound.

### Changed
- `SmartAdvisor.calculateTrend` was renamed in spirit only: the
  doc-comment used to claim "percentage change" but the body always
  returned `last.value - first.value` — a *delta in raw value units*.
  The comment is now accurate, the function is split into a
  `@MainActor` thin instance method and a pure `nonisolated static
  trend(in:windowMinutes:now:)` that takes `now` explicitly so the
  windowing logic is testable.
- The static `trend(...)` tightens the "needs ≥ 2 samples *inside the
  window*" guard. The prior code returned `last - first = 0` for a
  one-sample window, which all live callers (filtered by
  `trend > N` for N > 0) then ignored — same end result, but
  returning `nil` is the more honest "no signal" semantic.

### Added
- `smolTests/AnomalyDetectorTests.swift` — 16 tests covering the two
  pure transforms behind the Anomalies tab: the slope+R² fit used by
  the "memory pressure keeps climbing" leak heuristic, and the
  direction-reversal counter that flags processes repeatedly starting
  and stopping. Includes regression guards for the edge cases that
  would otherwise misbehave silently — `[]` and `[42]` returning `nil`
  for the regression fit, a constant series returning slope 0 with
  R² = 0, R² clamped to [0, 1] regardless of input, the
  oscillation-magnitude threshold correctly ignoring sub-threshold
  jitter, and the 5-reversal saturation. Suite is now 112 tests.

### Fixed
- **`AnomalyDetector.detectCPUAnomaly` no longer risks trapping on a
  malformed `ClosedRange`.** The `expectedRange` was built as
  `max(0, mean - 2σ) ... min(100, mean + 2σ)`. For pathological inputs
  where the rolling mean exceeds 100% (a defensive edge case rather
  than something we observe in the wild) the lower bound could end up
  greater than the upper bound, and `ClosedRange.init` would trap. The
  endpoints are now ordered before constructing the range.
- `AnomalyDetector.linearRegressionFit` clamps R² to [0, 1]. The
  least-squares slope guarantees `ssRes ≤ ssTot` analytically, but
  near-constant series can drift slightly outside the valid interval
  in IEEE 754, and that value is published downstream as
  `AIAnomaly.confidence`.

### Changed
- `AnomalyDetector.detectMemoryLeak` and `detectOscillation` now
  delegate to two pure statics — `linearRegressionFit(_:)` and
  `oscillationScore(_:minChangeMagnitude:)` — so the math is testable
  without instantiating the detector or providing 30+ sample fixtures.
  The instance API is unchanged.

### Added
- `smolTests/CPUMonitorTests.swift` — 8 tests pinning the pure idle-
  percentage formula (first-call lifetime fallback, half-idle, full
  idle, full busy, idle-delta-exceeding-total clamp, counter-reset
  wrap safety, no-change-between-samples fallback). Suite is now 95
  tests.
- `smolTests/MemoryMonitorTests.swift` — 7 tests pinning the
  compression-ratio → pressure mapping, including the regression guard
  for the bug below (10% compression on a healthy machine must NOT
  trip the medium-pressure warning). Suite is now 87 tests.
- `smolTests/ProcessAnalyzerTests.swift` — 14 tests pinning the
  suspicious-process detection rule (system-process skip, min-running
  floor, CPU-time floor, CPU% floor, sort order, the `<` boundary at
  exactly `minRunningMinutes`) and the bloatware match aggregation
  (case-insensitive substring, no-match short circuit, one match per
  bloatware entry regardless of pattern count, PID-dedup for redundant
  patterns, multi-entry independence). Suite is now 81 tests.
- `smolTests/SystemMonitorHealthTests.swift` — 18 tests pinning every
  rule in `SystemMonitor.calculateHealth`'s threshold ladder, every
  boundary condition (1 GB swap exact, 80% pressure exact, 80 °C exact),
  the singular/plural grammar for the suspicious-process count, and the
  priority ordering between competing rules (heavy-swap-beats-pressure,
  critical-memory-beats-hot-at-idle, swap-warning-beats-pressure-warning,
  pressure-warning-beats-suspicious, suspicious-beats-elevated-temperature).
  Suite is now 67 tests.

### Fixed
- **`CPUMonitor.getIdlePercent` no longer leaks the
  `host_processor_info` buffer.** The previous code placed the
  `vm_deallocate` call *between* two return paths, so the first-reading
  early return (taken on every fresh launch) silently leaked the
  allocation. Deallocation is now in a `defer` block right after the
  guard, so every path frees the buffer exactly once.
- `CPUMonitor.getProcessList` now clamps `actualCount` to the allocated
  buffer length. If the process table grew between the size-probing
  `sysctl` call and the data-fetching `sysctl` call, the kernel could
  in theory report more bytes than the buffer holds; the clamp
  prevents the resulting out-of-bounds read.
- `CPUMonitor.getIdlePercent` is now defended against
  `previousTotal > currentTotal` (Mach counter reset on sleep/resume).
  The pure `idlePercent(...)` helper uses wrapping subtraction and
  clamps to [0, 100] so the menu bar never displays a negative or
  >100% value.
- **Memory pressure no longer pinned at ≥50% on long-uptime machines.**
  `MemoryMonitor.getMemoryPressurePercent()` previously added
  `min(50, stats.pageouts / 1000)` to the compression ratio — but
  `stats.pageouts` is cumulative since boot, so after a handful of
  hours that term saturated to 50 and the displayed pressure was always
  ≥50, which then tripped `SystemMonitor.calculateHealth`'s "Memory
  pressure medium" warning on every healthy long-running Mac. Score is
  now driven purely by compression ratio (the metric Apple's own
  `memory_pressure(1)` tool emphasises). The formula was extracted into
  a pure static `MemoryMonitor.pressurePercent(compressedPages:
  totalPages:)` so it can be unit-tested without hitting Mach.
- **`ProcessAnalyzer.findKnownBloatware` no longer emits one match per
  *pattern*.** The previous code looped patterns inside the bloatware
  loop and created a fresh `BloatwareMatch` each time a pattern
  matched anything, so an entry like Adobe Creative Cloud (5 process
  patterns) appeared in the Alerts tab up to 5 times — each card
  listing only the process matched by that one pattern. Matches are
  now aggregated per bloatware entry: one `BloatwareMatch` whose
  `runningProcesses` is the union of all matching processes (dedup by
  PID, so a process matched by two patterns isn't counted twice) and
  whose `totalMemoryBytes` is the corresponding sum.
- `ProcessAnalyzer.findKnownBloatware` lowercases each process name
  once instead of per pattern.

### Changed
- `CPUMonitor.getIdlePercent` was refactored to delegate its arithmetic
  to a pure `static idlePercent(currentIdle: currentTotal: previousIdle:
  previousTotal:)` so the formula can be unit-tested without a Mach
  call. The kernel side effect (`host_processor_info`) remains in the
  instance method.
- `ProcessAnalyzer.findSuspiciousProcesses` and `findKnownBloatware`
  were each split into a thin instance method (kernel-IO side effect
  only) and a pure `static` variant that the new tests exercise
  directly. The instance API is unchanged.
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
- `MemoryMonitor.getMemoryPressureFromCommand()` — dead code that
  shelled out to `/usr/bin/memory_pressure` and parsed its output. No
  in-app caller, and the formula in `getMemoryPressurePercent` already
  produces the same LOW/MEDIUM/HIGH classification.
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
