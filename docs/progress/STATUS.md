# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-28
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Spec:** `docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md`
**Active plan:** `docs/superpowers/plans/2026-04-28-track-a-foundation.md`
**Predecessor plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Track A Foundation Sprint — IN PROGRESS** (`docs/superpowers/plans/2026-04-28-track-a-foundation.md`).
- F0 (Invariants verification) — ✅ DONE — see `docs/progress/INVARIANTS_VERIFIED.md` (10 open discrepancies catalogued)
- F1 (UI ViewModels: KeyMgmt + DeviceMgmt + NfcExchange + InCall + SasVerification) — ✅ DONE — 6 commits (`19fd9dd`, `fbffe3d`, `ecb8a5f`, `c3c9b31`, `cae30d3`, `d59bbd3`); ~26 unit tests across 6 ViewModels (`swift test` deferred to GitHub Actions `engine-tests.yml` since `swift` not on Windows)
- F2 (Platform scaffolding: ChatView consolidation + stray-files + ANDROID_REFERENCE WS-envelope correction) — IN PROGRESS
- F3 (Closeout) — pending

## Predecessor phases — ✅ DONE (do not redo)
**Phase 0** (capability + pipeline baseline) — `b470ed8`, `4e230ab`, `51b0404`, `b1e6ef9`. All 4 tasks landed. TestFlight `v1.0.24-ph0` green.

**Phase 1** (REST wire alignment) — CODE-COMPLETE except:
- Task 1.1 WS code fixes — **BLOCKED** by USER WT (`BCryptoCallingApiImpl` etc.).
- Audit §3.6–§3.8 backup transport — deferred to Track B (`.qabk` format now flagged as Desktop↔Android incompatible — Open discrepancy §10).
- Audit §3.11–§3.15 security endpoints — TODO in `BCryptoSecurityApiImpl`; server-team clarification needed (Open discrepancy from spec §10.2).

## Ultima task completata (audit)
**Task 1.2 — ✅ DONE (audit)** — `docs/progress/PHASE1_REST_AUDIT.md`.
- 35 Android endpoints catalogued; iOS covers 24; 11 missing; 12 payload drifts; 10 iOS-only extras.
- 2 D-CRITICAL findings: `auth/login` sends `phone_hash` key (server expects `phone_number`) + `register` sends raw phone & misses `password`/`display_name` → cross-platform auth currently broken.
- 5 security endpoints (zk-register, zk-auth, pqc-relay, threat-report, wipe-confirm) have completely different schemas from Android.
- `backup/*` transport/format wrong (JSON+base64 vs multipart+streaming).
- Android working tree untouched by the audit (verified via `git status` in Android repo).
- Fix plan (8 steps, §5 of audit doc) deferred to new Task 1.4 — none blocked by USER WT.

## Ultima task completata (code)
**Task 1.4-b5 — ✅ DONE** — commit `a0a70ed`.
- `BCryptoSecurityApiImpl.swift`: all 5 security endpoints (`zkRegister`, `zkAuth`, `sendPqcKeyExchange`, `reportThreat`, `confirmWipe`) annotated with `TODO(parity, §3.11..§3.15)` flagging wire-schema divergence from Android. **No wire-behavior change** — `zkRegister` TODO explicitly instructs future agents NOT to auto-rewrite without server-contract confirmation.
- `getCertInfo` / `getComplianceInfo` tagged iOS-only (no Android counterpart).
- `PHASE1_REST_AUDIT.md` §3.11–§3.15 marked "*(TODO in code — pending server-team clarification)*".

**Task 1.4-b4 — ✅ DONE** — commit `c0c8026`. AccountApi gained `recoverySetup/recoveryVerify/getPublicUser`; new `BCryptoSystemClient` (`version/health/directory-by-extension`) surfaced via `BCryptoBackendProvider+System.swift` extension file.

**Task 1.4-b3 — ✅ DONE** — commit `04f706b`. `AccountApi.updateProfile` now `(displayName?, statusMessage?, avatarUrl?)` JSON-only matching Android `UpdateProfileRequest`.

**Task 1.4-b2 — ✅ DONE** — commit `c6e605e`. KMS `registerPublicKey` + `getPendingKeys` envelope aligned with Android `DevicePublicKeyRequest` / `KmsKeyDto`.

**Task 1.4-b1 — ✅ DONE** — commit `baf314d`. Contacts `syncContacts` + `getBlockedContacts` aligned with Android `SyncContactsRequest` / `BlockedContactsResponse`.

