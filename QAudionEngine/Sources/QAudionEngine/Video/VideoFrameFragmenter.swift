import Foundation

/// Fragments H.264/HEVC NAL units into transport-sized chunks and
/// reassembles them. Direct port of Android's `VideoFrameFragmenter.kt`.
///
/// Each fragment gets a 7-byte sub-header:
/// ```
///   [fragFlags(1)][frameId(2)][fragIdx(1)][totalFrags(1)][bitrateHint(2)]
/// ```
///
/// Fragments are independently encrypted by the AEAD layer, so packet
/// loss only affects individual fragments, not the whole video frame.
public final class VideoFrameFragmenter: @unchecked Sendable {

    /// Result of defragmentation: a complete reassembled NAL unit.
    public struct ReassembledFrame: Equatable {
        public let nalUnit: Data
        public let frameId: Int
        public let isKeyFrame: Bool
        public let bitrateHintKbps: Int

        public init(nalUnit: Data, frameId: Int, isKeyFrame: Bool, bitrateHintKbps: Int) {
            self.nalUnit = nalUnit
            self.frameId = frameId
            self.isKeyFrame = isKeyFrame
            self.bitrateHintKbps = bitrateHintKbps
        }
    }

    // MARK: - Internal pending state

    private final class PendingFrame {
        var fragments: [Data?]
        let totalFragments: Int
        let isKeyFrame: Bool
        let bitrateHintKbps: Int
        let startTimeMs: Int64
        var receivedCount: Int

        init(totalFragments: Int, isKeyFrame: Bool, bitrateHintKbps: Int, startTimeMs: Int64) {
            self.fragments = Array(repeating: nil, count: totalFragments)
            self.totalFragments = totalFragments
            self.isKeyFrame = isKeyFrame
            self.bitrateHintKbps = bitrateHintKbps
            self.startTimeMs = startTimeMs
            self.receivedCount = 0
        }
    }

    private let lock = NSLock()
    private var pendingFrames: [Int: PendingFrame] = [:]
    private var nextFrameId: Int = 0

    public init() {}

    // MARK: - Fragment

    /// Fragment a NAL unit into transport-sized chunks with sub-headers.
    /// Each fragment will be independently encrypted by the AEAD layer.
    public func fragment(
        nalUnit: Data,
        isKeyFrame: Bool,
        bitrateKbps: Int = VideoConstants.defaultVideoBitrateBps / 1000
    ) -> [Data] {
        let maxDataPerFragment = VideoConstants.maxFragmentPayload - VideoConstants.videoFragmentHeaderSize
        let neededFragments = (nalUnit.count + maxDataPerFragment - 1) / maxDataPerFragment
        let totalFragments = max(1, min(neededFragments, VideoConstants.maxFragmentsPerFrame))

        lock.lock()
        let frameId = nextFrameId
        nextFrameId = (nextFrameId + 1) & 0xFFFF
        lock.unlock()

        var fragments: [Data] = []
        fragments.reserveCapacity(totalFragments)

        for i in 0..<totalFragments {
            let dataOffset = i * maxDataPerFragment
            let dataLength = min(maxDataPerFragment, nalUnit.count - dataOffset)
            let isLast = (i == totalFragments - 1)

            var fragFlags: UInt8 = 0
            if isKeyFrame { fragFlags |= VideoConstants.fragFlagKeyFrame }
            if isLast { fragFlags |= VideoConstants.fragFlagLastFragment }

            var fragment = Data(capacity: VideoConstants.videoFragmentHeaderSize + dataLength)
            fragment.append(fragFlags)
            // frameId u16 BE
            fragment.append(UInt8((frameId >> 8) & 0xFF))
            fragment.append(UInt8(frameId & 0xFF))
            fragment.append(UInt8(i & 0xFF))             // fragIdx
            fragment.append(UInt8(totalFragments & 0xFF)) // totalFrags
            // bitrateHint u16 BE
            fragment.append(UInt8((bitrateKbps >> 8) & 0xFF))
            fragment.append(UInt8(bitrateKbps & 0xFF))
            // NAL chunk
            if dataLength > 0 {
                fragment.append(nalUnit.subdata(in: (nalUnit.startIndex + dataOffset)..<(nalUnit.startIndex + dataOffset + dataLength)))
            }
            fragments.append(fragment)
        }
        return fragments
    }

