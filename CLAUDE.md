# CLAUDE.md — Agent Onboarding for Q-Audion iOS

You are an AI agent working on **Q-Audion iOS**, a post-quantum encrypted voice-calling app. Read this file end-to-end before your first action. It captures the hard-won state of the build pipeline so you don't repeat the work.

## Project snapshot

- **Repo:** `github.com/sigarone/Q-Audion-IOS`
- **Platform:** iOS 16.0+ / iPadOS 16.0+, Xcode 16.2
- **Team:** `5G22P9239N` (DEVELOPER, paid Apple Developer account)
- **Bundle id:** `com.qaudion.app`
- **App Store Connect App Apple ID:** `REDACTED_APP_ID`
- **Current status:** ✅ Distribution pipeline green; app v1.0.0 (build 1) is on TestFlight and installed on the internal testers' devices.

### Top-level layout

```
QAudionApp/          # The iOS app (SwiftUI) — XcodeGen-generated project
  project.yml        # XcodeGen spec; .xcodeproj is NOT committed
  Info.plist
  QAudion.entitlements
  Assets.xcassets/   # icon_1024.png MUST be opaque (no alpha)
  Services/, Views/
QAudionEngine/       # Swift package with crypto + audio C libs
  Package.swift      # swift-tools-version 5.9
  Sources/
    CLiboqs/         # ML-KEM-1024 (post-quantum KEM)
    COpus/           # Opus + SILK + CELT audio codec
    QAudionEngine/   # Swift API layer
  Resources/
    aasist_raw_*.onnx  # Deepfake detection models (run via onnxruntime)
codemagic.yaml       # CI — TWO workflows; qaudion-app-build is the TestFlight one
.github/workflows/
  engine-tests.yml   # macOS Swift test CI (informational)
```

## Build / release pipeline (CRITICAL — read before changing `codemagic.yaml`)

### How a release happens

1. Developer pushes a git tag `v*` (e.g. `v1.0.23`) to `origin/main`.
2. Codemagic fires workflow `qaudion-app-build` ("Q-Audion App Build (TestFlight)").
3. XcodeGen generates `QAudionApp.xcodeproj` from `project.yml`.
4. Code signing script creates/fetches Distribution cert + App Store profile via `app-store-connect` CLI.
5. `xcode-project build-ipa` produces `QAudionApp/build/ios/ipa/QAudionApp.ipa`.
6. **Post-build patch step** (see "Known ONNX bug" below) rewrites `onnxruntime.framework/Info.plist` and re-signs the bundle.
7. Publishing uploads the IPA to App Store Connect; internal tester group **`Q-Audion testers`** gets the build automatically.

### Trigger philosophy

- **Tag push `v*`** → full TestFlight pipeline.
- **Main branch push** → only the macOS `engine-tests.yml` on GitHub Actions (no iOS build).
- **Never** rely on Codemagic to build from branches — always tag.

## Hard-won lessons — DO NOT REPEAT THESE MISTAKES

### 1. Codemagic account type: Personal vs Team

This repo is on a **Personal Account**. The Codemagic UI only shows an "Apple Developer Portal" integration card, not a separate "App Store Connect" one. This means:

- ❌ YAML `integrations: app_store_connect: <key_name>` **does not work** — fails with "App Store Connect integration '…' does not exist".
- ✅ Use application-level **environment variable group `asc_credentials`** that stores API key + private key as env vars, and reference them directly in YAML (`api_key: $APP_STORE_CONNECT_PRIVATE_KEY`, etc.).
- If the Codemagic account is ever upgraded to Team, the cleaner `integrations:` syntax becomes available — but until then, leave this alone.

### 2. API key role — Admin or nothing

`app-store-connect fetch-signing-files --create` needs to create a Distribution certificate and App Store provisioning profile via the Apple API. Only **Admin** role keys can do this. App Manager / Developer roles cannot.

The current working key is stored in Codemagic as **`QAudion ASC API Key`** (Key ID `REDACTED_KEY_ID`). If it's ever revoked, the replacement MUST be Admin-role.

