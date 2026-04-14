# iOS Archive Build Errors — Da fixare

## Status: CLiboqs compila ✅, Swift errors ❌

## Errori Swift da fixare per iOS device archive:

### 1. VoiceAnalysisResult.swift:17-21
```
error: initializer 'init(f0Hz:voiced:rms:)' is internal and cannot be referenced from a default argument value
```
**Fix**: Aggiungere `public` agli init delle struct interne

### 2. OpusCodec.swift:38-40, 112-113
```
error: 'opus_encoder_ctl' is unavailable: Variadic function is unavailable
```
**Fix**: Swift non supporta funzioni C variadic. Creare wrapper C per opus_encoder_ctl

### 3. SecureEnclaveManager.swift:59, 104
```
error: type of expression is ambiguous without a type annotation
```
**Fix**: Aggiungere type annotation esplicita

### 4. EmbeddedTorManager.swift:19
```
error: cannot find type 'Process' in scope
```
**Fix**: `Process` (Foundation) non esiste su iOS. Usare #if os(macOS) guard

### 5. ContactDiscoveryView, QAudionMainView, WelcomeView, SettingsView
```
error: 'NavigationStack' is only available in iOS 16.0 or newer
```
**Fix**: Aggiungere `if #available(iOS 16.0, *)` o cambiare deployment target a 16.0

### 6. UI/SettingsView.swift:28
```
error: value of type 'BCryptoRestClient' has no member 'description'
```
**Fix**: Fix property access
