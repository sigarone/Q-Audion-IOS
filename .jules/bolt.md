## 2024-05-30 - View model computed property performance
**Learning:** In SwiftUI, view models with computed properties like `var filteredItems: [Item]` that perform O(N log N) sorting and filtering can cause severe performance issues because they are re-evaluated multiple times per render cycle (e.g., in `ForEach` or multiple sections like `pinned` and `regular`).
**Action:** Always memoize expensive operations (sorting/filtering) in the `ViewModel` by computing them once during `init` and storing the result in a `let` property when the struct itself is immutable and recreated on state changes.

## 2026-08-13 - DateFormatter inline instantiation in SwiftUI lists
**Learning:** Instantiating `DateFormatter` inline in SwiftUI list render methods (`ChatListScreen`, `CallHistoryView`) is a known Swift performance bottleneck and causes severe stuttering during scrolling because formatters are repeatedly allocated.
**Action:** Always extract `DateFormatter` instantiations to `private static let` properties in SwiftUI views, preserving formatting logic. Added static formatters for all timestamp formatting to improve scroll performance.

## 2024-05-31 - ISO8601DateFormatter inline instantiation overhead
**Learning:** Just like `DateFormatter`, `ISO8601DateFormatter` instantiation is expensive and can become a severe performance bottleneck when done repeatedly, such as inside data serialization methods that process ring buffers or large data sets (`RuntimeLogSink.swift`).
**Action:** Extract `ISO8601DateFormatter` instantiation to a `private static let` property when used in methods that are called frequently or that iterate over large arrays.

## 2024-06-05 - Computed Property Performance (Continued)
**Learning:** In SwiftUI, avoid placing O(N) operations like `.filter { ... }` inside view computed properties (e.g., `private var visibleEntries`) because they are executed on every single render pass, leading to stuttering during updates or animations.
**Action:** Extract filtered lists into stored `@State` or `@Published` properties. Update them only when their dependencies change using `.onChange(of:)`, `.onAppear()`, or `didSet` property observers in view models.
