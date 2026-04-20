# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-20
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Phase 0 — Baseline preparation (Codemagic-safe enablers)**

## Ultima task completata (code)
**Task 0.4 — IN PROGRESS** — Codemagic verification tag `v1.0.24-ph0` pushed at commit `b1e6ef9`. Build in corso su Codemagic.
- Branch `feature/ios-android-parity` pushed to origin (9 commits from `main`)
- Tag `v1.0.24-ph0` pushed → triggers `qaudion-app-build` workflow
- Expected outcome: TestFlight build 2 @ version 1.0.0 delivered to "Q-Audion testers" group

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
