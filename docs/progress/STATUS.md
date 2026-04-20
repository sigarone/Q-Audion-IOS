# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-20
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Phase 0 — Baseline preparation (Codemagic-safe enablers)**

## Ultima task completata
**Task 1.1 (audit)** — Wire protocol WS command audit vs Android `WsCommand.kt`. PARTIAL.
- Commit: docs only (no code; findings in `docs/progress/PHASE1_AUDIT.md`)
- Findings: **6 drifts** on 1:1 call signalling (`recipientId` camelCase, missing `call_id` / `call_type` / `has_video` / `sdp_mid` / `sdp_mline_index` / hangup `reason`) + 2 group-call schema splits needing server-truth reconciliation.
- Code fixes BLOCKED: the affected files (`BCryptoCallingApiImpl.swift`, `CallingApi.swift`, `QAudionCallIntegration.swift`) are in the USER's uncommitted working tree — parity agents must not stage/commit them.

## Prossima task (unblocked)
**Task 1.3** — Create canonical `PhoneHash` helper at `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift` + cross-platform KAT test. New file — no user-WT collision.

## Task dependencies blocked
| Task | Blocker | Owner |
|------|---------|-------|
| 0.4 (Codemagic tag v1.0.24-ph0) | Task 0.1 Apple Dev Portal manual action | USER |
| 1.1 (WS code fix) | User WT must land first | USER → then parity agents rerun audit |
| 1.2 (REST endpoint audit) | Same WT overlap risk; can run as read-only audit | — |

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