### 3. Distribution cert private key must be supplied

`fetch-signing-files --create` needs an RSA private key to sign the CSR. The key is stored in Codemagic env var `CERTIFICATE_PRIVATE_KEY` (PEM format, with `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`).

The PEM source of truth lives OUTSIDE the repo at `D:\users\f10379a\DEV APP\BCRYPTO\cert\distribution_cert_key.pem`. **Never commit it.** If lost, a new Distribution cert must be revoked & recreated (Apple allows max 2 per team).

The correct CLI flag is `--certificate-key "@file:$CERT_KEY_PATH"`, NOT `--certificate-key-path`.

### 4. ONNX Runtime 1.17.0 has a packaging bug — DO NOT UPGRADE

The dependency is **pinned** in `QAudionEngine/Package.swift`:

```swift
.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.17.0"),
```

- Newer versions (1.20+) raise `MinimumOSVersion` inside the XCFramework to iOS ≥ 18, which forces ITMS-90208 unless the app also raises deployment target to iOS 18+. This defeats the purpose.
- 1.17.0 supports iOS 13+ (good) **BUT** ships with a broken `onnxruntime.framework/Info.plist` where `MinimumOSVersion=""` (empty string). Apple's altool rejects this with two errors: "Invalid MinimumOSVersion … is ''" and "A value for the key 'MinimumOSVersion' … is required".
- The framework's Mach-O itself is fine (`LC_BUILD_VERSION` already declares iOS 16.0 minimum).

