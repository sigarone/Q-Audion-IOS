# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-20
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Phase 0 — Baseline preparation (Codemagic-safe enablers)**

## Ultima task completata (code)
**Task 0.4 — ✅ DONE (effectively)** — Codemagic build #40 (tag `v1.0.24-ph0`, commit `b1e6ef9`).
- **Build steps**: TUTTI verdi ✅ (Signing 4s, Build IPA 39s, onnxruntime patch, Publishing upload 54s)
- **IPA prodotto**: 7.74 MB + dSYM 4.07 MB — UUID `43328e71-44c2-4376-96cd-9c2dd2420424`
- **App Store Connect processing**: ✅ FINITO, build VALIDO (nessun ITMS rejection)
- **TestFlight**: build è LIVE per i tester interni (gruppo `Q-Audion testers`) — auto-assigned
- **Failure post-processing**: era un falso positivo di `codemagic.yaml` — tentava di assegnare un gruppo INTERNO via API (API rifiuta perché Apple auto-assigna i gruppi interni).

## Fix applicato (commit da fare)
Rimosso `beta_groups: [Q-Audion testers]` da `codemagic.yaml` — `submit_to_testflight: true` basta, Apple auto-assegna i gruppi interni. Aggiornato CODEMAGIC_GUARD I-11 + DECISIONS D-11.

## Phase 0 = COMPLETE ✅
Tutti i 4 task di Phase 0 (0.1 manual + 0.2 + 0.3 + 0.4 tag verify) passati. Phase 0 invariants validated:
- `aps-environment=production` entitlement ↔ portale capability → firmato ✅
- 6 nuovi SDK linkati (CallKit/PushKit/AVFoundation/CoreNFC/Contacts/ContactsUI) → build verde ✅
- `UIBackgroundModes=[voip,audio]` → nessun warning ITMS ✅
- Xcode 16.2 + onnxruntime 1.17 patch → ancora stabili ✅

## Prossima task
**Phase 1.3** — Canonical `PhoneHash` helper (no user-WT collision).
Prossima verification tag: `v1.0.24-ph1` dopo chiusura Phase 1.

## Prossima task (next, unblocked)
- **Attesa esito Codemagic** — se ❌ diagnosticare (probabile suspect: onnxruntime patch, signing, nuovi SDK link).
- **Task 1.3** — Canonical `PhoneHash` helper (new file, no user-WT collision).

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
