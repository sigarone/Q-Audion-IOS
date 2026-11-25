import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// The one place in the app that asks a peer connection for its statistics.
///
/// Why it exists: the voice check places every stats sample on the tap clock by three stamps taken around the call, and the
/// third one, `oldestNs`, says how long ago the oldest request that was still waiting for its answer was issued. libwebrtc
/// answers a request from its cached report, or lets it join a collection that another caller started, so the instant at which
/// the counters were sampled can be as old as the oldest request that is still outstanding. That is known only if every call on
/// the connection goes through one registry; a call that bypasses it can make a sample look younger than it is.
///
/// What it guarantees:
///  - the request stamp is taken INSIDE the lock, the request is registered and `oldestNs` is read under the same lock, and
///    only then the native call is issued;
///  - the arrival stamp is taken at the start of the native callback, before the lock;
///  - a registration is released by the native callback and by nothing else: never by a timeout, and never because the caller
///    stopped waiting;
///  - a closed connection drops its registry (`close()`); a callback that still arrives afterwards is delivered, and releases
///    nothing;
///  - the answer is delivered on the thread of the native callback, exactly as before: the gate adds no queue and no hop.
///
/// A connection has one gate. The group-call connections have a gate of their own each: they share nothing with the 1:1 call.
/// A source-scan test (`PeerConnectionStatsGateScanTests`) fails when a `statistics` call appears in any other file.
final class PeerConnectionStatsGate: @unchecked Sendable {
    /// The three stamps of one request, on the tap clock (`VoiceClock`).
    struct Stamp: Equatable {
        /// The clock immediately before the native call was issued.
        var reqNs: Int64
        /// The clock at the start of the native callback.
        var arriveNs: Int64
        /// The smallest `reqNs` among the requests of this connection that were outstanding when this one was issued, this one
        /// included: never above `reqNs`.
        var oldestNs: Int64
    }

    private let clock: () -> Int64
    private let lock = NSLock()
    private var outstanding: [UInt64: Int64] = [:]
    private var nextToken: UInt64 = 0
    private var closed = false

    init(clock: @escaping () -> Int64 = VoiceClock.nowNs) {
        self.clock = clock
    }

    /// How many requests are registered (not answered yet).
    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding.count
    }

    /// Drops the registry: the connection is closed. A request that is issued afterwards is not registered.
    func close() {
        lock.lock()
        closed = true
        outstanding.removeAll()
        lock.unlock()
    }

    /// The request, generic in what the native call delivers. `native` issues the native call and hands it the callback that
    /// the gate gave it; `completion` runs on the thread of that callback.
    func request<Report>(
        native: (@escaping (Report) -> Void) -> Void,
        completion: @escaping (Report, Stamp) -> Void
    ) {
        lock.lock()
        let reqNs = clock()
        let token = nextToken
        nextToken &+= 1
        var oldest = reqNs
        if !closed {
            outstanding[token] = reqNs
            for v in outstanding.values where v < oldest {
                oldest = v
            }
        }
        lock.unlock()
        native { [self] report in
            let arriveNs = clock()
            lock.lock()
            outstanding.removeValue(forKey: token)
            lock.unlock()
            completion(report, Stamp(reqNs: reqNs, arriveNs: arriveNs, oldestNs: oldest))
        }
    }

    /// The two selector calls of one poll make one snapshot: `reqNs` is the earlier, `arriveNs` the later, `oldestNs` the smaller.
    static func combine(_ a: Stamp, _ b: Stamp) -> Stamp {
        Stamp(reqNs: min(a.reqNs, b.reqNs), arriveNs: max(a.arriveNs, b.arriveNs), oldestNs: min(a.oldestNs, b.oldestNs))
    }

    #if canImport(WebRTC)
    /// The whole-connection report.
    func statistics(of pc: RTCPeerConnection, _ completion: @escaping (RTCStatisticsReport) -> Void) {
        request(native: { (done: @escaping (RTCStatisticsReport) -> Void) in
            pc.statistics { report in done(report) }
        }, completion: { report, _ in completion(report) })
    }

    /// The whole-connection report with the stamps of the request.
    func statistics(of pc: RTCPeerConnection, stamped completion: @escaping (RTCStatisticsReport, Stamp) -> Void) {
        request(native: { (done: @escaping (RTCStatisticsReport) -> Void) in
            pc.statistics { report in done(report) }
        }, completion: completion)
    }

    /// The report of one receiver, with the stamps of the request.
    func statistics(of pc: RTCPeerConnection, for receiver: RTCRtpReceiver,
                    stamped completion: @escaping (RTCStatisticsReport, Stamp) -> Void) {
        request(native: { (done: @escaping (RTCStatisticsReport) -> Void) in
            pc.statistics(for: receiver) { report in done(report) }
        }, completion: completion)
    }

    /// The report of one sender, with the stamps of the request.
    func statistics(of pc: RTCPeerConnection, for sender: RTCRtpSender,
                    stamped completion: @escaping (RTCStatisticsReport, Stamp) -> Void) {
        request(native: { (done: @escaping (RTCStatisticsReport) -> Void) in
            pc.statistics(for: sender) { report in done(report) }
        }, completion: completion)
    }
    #endif
}

/// The clock of the voice check: monotonic, one for every stamp, tap block and busy interval of the process.
enum VoiceClock {
    static func nowNs() -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
    }
}