**Workaround in `codemagic.yaml` — the "Patch onnxruntime.framework" step**:
1. Unzip the IPA produced by `xcode-project build-ipa`.
2. `plutil -replace MinimumOSVersion -string "16.0" Payload/QAudionApp.app/Frameworks/onnxruntime.framework/Info.plist` — the value **must match the Mach-O's `minos` (16.0)**, not something else. Mismatch between Info.plist (e.g. 13.0) and Mach-O (16.0) ALSO triggers ITMS-90208.
3. Re-sign the framework with `codesign --force --sign "$IDENTITY"`.
4. Re-sign the app with its original entitlements (dumped to a REAL file, not via `<(…)` process substitution — the latter creates `/dev/fd/63` which codesign can't stat).
5. Repackage the IPA and let publishing pick it up.

If you ever need to touch this step, run it first mentally against the full error history — there are several near-miss paths that look right and aren't.

### 5. XcodeGen system frameworks

In `QAudionApp/project.yml`, system SDK frameworks must use `sdk:`, not `framework:`:

```yaml
dependencies:
  - package: QAudionEngine
  - sdk: CoreAudio.framework
  - sdk: AudioToolbox.framework
  - sdk: Accelerate.framework
```

`framework:` causes XcodeGen to look for a local path and error with `No such file or directory`.

### 6. Platform declaration in Package.swift

`swift-tools-version: 5.9` only supports `.iOS(.v13)` through `.iOS(.v17)`. **`.iOS(.v18)` is Swift 6.0+ only** and breaks SwiftPM resolution with "Failed to show build settings" (exit 74).

Use the string form `.iOS("18.0")` if you need iOS 18+ on the 5.9 tools version. Currently we're at `.iOS(.v16)` which is safe.

### 7. IPA artifact path

`xcode-project build-ipa` runs with `cd QAudionApp` and writes to `QAudionApp/build/ios/ipa/*.ipa` (relative to repo root). The `artifacts:` block must include `QAudionApp/build/ios/ipa/*.ipa` — otherwise publishing emits `Skip publishing to App Store Connect: no IPAs or PKGs found` silently.

### 8. TestFlight beta group name

The group in App Store Connect is **`Q-Audion testers`** (lowercase "t", with hyphen). The YAML `publishing.app_store_connect.beta_groups` must match exactly — Codemagic fails silently (2s step) if the group doesn't exist.

### 9. Apple-required Info.plist keys

Current keys that must NOT be removed:

- `NSMicrophoneUsageDescription` — voice calls
- `NFCReaderUsageDescription` — NFC key import from Android
- `NSCameraUsageDescription` — QR code key exchange
- `NSContactsUsageDescription` — **required even though the app doesn't use Contacts** (a linked SDK references the API; ITMS-90683 otherwise)
- `UISupportedInterfaceOrientations~ipad` — must contain all 4 orientations for iPad multitasking, even if iPhone is Portrait-only

### 10. NFC entitlement format

`com.apple.developer.nfc.readersession.formats` accepts `TAG` (generic tag reading) on iOS SDK 18.2. **`NDEF`** is disallowed — Apple rejects the bundle with "NDEF is disallowed, TAG is missing in the entitlement".

The Swift code that handles NFC may need to be reviewed if it was written against the NDEF API — with TAG format the delegate receives `[NFCTag]` not `[NFCNDEFMessage]`. Confirm with runtime testing before assuming it works.

### 11. App icon alpha channel

`QAudionApp/Assets.xcassets/AppIcon.appiconset/icon_1024.png` **must be opaque RGB**, no alpha. ITMS-90208 rejects RGBA icons. If the icon is re-exported from a design tool, run:

```python
from PIL import Image
img = Image.open(path).convert('RGBA')
bg = Image.new('RGB', img.size, (255, 255, 255))
bg.paste(img, mask=img.split()[-1])
bg.save(path, 'PNG', optimize=True)
```

### 12. Xcode 26 / iOS 26 SDK deadline

Apple emits **ITMS-90725** (informational) on every upload: starting **April 28, 2026**, App Store Connect will only accept builds made with Xcode 26 / iOS 26 SDK.

Today's date matters: the deadline is close. When Codemagic adds Xcode 26 to its Mac mini M2 runners, update `codemagic.yaml`:

```yaml
environment:
  xcode: 26.0   # was 16.2
```

Check availability at https://docs.codemagic.io/specs/versions-macos/. `xcode: latest` also works but is less deterministic.

## Current `codemagic.yaml` env var dependencies

The `qaudion-app-build` workflow requires these in the Codemagic app's **Environment variables → group `asc_credentials`** (all secure):

| Variable | Content |
|---|---|
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID of the Admin ASC API Key (currently `REDACTED_KEY_ID`) |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer UUID from App Store Connect → Users and Access → Integrations |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full content of the .p8 file |
| `CERTIFICATE_PRIVATE_KEY` | PEM content of the Distribution cert's RSA 2048 private key |

Without these the build fails at the "Set up signing" step.

## Known open issues / next debugging topics

The app is on TestFlight but has not been exercised end-to-end. Expect to debug:

1. **NFC key import** — entitlement switched from `NDEF` to `TAG` for Apple compliance; Swift code may need adaptation.
2. **Post-quantum key exchange** (ML-KEM-1024 via liboqs) — runtime correctness across iPhone hardware/accelerators.
3. **Voice call quality** — Opus + SILK with our SILK source patches from v1.0.4; cross-platform interop with the Android client (see commit `e350b6a fix(compat): align wire format with Android`).
4. **AASIST deepfake detection** — onnxruntime 1.17.0 inference on iOS; currently patched frameworks may introduce subtle issues. Watch for crashes or weird spoofing scores on the first run.
5. **Memory / battery profile** — post-quantum crypto is heavy; Instruments run overdue.
6. **Group call (`GroupCallView`)** — added in commit `c3d5426`, never tested on TestFlight before.
7. **Export compliance for External TestFlight / public App Store** — ML-KEM post-quantum is NOT standard "mass market" cryptography; consult legal before enabling External testers or submitting for App Store review.

## Reference files & commits

- `IOS_BUILD_ERRORS.md` — historical list of Swift compile errors resolved
- `SESSION_LOG.md` — work log per session
- Last green build on TestFlight: tag `v1.0.22` (commit `626c807`)
- The debugging saga from "nothing to TestFlight" spans tags `v1.0.4` → `v1.0.22`; read git log for the blow-by-blow:
  ```
  git log --oneline v1.0.3..v1.0.22
  ```

## Rules for subsequent agents

1. **Never touch code signing config** (`integrations`, `environment.ios_signing`, `auth: integration`) without re-reading sections 1–3 above — the Personal Account topology is fragile.
2. **Never upgrade `onnxruntime-swift-package-manager` past 1.17.0** without a plan for handling its MinOS breakage — either find a version that both supports iOS 16 AND has a correct Info.plist, or change the patch step accordingly.
3. **Never remove the "Patch onnxruntime.framework" step** in `codemagic.yaml` — the pipeline breaks silently on validation otherwise.
4. **Always bump the tag** for a new release (e.g. `v1.0.23`). Don't re-use old tags; don't build from branches.
5. **Treat Apple emails after upload as canonical**. Codemagic reporting "publishing succeeded" only means the upload HTTP call returned 2xx. Apple may still reject on validation minutes later via email. Always check inbox before declaring victory.
6. **Use `TodoWrite` for multi-step tasks** and follow the superpowers skill guidance when relevant.

### 13. Swift type-checker timeout traps (Xcode 26.4)

Xcode 26.4 / Swift 6's type-checker is **less forgiving** than earlier versions for multi-segment string interpolation inside `@Sendable` closures or `Task { @MainActor in ... }` blocks. Patterns to avoid:

```swift
// ❌ TYPE-CHECKER TIMEOUT (silent build failure):
Task { @MainActor in
    print("[X] received \(obj.field) at \(timestamp)ms (\(other.nested))")
    snackbar?.show(.init(text: "\(a) of \(b) failed.", ...))
}

// ✅ Pre-bind locals or use String + concat:
Task { @MainActor in
    let a = obj.field
    let b = timestamp
    let c = other.nested
    print("[X] received " + String(a) + " at " + String(b) + "ms (" + c + ")")
    let msg: String = "\(a) of \(b) failed."
    await MainActor.run { snackbar?.show(.init(text: msg, ...)) }
}
```

**v1.0.253 update — pre-binding alone is NOT enough.** Even this pattern still trips the type-checker:

```swift
// ❌ STILL TIMES OUT (v1.0.251 → v1.0.252 broke on this exact line):
let errMsg: String = error.localizedDescription
print("[VoiceNote] start failed: " + errMsg)
```

The reason: `print` has many overloads (variadic, separator:, terminator:, to: &Output). Combined with `String + String → String` operator overloads, the type-checker explores too many resolution paths. The `+` MUST live outside the `print(...)` call:

```swift
// ✅ WORKS:
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

**Rule of thumb**: if a closure builds a String for `print` / `snackbar.show` / any function with overloads, build the full String into a `let line: String = ...` first, then pass that single String. Never do the concatenation or interpolation inline at the call site.

**v1.0.255 update — `String(numericValue)` is also a trap.** `String(_:)` has many numeric overloads (Int, UInt, Int64, UInt64, Double, Float, NSNumber, Substring, Character, CChar, …). Inside a complex closure, even an unambiguous `Int` argument can trigger overload-resolution timeout:

```swift
// ❌ TIMES OUT (rec.durationMs is Int):
let recDur: String = String(rec.durationMs)

// ✅ WORKS — String(describing:) has a single overload:
let recDur: String = String(describing: rec.durationMs)
```

Other safe alternatives that don't go through `String(_:)`'s overload set:
- `"\(rec.durationMs)"` (single-segment interpolation of a primitive — usually fine)
- `rec.durationMs.description`
- Any explicit cast first: `let n = Int(rec.durationMs); let s = "\(n)"`

**v1.0.256 update — even pre-bound `+` concat with explicit types times out.** The most stubborn variant:

```swift
// ❌ TIMES OUT, even with both sides explicitly typed as String:
let errMsg: String = error.localizedDescription
let line: String = "[VoiceNote] start failed: " + errMsg
print(line)
```

The `+` operator has many overloads (String+String, Array+Array, AdditiveArithmetic, custom Self+Self conformances, …). Inside a deeply nested closure (e.g. `Task { do { try await ... } catch { ... } }` inside a SwiftUI ViewBuilder argument), the type-checker exhausts its budget exploring all `+` candidates plus all the closure's surrounding constraints.

**Pragmatic rule for debug prints in nested closures**: don't build the String at all. Either:
1. Drop the print (debug-only logs aren't load-bearing — `_ = error` to suppress unused-variable warnings)
2. Use multiple `print()` calls with single-literal arguments (no concatenation)
3. Move the formatting to a top-level helper function called from the closure (lifts type inference out of the nested context)

Production code should use `os_log` / `Logger` anyway, never `print`.

**v1.0.258 update — even trivial function calls time out at sufficient closure depth.** v1.0.256 dropped all the String construction. v1.0.257 build STILL failed:

```
ChatDetailScreen.swift:145:29: error: the compiler is unable to type-check this expression in reasonable time
container.markFailed(messageId: UUID(), reason: .generic)
^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

A bog-standard method call with two arguments — but inside `closure → Task → do/catch with pattern matching` it's enough to exhaust the type-checker.

**The structural fix**: extract the inline closure body into a named method.

```swift
// ❌ BEFORE — 4 levels of closure constraints:
onStartVoiceNote: {
    HapticFeedback.recordingStart()
    Task {
        do {
            try await voiceNoteRecorder.start()
        } catch VoiceNoteRecorder.RecorderError.permissionDenied {
            container.markFailed(messageId: UUID(), reason: .generic)  // TIMES OUT
        } catch {
            _ = error
        }
    }
},

// ✅ AFTER — closure is trivial, type-checker has clean scope per method:
onStartVoiceNote: handleVoiceNoteStart,

private func handleVoiceNoteStart() {
    HapticFeedback.recordingStart()
    Task { await self.startVoiceNoteAsync() }
}

private func startVoiceNoteAsync() async {
    do {
        try await voiceNoteRecorder.start()
    } catch {
        await MainActor.run {
            container.markFailed(messageId: UUID(), reason: .generic)
        }
    }
}
```

**Rule of thumb**: any inline closure body deeper than `closure → Task → do/catch` should be moved to a method. Reference the method by name in the closure-binding parameter (no `{ ... }` at the call site).

Symptoms: the build console shows just `Failed to archive` with **no `error:`/`warning:` lines** — xcbeautify is consuming the diagnostic before tee can capture it.

**Mitigation:** the codemagic.yaml has a "Diagnose Swift compile (raw xcodebuild)" step that runs before `xcode-project build-ipa` with `CODE_SIGNING_ALLOWED=NO`. That output goes to `diag.log` (artifact) and is grepped at the end of Step 6. Always check Step 6 in failed Codemagic builds, not just the Build IPA step.

### 14. Single-file Swift compile budget

`ChatDetailScreen.swift` is the largest user-facing file (~830 lines after the v1.0.225 markdown extraction). Adding more state observers or complex view-builder branches risks the type-checker timeout. **Extract any new helper > 40 lines into its own `Services/*.swift` file** — see `Services/MarkdownLiteParser.swift` (W148/W149/W127/W152) as the reference pattern.

### 15. `guard let self = self` patterns in @Sendable closures

Xcode 26.4 elevates `value 'self' was defined but never used` from warning to **error** in some compile modes. If the closure body doesn't actually call `self.foo`, replace:

```swift
{ [weak self] _, _ in
    DispatchQueue.main.async {
        guard let self = self else { return }   // ❌
        print("...")
    }
}
```

with:

```swift
{ [weak self] _, _ in
    DispatchQueue.main.async {
        guard self != nil else { return }       // ✅
        print("...")
    }
}
```

(Already fixed at AppState.swift:1327 — see commit `d31f34e`.)
