# STATUS — iOS ↔ Android Parity Effort

> **Sovrascritta a ogni task.** Snapshot di DOVE siamo ADESSO.

**Last updated:** 2026-04-28
**Branch:** `feature/ios-android-parity` (off `main` @ 4516e01)
**Spec:** `docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md`
**Active plan:** `docs/superpowers/plans/2026-04-28-track-a-foundation.md`
**Predecessor plan:** `docs/superpowers/plans/2026-04-20-ios-android-parity.md`

## Fase attiva
**Track A.2 / A.3 / A.5 / A.6 — IN PROGRESS** — Code work landed in 4 parallel waves on 2026-04-28.

**Foundation Sprint** (`docs/superpowers/plans/2026-04-28-track-a-foundation.md`) — ✅ DONE
- F0 (Invariants) ✅ · F1 (6 ViewModels, ~26 tests) ✅ · F2 (hygiene) ✅ · F3 (closeout) ✅

**Track A.2 NFC + Key mgmt** — partial
- A.2.A.1 ✅ NfcPskDerivation + structural KAT (`422f8c8`)
- A.2.B.1 ✅ NfcCollaborativeExchange skeleton + state-machine tests (`a4fd17b`)
- A.2.B.2 — pending (CoreNFC APDU exchange, requires physical iPhone+Android-HCE smoke test)
- A.2.C.1 — BLOCKED on USER WT WS public surface
- A.2.D.x — pending (KeyManagementView / DeviceManagementView / NfcExchangeView refactors)

**Track A.3 CallKit** — partial
- A.3.A.1 ✅ CallKitManaging protocol + MockCallKitManager + 6 tests (`49393b7`)
- A.3.B.1 ✅ CallKitProvider concrete iOS-only impl (`16dc987`)
- A.3.C.1 ✅ AppState wiring with closure bridges (`98b3dfa` — combined with A.5.B.1)

**Track A.4 In-call UI** — pending Wave 5

**Track A.5 PushKit** — partial
- A.5.A.1 ✅ PushKitProvider + payload decoder + 5 tests (`49393b7` — landed in same commit as A.3.A.1 due to parallel-collision; content correct)
- A.5.B.1 ✅ AppState wiring with token registration + incoming-push → CallKit handoff (`98b3dfa`)
- DELIVERY still SERVER-BLOCKED per spec §10.1 (server team must pick option α/β/γ/δ)

**Track A.6 Settings 11-section restructure** — partial
- A.6.A.1 ✅ AccountSettingsViewModel (`2f5af13`)
- A.6.A.2 ✅ SecurityDashboardViewModel (`a803341`)
- A.6.A.3 ✅ PrivacySettingsViewModel (`25bb186`)
- A.6.A.4 ✅ CallsSettingsViewModel (`3d6bbf2`)
- A.6.A.5 ✅ ChatSettingsViewModel (`0862ba0`)
- A.6.A.6 ✅ NotificationsSettingsViewModel (`9333eb0`)
- A.6.A.7 ✅ AboutSettingsViewModel (`163f75b`)
- A.6.A.8 ✅ TransportSettingsViewModel (`f19a28b`)
- A.6.A.9 ✅ BackupSettingsViewModel (`13bc292` — UI scaffolds, upload/restore BLOCKED per Open Discrepancy §10)
- A.6.B (SettingsHubView + 11 sub-screens) — pending Wave 5

## Next phase
**Track A.2-A.6 — feature plans LANDED, ready to execute.** Suggested execution order based on dependency analysis: **A.3 → A.5 → A.4 → A.2 → A.6** (CallKit before PushKit before InCall UI; NFC and Settings independent of call stack).

- `docs/superpowers/plans/2026-04-28-track-a2-nfc-keymgmt.md` — NFC iOS-reader pairing + Key/Device mgmt views (PSK §5.5 + KAT vectors)
- `docs/superpowers/plans/2026-04-28-track-a3-callkit.md` — CallKitManaging protocol + iOS-only provider + AppState wiring
- `docs/superpowers/plans/2026-04-28-track-a4-incall-ui.md` — 7-element in-call UI consuming F1.5/F1.6 VMs
- `docs/superpowers/plans/2026-04-28-track-a5-pushkit.md` — PushKitProvider scaffolding (delivery SERVER-BLOCKED §10.1)
- `docs/superpowers/plans/2026-04-28-track-a6-settings.md` — SettingsHubView + 11 sub-screens + 9 new VMs + reuse F1.2/F1.3

## Open server-team / cross-team questions (carried from spec §10 + INVARIANTS_VERIFIED.md)
- §10.1 — APNs VoIP push: server team to pick option α/β/γ/δ
- §10.2 — security endpoints (zk-register/zk-auth/pqc-relay/threat-report/wipe-confirm) schema decision
- §10.3 — GroupChat — iOS UX decision (Android-folded vs Desktop-separate)
- §10.4 — Phonebook import scope decision
- 10 INVARIANTS_VERIFIED.md "Open discrepancies" — cross-team sign-off requested before any wire-touching work resumes (most critical: `.qabk` Desktop↔Android container incompatibility, fingerprint display format iOS/Desktop drift)

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

**Verified empty (0-byte) at 2026-04-28 — accidental shell redirects from prior sessions:**
- `.allocate(capacity` (also flagged 04-20)
- `120`
- `Note`

(The 2026-04-20 inventory listed `127`, `'`, `[DiscoveredContact]`, `2`, `AuthCredentials`, `Bool`, `0`, `ComplianceInfo`, `PublicUser,`, `String`, `Void)` — those have been cleaned up; only the three above remain as of 2026-04-28.)

These are harmless and DO NOT impact build. Parity agents will not auto-delete them (some look like USER's accidental keypresses); the user should `rm` them at their convenience.

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
