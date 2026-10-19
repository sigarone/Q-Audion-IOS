import Foundation

/// The frozen opening spectrum of the remote voice in one call.
///
/// The voice check wave of the call screen draws the live spectrum of the far
/// end on top of this one. The same voice keeps the live outline riding the
/// fill; a different voice pulls the two apart across whole regions of the
/// spectrum at once, which the eye reads in a glance with no legend and no
/// number.
///
/// What is stored is a measurement, not decoration: the per-band average of
/// the first `referenceFrames` spectrum frames of THIS call (the same 40-band
/// log-magnitude frames `SpectrumExtractor` produces for the on-screen
/// analyser), then frozen. Live and reference therefore share a speaker, a
/// codec, a network path and a room, which is what makes their agreement
/// mean something. Nothing here is compared with a stored template or with
/// another call.
///
/// Freezing is what makes the comparison mean anything: a reference that kept
/// averaging would slowly absorb whoever is talking, the two curves would
/// always agree, and the picture would be an expensive way of drawing nothing.
///
/// Mirrors the reference half of the Android class that does this job (frame
/// count, the 40-band size check, the rule that a frame with a non-finite
/// value is dropped whole, reset per call), so both platforms freeze the same
/// reference from the same kind of frames.
///
/// Honest limits: a band envelope is a coarse description of a voice. It moves
/// with loudness, with the distance from the microphone and with the vowel in
/// progress, so it is a companion to the speaker-change verdict and never the
/// verdict itself; nothing here feeds that decision.
///
/// Not thread-safe: feed and reset from one thread (the app calls it on the
/// main actor).
public final class VoiceReferenceEnvelope {
    /// Band count of the analyser this consumes. Frames of any other size are
    /// ignored rather than padded: a silently truncated envelope would make
    /// the picture meaningless without ever failing.
    public static let bandCount = 40

    /// Spectrum frames averaged into the reference before it freezes. The
    /// analyser publishes at about 15 Hz, so this is about four seconds of the
    /// far end's opening audio: long enough to average across several different
    /// sounds rather than freezing whichever vowel happened to be in progress.
    public static let defaultReferenceFrames = 60

    /// The frozen reference, or nil until `referenceFrames` frames were seen.
    public private(set) var reference: [Float]?

    private let referenceFrames: Int
    private var accumulator = [Float](repeating: 0, count: VoiceReferenceEnvelope.bandCount)
    private var accumulatedFrames = 0

    public init(referenceFrames: Int = VoiceReferenceEnvelope.defaultReferenceFrames) {
        self.referenceFrames = max(1, referenceFrames)
    }

    /// Feeds one spectrum frame. Returns true when this frame froze the
    /// reference (it is then available in `reference`); false otherwise,
    /// including every frame after the freeze, which changes nothing.
    @discardableResult
    public func feed(_ frame: [Float]) -> Bool {
        guard reference == nil else { return false }
        guard frame.count == Self.bandCount else { return false }
        if frame.contains(where: { !$0.isFinite }) { return false }
        for index in 0..<Self.bandCount {
            accumulator[index] += frame[index]
        }
        accumulatedFrames += 1
        guard accumulatedFrames >= referenceFrames else { return false }
        let count = Float(accumulatedFrames)
        reference = accumulator.map { $0 / count }
        return true
    }

    /// New call: forget the reference and the frames averaged towards it.
    public func reset() {
        reference = nil
        accumulator = [Float](repeating: 0, count: Self.bandCount)
        accumulatedFrames = 0
    }
}
