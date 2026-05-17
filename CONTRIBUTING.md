# Contributing to smol

Thanks for considering a contribution. smol is a tiny tool with strong opinions:
**stay small, stay honest, stay fast.** That shapes what we merge.

## Ground rules

- **Keep the binary tiny.** New dependencies need a real reason. Pure-Swift code
  beats a framework. Don't pull in something heavy "in case we need it later".
- **No telemetry. Ever.** smol does not phone home. Don't add analytics,
  remote configs, crash reporters that ship data off-device, or "anonymous"
  usage pings.
- **No bloat.** Background timers should be measured and necessary. If a
  feature would meaningfully increase resident memory, justify it in the PR.
- **Native only.** SwiftUI + IOKit + native frameworks. No webviews, no
  Electron, no JavaScript runtime.

## How to start

1. Fork and clone.
2. Open `smol.xcodeproj` in **Xcode 26+** on **macOS 26 (Tahoe)**.
3. Build & Run (`⌘R`). The first launch will prompt to install the
   privileged fan-control helper — say yes if you're on Apple Silicon.
4. Tests: `⌘U` or `xcodebuild -scheme smol test`. See [CI workflow](.github/workflows/ci.yml).

## What's most useful

The README's "Contributing" section calls out the highest-leverage areas:

- **Bloatware database**: add entries to `smol/KnownBloatware.json` for
  apps that are common resource hogs.
- **Anomaly detection**: improve heuristics in
  `smol/Services/AnomalyDetector.swift` and `MLAnomalyEngine.swift`.
  Include unit tests covering the new pattern.
- **Apple Silicon sensors**: more SMC keys, more chip families. See
  `DEVELOPMENT_NOTES.md` for what's known about M-series SMC layout.
- **Translations**: extend `smol/Localization/LocalizationManager.swift`.

## Pull request checklist

- [ ] `xcodebuild -scheme smol -configuration Debug build` succeeds with **zero warnings**.
- [ ] `xcodebuild -scheme smol -only-testing:smolTests test` is green.
- [ ] New behavior has a unit test in `smolTests/` (or a clear note on why it can't).
- [ ] No new dependencies unless discussed in an issue first.
- [ ] No `print()` — use `SmolLog` (see `smol/Services/Logger.swift`).
- [ ] No force unwraps (`!`) in non-test Swift code.
- [ ] Updated `README.md` / `DEVELOPMENT_NOTES.md` if user-visible or architectural.

## Style

- Swift 6 language mode. We treat warnings as bugs.
- 4-space indent, no tabs.
- Prefer `private let` over `private var` where the value never changes.
- `async`/`await` for new async code. No `DispatchQueue` unless interfacing with
  callback-based system APIs.
- UI strings go through `LocalizationManager`, never hardcoded in views.

## Reporting bugs

Open an issue with:
- `sw_vers` output (macOS version + build).
- Mac model (e.g. "MacBook Pro M4 Max 14-inch 2024").
- What smol reports vs. what you expect.
- Console logs filtered to smol:
  ```bash
  log stream --predicate 'subsystem == "com.whitepaper.smol"' --info
  ```
  Helper logs:
  ```bash
  log stream --predicate 'process == "com.smol.fanhelper"' --info
  ```

## License

By contributing you agree your changes are licensed under the [MIT License](LICENSE).
