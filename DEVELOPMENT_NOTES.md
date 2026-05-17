# smol — Development Notes

This document captures what we learned reverse-engineering Apple Silicon SMC
keys, the privileged helper architecture, and the AI-inference layer. Treat
it as supplementary to the source — when the code and these notes disagree,
trust the code, then fix the notes.

## Current state

The shipping app provides:
- A menu-bar widget that polls system metrics in real time.
- A privileged XPC helper installed via `SMJobBless` (see `smol.app/Contents/Library/LaunchDaemons`).
- Working XPC communication between app and helper.
- Correct fan RPM reads on M-series via `flt` (IEEE 754) decoding.
- Confirmed fan target writes on Apple Silicon (M4 tested, M1/M2/M3 likely
  identical — see "Differences" table).

---

## Apple Silicon fan control — what we found

### SMC keys observed on M4 Max

| Key       | Type | Value     | Meaning                  |
|-----------|------|-----------|--------------------------|
| `FNum`    | ui8  | 2         | Number of fans           |
| `F0Ac` `F1Ac` | flt  | 0–5777 | Current RPM              |
| `F0Mn` `F1Mn` | flt  | 1350   | Minimum RPM              |
| `F0Mx` `F1Mx` | flt  | 5777   | Maximum RPM              |
| `F0Tg` `F1Tg` | flt  | 0      | Target RPM (write here)  |
| `F0Md` `F1Md` | ui8  | 3      | Mode (3 = auto)          |
| `F0St` `F1St` | ui8  | 3      | Status                   |
| `F0Fc` `F1Fc` | ui16 | 6      | Force Control            |

### RPM encoding

**Apple Silicon uses IEEE 754 `flt`, not Intel's fixed-point `fpe2`.**

```swift
private func bytesToFloat(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Float {
    let bits: UInt32 = UInt32(b0)
        | (UInt32(b1) << 8)
        | (UInt32(b2) << 16)
        | (UInt32(b3) << 24)
    return Float(bitPattern: bits)
}
```

### Write behaviour

What we proved by capturing TG Pro's SMC writes:

```
15:16:21  F0Tg=0     F0Ac=0     # fans idle
15:16:23  F0Tg=1350             # TG Pro writes target = minimum
15:16:25             F0Ac=714   # fans spinning up
15:16:27  F0Tg=5777             # max
```

| Operation        | Result                                         |
|------------------|------------------------------------------------|
| Write `F0Tg`     | Accepted, even when current RPM is 0.          |
| Write `F0Md`     | Sometimes returns IOKit error 130.             |
| Fan spin-up      | Confirmed end-to-end with the helper running.  |

Earlier TG Pro documentation stated that fan control is unavailable when
current RPM is 0. That is no longer accurate — writing `F0Tg` is enough to
spin the fan up from a parked state. Treat the SMC's `F{n}Md` write
rejection as an expected failure path, not a blocker.

### Intel vs. Apple Silicon

| Aspect              | Intel Mac           | Apple Silicon M-series       |
|---------------------|---------------------|------------------------------|
| SMC IOKit service   | `AppleSMC`          | `AppleSMCKeysEndpoint`       |
| RPM encoding        | `fpe2` (fixed 14.2) | `flt` (IEEE 754)             |
| Force-mode key      | `FS!` (bitmask)     | `F{N}Md` (per-fan)           |
| Write protection    | Limited             | Strong (frequent error 130)  |
| Fan-off behaviour   | Rare                | Common (cool system → 0 RPM) |

### UI strategy for Apple Silicon

Fan control works even when current RPM is 0, so the UI:

1. Always shows fan controls — never grey them out at 0 RPM.
2. When RPM is 0 reports "System cool, controls available" (green).
3. When RPM > 0 shows current RPM next to the controls.
4. `setFanRPM(index:rpm:)` writes `F{N}Tg`; the fan spins up from 0.
5. `setFanMode(0)` returns the fan to auto.

---

## Privileged helper architecture

```
smol/
├── smol/                          # Main app
│   ├── Services/
│   │   └── FanMonitor.swift       # XPC client
│   └── SharedProtocol.swift       # Shared protocol (must match helper copy)
└── com.smol.fanhelper/            # Privileged helper (LaunchDaemon)
    ├── main.swift                 # XPC listener + input validation
    ├── SMCAccess.swift            # IOKit / SMC I/O
    └── SharedProtocol.swift       # Shared protocol (must match app copy)
```

The two `SharedProtocol.swift` files must declare the exact same
`@objc protocol`. The `@objc` runtime checks the method signatures when the
XPC interface is bound; any drift causes the connection to be refused
silently.

### XPC protocol

