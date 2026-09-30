import Foundation

/// Group calls v2 (spec §4.5) — the transport self-check every client runs on
/// EVERY PeerConnection after it reaches `connected`. qjanus enforces the same
/// level fail-closed on its side; this check makes the client refuse a node
/// (or a downgraded path) that does not meet it, whatever the reason.
///
/// Values come from the WebRTC `transport` stats row. All three are protocol
/// identifiers, not secrets, so the observed values are allowed in telemetry.
public enum GroupTransportPolicy {

    /// DTLS 1.3 (the stats value is the on-wire version code 0xFEFC).
    public static let requiredTlsVersion = "FEFC"
    public static let requiredDtlsCipher = "TLS_AES_256_GCM_SHA384"
    /// Chromium spells the SRTP suite `AEAD_AES_256_GCM` or
    /// `SRTP_AEAD_AES_256_GCM` depending on its version (spec §10): both are
    /// accepted, nothing else.
    public static let acceptedSrtpCiphers: Set<String> = ["AEAD_AES_256_GCM", "SRTP_AEAD_AES_256_GCM"]

    public struct Observed: Equatable, Sendable {
        public let tlsVersion: String?
        public let dtlsCipher: String?
        public let srtpCipher: String?
        /// Type of the selected local candidate (`host`/`srflx`/`relay`), for
        /// the `group.transport` telemetry only.
        public let candidateType: String?

        public init(tlsVersion: String?, dtlsCipher: String?, srtpCipher: String?, candidateType: String? = nil) {
            self.tlsVersion = tlsVersion
            self.dtlsCipher = dtlsCipher
            self.srtpCipher = srtpCipher
            self.candidateType = candidateType
        }
    }

    public enum Verdict: Equatable, Sendable {
        case ok
        /// `fields` names what failed (`tls`, `cipher`, `srtp`), in that order.
        case violation(fields: [String])
        /// The stats row exists but is not filled yet (DTLS still settling):
        /// the caller asks again, it must not count as a violation.
        case notReady
    }

    public static func evaluate(_ observed: Observed) -> Verdict {
        if observed.tlsVersion == nil && observed.dtlsCipher == nil && observed.srtpCipher == nil {
            return .notReady
        }
        var failed: [String] = []
        if observed.tlsVersion?.uppercased().replacingOccurrences(of: "0X", with: "") != requiredTlsVersion {
            failed.append("tls")
        }
        if observed.dtlsCipher != requiredDtlsCipher { failed.append("cipher") }
        if let srtp = observed.srtpCipher, acceptedSrtpCiphers.contains(srtp) {
            // ok
        } else {
            failed.append("srtp")
        }
        return failed.isEmpty ? .ok : .violation(fields: failed)
    }
}
