# ChatView Consolidation Analysis

> **Generated:** 2026-04-28 (F2.1).
> **Decision needed before:** Track B.6 (chat parity) or A.6 settings split, whichever lands first.

## Two files exist

| Aspect | `QAudionApp/Views/ChatView.swift` | `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift` |
|---|---|---|
| LOC | 133 | 106 (incl. `ChatMessage` model) |
| Imports | `SwiftUI`, `QAudionEngine` | `SwiftUI` only |
| Public surface | `internal struct ChatView` (no public modifier) | `public struct ChatView`, `public struct ChatMessage` |
| State management | `@EnvironmentObject var appState: AppState` (app-level type); reads `appState.currentMessages`; `@State private var messageText`; `@State private var scrollToBottom` | `@EnvironmentObject var appState: QAudionAppState` (engine-level type); `@State private var messageText`; `@State private var messages: [ChatMessage]` (local array, not sourced from app state) |
| Server calls | Delegates to `appState.sendMessage(to:text:)` and `appState.loadMessages(for:)` — real async calls through the engine API layer | `appState.backend?.messageApi.sendMessage(recipientId:content:)` called directly with `Data(text.utf8)` (comment: "In production: encrypt with session key") — encryption stub, not wired to key material |
| Subviews | `MessageBubbleView` (external subview imported from engine, showing `isSent`, `text`, `timestamp`, `isEncrypted` fields); `encryptionBanner` (inline computed property); `inputBar` (inline computed property) | `messageBubble(_:)` (inline private func only); no encryption banner; no external subview |
| Attachments | None | None |
| Navigation / toolbar | Custom `.principal` toolbar with lock icon + contact name; trailing phone-call button wired to `appState.startCall(contactId:video:)`; `.task { await appState.loadMessages(for:) }` on appear | `.navigationTitle(contactName)` only; two stub call buttons (audio/video) with empty `action: {}` closures — not wired |
| Scroll behaviour | `ScrollViewReader` with `onChange(of: messages.count)` and `onAppear` to scroll to last message | Plain `ScrollView` — no auto-scroll |
| Encryption indicator | Top banner ("End-to-end encrypted") + lock icon in toolbar | None |
| Message model | Uses `Message` type sourced from `appState.currentMessages` with `.isEncrypted` field | Defines its own `ChatMessage` (id, text, isOutgoing, timestamp) — no encryption field; appended locally, not persisted |
| Last commit touching it | `6ea59f3 fix(app): resolve all iOS 15 compat + API mismatch errors` | `9103a3d feat: full iOS-Android-Server alignment — end-to-end cross-platform compatibility` |

## Recommendation

Keep app-level, delete engine-level (engine view is dead code).

**Rationale:** `QAudionApp/Views/ChatView.swift` is the file actually used in production navigation. `ConversationListView` (the app-level file at `QAudionApp/Views/ConversationListView.swift`) navigates directly to this struct. The engine-level `ChatView` is navigated to only by the engine-internal `QAudionMainView.ConversationListView` — itself a duplicate list view that is not wired into the app's main `ContentView` or `AppState`. The app-level view is richer in every measurable way: real async message loading, `ScrollViewReader` auto-scroll, an encryption banner, a wired phone-call button, and it delegates correctly through `AppState` rather than holding a detached local array. The engine-level view has a commented-out encryption stub (`// In production: encrypt with session key`) and stub call buttons with empty closures — clear signals it was never completed. The most recent commit touching the engine-level file (`9103a3d`) is older than the app-level file's last commit (`6ea59f3`), confirming active development continued on the app-level copy.

One concern worth noting: the engine-level `ChatMessage` model defined in `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift` is not used anywhere outside that file (the app-level view uses a different `Message` type from `AppState`). Deleting the file removes both the dead view and the dead model with no collateral impact.

## Action item for the next plan

B.6 Step 1: delete `QAudionEngine/Sources/QAudionEngine/UI/ChatView.swift` and confirm `QAudionEngine/Sources/QAudionEngine/UI/QAudionMainView.swift`'s `ConversationListView` (which also references `ChatView`) either uses the app-level import or is itself cleaned up.
