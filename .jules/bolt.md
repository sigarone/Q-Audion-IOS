## 2024-05-30 - View model computed property performance
**Learning:** In SwiftUI, view models with computed properties like `var filteredItems: [Item]` that perform O(N log N) sorting and filtering can cause severe performance issues because they are re-evaluated multiple times per render cycle (e.g., in `ForEach` or multiple sections like `pinned` and `regular`).
**Action:** Always memoize expensive operations (sorting/filtering) in the `ViewModel` by computing them once during `init` and storing the result in a `let` property when the struct itself is immutable and recreated on state changes.

## 2026-08-13 - DateFormatter inline instantiation in SwiftUI lists
**Learning:** Instantiating `DateFormatter` inline in SwiftUI list render methods (`ChatListScreen`, `CallHistoryView`) is a known Swift performance bottleneck and causes severe stuttering during scrolling because formatters are repeatedly allocated.
**Action:** Always extract `DateFormatter` instantiations to `private static let` properties in SwiftUI views, preserving formatting logic. Added static formatters for all timestamp formatting to improve scroll performance.

## 2024-06-25 - Extracted DateFormatter Instantiations in more List Views
**Learning:** `DateFormatter` was still being instantiated inline in methods invoked heavily during list rendering (`GroupChatScreen`, `GroupCallChatPanel`, `DayHeader`, `ContactDetailScreen`). Given Swift's known performance bottleneck around `DateFormatter` allocations, this was triggering unnecessary layout pauses during rapid data changes in group chats.
**Action:** Always extract `DateFormatter` instantiations to `private static let` properties in SwiftUI views, preserving formatting logic.
