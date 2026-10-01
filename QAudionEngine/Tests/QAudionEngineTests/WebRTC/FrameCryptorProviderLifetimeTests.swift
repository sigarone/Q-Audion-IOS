import XCTest

/// P12 design rule S5: a frame-cryptor KeyProvider MUST live at least as long as every sender
/// transformer that uses it, and an app MUST NOT create a new provider for an RtpSender whose ssrc
/// is unchanged under a key that is still installed. The native receiver anti-replay window and the
/// sender IV counter live in the per-stream handler, behind the provider: re-creating a provider
/// mid-call would restart the counter under the same key (nonce reuse) or make the peer's window
/// refuse the stream.
///
/// The providers are call-scoped by construction: each one is a `let` assigned exactly once, in the
/// `init` of the cryptor object that owns it, and the PeerConnection caches that object for its
/// whole life (`ensureNative*Cryptor`) and only drops it in `close()`. This test pins those
/// structural facts on the sources, so a future refactor that re-creates a provider fails here.
/// (The cryptors wrap a native object that only exists in the WebRTC binary, so the invariant is
/// checked on the source text, not at runtime.)
final class FrameCryptorProviderLifetimeTests: XCTestCase {

    private func sourcesRoot() throws -> URL {
        // .../QAudionEngine/Tests/QAudionEngineTests/WebRTC/<this file>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("Sources/QAudionEngine")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("package sources are not on disk next to the tests")
        }
        return root
    }

    private func source(_ relative: String) throws -> String {
        let url = try sourcesRoot().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        return text.components(separatedBy: needle).count - 1
    }

    private func allSwiftSources() throws -> [(path: String, text: String)] {
        let root = try sourcesRoot()
        var out: [(String, String)] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.lastPathComponent, text))
            }
        }
        return out
    }

    /// Exactly three places create a provider, one per owner type; no other file does.
    func testProvidersAreCreatedOnlyByTheirOwners() throws {
        var creators: [String: Int] = [:]
        for (name, text) in try allSwiftSources() {
            let n = occurrences(of: "RTCFrameCryptorKeyProvider(", in: text)
            if n > 0 { creators[name] = n }
        }
        XCTAssertEqual(
            creators,
            ["NativeAudioFrameCryptor.swift": 1, "NativeVideoFrameCryptor.swift": 1, "GroupFrameCryptorHub.swift": 1],
            "a new RTCFrameCryptorKeyProvider creator appeared: it must satisfy P12 S5 and be added here")
    }

    /// The provider is an immutable `let`, assigned once in the owner's initializer, never reassigned.
    func testProviderIsAnImmutableLetAssignedInInit() throws {
        for file in ["WebRTC/NativeAudioFrameCryptor.swift", "WebRTC/NativeVideoFrameCryptor.swift", "GroupCall/GroupFrameCryptorHub.swift"] {
            let text = try source(file)
            XCTAssertEqual(occurrences(of: "public let keyProvider: RTCFrameCryptorKeyProvider", in: text), 1, file)
            XCTAssertEqual(occurrences(of: "self.keyProvider = RTCFrameCryptorKeyProvider(", in: text), 1, file)
            XCTAssertEqual(occurrences(of: "var keyProvider", in: text), 0, file)
            // The only assignment to the property is the one in init.
            XCTAssertEqual(occurrences(of: "keyProvider =", in: text), 1, "\(file): keyProvider reassigned")
        }
        for (name, text) in try allSwiftSources() where !name.hasSuffix("FrameCryptor.swift") && name != "GroupFrameCryptorHub.swift" {
            XCTAssertEqual(occurrences(of: ".keyProvider =", in: text), 0, "\(name) must not replace a provider")
        }
    }

    /// The PeerConnection hands out ONE cryptor per kind and only drops it in `close()`.
    func testPeerConnectionCachesCryptorsAndDropsThemOnlyInClose() throws {
        let text = try source("WebRTC/QAudionPeerConnection.swift")
        XCTAssertTrue(text.contains("if let c = nativeVideoCryptor { return c }"))
        XCTAssertTrue(text.contains("if let existing = nativeAudioCryptor { return existing }"))
        // `nativeAudioCryptor = nil` / `nativeVideoCryptor = nil` appear once each, in `close()`.
        XCTAssertEqual(occurrences(of: "nativeVideoCryptor = nil", in: text), 1)
        XCTAssertEqual(occurrences(of: "nativeAudioCryptor = nil", in: text), 1)
        let closeStart = try XCTUnwrap(text.range(of: "public func close() {"))
        let afterClose = text[closeStart.upperBound...]
        XCTAssertTrue(afterClose.contains("nativeVideoCryptor = nil"))
        XCTAssertTrue(afterClose.contains("nativeAudioCryptor = nil"))
        // No other place constructs a cryptor object.
        XCTAssertEqual(occurrences(of: "NativeAudioFrameCryptor(", in: text), 1)
        XCTAssertEqual(occurrences(of: "NativeVideoFrameCryptor(", in: text), 1)
    }

    /// Group calls: the hub (and with it the provider, the receiving handlers and their windows)
    /// is replaced only at a call boundary (`beginCall` / `endCall`), never by a media restart:
    /// `makeLink` (a media rejoin builds a new PeerConnection) reuses the current hub.
    func testGroupHubSurvivesMediaRestartAndIsReplacedOnlyAtCallBoundaries() throws {
        let text = try source("GroupCall/WebRtcGroupMediaBackend.swift")
        XCTAssertEqual(occurrences(of: "GroupFrameCryptorHub()", in: text), 3, "init, beginCall, endCall")
        let makeLink = try XCTUnwrap(text.range(of: "public func makeLink("))
        let endCall = try XCTUnwrap(text.range(of: "public func endCall()"))
        let body = String(text[makeLink.upperBound..<endCall.lowerBound])
        XCTAssertFalse(body.contains("GroupFrameCryptorHub("), "makeLink must not re-create the hub")
        XCTAssertTrue(body.contains("let cryptors = currentHub"))
    }

    /// The 1:1 cryptors run in per-participant mode with the ring slot semantics of WIRE_SPEC §3.7.2.
    func testOneToOneCryptorsUsePerParticipantKeys() throws {
        for file in ["WebRTC/NativeAudioFrameCryptor.swift", "WebRTC/NativeVideoFrameCryptor.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("sharedKeyMode: false"), file)
            XCTAssertFalse(text.contains("sharedKeyMode: true"), file)
        }
    }
}
