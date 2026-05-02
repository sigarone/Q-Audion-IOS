import Foundation

/// Cross-platform WS-relay transport for the audio (and video) call media
/// path. The wire codec is byte-for-byte compatible with Android's
/// `DefaultFrameRelayTransport`, so iOS↔Android calls can use the
/// `audio_frame` / `video_frame` Bcrypto WebSocket envelope without going
/// through WebRTC.
///
/// On iOS the legacy `FrameEncoder` (versioned, with timestamp + optional
/// deepfake score) is still used by the UDP P2P path (`UdpPeerTransport`)
/// for iOS-to-iOS direct connections; this transport is the fallback that
/// also serves as the only path Android can talk back on.
public final class BCryptoWebSocketTransport: SecureChannel, @unchecked Sendable {
    private let wsClient: BCryptoWebSocketClient
    private let lock = NSLock()
    private var _isOpen = false
    private var recipientId: String?
    private var callback: ((EncryptedFrame) -> Void)?
    private var videoCallback: ((EncryptedFrame, UInt16, UInt16, Bool) -> Void)?
    private var _framesSent: Int64 = 0
    private var _framesReceived: Int64 = 0
    private var _videoFramesSent: Int64 = 0
    private var _videoFramesReceived: Int64 = 0
    private var _legacyFramesReceived: Int64 = 0

    public init(wsClient: BCryptoWebSocketClient) { self.wsClient = wsClient }

    public func open(config: ChannelConfig) {
        lock.lock(); _isOpen = true; lock.unlock()

        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let raw = Data(base64Encoded: b64) else { return }
            self.dispatchInbound(raw, isVideoChannel: false)
        }

        wsClient.registerHandler(type: "video_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let raw = Data(base64Encoded: b64) else { return }
            self.dispatchInbound(raw, isVideoChannel: true)
        }
    }

    public func close() { lock.lock(); _isOpen = false; lock.unlock() }

    /// Outbound audio. Always uses the Android-compatible wire codec so the
    /// peer can be either an Android device or another iOS device on the
    /// same protocol.
    public func send(_ frame: EncryptedFrame) {
        guard let rid = recipientId else { return }
        let data = WireRelayFrameCodec.encodeAudio(frame)
        wsClient.sendAudioFrame(recipientId: rid, frame: data)
        lock.lock(); _framesSent += 1; lock.unlock()
    }

    /// Outbound video fragment. Mirrors Android's `sendVideo`.
    public func sendVideo(
        _ frame: EncryptedFrame,
        fragIdx: UInt16,
        totalFrags: UInt16,
        isKey: Bool
    ) {
        guard let rid = recipientId else { return }
        let data = WireRelayFrameCodec.encodeVideo(
            frame, fragIdx: fragIdx, totalFrags: totalFrags, isKey: isKey)
        wsClient.sendVideoFrame(recipientId: rid, frame: data)
        lock.lock(); _videoFramesSent += 1; lock.unlock()
    }

    public func setOnFrameReceived(_ callback: ((EncryptedFrame) -> Void)?) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    /// Optional video callback. Receives the decoded EncryptedFrame plus the
    /// per-fragment header that the codec extracted off the wire.
    public func setOnVideoFrameReceived(
        _ callback: ((EncryptedFrame, UInt16, UInt16, Bool) -> Void)?
    ) {
        lock.lock(); self.videoCallback = callback; lock.unlock()
    }

    public func setRecipientId(_ id: String) { recipientId = id }
    public func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return _isOpen }
    public func getStats() -> ChannelStats {
        lock.lock(); defer { lock.unlock() }
        return ChannelStats(framesSent: _framesSent, framesReceived: _framesReceived)
    }
    public func getMode() -> TransportMode { .dataChannel }

    // MARK: - Inbound dispatch

    /// First try the Android-compatible mux-byte codec. If the payload is a
    /// legacy iOS-only frame (FrameEncoder.serialize, version 0x01 followed
    /// by flags), fall back to the historical decoder so old iOS↔iOS calls
    /// still work during the rollover.
    private func dispatchInbound(_ raw: Data, isVideoChannel: Bool) {
        // Try the Android codec first.
        if let decoded = try? WireRelayFrameCodec.decode(raw) {
            switch decoded.kind {
            case .audio:
                self.lock.lock()
                self._framesReceived += 1
                let cb = self.callback
                self.lock.unlock()
                cb?(decoded.frame)
                return
            case .video(let fragIdx, let totalFrags, let isKey):
                self.lock.lock()
                self._videoFramesReceived += 1
                let cb = self.videoCallback
                self.lock.unlock()
                cb?(decoded.frame, fragIdx, totalFrags, isKey)
                return
            }
        }
        // Legacy iOS-only frame (FrameEncoder format from older builds).
        // Only trust this on the audio channel — video is new and never
        // shipped with the legacy codec.
        if !isVideoChannel, let legacy = try? FrameEncoder.deserialize(raw) {
            self.lock.lock()
            self._framesReceived += 1
            self._legacyFramesReceived += 1
            let cb = self.callback
            self.lock.unlock()
            cb?(legacy)
            return
        }
        print("[BCryptoWebSocketTransport] dropping unparseable frame (\(raw.count) bytes, video=\(isVideoChannel))")
    }
}
