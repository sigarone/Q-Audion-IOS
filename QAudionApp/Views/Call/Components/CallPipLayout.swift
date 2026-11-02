import SwiftUI

// MARK: - Layout of the local camera preview (pure, tested)

/// The four places the local camera preview snaps to.
enum CallPipCorner: CaseIterable, Equatable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// Where the local camera preview of the video call sits. The free area is the screen between the header (top bar, trust
/// bar, banners) and the control dock, so the preview never covers either; when the dock is hidden the area grows into the
/// space it left.
enum CallPipLayout {
    static let size = CGSize(width: 120, height: 160)
    /// Distance from the screen edges.
    static let margin: CGFloat = 16
    /// Distance from the header and from the dock.
    static let gap: CGFloat = 8
    static let defaultCorner: CallPipCorner = .topTrailing

    /// The rectangle the preview may occupy. `topInset` is the bottom edge of the header and `bottomInset` the height taken
    /// from the bottom by the dock (or by the safe area when the dock is hidden), both measured in the space of `screen`.
    static func freeArea(size screen: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
        let top = max(0, topInset) + gap
        let bottom = max(top, screen.height - max(0, bottomInset) - gap)
        let left = margin
        let right = max(left, screen.width - margin)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The corner of `bounds` nearest to `point` (the centre of the preview): the quadrant of `bounds` that holds it.
    /// A point exactly on a middle line goes to the trailing side and to the top.
    static func nearestCorner(point: CGPoint, bounds: CGRect) -> CallPipCorner {
        let leading = point.x < bounds.midX
        let top = point.y <= bounds.midY
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    /// The top-left point of the preview when it rests in `corner` of `area`. `leadingBottomLimit` lifts the bottom-leading
    /// corner above something that sits there (the SAS panel).
    static func origin(corner: CallPipCorner, size: CGSize = CallPipLayout.size, area: CGRect,
                       leadingBottomLimit: CGFloat? = nil) -> CGPoint {
        let x: CGFloat
        switch corner {
        case .topLeading, .bottomLeading: x = area.minX
        case .topTrailing, .bottomTrailing: x = area.maxX - size.width
        }
        var bottom = area.maxY
        if corner == .bottomLeading, let limit = leadingBottomLimit { bottom = min(bottom, limit) }
        let y: CGFloat
        switch corner {
        case .topLeading, .topTrailing: y = area.minY
        case .bottomLeading, .bottomTrailing: y = bottom - size.height
        }
        return CGPoint(x: x, y: max(area.minY, y))
    }

    /// `origin` moved the least needed to keep the preview inside `rect` while it is dragged.
    static func clamped(origin: CGPoint, size: CGSize = CallPipLayout.size, within rect: CGRect) -> CGPoint {
        let maxX = max(rect.minX, rect.maxX - size.width)
        let maxY = max(rect.minY, rect.maxY - size.height)
        return CGPoint(x: min(max(origin.x, rect.minX), maxX), y: min(max(origin.y, rect.minY), maxY))
    }
}

/// Frames the video call screen reports for the preview: where the header ends, where the dock and the SAS panel start.
struct CallPipInsets: Equatable {
    var headerMaxY: CGFloat = 0
    var dockMinY: CGFloat? = nil
    var sasMinY: CGFloat? = nil
}

struct CallPipInsetsKey: PreferenceKey {
    static var defaultValue = CallPipInsets()
    static func reduce(value: inout CallPipInsets, nextValue: () -> CallPipInsets) {
        let next = nextValue()
        value.headerMaxY = max(value.headerMaxY, next.headerMaxY)
        if let dock = next.dockMinY { value.dockMinY = min(value.dockMinY ?? dock, dock) }
        if let sas = next.sasMinY { value.sasMinY = min(value.sasMinY ?? sas, sas) }
    }
}
