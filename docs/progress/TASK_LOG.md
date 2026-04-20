# TASK LOG — append-only

> Una riga per ogni task chiusa. Newest on top. Non cancellare mai, non riordinare.

Format: `YYYY-MM-DD | <phase.task> | <title> | <commit sha|-> | <status> | <note>`

Status codes: `DONE` · `PARTIAL` · `BLOCKED` · `SKIPPED` · `REVERTED`

---

- 2026-04-20 | 1.1 | WS command audit vs Android WsCommand.kt | (kb only) | PARTIAL | 6 drifts found in 1:1 call signalling + 2 group-call schema splits; fixes blocked on USER's WT. See PHASE1_AUDIT.md
- 2026-04-20 | 0.3 | Link CallKit/PushKit/CoreNFC/Contacts SDK frameworks | 4e230ab | DONE | Spec ✅ + Quality ✅; xcodegen/xcodebuild verification deferred to Codemagic
- 2026-04-20 | kb | Initialize docs/progress/ knowledge base | 3a313e6 | DONE | 6 files: README, STATUS, TASK_LOG, DECISIONS, ANDROID_REFERENCE, CODEMAGIC_GUARD
- 2026-04-20 | 0.2 | Declare VoIP background mode + aps-environment | 51b0404 | DONE | Spec ✅ + Quality ✅ (both reviews passed)
- 2026-04-20 | 0.1 | Apple Developer Portal Push Notifications capability | - | BLOCKED | Manual, owner=USER (see SESSION_LOG.md)
- 2026-04-20 | setup | Feature branch + session log + progress KB | 413c9e9 | DONE | Branch `feature/ios-android-parity`
- 2026-04-20 | setup | 13-phase implementation plan | 668f4b8 | DONE | docs/superpowers/plans/2026-04-20-ios-android-parity.md
