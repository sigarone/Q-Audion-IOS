import Foundation

/// The one operation `SpeakerVerifier` needs from a speaker-embedding
/// backend: turn 16 kHz mono PCM into a fixed-length embedding vector.
///
/// Extracted 2026-08-02. `SpeakerVerifier` used to hold a concrete
/// `CamPlusSpeakerEmbedder`, which made its state machine untestable
/// anywhere the real model cannot load — and the model deliberately does
/// not load on a simulator (`CamPlusSpeakerEmbedder.loadModel` is
/// `#if !targetEnvironment(simulator) … #else return false #endif`), which
/// is where CI runs. The consequence was three permanently-failing
/// SpeakerVerifierTests cases, a suite red on 40+ consecutive pushes, and a
/// genuine ContactsStore regression that sat unnoticed inside that red.
///
/// This changes nothing about production behaviour: the app injects
/// `CamPlusSpeakerEmbedder.shared` exactly as before, and the ONNX path is
/// still the only one that ever runs on a device.
public protocol SpeakerEmbedding: AnyObject, Sendable {

    /// Length of the returned vector. Callers use it only for validation;
    /// `SpeakerVerifier` itself is dimension-agnostic (cosine similarity
    /// works on whatever length both sides share).
    static var embeddingDimension: Int { get }

    /// - Parameter pcm16kMono: mono float samples at 16 kHz.
    /// - Returns: the embedding vector.
    /// - Throws: when no usable backend exists (no model, no runtime) or
    ///   inference fails. MUST throw rather than return a zero/placeholder
    ///   vector — a silent zero vector would read downstream as a real
    ///   embedding and produce a meaningless similarity score.
    func embed(pcm16kMono: [Float]) throws -> [Float]
}

extension CamPlusSpeakerEmbedder: SpeakerEmbedding {}
