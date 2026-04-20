# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-20
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Phase 0 — Baseline preparation (Codemagic-safe enablers)**

## Ultima task completata
**Task 0.2** — Declare VoIP background mode + `aps-environment` entitlement. ✅
- Commit: `51b0404 feat(ios): declare voip background mode + aps-environment`
- Touched: `QAudionApp/Info.plist`, `QAudionApp/QAudion.entitlements`
- Status: **DONE** (spec review ✅, code-quality review ✅).

## Prossima task
**Task 0.3** — `QAudionApp/project.yml`: link `CallKit`, `PushKit`, `AVFoundation`, `CoreNFC`, `Contacts`, `ContactsUI` via `sdk:` style.
Then: **Task 0.4** — Codemagic verification tag `v1.0.24-ph0` (pushed ONLY after Task 0.1 done by USER).

## Blocker aperti
| ID | Owner | Descrizione | Sblocca |
|----|-------|-------------|---------|
| 0.1 | **USER (manual)** | Enable **Push Notifications** capability on `com.qaudion.app` in developer.apple.com portal. See `SESSION_LOG.md`. | Task 0.4 |

## Working-tree hygiene (DO NOT COMMIT FROM PARITY EFFORT)
Pre-existing user BCrypto workstream (uncommitted):
- `QAudionApp/Services/ContactSyncService.swift` (untracked)
- `QAudionEngine/.../BCrypto/BCryptoBackendProvider.swift` (M)
- `QAudionEngine/.../BCrypto/BCryptoCallingApiImpl.swift` (M)
- `QAudionEngine/.../BCrypto/BCryptoGroupCallManager.swift` (M)
- `QAudionEngine/.../BCrypto/BCryptoWebSocketClient.swift` (M)
- `QAudionEngine/.../Protocols/CallingApi.swift` (M)
- `QAudionEngine/.../Integration/QAudionCallIntegration.swift` (M)
- `QAudionEngine/.../BCrypto/BCryptoPresenceManager.swift` (untracked)

These belong to the USER and must remain out of parity-effort commits.

## Commits fatti su `feature/ios-android-parity`
1. `668f4b8 docs: implementation plan for iOS↔Android full parity`
2. `413c9e9 docs(session): log Phase 0 kickoff + Apple Dev portal blocker (Task 0.1)`
3. `51b0404 feat(ios): declare voip background mode + aps-environment`
