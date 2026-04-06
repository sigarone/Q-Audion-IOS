import Foundation

public final class ConfidenceIndex: @unchecked Sendable {
    public enum Level: String { case green; case yellow; case red }

    public static let greenThreshold: Float = 0.8
    public static let yellowThreshold: Float = 0.5
    private static let emaAlpha: Float = 0.1
    private static let windowSize = 100

    private let lock = NSLock()
    private var scores: [Float] = []
    private var emaScore: Float = 0.5

    public init() {}

    public func update(_ score: Float) -> Level {
        lock.lock(); defer { lock.unlock() }
        let clamped = max(0, min(1, score))
        emaScore = Self.emaAlpha * clamped + (1 - Self.emaAlpha) * emaScore
        scores.append(clamped)
        if scores.count > Self.windowSize { scores.removeFirst() }
        return currentLevelLocked()
    }

    public var currentLevel: Level { lock.lock(); defer { lock.unlock() }; return currentLevelLocked() }
    public var currentScore: Float { lock.lock(); defer { lock.unlock() }; return emaScore }
    public var scoreHistory: [Float] { lock.lock(); defer { lock.unlock() }; return scores }

    public func reset() { lock.lock(); scores.removeAll(); emaScore = 0.5; lock.unlock() }

    private func currentLevelLocked() -> Level {
        if emaScore >= Self.greenThreshold { return .green }
        if emaScore >= Self.yellowThreshold { return .yellow }
        return .red
    }
}
