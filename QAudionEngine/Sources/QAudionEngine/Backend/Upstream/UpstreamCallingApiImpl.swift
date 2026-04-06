import Foundation

/// Delegates to Signal's calling infrastructure. Stub until Signal-iOS fork integration.
public final class UpstreamCallingApiImpl: CallingApi {
    public init() {}
    public func sendCallOffer(recipientId: String, sdp: String) async throws { /* Signal handles */ }
    public func sendCallAnswer(recipientId: String, sdp: String) async throws { /* Signal handles */ }
    public func sendIceCandidate(recipientId: String, candidate: String) async throws { /* Signal handles */ }
    public func sendHangup(recipientId: String) async throws { /* Signal handles */ }
    public func sendOpaqueMessage(recipientId: String, data: Data) async throws { /* Signal handles */ }
}
