# smol - Note di Sviluppo

## Stato Attuale

App smol funzionante con:
- Menu bar icon con monitoraggio sistema
- Helper privilegiato installato via SMJobBless
- Comunicazione XPC funzionante
- Lettura RPM ventole corretta

---

## Apple Silicon M4 Fan Control - Scoperte Tecniche

### Chiavi SMC Disponibili su M4 Max

| Chiave | Tipo | Valore | Descrizione |
|--------|------|--------|-------------|
| FNum | ui8 | 2 | Numero ventole |
| F0Ac/F1Ac | flt | 0-5777 | RPM attuale |
| F0Mn/F1Mn | flt | 1350 | RPM minimo |
| F0Mx/F1Mx | flt | 5777 | RPM massimo |
| F0Tg/F1Tg | flt | 0 | Target RPM |
| F0Md/F1Md | ui8 | 3 | Mode (3=auto) |
| F0St/F1St | ui8 | 3 | Status |
| F0Fc/F1Fc | ui16 | 6 | Force Control |

### Formato Dati RPM

**Apple Silicon M4 usa IEEE 754 float (`flt`), NON fixed-point `fpe2` come Intel!**

```swift
// Conversione corretta per Apple Silicon
private func bytesToFloat(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Float {
    let bits: UInt32 = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
    return Float(bitPattern: bits)
}
```

### Risultati Write Test

**AGGIORNAMENTO: Il controllo funziona anche con ventole a 0 RPM!**

Analizzando TG Pro abbiamo scoperto che scrivendo su F0Tg (target RPM) le ventole
partono anche da 0 RPM. La sequenza catturata dai log:
```
15:16:21: F0Tg=0, F0Ac=0 (ventole spente)
15:16:23: F0Tg=1350 (TG Pro scrive target=minimo)
15:16:25: F0Ac=714 RPM (ventole in avvio!)
15:16:27: F0Tg=5777 (max), ventole accelerano
```

**Come funziona:**
| Operazione | Risultato |
|------------|-----------|
| Write F0Tg (target) | ✅ Funziona anche con RPM=0 |
| Write F0Md (mode) | ⚠️ Può fallire con error 130 |
| Le ventole partono | ✅ Confermato con test reali |

### Comportamento Ventole M4

**Quando sistema freddo (RPM = 0):**
- Le ventole sono in stato "sleep" ma NON disabilitate
- Scrivendo su F0Tg si forzano ad accendersi
- Il controllo È possibile, contrariamente a quanto documentato prima

**Nota su TG Pro docs:**
La documentazione TG Pro diceva che il controllo non funziona con RPM=0, ma
i test mostrano che funziona comunque scrivendo su F0Tg. Probabilmente la
documentazione era obsoleta o riferita a modelli precedenti.

### Differenze Intel vs Apple Silicon

| Aspetto | Intel Mac | Apple Silicon M4 |
|---------|-----------|------------------|
| SMC Service | AppleSMC | AppleSMCKeysEndpoint |
| Tipo RPM | fpe2 (fixed 14.2) | flt (IEEE 754 float) |
| Force Mode Key | FS! (bit array) | F{n}Md (per-fan) |
| Write Protection | Limitata | Totale (error 130) |
| Fan Off Mode | Raro | Comune |

---

## Architettura Helper

```
smol/
├── smol/                          # App principale
│   ├── Services/
│   │   └── FanMonitor.swift       # Client XPC
│   └── SharedProtocol.swift       # Protocollo condiviso
└── com.smol.fanhelper/            # Helper privilegiato
    ├── main.swift                 # XPC listener
    ├── SMCAccess.swift            # Accesso SMC via IOKit
    └── SharedProtocol.swift       # Protocollo condiviso
```

### Protocollo XPC

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

---

## Debug Commands

```bash
# Log helper
log stream --predicate 'process == "com.smol.fanhelper"' --info

# Verifica helper installato
ls -la /Library/PrivilegedHelperTools/

# Debug log SMC
cat /tmp/smol_helper_debug.log

# Rimuovi helper per reinstallazione
sudo launchctl unload /Library/LaunchDaemons/com.smol.fanhelper.plist
sudo rm /Library/PrivilegedHelperTools/com.smol.fanhelper
sudo rm /Library/LaunchDaemons/com.smol.fanhelper.plist
```

---

## Strategia UI per M4

**Il controllo ventole funziona SEMPRE, anche con RPM = 0!** Strategia:

1. **Mostrare controlli sempre:** Non bloccare UI quando RPM = 0
2. **Se RPM = 0:** Mostrare info "Sistema freddo, controlli disponibili" (verde)
3. **Se RPM > 0:** Mostrare RPM attuale e controlli
4. **setFanRPM(index, rpm)** scrive su F0Tg e avvia le ventole anche da 0
5. **setFanMode(0)** per tornare ad auto

---

---

## LLM Inference Backends

### Architettura

```
smol/Services/LLMInference/
├── LLMInferenceEngine.swift   # Protocol + LLMInferenceManager
├── LlamaCppEngine.swift       # llama.cpp backend (GGUF/GGML)
└── MLXEngine.swift            # MLX backend (Apple Silicon)
```

### Backend Disponibili

| Backend | Formato | Compatibilità | Performance |
|---------|---------|---------------|-------------|
| llama.cpp | GGUF, GGML | Tutti i Mac | Buona |
| MLX | SafeTensors, MLX | Solo Apple Silicon | Ottima |

### Aggiungere Dipendenze SPM (da Xcode)

**Per attivare llama.cpp:**
1. File > Add Package Dependencies
2. URL: `https://github.com/ggerganov/llama.cpp`
3. Branch: `master`
4. Aggiungi "llama" al target smol

**Per attivare MLX:**
1. File > Add Package Dependencies
2. URL: `https://github.com/ml-explore/mlx-swift`
3. Branch: `main`
4. Aggiungi "MLX", "MLXNN", "MLXRandom" al target smol

**Nota:** I backend funzionano con placeholder/demo mode finché non si aggiungono le dipendenze reali. Quando le dipendenze vengono aggiunte, rimuovere i `#if !canImport(...)` blocks.

### Modelli Supportati

| Modello | Size | RAM Min | Velocità Stim. |
|---------|------|---------|----------------|
| Qwen2 0.5B | 350 MB | 1 GB | ~50 tok/s |
| TinyLlama 1.1B | 670 MB | 2 GB | ~35 tok/s |
| Phi-2 2.7B | 1.6 GB | 4 GB | ~20 tok/s |
| Gemma 2B | 1.4 GB | 4 GB | ~22 tok/s |
| Mistral 7B | 4.1 GB | 8 GB | ~10 tok/s |

### Resource Tracking

Ogni query AI viene tracciata per:
- CPU usage (media e picco)
- Memory delta
- Energia stimata (mWh)
- Token generati e tok/s

L'utente vede un badge con impatto (basso/medio/alto) sotto le risposte AI.

---

## Riferimenti

- TG Pro Tutorial: https://www.tunabellysoftware.com/support/tgpro_tutorial/
- TG Pro Release Notes: https://www.tunabellysoftware.com/tgpro/releasenotes/
- llama.cpp: https://github.com/ggerganov/llama.cpp
- MLX Swift: https://github.com/ml-explore/mlx-swift
- Hugging Face Models: https://huggingface.co/models?library=gguf
