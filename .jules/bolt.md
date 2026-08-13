## 2026-08-13 - DateFormatter inline instantiation in SwiftUI lists
**Learning:** Instantiating `DateFormatter` inline in SwiftUI list render methods (`ChatListScreen`, `CallHistoryView`) is a known Swift performance bottleneck and causes severe stuttering during scrolling because formatters are repeatedly allocated.
**Action:** Always extract `DateFormatter` instantiations to `private static let` properties in SwiftUI views, preserving formatting logic. Added static formatters for all timestamp formatting to improve scroll performance.
