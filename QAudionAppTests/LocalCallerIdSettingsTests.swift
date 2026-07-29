import XCTest
@testable import QAudionApp

/// Pins `LocalCallerIdSettings`'s digit-normalization/persistence contract —
/// the mechanism section 11.6 of `ACCOUNT_REGISTRATION_SPEC.md` (bcrypto-server
/// repo) explicitly says must stay UNCHANGED while `AccountSettingsScreen`'s
/// caller-ID field was upgraded from free text to a single-select `Picker`
/// (2026-07-29). This file does not test the new picker UI itself (its
/// `callerIdPicker`/`callerIdOptions`/`extensionOptionLabel` are `private`
/// computed properties on a SwiftUI `View` struct in `AccountSettingsScreen
/// .swift` — `@testable import` only lifts `internal` access, not `private`,
/// so they are not reachable from a test target without an out-of-scope
/// refactor to extract them into a separately-testable type. Flagged here as
/// a real, currently-untested surface rather than silently skipped) — it
/// pins the one thing underneath the picker that genuinely was, and had to
/// stay, unchanged: whatever the user selects still round-trips through
/// `LocalCallerIdSettings.setPhoneNumber`/`.phoneNumber()` exactly as the old
/// free-text field did, which is what `AppState`'s outbound `call_offer`
/// (`caller_display`) plumbing reads at call time.
///
/// NOTE (not yet wired into a build target): this repo has no
/// `QAudionAppTests` XCTest target in `QAudionApp/project.yml` today — only
/// `QAudionEngine` ships a runnable `swift test` / `xcodebuild test` harness.
/// This file is written against that same gap `PeerTrustEvaluatorTests.swift`
/// and `HeroPresenceLabelTests.swift` already document, for the same reason:
/// wiring it in later is a small, mechanical `project.yml` addition rather
/// than blind infrastructure added without any way to verify it compiles —
/// this session has no macOS/Xcode/Swift toolchain available to validate
/// either the test or a `project.yml` change. Disclosed, not silently
/// skipped, per this repo's established pattern from earlier work this
/// session. See the task report for the full reasoning.
final class LocalCallerIdSettingsTests: XCTestCase {

    /// Isolated UserDefaults suite so this never touches the app's real
    /// `qaudion.local.phone` key (mirrors the collision-proof pattern
    /// `PeerTrustEvaluatorTests` uses for its own store cleanup).
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LocalCallerIdSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Selecting a registered E.164 number in the new picker still ends up
    /// stored verbatim (leading "+" preserved) — matches the picker's tags,
    /// which are exactly the strings from `container.publicPhones`.
    func test_setPhoneNumber_e164_roundTripsWithPlusPreserved() {
        LocalCallerIdSettings.setPhoneNumber("+393331234567", defaults: defaults)
        XCTAssertEqual(LocalCallerIdSettings.phoneNumber(defaults: defaults), "+393331234567")
    }

    /// Punctuation the user might have had left over from the OLD free-text
    /// field (spaces/dashes/parens) is still stripped — the new picker only
    /// ever writes clean tag strings, but `setPhoneNumber` itself must keep
    /// tolerating messier input from any other remaining call site.
    func test_setPhoneNumber_stripsSeparatorsButKeepsLeadingPlus() {
        LocalCallerIdSettings.setPhoneNumber("+39 333-123 (4567)", defaults: defaults)
        XCTAssertEqual(LocalCallerIdSettings.phoneNumber(defaults: defaults), "+393331234567")
    }

    /// The picker's "la mia estensione" option is tagged `""` — selecting it
    /// must clear the stored override entirely so the server-side fallback
    /// (extension) takes over, exactly as the doc comment on the picker
    /// promises ("tag \"\", clears LocalCallerIdSettings so the server falls
    /// back to the extension").
    func test_setPhoneNumber_emptyString_clearsStoredValue() {
        LocalCallerIdSettings.setPhoneNumber("+393331234567", defaults: defaults)
        XCTAssertNotNil(LocalCallerIdSettings.phoneNumber(defaults: defaults), "precondition")

        LocalCallerIdSettings.setPhoneNumber("", defaults: defaults)
        XCTAssertNil(LocalCallerIdSettings.phoneNumber(defaults: defaults))
    }

    /// `nil` input (not just empty string) must also clear — covers the
    /// `Optional<String>` overload the container's save path could call.
    func test_setPhoneNumber_nil_clearsStoredValue() {
        LocalCallerIdSettings.setPhoneNumber("+393331234567", defaults: defaults)
        LocalCallerIdSettings.setPhoneNumber(nil, defaults: defaults)
        XCTAssertNil(LocalCallerIdSettings.phoneNumber(defaults: defaults))
    }

    /// A value with no digits at all (e.g. stray punctuation) must not leave
    /// a garbage entry behind — same "never end up with garbage" guarantee
    /// the type's own doc comment states.
    func test_setPhoneNumber_noDigits_clearsRatherThanStoringGarbage() {
        LocalCallerIdSettings.setPhoneNumber("+393331234567", defaults: defaults)
        LocalCallerIdSettings.setPhoneNumber("+()- ", defaults: defaults)
        XCTAssertNil(LocalCallerIdSettings.phoneNumber(defaults: defaults))
    }

    /// Fresh install / never-configured state reads as nil, which is what
    /// drives `AccountSettingsContainer.draftLocalPhone` to initialize to
    /// `""` and the picker to default its selection to the extension tag.
    func test_phoneNumber_whenNeverSet_returnsNil() {
        XCTAssertNil(LocalCallerIdSettings.phoneNumber(defaults: defaults))
    }
}
