# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-20
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Phase 1 — Wire protocol alignment** (Task 1.3 landed; Task 1.1/1.2 still blocked by USER's WT)

## Ultima task completata (code)
**Task 1.3 — ✅ DONE** — commit `65c5ea4`.
- New canonical helper `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift` matches Android `PhoneHashHelper.kt` byte-for-byte.
- 5 cross-platform vectors appended to `QAudionEngine/Tests/Resources/cross_platform_vectors.json` (US canonical, US formatted, Italian `00`-prefix, default-country fallback, invalid too-short).
- `PhoneHashTests.swift` covers all vectors + normalization edge cases + throwing behavior.
- Callers migrated: `AuthService.swift`, `QAudionAppState.swift` (login/register), `ContactDiscoveryView.swift` (via `hashOrNil`).
- `BCryptoAccountApiImpl.hashPhone` kept as `@deprecated` forwarder to avoid breaking USER WT `ContactSyncService.swift` (D-05 hygiene).

## Phase 0 = COMPLETE ✅
Tutti i 4 task di Phase 0 (0.1 manual + 0.2 + 0.3 + 0.4 tag verify) passati + fix `beta_groups` rimosso (`b470ed8`). Phase 0 invariants validated:
- `aps-environment=production` entitlement ↔ portale capability → firmato ✅
- 6 nuovi SDK linkati (CallKit/PushKit/AVFoundation/CoreNFC/Contacts/ContactsUI) → build verde ✅
- `UIBackgroundModes=[voip,audio]` → nessun warning ITMS ✅
- Xcode 16.2 + onnxruntime 1.17 patch → ancora stabili ✅

## Prossima task (next, unblocked)
- **Task 1.2** — REST endpoint audit vs Android `BCryptoApi.kt` (read-only, safe to run).
- **Phase 2 task 2.1** — FastSetup QR login (new file, no collision). Ready to start.
- Eventual **Task 1.1 WS code fixes** — still blocked on USER's WT (BCryptoCallingApiImpl etc.). Fixes documented in PHASE1_AUDIT.md.

## Prossima verification tag
`v1.0.24-ph1` dopo chiusura Phase 1 completa (1.1 + 1.2 + 1.3).

## Task dependencies blocked
| Task | Blocker | Owner |
|------|---------|-------|
| 1.1 (WS code fix) | User WT must land first | USER → then parity agents rerun audit |
| 1.2 (REST endpoint audit) | Same WT overlap risk; can run as read-only audit | — |

## Task 0.1 completamento
✅ 2026-04-20 — USER ha confermato (screenshot portale) capability Push Notifications abilitata su `com.qaudion.app`.

## Stray files in working tree (not ours, flagged)
- `127` — empty 0-byte file appeared during Task 0.3 work (likely accidental shell redirect). Not deleted by the agent pending user confirmation; harmless.

## Blocker aperti
_(nessuno — Task 0.1 completato 2026-04-20 ✅)_

~~Task 0.1~~ — Push Notifications capability on `com.qaudion.app` → **DONE** by USER, confirmed via portale screenshot.

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
4. `4e230ab chore(ios): link CallKit/PushKit/CoreNFC/Contacts SDK frameworks`
5. `3a313e6 docs(progress): initialize knowledge base`
6. `d915d9b docs(progress): Task 0.3 complete (SDK frameworks linked)`
7. `1c113ac docs(progress): Phase 1.1 WS command audit findings`
8. `b1e6ef9 docs(session): Task 0.1 complete — Push Notifications capability enabled`
9. `7509ae8 docs(progress): Task 0.4 — tag v1.0.24-ph0 pushed to Codemagic`
10. `b470ed8 fix(ci): remove internal beta_groups from codemagic publishing`
11. `65c5ea4 feat(engine): canonical PhoneHash helper matching Android PhoneHashHelper` ← **Task 1.3**
