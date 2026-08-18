import SwiftUI
import CryptoKit
import QAudionEngine

/// Entitlements Task 5 (design doc §7.2) — the lock-badge wrapper every
/// gated UI trigger site uses: a control that stays visible and tappable
/// whether or not it is entitled (never removed from the layout, never
/// disabled-and-greyed-to-nothing), dimmed with a small lock glyph when
/// locked, and routed to `onLockedClick` (opening `UpgradeSheet`) instead
/// of `action` while locked. SwiftUI port of Android's `GatedActionButton`
/// (`core-ui/.../components/GatedActionButton.kt`, shipped after 2 review
/// rounds there) — this file applies both fixes that review already found
/// rather than re-discovering them here:
///   - **I1 (fail-open default)**: `onLockedClick` is a REQUIRED parameter,
///     not an optional defaulting to `action` — a locked tap must never
///     silently perform the real action.
///   - **I3 (accessibility)**: the lock glyph carries its own
///     `accessibilityLabel` and the whole control keeps `.isButton` traits,
///     so VoiceOver actually announces the locked state instead of reading
///     a locked control identically to an unlocked one.
///
/// Callers compute `unlocked` themselves, typically via
/// `capabilityGate.isUnlocked(capability)` — see
/// `CapabilityGate.isUnlocked(_:)`'s own doc for why that method, never
/// `!capabilityGate.has(capability)`, is the correct read for a lock-badge
/// decision (the two disagree exactly on "no grant loaded yet", which must
/// render unlocked, not locked). Every call site declares its OWN
/// `@EnvironmentObject var capabilityGate: CapabilityGate` (available since
/// Task 5's fix injecting it at the app root) so the `unlocked` value it
/// passes in is itself reactive — this view does not read `capabilityGate`
/// directly, matching Android's `GatedActionButton` staying
/// capability-agnostic so it has no dependency on where the gate lives.
struct GatedActionButton<Content: View>: View {
    let unlocked: Bool
    let action: () -> Void
    let onLockedClick: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button {
            if unlocked { action() } else { onLockedClick() }
        } label: {
            ZStack(alignment: .topTrailing) {
                content()
                    .opacity(unlocked ? 1.0 : 0.55)
                if !unlocked {
                    LockBadgeGlyph()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

/// Visual-only counterpart to `GatedActionButton`, for a site whose
/// `content` already owns its own tap handling (e.g. `VpnToggleChip`,
/// which has its own `Button` plus a long-press gesture for the exit
/// picker) — nesting a second tappable control around an already-tappable
/// child is dead code in SwiftUI (the inner control consumes the tap
/// first) as well as bad accessibility practice (two overlapping click
/// targets). This applies only the dim + lock-badge visuals; the caller
/// routes the tap itself, typically branching its own action closure on
/// the same `unlocked` value passed here. Mirrors Android's
/// `GatedVisualBadge`.
struct GatedVisualBadge<Content: View>: View {
    let unlocked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .opacity(unlocked ? 1.0 : 0.55)
            if !unlocked {
                LockBadgeGlyph()
            }
        }
    }
}

/// The small corner lock glyph both wrappers above render — pulled out
/// once so the visual treatment (size, offset, background) cannot drift
/// between the two.
private struct LockBadgeGlyph: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(Color.black.opacity(0.6)))
            .offset(x: 3, y: -3)
            .accessibilityLabel("Funzione Pro bloccata")
    }
}

/// Entitlements Task 5 — SwiftUI port of Android's `gatedEntry` (Nav3 entry
/// wrapper, `navigation/GatedEntry.kt`): wraps a `NavigationLink`
/// destination so a locked whole-screen `Capability` (key management,
/// backup, voice enrollment — the 3 capabilities that gate an entire
/// settings sub-screen rather than a single button) renders `UpgradeSheet`
/// instead of the real screen. The row that PUSHES this destination is
/// NEVER hidden or disabled (design doc §7.2: a control that vanishes
/// reads as a bug) — only the CONTENT the push lands on changes, exactly
/// like Android's entry swap. Reactive by construction: reads
/// `capabilityGate.isUnlocked(capability)` from `@EnvironmentObject`,
/// so a grant that lands after this destination is already on-screen
/// (a redemption completed from the upsell right here) flips it to the
/// real content on the next recomposition, no back-and-forth navigation
/// required.
///
/// Reuses `UpgradeSheet` itself as the locked-state content rather than
/// building a second, parallel "upsell page" type — same
/// `UpgradeSheetContainer` redeem logic Task 4 already tested, pushed
/// instead of sheeted. `UpgradeSheet`'s own `.presentationDetents(_:)` /
/// drag-capsule handle are sheet-only affordances that render as
/// harmless no-ops in a pushed `NavigationLink` destination (SwiftUI
/// ignores a presentation-only modifier outside its matching
/// presentation context) — not worth a second bespoke layout for a
/// UNVERIFIED-by-render distinction (no simulator in this environment;
/// see Task 5's own report for the disclosed gap).
struct GatedScreenEntry<Destination: View>: View {
    let capability: Capability
    @EnvironmentObject private var capabilityGate: CapabilityGate
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        if capabilityGate.isUnlocked(capability) {
            destination()
        } else {
            UpgradeSheet(capability: capability)
                .navigationTitle("Funzione Pro")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Lets `Capability` drive a `.sheet(item:)` binding directly
/// (`@State private var upgradeSheetCapability: Capability?`) — the
/// convention every multi-capability screen in Task 5 uses instead of one
/// `Bool` flag per capability, since several real screens
/// (`ChatDetailScreen`, `GroupChatScreen`) gate more than one `Capability`
/// and a single optional-capability state var covers all of them with one
/// `.sheet` modifier.
extension Capability: Identifiable {
    public var id: String { rawValue }
}

extension CapabilityGate {
    /// Preview-only convenience — every Task 5 call site's `#Preview`
    /// gained a `@EnvironmentObject var capabilityGate: CapabilityGate`
    /// dependency once it started reading `capabilityGate.isUnlocked(_:)`
    /// reactively; without an injected instance, SwiftUI fatal-errors at
    /// preview render time ("no ObservableObject of type CapabilityGate
    /// found"). This throwaway verifier/API pair is never actually
    /// invoked by a preview — `isUnlocked(_:)` reads `claims` directly and
    /// `claims` starts `nil`, so every preview renders every capability
    /// UNLOCKED (design intent: `isUnlocked` treats "nothing loaded yet"
    /// as unlocked, see that method's own doc).
    ///
    /// NOT `#if DEBUG`-guarded, on purpose: `#Preview` blocks compile
    /// unconditionally in this project (no ENABLE_PREVIEWS stripping in
    /// the Release/archive build config), so a DEBUG-only definition here
    /// left every one of the 9 `#Preview` call sites that reference it
    /// unresolved during the TestFlight archive build — confirmed via the
    /// v1.0.1001 CI failure ("type 'CapabilityGate' has no member
    /// 'previewInstance'" in VpnToggleChip.swift and 6 other files).
    static func previewInstance() -> CapabilityGate {
        let key = Curve25519.Signing.PrivateKey()
        let verifier = EgtVerifier(pinnedPublicKeyRaw: key.publicKey.rawRepresentation)!
        return CapabilityGate(verifier: verifier, api: BCryptoEntitlementsApiClient())
    }
}
