import Foundation

// The local stats trace of a debug build. A release build has no path that writes it: the writer exists only under `#if DEBUG`,
// and the hook that the call wiring calls is empty without it. The trace is written only while a recording that its user
// agreed to is running (the key below), beside the recording, and is never shipped.

#if DEBUG

/// One line per stats snapshot (the stamps, the ssrc, the counters and the two round trips) and one per tap block (the clock and the
/// cumulative tap position), as JSON in a file of the caches folder.
final class VoiceStatsTraceWriter {
    static let recordingKey = "voice.trace.recording"
    static let shared = VoiceStatsTraceWriter()

    private let lock = NSLock()
    private var handle: FileHandle?

    private var isRecording: Bool {
        UserDefaults.standard.bool(forKey: Self.recordingKey)
    }

    private func open() -> FileHandle? {
        if let handle { return handle }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("voice-trace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("trace-\(Int(Date().timeIntervalSince1970)).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        let h = try? FileHandle(forWritingTo: url)
        handle = h
        return h
    }

    private func write(_ object: [String: Any]) {
        guard isRecording else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let h = open() else { return }
        h.write(data)
        h.write(Data([0x0A]))
    }

    func snapshot(_ s: VoiceStatsSnapshot) {
        var o: [String: Any] = [
            "k": "stats", "req_ns": s.reqNs, "arrive_ns": s.arriveNs, "oldest_ns": s.oldestNs, "report_ns": s.reportNs
        ]
        func put(_ key: String, _ value: Any?) { if let value { o[key] = value } }
        put("rx_ssrc", s.rxSsrc)
        put("concealed", s.concealed)
        put("silent_concealed", s.silentConcealed)
        put("conc_events", s.concealmentEvents)
        put("total_samples", s.totalSamples)
        put("inserted_decel", s.insertedDecel)
        put("removed_accel", s.removedAccel)
        put("jb_delay_s", s.jbDelayS)
        put("jb_emitted", s.jbEmitted)
        put("tx_energy", s.txEnergy)
        put("tx_duration_s", s.txDurationS)
        put("rtt_remote_s", s.rttRemoteS)
        put("rtt_pair_s", s.rttPairS)
        write(o)
    }

    func tap(tNs: Int64, ticks: Int64) {
        write(["k": "tap", "t_ns": tNs, "ticks": ticks])
    }
}

enum VoiceStatsTraceHook {
    static func snapshot(_ s: VoiceStatsSnapshot) { VoiceStatsTraceWriter.shared.snapshot(s) }
    static func tap(tNs: Int64, ticks: Int64) { VoiceStatsTraceWriter.shared.tap(tNs: tNs, ticks: ticks) }
}

#else

enum VoiceStatsTraceHook {
    static func snapshot(_ s: VoiceStatsSnapshot) {}
    static func tap(tNs: Int64, ticks: Int64) {}
}

#endif
