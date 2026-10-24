import Foundation
#if canImport(WebRTC)
@preconcurrency import WebRTC

/// The check behind "Verifica la modalità scelta" in Settings > Trasporto: it gathers ICE candidates with the
/// configuration a call in the selected mode would use, counts their types and gives a verdict. No call is started.
///
/// The configuration is not rebuilt here: it comes from the same `TransportPlan` as a real call (`make`, `wantsBridge`,
/// `servers(pool:bridgeIceUrl:)`, `poolTurnCredentials(in:)`), through the same pool ordering, so what is measured is
/// what `QAudionWebRtcCallController.relayIceServers` would hand to libwebrtc. In relay mode the WSS-TURN bridge is
/// really started (and stopped at the end), because the route of that mode is the bridge; if it cannot start, the plan
/// falls back to the TURN servers of the pool and the result's `plan.route` says so. A custom TURN server is the whole
/// list with its own credentials, so for it the relay list of the BCrypto server is not requested at all.
///
/// A check that tried no server is not OK in any mode: `serverListAvailable` of the result is whether the plan produced
/// at least one server for libwebrtc (no list from the server, or a list with nothing this mode may use, makes it
/// `false`), and `TransportCheckOutcome.evaluate` turns that into `serverListUnavailable`.
///
/// What it does NOT do: no audio track (so no audio unit), no signaling, nothing is sent to a peer, and the candidate
/// lines are never stored or logged: only their type is counted (`TransportCandidateCounts`). It uses the process-wide
/// PeerConnection factory and closes its own PeerConnection before returning.
public enum TransportCandidateProbe {

    /// Upper bound for one gathering. TURN allocations that never answer would otherwise hold the check for a long time.
    public static let defaultTimeoutSec: Double = 8

    /// Runs the check for `mode` (and the custom address, if one is typed) and returns what was found.
    /// `relayProvider` gives the server's relay list; `nil` (not signed in) is reported as an unavailable list. A custom
    /// server needs no list, so it is not asked for.
    public static func run(mode: TransportSettingsViewModel.Mode,
                           customTurnUrl: URL?,
                           relayProvider: RelayCredentialsProvider?,
                           accessToken: String?,
                           pinnedSession: URLSession?,
                           timeoutSec: Double = TransportCandidateProbe.defaultTimeoutSec) async -> TransportCheckResult {
        let wantPlan = TransportPlan.make(mode: mode, customTurnUrl: customTurnUrl, bridgeAvailable: true)
        var pool: [RelayServer] = []
        var bridge: WssTurnBridge?
        var bridgeIceUrl: String?

        // A custom server is the whole list and has its own credentials: the relay list is not requested for it. Every
        // other plan (p2p too, which ignores the custom address) starts from the pool of the BCrypto server.
        if wantPlan.customTurn == nil {
            var bundle: RelayCredentialsProvider.RelayBundle?
            if let provider = relayProvider {
                bundle = await provider.currentOrRefresh()
            }
            if let bundle = bundle, !bundle.servers.isEmpty {
                // Same ordering and same UDP evidence as the call (relay mode skips the probe, see the controller).
                var rttByUrl: [String: Double] = [:]
                if wantPlan.bridgeRole != .always {
                    rttByUrl = await RelayLatencyProbe().measureAll(bundle.servers)
                }
                pool = RelayOrdering.order(bundle.servers, rttMsByFirstUrl: rttByUrl)
                if wantPlan.wantsBridge(udpReachable: !rttByUrl.isEmpty),
                   let wssUrlString = bundle.wssTurnUrl,
                   let wssUrl = URL(string: wssUrlString),
                   let creds = TransportPlan.poolTurnCredentials(in: bundle.servers) {
                    let candidateBridge = WssTurnBridge(
                        wssUrl: wssUrl,
                        username: creds.username,
                        credential: creds.credential,
                        accessToken: accessToken,
                        pinnedSession: pinnedSession)
                    do {
                        let started = try await candidateBridge.start()
                        bridge = candidateBridge
                        bridgeIceUrl = started.iceUrl
                    } catch {
                        // The plan below falls back to the pool (relay) or goes without the bridge (auto); the
                        // route in the result tells which.
                        candidateBridge.stop()
                    }
                }
            }
        }

        let plan = TransportPlan.make(mode: mode, customTurnUrl: customTurnUrl, bridgeAvailable: bridgeIceUrl != nil)
        let plannedServers = plan.servers(pool: pool, bridgeIceUrl: bridgeIceUrl)
        // "Was there anything to try": the list the plan hands to libwebrtc is not empty. No list from the server, or a
        // list with nothing this mode may use, leaves it empty.
        let serverListAvailable = !plannedServers.isEmpty
        let servers = QAudionPeerConnectionFactory.iceServers(from: plannedServers)
        let policy: RTCIceTransportPolicy = plan.icePolicy == .relay ? .relay : .all

        // Relay policy with nothing to relay through can only gather nothing: no PeerConnection needed to know it.
        if policy == .relay && servers.isEmpty {
            bridge?.stop()
            return TransportCheckResult(plan: plan, counts: TransportCandidateCounts(),
                                        serverListAvailable: serverListAvailable, gatheringTimedOut: false)
        }

        // Auto and p2p with an empty list still gather (the host candidates are shown), but the verdict is not OK.
        let gatherer = Gatherer()
        let timedOut = await gatherer.gather(servers: servers, policy: policy, timeoutSec: timeoutSec)
        bridge?.stop()
        return TransportCheckResult(plan: plan, counts: gatherer.snapshotCounts(),
                                    serverListAvailable: serverListAvailable, gatheringTimedOut: timedOut)
    }

