import Foundation

/// A view model is a pure-data shape consumed by a SwiftUI screen.
///
/// View models in QAudionEngine intentionally do NOT import SwiftUI or Combine.
/// They are values you can build, test, and snapshot from any host (iOS app,
/// macOS catalyst variant, swift-test on Linux CI). The hosting view layer is
/// responsible for wrapping a view model in `@StateObject` / `@ObservedObject`
/// / `@Observable` — none of that is the engine's concern.
///
/// A view model has two responsibilities:
///   1. Expose every datum the screen renders.
///   2. Provide a `mock` factory so previews + tests stay decoupled from
///      live wire data.
public protocol ViewModelProtocol: Equatable, Sendable {
    /// A deterministic mock instance used by SwiftUI previews and unit tests.
    /// Every concrete view model MUST provide a `.mock` value with realistic
    /// (but synthetic) data.
    static var mock: Self { get }
}