    // MARK: - Defragment

    /// Defragment a received fragment and attempt to reassemble the
    /// complete NAL unit. Returns a `ReassembledFrame` when all
    /// fragments of a frame have arrived, `nil` otherwise.
    public func defragment(_ fragmentPayload: Data) -> ReassembledFrame? {
        guard fragmentPayload.count >= VideoConstants.videoFragmentHeaderSize else {
            return nil
        }
        let base = fragmentPayload.startIndex
        let fragFlags = fragmentPayload[base]
        let frameId = (Int(fragmentPayload[base + 1]) << 8) | Int(fragmentPayload[base + 2])
        let fragIdx = Int(fragmentPayload[base + 3])
        let totalFrags = Int(fragmentPayload[base + 4])
        let bitrateHintKbps = (Int(fragmentPayload[base + 5]) << 8) | Int(fragmentPayload[base + 6])
        let isKeyFrame = (fragFlags & VideoConstants.fragFlagKeyFrame) != 0

        guard totalFrags > 0, fragIdx < totalFrags else { return nil }

        let nalChunk = fragmentPayload.subdata(in:
            (base + VideoConstants.videoFragmentHeaderSize)..<fragmentPayload.endIndex)

        lock.lock()
        defer { lock.unlock() }

        let pending: PendingFrame
        if let existing = pendingFrames[frameId] {
            // Validate consistency (reject if total/keyframe disagrees).
            if existing.totalFragments != totalFrags { return nil }
            pending = existing
        } else {
            pending = PendingFrame(
                totalFragments: totalFrags,
                isKeyFrame: isKeyFrame,
                bitrateHintKbps: bitrateHintKbps,
                startTimeMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
            pendingFrames[frameId] = pending
        }

        // Store fragment (ignore duplicates).
        if pending.fragments[fragIdx] == nil {
            pending.fragments[fragIdx] = nalChunk
            pending.receivedCount += 1
        }

        // Check if complete.
        guard pending.receivedCount >= pending.totalFragments else {
            return nil
        }
        pendingFrames.removeValue(forKey: frameId)

        // Reassemble NAL unit.
        let totalSize = pending.fragments.reduce(0) { $0 + ($1?.count ?? 0) }
        var nalUnit = Data(capacity: totalSize)
        for chunk in pending.fragments {
            if let chunk = chunk { nalUnit.append(chunk) }
        }
        return ReassembledFrame(
            nalUnit: nalUnit,
            frameId: frameId,
            isKeyFrame: pending.isKeyFrame,
            bitrateHintKbps: pending.bitrateHintKbps
        )
    }

    // MARK: - Maintenance

    /// Purge stale incomplete frames that exceeded the reassembly timeout.
    /// Should be called periodically (e.g., every 100ms). Returns the
    /// number of purged frames.
    @discardableResult
    public func purgeStaleFrames() -> Int {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let timeout = VideoConstants.fragmentReassemblyTimeoutMs
        lock.lock()
        defer { lock.unlock() }
        let staleIds = pendingFrames.compactMap { (id, p) in
            (nowMs - p.startTimeMs > timeout) ? id : nil
        }
        for id in staleIds {
            pendingFrames.removeValue(forKey: id)
        }
        return staleIds.count
    }

    public var pendingFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingFrames.count
    }

    public func reset() {
        lock.lock()
        pendingFrames.removeAll()
        nextFrameId = 0
        lock.unlock()
    }
}
