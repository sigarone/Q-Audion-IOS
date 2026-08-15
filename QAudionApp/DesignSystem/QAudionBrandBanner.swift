import SwiftUI

/// Shield+"Q-AUDION" wordmark strip, drawn at the top of each of the four
/// main screens (Chat/Contatti/Chiamate/Impostazioni) — 1:1 with Android's
/// `HomeShell.kt` topBar Image (same `QAudionWordmark` asset — byte-identical
/// PNG, see SplashScreen.swift's own W-BRAND parity note — same 32pt height
/// / aspect-fit scale, same left-aligned placement).
///
/// W-BRAND (2026-08-15): NOT attached via `.safeAreaInset` on the shared
/// TabView/NavigationSplitView the way it was first tried — that composed
/// badly with each screen's own `.toolbar(.hidden, for: .navigationBar)`
/// and rendered the screen's own top-of-body row (e.g. ChatListScreen's
/// `accountTopBar`) UNDER this banner instead of below it, reported live as
/// an overlap. Same failure mode `vpnToolbarItem()`'s kdoc already
/// documents for the VPN chip, same fix: draw it INSIDE each screen's own
/// body, as the first row above that screen's existing top bar, so it is
/// just another sibling in an ordinary VStack — nothing to overlap.
///
/// Deliberately wordmark-only, no VPN chip here: each of the four screens
/// already renders its own correct VPN chip inline in ITS top bar
/// (`vpnToolbarItem()`'s kdoc explains why that split happened), and
/// duplicating it in this banner too would show it twice.
struct QAudionBrandBanner: View {
    @Environment(\.qaudionScheme) private var scheme

    var body: some View {
        HStack {
            Image("QAudionWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 32)
                .accessibilityLabel("Q-Audion")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(scheme.background)
    }
}
