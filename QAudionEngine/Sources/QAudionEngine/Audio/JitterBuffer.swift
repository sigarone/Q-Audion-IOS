import Foundation

public final class JitterBuffer: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var buffer: [Data] = []
    private var _underrunCount: Int64 = 0
    private var _overrunCount: Int64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func push(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count >= capacity { buffer.removeFirst(); _overrunCount += 1 }
        buffer.append(frame)
    }

    public func pop() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if buffer.isEmpty { _underrunCount += 1; return nil }
        return buffer.removeFirst()
    }

    public var size: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return buffer.isEmpty }
    public var isFull: Bool { lock.lock(); defer { lock.unlock() }; return buffer.count >= capacity }
    public var underrunCount: Int64 { lock.lock(); defer { lock.unlock() }; return _underrunCount }
    public var overrunCount: Int64 { lock.lock(); defer { lock.unlock() }; return _overrunCount }

    public func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }

    public func generateComfortNoise() -> Data {
        var pcm = Data(count: AudioConstants.bytesPerFrame)
        pcm.withUnsafeMutableBytes { buf in
            let ptr = buf.bindMemory(to: Int16.self)
            for idx in 0..<AudioConstants.samplesPerFrame {
                ptr[idx] = Int16.random(in: -AudioConstants.comfortNoiseAmplitude...AudioConstants.comfortNoiseAmplitude)
            }
        }
        return pcm
    }
}
