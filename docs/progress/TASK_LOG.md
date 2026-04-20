# TASK LOG — append-only

> Una riga per ogni task chiusa. Newest on top. Non cancellare mai, non riordinare.

Format: `YYYY-MM-DD | <phase.task> | <title> | <commit sha|-> | <status> | <note>`

Status codes: `DONE` · `PARTIAL` · `BLOCKED` · `SKIPPED` · `REVERTED`

---

- 2026-04-20 | 1.4-b1 | Contacts sync schema + blocked decode aligned with Android | baf314d | DONE | `ContactsApi.syncContacts` signature changed to `(entries: [SyncContactEntry])`; iOS now sends `{contacts:[{contact_user_id,display_name?,local_alias?}]}` matching `SyncContactsRequest`. `getBlockedContacts` returns `[BlockedContact]` decoded from `{blocked:[{user_id,blocked_at?}]}` matching `BlockedContactsResponse`. Both BCrypto + Upstream impls updated. New `BCryptoContactsWireFormatTests.swift` pins the wire shape. Resolves PHASE1_REST_AUDIT.md §3.4 + §3.5. No callers in repo → no UI adaptation required.
- 2026-04-20 | 1.4-a | D-CRITICAL auth wire fixes (register hash+password, login phone_number key) | 2e78912 | DONE | `BCryptoAccountApiImpl.register` now hashes phone via `PhoneHash.hash(_:)` and sends `{phone_number: <hash>, password, invite_code?, display_name?}` matching Android RegisterRequest. `login` sends `phone_number` (not `phone_hash`) matching LoginRequest. Protocol signature + callers (AuthService/QAudionAppState/RegisterView/WelcomeView) updated. New `BCryptoAuthWireFormatTests.swift` with URLProtocol stub verifies byte-for-byte wire shape. Resolves PHASE1_REST_AUDIT.md §3.1 + §3.2.
- 2026-04-20 | 1.2 | REST endpoint audit vs Android BCryptoApi.kt | 82cb970 | DONE | 35 Android endpoints catalogued in PHASE1_REST_AUDIT.md. iOS covers 24; 11 missing; 12 payload drifts; 10 iOS-only extras. 2 D-CRITICAL: login field key mismatch + register missing password/hash. Android WT verified untouched. Fix plan (8 steps) deferred to new Task 1.4 — no USER-WT conflict.
- 2026-04-20 | 1.3 | Canonical PhoneHash helper + Android cross-platform vectors | 65c5ea4 | DONE | New `QAudionEngine/Utils/PhoneHash.swift` byte-for-byte matches Android `PhoneHashHelper.kt`. 5 vectors added to `cross_platform_vectors.json`. Callers migrated in AuthService/QAudionAppState/ContactDiscoveryView; `BCryptoAccountApiImpl.hashPhone` kept as @deprecated forwarder for user WT ContactSyncService.
- 2026-04-20 | 0.4-fix | Remove `beta_groups: [Q-Audion testers]` from codemagic.yaml | b470ed8 | DONE | Internal group auto-assigned; API rejected explicit add; see DECISIONS D-11 + CODEMAGIC_GUARD I-11
- 2026-04-20 | 0.4 | Push Codemagic verification tag v1.0.24-ph0 | tag b1e6ef9 | DONE | Build #40: core green, IPA `43328e71-44c2-4376-96cd-9c2dd2420424` LIVE on TestFlight. Codemagic "post-processing failed" = false positive (internal group config bug, now fixed).
- 2026-04-20 | 0.1 | Apple Developer Portal Push Notifications capability | b1e6ef9 | DONE | User manual action, logged in SESSION_LOG.md
- 2026-04-20 | 1.1 | WS command audit vs Android WsCommand.kt | (kb only) | PARTIAL | 6 drifts found in 1:1 call signalling + 2 group-call schema splits; fixes blocked on USER's WT. See PHASE1_AUDIT.md
- 2026-04-20 | 0.3 | Link CallKit/PushKit/CoreNFC/Contacts SDK frameworks | 4e230ab | DONE | Spec ✅ + Quality ✅; xcodegen/xcodebuild verification deferred to Codemagic
- 2026-04-20 | kb | Initialize docs/progress/ knowledge base | 3a313e6 | DONE | 6 files: README, STATUS, TASK_LOG, DECISIONS, ANDROID_REFERENCE, CODEMAGIC_GUARD
- 2026-04-20 | 0.2 | Declare VoIP background mode + aps-environment | 51b0404 | DONE | Spec ✅ + Quality ✅ (both reviews passed)
- 2026-04-20 | 0.1 | Apple Developer Portal Push Notifications capability | - | DONE | Manual by USER; screenshot confirmed checkbox enabled
- 2026-04-20 | setup | Feature branch + session log + progress KB | 413c9e9 | DONE | Branch `feature/ios-android-parity`
- 2026-04-20 | setup | 13-phase implementation plan | 668f4b8 | DONE | docs/superpowers/plans/2026-04-20-ios-android-parity.md
