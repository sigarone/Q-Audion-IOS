import Foundation

/// Lazy BCrypto-only system-endpoints client, surfaced via an extension so
/// it lives outside `BCryptoBackendProvider.swift` (that file is in the
/// user's active workstream — see `docs/progress/STATUS.md` working-tree
/// hygiene list). Functionally equivalent to a `lazy var` on the type but
/// implemented with an associated-object-style shim is unnecessary: each
/// access creates a fresh client, and the underlying `BCryptoRestClient`
/// is already cached on the provider.
///
/// If/when the USER workstream lands, this extension can be inlined back
/// onto the main provider as a `lazy var`.
public extension BCryptoBackendProvider {
    /// System endpoints (version / health / directory-by-extension).
    /// Not part of `BackendProvider` protocol — upstream (Signal-style)
    /// backend has no equivalent.
    var systemClient: BCryptoSystemClient {
        BCryptoSystemClient(rest: getRestClient())
    }
}
