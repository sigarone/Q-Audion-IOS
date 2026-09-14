import Foundation

/// Client-side view of the account's plan, derived from the EGT's `fea`
/// claim (design doc §3.1) — never a new field the server sends, purely a
/// local read of what's already there (docs/superpowers/specs/
/// 2026-08-17-client-pro-badge-trial-banner-design.md §2).
public enum PlanStatus: Equatable {
    case base
    case proPerpetual
    case proTrial(daysRemaining: Int, expiresAtSeconds: Int64)
}

/// The anchor feature used to read Pro/trial status: always present in the
/// server's `pro` package (`entitlements_packages.go`, `defaultProPackage`),
/// and a single redemption's grant sets one uniform expiry across every
/// feature it grants (`entitlements_redemption.go`) — so this one key
/// represents the whole account's Pro/trial state today. Known limitation
/// (design doc §2): a future account with two active grants at different
/// expiries could read the wrong one via this single-key approach — not
/// handled here, flagged rather than silently wrong. Matches
/// `Capability.callsVideo.rawValue` (`CapabilityGate.swift`), spelled out
/// as a literal here so this file has zero dependency on `QAudionApp`.
private let anchorFeature = "feat.calls.video"

private let secondsPerDay: Int64 = 86_400

/// Pure, deterministic derivation — takes the current time explicitly
/// rather than reading `Date()`, so it is fully unit-testable with no
/// clock-mocking.
public func derivePlanStatus(claims: EgtClaims?, nowSeconds: Int64) -> PlanStatus {
    guard let expiry = claims?.fea[anchorFeature] else { return .base }
    if expiry == 0 { return .proPerpetual }
    if expiry <= nowSeconds { return .base } // stale cached token; next refresh corrects it
    let secondsRemaining = expiry - nowSeconds
    let daysRemaining = Int((secondsRemaining + secondsPerDay - 1) / secondsPerDay)
    return .proTrial(daysRemaining: daysRemaining, expiresAtSeconds: expiry)
}
