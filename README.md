# smol

**A tiny Mac monitor that actually works.** Free. Open Source. No bullshit.

> *"CleanMyMac uses 500MB to tell you your Mac is dirty. smol uses 5MB to tell you the truth."*

---

## Why?

Because I found out that:
- **Logitech Options+ updater** was running at 70% CPU for **10 MONTHS**
- **CleanMyMac** was using **11 GB of RAM** to "protect" me
- **Adobe Creative Cloud** had 16+ background processes doing nothing

After freeing 62 GB of RAM and dropping temperature by 40°C, I made this.

---

## Philosophy

| What others show | What smol shows | Why |
|------------------|-----------------|-----|
| "29 GB RAM used!!!" | Memory Pressure: LOW | GB used means nothing on macOS |
| "CPU 85%!!!" | CPU: 15% in uso | Shows actual work, not panic |
| Nothing about swap | Swap: 0 MB ✓ | Swap > 0 = real problem |
| "Temperature: High" | 52°C ↓ | Actual degrees + trend |

---

## Features

- **smol menu bar** - Changes color based on REAL system health
- **Ghost process detection** - Finds processes hogging CPU for too long
- **Bloatware database** - Knows problematic apps (Logitech, CleanMyMac, Adobe CC...)
- **Cleanup tool** - Finds orphaned LaunchAgents and leftover folders
- **Actually smol** - The app itself is tiny and doesn't become what it fights

---

## Screenshot

```
┌──────────────────────────────────┐
│  smol              [●] Healthy   │
├──────────────────────────────────┤
│  CPU     ██░░░░░░░░  15% in uso  │
│  Pressure ███░░░░░░  LOW (23%)   │
│  Swap    ✓ 0 MB                  │
│  Temp    52°C ↓                  │
├──────────────────────────────────┤
│  RAM: 29 GB / 128 GB             │
│  ░░░░░░░░░░░░░░░░░░░░░░░░        │
│  💡 RAM "used" includes cache    │
├──────────────────────────────────┤
│  Top CPU: WindowServer 2.1%      │
├──────────────────────────────────┤
│  [Dashboard]  [Cleanup]   [Quit] │
└──────────────────────────────────┘
```

---

## Install

### Homebrew (recommended)
```bash
brew install --cask smol
```

### Manual Download
[GitHub Releases](https://github.com/USERNAME/smol/releases)

### Build from source
Open `smol.xcodeproj` in Xcode and build.

---

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon or Intel

---

## Why not App Store?

Reading actual CPU temperature requires SMC access via IOKit, which isn't allowed in sandbox. The app is still signed and notarized by Apple.

---

## Size comparison

| App | Size | RAM Usage |
|-----|------|-----------|
| CleanMyMac X | ~500 MB | 200+ MB |
| smol | ~5 MB | ~15 MB |

---

## License

MIT - Do whatever you want, just don't become bloatware yourself.

---

## Contributing

PRs welcome! Especially for:
- Adding apps to the bloatware database
- Improving anomaly detection
- New Apple Silicon sensor support

---

*Made with frustration and Swift.*