    // MARK: - Gathering

    /// One PeerConnection that only gathers: it counts the type of every local candidate and nothing else.
    final class Gatherer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {

        private let lock = NSLock()
        private var counts = TransportCandidateCounts()
        private var finished = false
        private var completion: ((Bool) -> Void)?

        /// Returns `true` when the time limit cut the gathering, `false` when it reported complete (or could not start).
        func gather(servers: [RTCIceServer], policy: RTCIceTransportPolicy, timeoutSec: Double) async -> Bool {
            let (factory, _) = await QAudionPeerConnectionFactory.shared.sharedFactory()
            let config = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: servers)
            config.iceTransportPolicy = policy
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
            guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                return false
            }
            // A data channel is what makes the offer carry a media section, which is what starts gathering.
            _ = pc.dataChannel(forLabel: "transport-check", configuration: RTCDataChannelConfiguration())

            let timedOut: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                self.arm { cutByTimeLimit in cont.resume(returning: cutByTimeLimit) }
                pc.offer(for: constraints) { [weak self] sdp, error in
                    guard let sdp = sdp, error == nil else {
                        self?.finish(timedOut: false)
                        return
                    }
                    pc.setLocalDescription(sdp) { [weak self] setError in
                        if setError != nil { self?.finish(timedOut: false) }
                    }
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
                    self?.finish(timedOut: true)
                }
            }
            pc.close()
            return timedOut
        }

        private func arm(_ onFinish: @escaping (Bool) -> Void) {
            lock.lock()
            completion = onFinish
            lock.unlock()
        }

        /// Ends the gathering once: the first caller wins, later ones (a complete state after the time limit, a late
        /// candidate) change nothing.
        private func finish(timedOut: Bool) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let done = completion
            completion = nil
            lock.unlock()
            done?(timedOut)
        }

        private func record(candidateSdp: String) {
            lock.lock()
            if !finished {
                counts.add(candidateSdp: candidateSdp)
            }
            lock.unlock()
        }

        func snapshotCounts() -> TransportCandidateCounts {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }

        // MARK: RTCPeerConnectionDelegate

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
            if newState == .complete { finish(timedOut: false) }
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            record(candidateSdp: candidate.sdp)
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    }
}
#endif
