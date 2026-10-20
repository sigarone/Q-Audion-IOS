import Foundation

/// The word at the end of the tone row: whether the voice of the other person is being heard.
public enum VoiceWord: Equatable, Sendable {
    /// A voiced result has arrived since the last reset, and the last 2 s of audio were not all unvoiced.
    case voice
    /// The last 2 s of audio (20 results) held no voiced result.
    case silence
    /// Nothing voiced since the reset, and not yet 2 s without it: the row shows the value and no word.
    case noWord
}

/// The rule behind `VoiceWord` (docs/voice-analysis-spec.md, section 12.6), kept over the step results.
///
/// The word does not follow the voiced flag of the display value (section 9). That flag is a majority over the last
/// second, so ordinary speech turns it off: unvoiced consonants, short pauses and a voice that is periodic for less
/// than half of the second. The word follows the results themselves and holds over a pause: a voiced result shows
/// "voice" at once, and "silence" comes only after 20 unvoiced results in a row (2 s of audio).
///
/// The count is in results, that is in audio time, never in wall-clock time. The engine updates it once per step,
/// clears it with the display history (a reset or a gap of 2 s or more) and keeps it over a shorter gap.
///
/// Pure value: no clock, no lock; the engine touches it with its own lock held.
public struct VoiceWordHold: Sendable {
    /// Unvoiced results in a row after which the word is "silence": 2 s of audio.
    public static let silenceResults = 20

    /// A voiced result has arrived since the last reset.
    private var heard = false
    /// Unvoiced results since the last voiced one, or since the reset.
    private var unvoiced = 0

    public init() {}

    /// The word after the latest result.
    public var word: VoiceWord {
        if unvoiced >= Self.silenceResults { return .silence }
        return heard ? .voice : .noWord
    }

    /// Counts one step result and returns the word after it.
    @discardableResult
    public mutating func update(voiced: Bool) -> VoiceWord {
        if voiced {
            heard = true
            unvoiced = 0
        } else {
            unvoiced += 1
        }
        return word
    }

    /// Forgets everything: nothing has been heard.
    public mutating func reset() {
        heard = false
        unvoiced = 0
    }
}
