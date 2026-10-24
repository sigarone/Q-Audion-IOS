import SwiftUI

/// Layout decisions for the sizes an iPhone can take: the folded and unfolded foldable iPhone, Split View and the
/// usual phone and tablet screens. Pure functions of the size class and the measured size, so each rule can be tested
/// without a view; the views read the size from the environment or from a `GeometryReader`, never from the screen.
///
/// The decisions are made on the size the view really has (size class and width), not on the device or the
/// orientation: the unfolded display of a foldable iPhone is regular in both dimensions and does not rotate with the
/// device, and a window in Split View changes size with no rotation at all.
/// https://developer.apple.com/videos/play/tech-talks/111461/
enum QAudionAdaptive {

    /// Widest a column of reading content, a form or a call stack gets. Wider canvases centre the column instead of
    /// stretching it to the edges.
    static let readableMaxWidth: CGFloat = 600

    /// Narrowest width at which the chat list and the open chat sit side by side.
    static let twoPaneMinWidth: CGFloat = 560

    /// Narrowest window in which the navigation moves from the bottom tab bar to a sidebar. Narrower regular windows
    /// (the unfolded foldable iPhone, a small Split View) keep the tab bar and give the width to the content.
    static let sidebarMinWidth: CGFloat = 700

    /// Width of the list column when two panes are shown.
    static let listPaneMinWidth: CGFloat = 300
    static let listPaneMaxWidth: CGFloat = 380

    /// Below this height a call screen no longer fits one column of ring, name and buttons.
    static let callStackedMinHeight: CGFloat = 540

    enum ShellStyle: Equatable {
        case tabs
        case sidebar
    }

    /// Bottom tab bar, or sidebar plus detail.
    static func shellStyle(horizontalRegular: Bool, width: CGFloat) -> ShellStyle {
        horizontalRegular && width >= sidebarMinWidth ? .sidebar : .tabs
    }

    /// Whether the chat list and the open chat are shown next to each other.
    static func chatsAreTwoPane(horizontalRegular: Bool, width: CGFloat) -> Bool {
        horizontalRegular && width >= twoPaneMinWidth
    }

    /// Width of the list column in a two-pane layout of `totalWidth`.
    static func listPaneWidth(totalWidth: CGFloat) -> CGFloat {
        min(listPaneMaxWidth, max(listPaneMinWidth, totalWidth * 0.42))
    }

    enum CallArrangement: Equatable {
        case stacked
        case sideBySide
    }

    /// One column (ring, name, buttons below) or two (identity next to the buttons) for a call screen of `size`. At the
    /// accessibility text sizes the texts are too tall for one column on any phone, so the two columns (the identity one
    /// scrolls) are used.
    static func callArrangement(size: CGSize, accessibilityTextSize: Bool = false) -> CallArrangement {
        if accessibilityTextSize { return .sideBySide }
        if size.height < callStackedMinHeight { return .sideBySide }
        if size.width >= size.height * 1.2 && size.width >= twoPaneMinWidth { return .sideBySide }
        return .stacked
    }

    /// Sizes of the avatar ring of a call screen: as large as the room allows, never larger than the design size.
    struct CallRingMetrics: Equatable {
        let ring: CGFloat
        let avatar: CGFloat
    }

    static let callRingDesign: CGFloat = 240
    static let callRingFloor: CGFloat = 120

    /// `verticalRoom` is the height left for the ring once the texts and the buttons have their share.
    static func callRing(verticalRoom: CGFloat) -> CallRingMetrics {
        let ring = min(callRingDesign, max(callRingFloor, verticalRoom))
        // 160 pt avatar inside the 240 pt design ring.
        return CallRingMetrics(ring: ring, avatar: (ring * 2 / 3).rounded())
    }
}

private struct QAudionReadableWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Keeps the content in a column no wider than `maxWidth`, centred in the space it is given. On a phone width it
    /// changes nothing; on a wider canvas the column stays readable instead of running to the edges.
    func qaudionReadableWidth(_ maxWidth: CGFloat = QAudionAdaptive.readableMaxWidth) -> some View {
        modifier(QAudionReadableWidth(maxWidth: maxWidth))
    }
}

private struct QAudionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Reports the width this view is given into `width`, without changing its layout.
    func qaudionReportsWidth(_ width: Binding<CGFloat>) -> some View {
        self
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: QAudionWidthKey.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(QAudionWidthKey.self) { newValue in
                if newValue > 0, abs(width.wrappedValue - newValue) >= 0.5 {
                    width.wrappedValue = newValue
                }
            }
    }
}

extension QAudionAdaptive {
    /// The width of the app's window scene, read once before the first measurement so the first frame already has the
    /// right arrangement. A window scene, never the main screen: a device with two displays has no single main screen.
    /// `greatestFiniteMagnitude` when no scene is connected yet (the size class alone decides then).
    @MainActor
    static func sceneWidth() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.coordinateSpace.bounds.width ?? CGFloat.greatestFiniteMagnitude
    }
}
