import Foundation

/// Audio wire shape -- the shared diagnostic lines of the native-SRTP audio path, identical in name and fields on
/// iOS, Android and Desktop, so one query compares the three platforms:
///
///  * `audiowire win_ms=<n> tx_pkts=<n> tx_bytes=<n> tx_hdr_bytes=<n> tx_retx_pkts=<n> rx_pkts=<n> rx_bytes=<n>`
///    every 5 s: the DELTAS of the outbound / inbound audio RTP counters over the window, bounded by the capture
///    stamps of the two stats reports (`win_ms` is the time between those two reports). `tx_bytes` is payload,
///    `tx_hdr_bytes` the RTP header AND padding bytes (the `headerBytesSent` counter of the stats API), so `tx_pkts`
///    against the number of media frames shows packets that carry no audio, and `tx_bytes / tx_pkts` the packet size.
///  * `audiowire codec ptime=<n> minptime=<n> maxptime=<n> cbr=<0|1> fec=<0|1> dtx=<0|1> maxavg=<n> stereo=<0|1>
///    alevel=<0|1> tcc=<0|1>` once per negotiation: the SEND-side codec as it is actually configured (the fmtp of the
///    codec the OUTBOUND stream reports) and what the SDP negotiated for the audio section. `alevel` = 1 iff a speech
///    level extension (`ssrc-audio-level` or `csrc-audio-level`, plain or in the RFC 6904 wrapped form) is present in
///    the audio section after the audio SDP policy; `tcc` = 1 iff a `transport-wide-cc` extension (either URI) is.
///
/// Rules, same as every other line of the call: numbers only (the log shipper's redactor is a fail-closed
/// allow-list), a value that was not measured is omitted instead of printed as -1, and nothing here decides anything
/// about the call. Foundation only, so it is unit-tested off-device (`AudioWireLinesTests`).
public enum AudioWireLines {

    // MARK: - Window line

    /// Cumulative audio RTP counters of one stats report. `-1` = the stats row or the field does not exist.
    public struct Counters: Equatable, Sendable {
        public var txPackets: Int64
        public var txBytes: Int64
        public var txHeaderBytes: Int64
        public var txRetransmittedPackets: Int64
        public var rxPackets: Int64
        public var rxBytes: Int64

        public init(txPackets: Int64 = -1, txBytes: Int64 = -1, txHeaderBytes: Int64 = -1,
                    txRetransmittedPackets: Int64 = -1, rxPackets: Int64 = -1, rxBytes: Int64 = -1) {
            self.txPackets = txPackets
            self.txBytes = txBytes
            self.txHeaderBytes = txHeaderBytes
            self.txRetransmittedPackets = txRetransmittedPackets
            self.rxPackets = rxPackets
            self.rxBytes = rxBytes
        }
    }

    /// The delta of one cumulative counter: `-1` when either side is missing or the counter went backwards (a reset
    /// is not negative traffic).
    static func delta(_ previous: Int64, _ current: Int64) -> Int64 {
        guard previous >= 0, current >= previous else { return -1 }
        return current - previous
    }

    /// `audiowire win_ms=... tx_pkts=...` for one window. A field that could not be measured is omitted.
    public static func windowLine(winMs: Int, previous: Counters, current: Counters) -> String {
        var out: String = "audiowire"
        out += CallMetricsLines.field("win_ms", winMs)
        out += CallMetricsLines.field("tx_pkts", delta(previous.txPackets, current.txPackets))
        out += CallMetricsLines.field("tx_bytes", delta(previous.txBytes, current.txBytes))
        out += CallMetricsLines.field("tx_hdr_bytes", delta(previous.txHeaderBytes, current.txHeaderBytes))
        out += CallMetricsLines.field("tx_retx_pkts", delta(previous.txRetransmittedPackets, current.txRetransmittedPackets))
        out += CallMetricsLines.field("rx_pkts", delta(previous.rxPackets, current.rxPackets))
        out += CallMetricsLines.field("rx_bytes", delta(previous.rxBytes, current.rxBytes))
        return out
    }

    // MARK: - Codec line

    /// What the SDP negotiated for the audio section, as the `audiowire codec` line reports it. `-1` = not present.
    public struct SdpFacts: Equatable, Sendable {
        public var ptime: Int
        public var maxptime: Int
        /// 1 when a speech-level extension (`ssrc-audio-level` / `csrc-audio-level`, in any form, plain or RFC 6904
        /// wrapped) is present in the audio section (after the audio SDP policy).
        public var audioLevel: Int
        /// 1 when a `transport-wide-cc` extension (either URI) is present in the audio section (after the audio SDP
        /// policy).
        public var transportCc: Int

        public init(ptime: Int, maxptime: Int, audioLevel: Int, transportCc: Int) {
            self.ptime = ptime
            self.maxptime = maxptime
            self.audioLevel = audioLevel
            self.transportCc = transportCc
        }
    }

