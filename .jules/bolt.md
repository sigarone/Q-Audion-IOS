## 2024-05-30 - View model computed property performance
**Learning:** In SwiftUI, view models with computed properties like `var filteredItems: [Item]` that perform O(N log N) sorting and filtering can cause severe performance issues because they are re-evaluated multiple times per render cycle (e.g., in `ForEach` or multiple sections like `pinned` and `regular`).
**Action:** Always memoize expensive operations (sorting/filtering) in the `ViewModel` by computing them once during `init` and storing the result in a `let` property when the struct itself is immutable and recreated on state changes.

## 2026-08-13 - DateFormatter inline instantiation in SwiftUI lists
**Learning:** Instantiating `DateFormatter` inline in SwiftUI list render methods (`ChatListScreen`, `CallHistoryView`) is a known Swift performance bottleneck and causes severe stuttering during scrolling because formatters are repeatedly allocated.
**Action:** Always extract `DateFormatter` instantiations to `private static let` properties in SwiftUI views, preserving formatting logic. Added static formatters for all timestamp formatting to improve scroll performance.

## 2024-05-31 - ISO8601DateFormatter inline instantiation overhead
**Learning:** Just like `DateFormatter`, `ISO8601DateFormatter` instantiation is expensive and can become a severe performance bottleneck when done repeatedly, such as inside data serialization methods that process ring buffers or large data sets (`RuntimeLogSink.swift`).
**Action:** Extract `ISO8601DateFormatter` instantiation to a `private static let` property when used in methods that are called frequently or that iterate over large arrays.

## 2024-05-30 - Stateful lists from ObservableObject array properties
**Learning:** When generating a SwiftUI `List` or `ForEach` that relies on an O(N log N) filtering/sorting operation over an array owned by an `@ObservedObject` (e.g., `groupRegistry.entries`), placing the logic inside a view computed property causes the expensive operation to re-run on EVERY render cycle.
**Action:** Extract the sorted/filtered array into an `@State` variable, create an update function, and call it from `.onAppear` and `.onChange(of: observedObject.entries)` (if the array elements are `Equatable`) to restrict execution exclusively to when the source data changes.

## 2026-08-20 - Synchronous Keychain/UserDefaults reads in SwiftUI computed properties
**Learning:** Performing heavy I/O and cryptographic operations (like reading from `UserDefaults`, decoding JSON, and executing AES-GCM decryption which accesses `SecItemCopyMatching` from the Keychain) inside a SwiftUI computed property (e.g. `adminBanner`) causes severe main-thread blocking and frame drops. This happens because SwiftUI evaluates the computed property repeatedly on every render pass (such as during scrolling or text input).
**Action:** When deriving UI state from encrypted persistence (like `ThreatReportLogStore`), execute the load and decryption asynchronously (e.g. inside `Task.detached` within a `.task` or `.onAppear` modifier) and store the result in an `@State` variable to prevent O(N) Keychain reads during rendering.
