import SwiftUI

/// The "small radar" visualization inside the mesh sheet. Distance from the
/// center encodes signal strength (proximity), NOT a real direction — BLE
/// gives no bearing, so angles are assigned deterministically per peer just
/// to spread them out. Selection/tapping happens in the peer list below the
/// radar; this is a read-only visualization, matching the Android sibling's
/// `MeshRadar.kt` (angle-spread + concentric range rings + a chat-peer
/// halo), redrawn with SwiftUI `Canvas` instead of Compose `Canvas` — same
/// visual language, idiomatic API for this platform.
struct MeshRadarView: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras

    let peers: [MeshRuntimePeer]
    let selectedNodeHex: String?
    let expandedNodeHex: String?
    let currentChatPeerNodeHex: String?
    /// Resolves a node hex to whether it's a known (paired) contact, for
    /// dot styling. Kept as a closure rather than baking `known` into
    /// `MeshRuntimePeer` — that struct is transport-layer state and has no
    /// business knowing about the contacts store.
    let isKnown: (String) -> Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2 - 10

            drawRangeRings(context: context, center: center, maxRadius: maxRadius)
            drawSelf(context: context, center: center)

            let count = max(peers.count, 1)
            for (index, peer) in peers.enumerated() {
                let angle = -CGFloat.pi / 2 + CGFloat(index) * (2 * CGFloat.pi / CGFloat(count))
                let radius = maxRadius * CGFloat(peer.radiusFraction)
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                drawPeer(context: context, at: point, peer: peer)

                if peer.nodeHex == selectedNodeHex {
                    drawRing(context: context, at: point, radius: 11, color: scheme.onBackground, lineWidth: 1.6)
                }
                if peer.nodeHex == currentChatPeerNodeHex {
                    drawRing(context: context, at: point, radius: 15, color: extras.pqcAccent, lineWidth: 2.2)
                }
                if !peer.relayNodeHexes.isEmpty {
                    let marker = CGPoint(x: point.x + 8, y: point.y - 8)
                    context.fill(Circle().path(in: CGRect(x: marker.x - 4, y: marker.y - 4, width: 8, height: 8)), with: .color(extras.warning))
                }
                if peer.nodeHex == expandedNodeHex, !peer.relayNodeHexes.isEmpty {
                    drawRelaySatellites(context: context, around: point, angle: angle, maxRadius: maxRadius, radius: radius, relays: peer.relayNodeHexes)
                }
            }
        }
        .accessibilityLabel("Mesh radar")
        .accessibilityHidden(peers.isEmpty)
    }

    private func drawRangeRings(context: GraphicsContext, center: CGPoint, maxRadius: CGFloat) {
        for fraction: CGFloat in [0.34, 0.62, 0.82, 1.0] {
            let r = maxRadius * fraction
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.stroke(path, with: .color(scheme.outline), lineWidth: 1)
        }
    }

    private func drawSelf(context: GraphicsContext, center: CGPoint) {
        let r: CGFloat = 5
        context.fill(Circle().path(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(scheme.primary))
    }

    private func drawPeer(context: GraphicsContext, at point: CGPoint, peer: MeshRuntimePeer) {
        let r: CGFloat = 7
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        if isKnown(peer.nodeHex) {
            context.fill(Circle().path(in: rect), with: .color(scheme.secondary))
        } else {
            var path = Path()
            path.addEllipse(in: rect)
            context.stroke(path, with: .color(extras.trustUnverified), style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
        }
    }

    private func drawRing(context: GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color, lineWidth: CGFloat) {
        var path = Path()
        path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func drawRelaySatellites(context: GraphicsContext, around point: CGPoint, angle: CGFloat, maxRadius: CGFloat, radius: CGFloat, relays: [String]) {
        for (j, relayHex) in relays.enumerated() {
            let spread = (CGFloat(j) - CGFloat(relays.count - 1) / 2) * 0.5
            let satelliteAngle = angle + spread
            let satelliteRadius = min(maxRadius, radius + maxRadius * 0.18)
            let satellitePoint = CGPoint(
                x: point.x + cos(satelliteAngle) * (satelliteRadius - radius),
                y: point.y + sin(satelliteAngle) * (satelliteRadius - radius)
            )
            var line = Path()
            line.move(to: point)
            line.addLine(to: satellitePoint)
            context.stroke(line, with: .color(scheme.outline), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))

            let r: CGFloat = 4.5
            let rect = CGRect(x: satellitePoint.x - r, y: satellitePoint.y - r, width: r * 2, height: r * 2)
            if isKnown(relayHex) {
                context.fill(Circle().path(in: rect), with: .color(scheme.secondary.opacity(0.75)))
            } else {
                var path = Path()
                path.addEllipse(in: rect)
                context.stroke(path, with: .color(extras.trustUnverified), style: StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
            }
        }
    }
}