    /// The send-side codec of the audio stream. `-1` = not present.
    public struct Codec: Equatable, Sendable {
        public var ptime: Int
        public var minptime: Int
        public var maxptime: Int
        public var cbr: Int
        public var fec: Int
        public var dtx: Int
        public var maxAverageBitrate: Int
        public var stereo: Int
        public var audioLevel: Int
        public var transportCc: Int

        public init(ptime: Int, minptime: Int, maxptime: Int, cbr: Int, fec: Int, dtx: Int,
                    maxAverageBitrate: Int, stereo: Int, audioLevel: Int, transportCc: Int) {
            self.ptime = ptime
            self.minptime = minptime
            self.maxptime = maxptime
            self.cbr = cbr
            self.fec = fec
            self.dtx = dtx
            self.maxAverageBitrate = maxAverageBitrate
            self.stereo = stereo
            self.audioLevel = audioLevel
            self.transportCc = transportCc
        }
    }

    /// `audiowire codec ptime=... minptime=... ...`
    public static func codecLine(_ codec: Codec) -> String {
        var out: String = "audiowire codec"
        out += CallMetricsLines.field("ptime", codec.ptime)
        out += CallMetricsLines.field("minptime", codec.minptime)
        out += CallMetricsLines.field("maxptime", codec.maxptime)
        out += CallMetricsLines.field("cbr", codec.cbr)
        out += CallMetricsLines.field("fec", codec.fec)
        out += CallMetricsLines.field("dtx", codec.dtx)
        out += CallMetricsLines.field("maxavg", codec.maxAverageBitrate)
        out += CallMetricsLines.field("stereo", codec.stereo)
        out += CallMetricsLines.field("alevel", codec.audioLevel)
        out += CallMetricsLines.field("tcc", codec.transportCc)
        return out
    }

    /// The Opus fmtp parameters that the codec line reports, parsed out of an `sdpFmtpLine`
    /// (`minptime=60;useinbandfec=1;...`, with or without the `a=fmtp:<pt> ` prefix). A flag that is not in the line is
    /// 0 (Opus default: off), a number that is not in it is -1.
    struct Fmtp: Equatable {
        var minptime: Int = -1
        var cbr: Int = 0
        var fec: Int = 0
        var dtx: Int = 0
        var maxAverageBitrate: Int = -1
        var stereo: Int = 0
    }