```swift
@objc public protocol FanHelperProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func getFanCount(reply: @escaping (Int) -> Void)
    func getFanRPM(index: Int, reply: @escaping (Int) -> Void)
    func getFanInfo(reply: @escaping ([String: Any]) -> Void)
    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)
    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void)
    func debugEnumerateKeys(reply: @escaping (String) -> Void)
    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void)
}
```

### Client authentication

The helper runs as root, so the XPC listener verifies the caller's code
signature before exporting any object. We use the connection's
`audit_token_t` (not the PID) to look up the `SecCode`, since PIDs can be
recycled across `exec` and the lookup would otherwise be racy. The
designated requirement enforces our Team ID and identifier, with
`kSecCSCheckAllArchitectures` to cover universal binaries.

### Input bounds

All XPC entry points that take a `Int` argument from the caller pass it
through `validIndex(_:)` and `clampRPM(_:)` in `main.swift` before reaching
any SMC key construction. The cap on fan index is 7; the cap on requested
RPM is 10000. Anything outside is rejected (index) or clamped (RPM).

---

## Debug commands

```bash
# Live helper log via os_log/NSLog
log stream --predicate 'process == "com.smol.fanhelper"' --info

# Check the helper is installed
ls -la /Library/PrivilegedHelperTools/

# Remove and let the next launch reinstall
sudo launchctl unload /Library/LaunchDaemons/com.smol.fanhelper.plist
sudo rm /Library/PrivilegedHelperTools/com.smol.fanhelper
sudo rm /Library/LaunchDaemons/com.smol.fanhelper.plist
```

---

## LLM inference layer

### Layout

```
smol/Services/LLMInference/
├── LLMInferenceEngine.swift      # Protocol + LLMInferenceManager
├── FoundationModelEngine.swift   # Apple FoundationModels (macOS 26+)
├── MLXEngine.swift               # mlx-swift backend (Apple Silicon)
└── OpenRouterEngine.swift        # Cloud SSE streaming
```

`LLMInferenceManager` owns all three engines as `private let`. Backend
selection is driven by `selectedBackend`; in `.auto` mode the manager
picks the first loaded backend in the order
**FoundationModels → MLX → OpenRouter**.

### Backend matrix

| Backend            | Formats accepted     | Where it runs    | Notes                                 |
|--------------------|----------------------|------------------|---------------------------------------|
| Apple AI           | system model         | Neural Engine    | Free; macOS 26 + Apple Intelligence   |
| MLX                | `.safetensors`, `.mlx` | Apple Silicon  | Free; requires SPM dep at build time  |
| OpenRouter / cloud | API only             | provider's server | Pay per token; needs API key         |

### Adding the SPM dependencies

llama.cpp is **not** currently wired in. To enable it:

1. Xcode → *File → Add Package Dependencies…*
2. URL: `https://github.com/ggerganov/llama.cpp`
3. Add `llama` to the `smol` target.

MLX (already covered by the `#if canImport(MLX)` placeholders):

1. Xcode → *File → Add Package Dependencies…*
2. URL: `https://github.com/ml-explore/mlx-swift`
3. Add `MLX`, `MLXNN`, `MLXRandom` to the `smol` target.

Once a dependency is in, remove the corresponding `#if !canImport(...)`
placeholder in the engine file so the real call path takes over.

### Model size guide

| Model           | On-disk | RAM minimum | Throughput estimate |
|-----------------|---------|-------------|---------------------|
| Qwen2 0.5B      | 350 MB  | 1 GB        | ~50 tok/s           |
| TinyLlama 1.1B  | 670 MB  | 2 GB        | ~35 tok/s           |
| Phi-2 2.7B      | 1.6 GB  | 4 GB        | ~20 tok/s           |
| Gemma 2B        | 1.4 GB  | 4 GB        | ~22 tok/s           |
| Mistral 7B      | 4.1 GB  | 8 GB        | ~10 tok/s           |

### Resource tracking

Every AI call is wrapped by `ResourceTracker`, which records:
- average and peak CPU,
- memory delta,
- estimated energy (mWh),
- tokens generated and tok/s.

The user-facing chat surface shows a small impact badge (low / medium /
high) under each AI response based on these numbers.

---

## References

- TG Pro tutorial: <https://www.tunabellysoftware.com/support/tgpro_tutorial/>
- TG Pro release notes: <https://www.tunabellysoftware.com/tgpro/releasenotes/>
- llama.cpp: <https://github.com/ggerganov/llama.cpp>
- MLX Swift: <https://github.com/ml-explore/mlx-swift>
- Hugging Face GGUF models: <https://huggingface.co/models?library=gguf>
