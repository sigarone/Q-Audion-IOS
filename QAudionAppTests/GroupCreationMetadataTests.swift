import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-GRPNAME (2026-08-02) — the app-layer half of "a group is never nameless".
/// The decision rules themselves are pure and live in the engine
/// (`GroupCreationPolicy` / `GroupCreationPolicyTests`, which DO compile and
/// run); what is left here are the two facts that only exist in the app
/// target and that the create path depends on being true:
///
///   1. the plaintext packed into the creation blob serialises to the
///      cross-platform `{name, avatar_ref?}` shape, with `avatar_ref` OMITTED
///      rather than null when the group has no avatar;
///   2. the interim name `bootstrapGroupFromServer` now writes is recognised
///      as a placeholder by BOTH placeholder checks — the app one
///      (`DisplayName.isPlaceholderName`, which decides what may be rendered)
///      and the engine one (`isSynthesizedGroupPlaceholderName`, which decides
///      what may be re-published). The old bare-hex placeholder satisfied
///      NEITHER, which is exactly how "3fedc2e7…" ended up being treated as a
///      real group name.
///
/// Same gap `DisplayNameTests.swift`/`PeerTrustEvaluatorTests.swift`/
/// `HeroPresenceLabelTests.swift` already document: no `QAudionAppTests`
/// target is wired in `QAudionApp/project.yml` yet, and no Xcode/Swift
/// toolchain is available in this session (Windows, no macOS/Xcode) to
/// compile or run this file. Written against that gap rather than left
/// unwritten — UNVERIFIED BY COMPILATION, reviewed by hand against the real
/// implementations instead.
final class GroupCreationMetadataTests: XCTestCase {

    // MARK: - The blob's plaintext shape

    private func encodedPayload(name: String, avatarRef: String?) throws -> [String: Any] {
        let data = try JSONEncoder().encode(GroupMetadataPayload(name: name, avatarRef: avatarRef))
        let json = try JSONSerialization.jsonObject(with: data)
        return (json as? [String: Any]) ?? [:]
    }

    /// A brand-new group has no avatar. The server contract's shape is
    /// `{name, avatar_ref?}` with the key OMITTED for "no avatar" — an
    /// explicit null is a different document, and the peers that consume this
    /// blob (Android/Desktop) decode the absence, not a null.
    func test_creationPayload_omitsAvatarRefEntirely_whenThereIsNoAvatar() throws {
        let obj = try encodedPayload(name: "Famiglia", avatarRef: nil)
        XCTAssertEqual(obj["name"] as? String, "Famiglia")
        XCTAssertNil(obj["avatar_ref"])
        XCTAssertFalse(obj.keys.contains("avatar_ref"))
        XCTAssertEqual(obj.count, 1)
    }

    /// The rename path DOES carry an avatar, under the snake_case wire key —
    /// pinned here so a future rename of the Swift property cannot silently
    /// change the wire.
    func test_metadataPayload_usesSnakeCaseAvatarRefOnTheWire() throws {
        let obj = try encodedPayload(name: "Team", avatarRef: "file-123")
        XCTAssertEqual(obj["avatar_ref"] as? String, "file-123")
        XCTAssertNil(obj["avatarRef"])
    }

    /// The blob is what other members decrypt into a group name, so the round
    /// trip has to be exact — including non-ASCII, which the app's canonical
    /// envelope builder deliberately passes through as raw UTF-8.
    func test_metadataPayload_roundTripsUnicodeNames() throws {
        let original = GroupMetadataPayload(name: "Famiglia Rossi 🇮🇹", avatarRef: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GroupMetadataPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - The interim name is recognisable as one, on both sides

    /// THE invariant behind the bootstrap-placeholder fix. If either check
    /// stops recognising this string, the placeholder starts being treated as
    /// a name the user chose: rendered verbatim forever by the app check, or
    /// re-published as the group's real encrypted name by the engine check.
    func test_bootstrapPlaceholder_isRecognisedByBothPlaceholderChecks() {
        let hex = "3fedc2e71a2b4c3d8e9f0011223344aa"
        let placeholder = DisplayName.shortGroupFallback(hex)
        XCTAssertEqual(placeholder, "Gruppo 3fedc2e7…")
        XCTAssertTrue(DisplayName.isPlaceholderName(placeholder))
        XCTAssertTrue(isSynthesizedGroupPlaceholderName(placeholder))
    }

    /// The shape this replaced. Kept as a test because it documents the whole
    /// defect in two assertions: the bare fragment passed both checks as a
    /// "real" name, which is why it survived all the way to the chat list.
    func test_theLegacyBareHexPlaceholder_wasInvisibleToTheAppCheck() {
        let legacy = "3fedc2e7…"
        XCTAssertFalse(DisplayName.isPlaceholderName(legacy),
                       "documents the defect: the app resolver saw this as a real name")
        XCTAssertTrue(isSynthesizedGroupPlaceholderName(legacy),
                      "the engine check covers it, so it can never be re-published")
    }

    /// A dashed-UUID group id must produce the same placeholder as its
    /// hex form — the two ids are the same group, and two different interim
    /// names for one group would show up as a rename that never happened.
    func test_bootstrapPlaceholder_isIdenticalForBothIdForms() {
        let dashed = "3FEDC2E7-1A2B-4C3D-8E9F-0011223344AA"
        let hex = "3fedc2e71a2b4c3d8e9f0011223344aa"
        XCTAssertEqual(DisplayName.shortGroupFallback(dashed),
                       DisplayName.shortGroupFallback(hex))
    }

    /// And the placeholder must never be what the group publishes. This is
    /// the engine rule (`groupNameToPublishAtCreation`) applied to the exact
    /// string this app layer produces — the two halves have to line up or a
    /// device that bootstrapped from a snapshot would poison the group name
    /// for everybody the first time it created… nothing. Belt and braces.
    func test_thePlaceholderIsNeverPublishableAsACreationName() {
        let placeholder = DisplayName.shortGroupFallback("3fedc2e71a2b4c3d8e9f0011223344aa")
        XCTAssertNil(groupNameToPublishAtCreation(placeholder))
    }
}
