# CODEMAGIC_GUARD — Invariants the pipeline expects

> **Prima di modificare** `codemagic.yaml`, `QAudionApp/project.yml`, `QAudionApp/QAudion.entitlements`, `QAudionApp/Info.plist`, `QAudionEngine/Package.swift` → **rileggere questo file**.
> Reference: `CLAUDE.md` sections 1–12.

---

## Hard invariants (break these → build fails)

### I-01 · onnxruntime pinned exactly 1.17.0
`QAudionEngine/Package.swift`:
```swift
.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.17.0"),
```
- Newer versions force `MinimumOSVersion ≥ 18` → ITMS-90208 unless we raise iOS deployment target.
- 1.17.0 ships broken `Info.plist` (`MinimumOSVersion=""`) → requires post-build patch.
- **DO NOT UPGRADE** without a documented migration plan for BOTH issues.

### I-02 · Post-build "Patch onnxruntime.framework" step
In `codemagic.yaml` after `build-ipa`:
1. Unzip IPA
2. `plutil -replace MinimumOSVersion -string "16.0" ...onnxruntime.framework/Info.plist` (value MUST match Mach-O `minos` = 16.0)
3. `codesign --force --sign "$IDENTITY"` on framework
4. Re-sign app with entitlements dumped to a REAL file (not `<(...)` — codesign can't stat `/dev/fd/*`)
5. Repackage IPA

**DO NOT REMOVE THIS STEP.** Silent validation failure otherwise.

### I-03 · Xcode version pinned
```yaml
environment:
  xcode: 16.2
```
- `26.x` beta → unstable on current runners.
- Deadline `2026-04-28` for Xcode 26 SDK submissions. Bump `xcode:` only when Mac mini M2 runners list 26.0 as GA.

### I-04 · Trigger = tag `v*` only
```yaml
triggering:
  events:
    - tag
  tag_patterns:
    - pattern: 'v*'
```
- Branch pushes do NOT trigger iOS build.
- Tag convention for parity effort: `v1.0.24-phN`; final release `v1.0.24` (no suffix).

### I-05 · Personal Codemagic account — no `integrations:` for ASC
Codemagic is on a Personal account. Therefore:
```yaml
# ❌ DOES NOT WORK
integrations:
  app_store_connect: QAudion ASC API Key

# ✅ CORRECT
environment:
  groups:
    - asc_credentials   # contains APP_STORE_CONNECT_KEY_IDENTIFIER, _ISSUER_ID, _PRIVATE_KEY, CERTIFICATE_PRIVATE_KEY
```
Reference direct env vars in signing scripts: `api_key: $APP_STORE_CONNECT_PRIVATE_KEY` etc.

### I-06 · ASC API key role = Admin
Key ID `REDACTED_KEY_ID` (stored as "QAudion ASC API Key"). Only **Admin**-role keys can create Distribution certs + App Store profiles via `app-store-connect fetch-signing-files --create`.

### I-07 · Distribution cert private key path
`CERTIFICATE_PRIVATE_KEY` env var holds PEM content. CLI flag:
```
--certificate-key "@file:$CERT_KEY_PATH"
```
NOT `--certificate-key-path`. The source-of-truth PEM file lives outside the repo at `D:\users\f10379a\DEV APP\BCRYPTO\cert\distribution_cert_key.pem`. Never commit it.

### I-08 · XcodeGen `sdk:` not `framework:` for system SDKs
```yaml
# ✅
dependencies:
  - sdk: CallKit.framework
  - sdk: PushKit.framework
  - sdk: CoreNFC.framework
# ❌
  - framework: CallKit.framework   # "No such file or directory"
```

### I-09 · `swift-tools-version: 5.9` platform cap = iOS 17
`.iOS(.v18)` breaks SwiftPM resolution (exit 74). Use string `.iOS("18.0")` if ever needed. Currently `.iOS(.v16)` — safe.

### I-10 · IPA artifact path
Artifact glob must be `QAudionApp/build/ios/ipa/*.ipa`. `xcode-project build-ipa` runs with `cd QAudionApp` and writes that relative path.

### I-11 · TestFlight beta groups = EXTERNAL only
`Q-Audion testers` is an **INTERNAL** group. Internal groups are auto-assigned by ASC to every processed build — the API rejects explicit `beta_groups: [Q-Audion testers]` entries with *"Cannot add internal group to a build"*.
- ✅ Leave `submit_to_testflight: true` and **omit** `beta_groups` unless you have explicit external groups.
- ❌ DO NOT re-add `- Q-Audion testers` without first converting it to an external group in ASC.
- If `beta_groups:` is re-introduced, every listed name must: (a) exist in ASC, (b) be marked External, (c) match char-for-char including spaces/hyphens.

### I-12 · Required Info.plist keys (don't remove)
- `NSMicrophoneUsageDescription`
- `NFCReaderUsageDescription`
- `NSCameraUsageDescription`
- `NSContactsUsageDescription` (required even though we don't use Contacts, SDK linkage → ITMS-90683)
- `UIBackgroundModes` (currently `[voip, audio]` — added in Task 0.2)
- `UISupportedInterfaceOrientations~ipad` (all 4 orientations)

### I-13 · NFC entitlement format = `TAG`
```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
  <string>TAG</string>
</array>
```
`NDEF` is disallowed by Apple on iOS SDK 18.2 — bundle rejected. Swift NFC code must use `NFCTagReaderSession` (not `NFCNDEFReaderSession`).

### I-14 · App icon = opaque RGB (no alpha)
`QAudionApp/Assets.xcassets/AppIcon.appiconset/icon_1024.png`. RGBA rejected with ITMS-90208. Re-export flatten-on-white if alpha sneaks in.

---

## Cross-reference
- `CLAUDE.md` §1 — Codemagic Personal account gotchas
- `CLAUDE.md` §2 — Admin API key requirement
- `CLAUDE.md` §3 — Cert private key flag
- `CLAUDE.md` §4 — onnxruntime 1.17.0 patch saga
- `CLAUDE.md` §5 — XcodeGen `sdk:` vs `framework:`
- `CLAUDE.md` §6 — Platform.v18 bug on Swift 5.9
- `CLAUDE.md` §7 — IPA artifact path
- `CLAUDE.md` §8 — Beta group name
- `CLAUDE.md` §9 — Info.plist keys
- `CLAUDE.md` §10 — NFC entitlement
- `CLAUDE.md` §11 — Icon alpha
- `CLAUDE.md` §12 — Xcode 26 deadline