    static func parseFmtp(_ line: String) -> Fmtp {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("a=fmtp:") {
            // "a=fmtp:<pt> params"
            if let space = text.firstIndex(of: " ") { text = String(text[text.index(after: space)...]) }
        }
        var out = Fmtp()
        for raw in text.split(separator: ";") {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<eq])
            let value = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "minptime": out.minptime = Int(value) ?? -1
            case "cbr": out.cbr = value == "1" ? 1 : 0
            case "useinbandfec": out.fec = value == "1" ? 1 : 0
            case "usedtx": out.dtx = value == "1" ? 1 : 0
            case "maxaveragebitrate": out.maxAverageBitrate = Int(value) ?? -1
            case "stereo": out.stereo = value == "1" ? 1 : 0
            default: break
            }
        }
        return out
    }

    /// The codec line's content: fmtp of the codec the outbound stream reports (`sendFmtp`, the `sdpFmtpLine` of the
    /// codec row the OUTBOUND rtp row points to) and the SDP facts. `nil` until both are known.
    public static func codec(sendFmtp: String?, sdp: SdpFacts?) -> Codec? {
        guard let sendFmtp, !sendFmtp.isEmpty, let sdp else { return nil }
        let fmtp = parseFmtp(sendFmtp)
        return Codec(ptime: sdp.ptime, minptime: fmtp.minptime, maxptime: sdp.maxptime, cbr: fmtp.cbr, fec: fmtp.fec,
                     dtx: fmtp.dtx, maxAverageBitrate: fmtp.maxAverageBitrate, stereo: fmtp.stereo,
                     audioLevel: sdp.audioLevel, transportCc: sdp.transportCc)
    }

    // MARK: - SDP facts

    private static let transportCcUris: Set<String> = [
        "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
        "http://www.webrtc.org/experiments/rtp-hdrext/transport-wide-cc-02",
    ]

    private struct SectionFacts {
        var ptime = -1
        var maxptime = -1
        var audioLevel = false
        var transportCc = false
    }

    /// The facts of the first `m=audio` section that carries Opus, or `nil` when there is none.
    private static func section(of sdp: String) -> SectionFacts? {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var facts = SectionFacts()
        var inAudio = false
        var found = false
        var hasOpus = false
        for line in lines {
            if line.hasPrefix("m=") {
                if inAudio, hasOpus { found = true; break }
                inAudio = line.hasPrefix("m=audio")
                facts = SectionFacts()
                hasOpus = false
                continue
            }
            guard inAudio else { continue }
            if line.hasPrefix("a=rtpmap:"), line.lowercased().contains(" opus/48000") { hasOpus = true }
            if line.hasPrefix("a=ptime:") { facts.ptime = Int(line.dropFirst("a=ptime:".count).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if line.hasPrefix("a=maxptime:") { facts.maxptime = Int(line.dropFirst("a=maxptime:".count).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if let target = AudioSdpPolicy.extmapTarget(of: line) {
                if AudioSdpPolicy.speechIndicatorExtmapUris.contains(target.uri) { facts.audioLevel = true }
                if transportCcUris.contains(target.uri) { facts.transportCc = true }
            }
        }
        if !found, inAudio, hasOpus { found = true }
        return found ? facts : nil
    }

    /// What the SDP negotiated for the audio section. Both descriptions are the ones the peer connection holds, i.e.
    /// already through the audio SDP policy; an extension counts as negotiated only when BOTH carry it (an offer's
    /// extension that the answer drops is not negotiated); the packetization times are what the REMOTE description asks
    /// of our sender, falling back to the local one. `nil` when neither description has an Opus audio section.
    public static func sdpFacts(local: String?, remote: String?) -> SdpFacts? {
        let l = local.flatMap { section(of: $0) }
        let r = remote.flatMap { section(of: $0) }
        guard l != nil || r != nil else { return nil }
        let level: Bool
        let cc: Bool
        if let l, let r {
            level = l.audioLevel && r.audioLevel
            cc = l.transportCc && r.transportCc
        } else {
            level = (l ?? r)?.audioLevel ?? false
            cc = (l ?? r)?.transportCc ?? false
        }
        let timing = r ?? l
        return SdpFacts(ptime: timing?.ptime ?? -1, maxptime: timing?.maxptime ?? -1,
                        audioLevel: level ? 1 : 0, transportCc: cc ? 1 : 0)
    }

    // MARK: - Reporter

    /// Per-call state behind the two lines: the previous counters (window deltas) and the last codec reported (one
    /// codec line per negotiation, again only when it changes).
    public struct Reporter: Equatable, Sendable {
        private var previous: Counters?
        private var previousCapturedAtMs: Int64?
        private var lastCodec: Codec?

        public init() {}

        /// The lines due at this heartbeat: the codec line when the codec is known and differs from the last one
        /// reported, then the window line.
        ///
        /// `capturedAtMs` is the capture stamp (uptime, ms) of the stats report `counters` come from, `-1` while no
        /// report exists yet. The window is the time between the stamps of two reports, so it is exact whatever the
        /// heartbeat's own timing. A report with a stamp that did not advance is the report the last heartbeat
        /// already used (the stats poll did not deliver a new one): no window is written for it and the baseline is
        /// kept, so the next report spans the whole elapsed time instead of producing a window of zeros. The first
        /// report of a call only takes the baseline.
        public mutating func lines(counters: Counters, capturedAtMs: Int64, codec: Codec?) -> [String] {
            var out: [String] = []
            if let codec, codec != lastCodec {
                lastCodec = codec
                out.append(AudioWireLines.codecLine(codec))
            }
            guard capturedAtMs >= 0 else { return out }
            if let previous, let previousCapturedAtMs {
                guard capturedAtMs > previousCapturedAtMs else { return out }
                let winMs = Int(min(capturedAtMs - previousCapturedAtMs, Int64(Int32.max)))
                out.append(AudioWireLines.windowLine(winMs: winMs, previous: previous, current: counters))
            }
            previous = counters
            previousCapturedAtMs = capturedAtMs
            return out
        }

        /// Forget everything: a new call starts from a clean baseline.
        public mutating func reset() {
            previous = nil
            previousCapturedAtMs = nil
            lastCodec = nil
        }
    }

    // MARK: - Sender parameters line

    /// `audiosrtp cap n=<encodings> min=<bps> max=<bps> apt=<0|1> prio=<n> ok=<0|1> src=<n>`: what the native audio
    /// sender's parameters read back as after the 32 kbps / DSCP / fixed-packet-time pin was applied. `ok` is 1 when the
    /// read-back equals what was set. `src`: 1 = sender created, 2 = after a local description, 3 = after a remote
    /// description, 4 = at activation. A value that could not be read is omitted.
    public static func senderCapLine(encodings: Int, minBps: Int, maxBps: Int, adaptivePacketTime: Int,
                                     priority: Int, ok: Bool, source: Int) -> String {
        var out: String = "audiosrtp cap"
        out += CallMetricsLines.field("n", encodings)
        out += CallMetricsLines.field("min", minBps)
        out += CallMetricsLines.field("max", maxBps)
        out += CallMetricsLines.field("apt", adaptivePacketTime)
        out += CallMetricsLines.field("prio", priority)
        out += " ok=" + (ok ? "1" : "0")
        out += CallMetricsLines.field("src", source)
        return out
    }
}