**Task 1.4-a — ✅ DONE** — commit `2e78912`. D-CRITICAL auth fixes (`register` hashes phone + sends password; `login` uses `phone_number` key).

**Task 1.3 — ✅ DONE** — commit `65c5ea4`. Canonical `PhoneHash` helper + cross-platform vectors.

## Phase 0 = COMPLETE ✅
Tutti i 4 task di Phase 0 (0.1 manual + 0.2 + 0.3 + 0.4 tag verify) passati + fix `beta_groups` rimosso (`b470ed8`). Phase 0 invariants validated:
- `aps-environment=production` entitlement ↔ portale capability → firmato ✅
- 6 nuovi SDK linkati (CallKit/PushKit/AVFoundation/CoreNFC/Contacts/ContactsUI) → build verde ✅
- `UIBackgroundModes=[voip,audio]` → nessun warning ITMS ✅
- Xcode 16.2 + onnxruntime 1.17 patch → ancora stabili ✅

## Prossima task (next, unblocked)
- **User decision** on audit §3.6–§3.8 (backup transport: multipart upload / streaming download / `BackupEntryDto`) — land before `v1.0.24-ph1` tag or defer to Phase 2. Currently unblocked.
- **Tag `v1.0.24-ph1`** — push to Codemagic after §3.6–§3.8 decision; verifies Phase 1 REST alignment end-to-end.
- **Phase 2 task 2.1** — FastSetup QR login (new file, no collision). Ready to start.
- Eventual **Task 1.1 WS code fixes** — still blocked on USER's WT (`BCryptoCallingApiImpl` etc.). Fixes documented in `PHASE1_AUDIT.md`.
- §3.11–§3.15 security endpoints — **blocked on server-team clarification** (TODO'd in `BCryptoSecurityApiImpl`). Will not be progressed by parity agents.

## Prossima verification tag
`v1.0.24-ph1` dopo chiusura Phase 1 completa (1.1 + 1.2 + 1.3 + **1.4 new**).

## Task dependencies blocked
| Task | Blocker | Owner |
|------|---------|-------|
| 1.1 (WS code fix) | User WT must land first | USER → then parity agents rerun audit |
| 1.2 (REST audit) | DONE 2026-04-20 — see PHASE1_REST_AUDIT.md | — |
| 1.4 (REST schema fixes) | Unblocked — files outside USER WT. Ready to start | parity agents |

## Task 0.1 completamento
✅ 2026-04-20 — USER ha confermato (screenshot portale) capability Push Notifications abilitata su `com.qaudion.app`.

## Stray files in working tree (not ours, flagged)
- `127`, `'`, `[DiscoveredContact]`, `.allocate(capacity`, `2`, `AuthCredentials`, `Bool`, `0`, `ComplianceInfo`, `PublicUser,`, `String`, `Void)` — empty 0-byte files, accidental shell redirects from USER or IDE sessions. Not deleted by the agent pending user confirmation; harmless.

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
12. `74da7cd docs(progress): Task 1.3 DONE — canonical PhoneHash helper landed`
13. `82cb970 docs(progress): Task 1.2 — REST endpoint audit vs Android BCryptoApi.kt`
14. `2e78912 feat(auth): align register+login wire format with Android (D-CRITICAL)` ← **Task 1.4-a**
15. `5b4f32c docs(progress): record Task 1.4-a commit sha in TASK_LOG`
16. `baf314d fix(engine): align Contacts sync + blocked REST schema with Android` ← **Task 1.4-b1**
17. `cd0cc3c docs(progress): record Task 1.4-b1 commit sha (baf314d)`
18. `c6e605e fix(engine): align KMS device/publickey + kms/pending with Android` ← **Task 1.4-b2**
19. `716e044 docs(progress): record Task 1.4-b2 commit sha (c6e605e)`
20. `04f706b fix(engine): align Profile updateProfile with Android UpdateProfileRequest` ← **Task 1.4-b3**
21. `b9a91b6 docs(progress): record Task 1.4-b3 commit sha (04f706b)`
22. `c0c8026 feat(engine): add missing Android REST endpoints (recovery + users + system)` ← **Task 1.4-b4**
23. `b44a1d7 docs(progress): record Task 1.4-b4 commit sha (c0c8026)`
24. `a0a70ed docs(parity,security): flag §3.11-§3.15 security REST schema drift as TODO` ← **Task 1.4-b5**
