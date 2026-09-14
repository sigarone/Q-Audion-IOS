import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-EXTPREFIX consolidation (2026-07-29) — coverage for the canonical
/// identity-display resolver, `DisplayName.forUser` and its supporting
/// primitives (`isPlaceholderName`, `extensionDigits(fromLegacyLabel:)`,
/// `bareDigits`, `resolvedExtension`, `formatExtension`). This is the ONE
/// function every other call site in the app (rubrica rows, call banners,
/// CallKit, call history, dial-by-extension, self-profile screens…) must
/// now go through instead of reimplementing its own placeholder-check/
/// prefix-formatting copy — see `DisplayName.swift`'s type kdoc for the
/// full list of sites this replaced.
///
/// Same gap `PeerTrustEvaluatorTests.swift`/`HeroPresenceLabelTests.swift`/
/// `NameResolutionServicePhoneNumberOfTests.swift` already document: no
/// `QAudionAppTests` target is wired in `QAudionApp/project.yml` yet, and no
/// Xcode/Swift toolchain is available in this session (Windows, no macOS/
/// Xcode) to compile or run this file. Written against that gap rather than
/// left unwritten — UNVERIFIED BY COMPILATION, reviewed carefully by hand
/// against `DisplayName.swift`'s actual implementation instead.
final class DisplayNameTests: XCTestCase {

    // MARK: - Test fixture builder

    private func contact(userId: String, displayName: String,
                         extensionNumber: String? = nil,
                         phoneNumber: String? = nil) -> ContactsStore.StoredContact {
        ContactsStore.StoredContact(
            userId: userId, displayName: displayName, phoneHash: "",
            avatarUrl: nil, lastSeen: nil, isVerified: false,
            phoneNumber: phoneNumber, extension: extensionNumber
        )
    }

    // MARK: - Rule 1: real human-set display name passthrough

    func test_realRubricaName_isReturnedVerbatim() {
        let contacts = [contact(userId: "u1", displayName: "Mario Rossi", extensionNumber: "100")]
        XCTAssertEqual(
            DisplayName.forUser("u1", contacts: contacts),
            "Mario Rossi"
        )
    }

    func test_realServerDisplayName_isReturnedVerbatim_whenNoRubricaMatch() {
        XCTAssertEqual(
            DisplayName.forUser("u2", serverDisplay: "Marta Rinaldi", contacts: []),
            "Marta Rinaldi"
        )
    }

    func test_rubricaRealName_winsOverServerDisplay() {
        let contacts = [contact(userId: "u1", displayName: "Mario Rossi")]
        XCTAssertEqual(
            DisplayName.forUser("u1", serverDisplay: "Some Stale Wire Name", contacts: contacts),
            "Mario Rossi"
        )
    }

    // MARK: - THE regression case from this session's investigation:
    // a peer whose serverDisplay/display_name is "Phone #100" and
    // extensionNumber/peerExtension = 100 — every call site must now
    // converge on the identical bare "100", never "Phone #100"/"Phone
    // N100"/"Int. 100"/"Interno 100"/etc.

    func test_legacyPhoneHashPlaceholder_withKnownExtension_yieldsBareDigits() {
        XCTAssertEqual(
            DisplayName.forUser("u3", serverDisplay: "Phone #100", knownExtension: "100", contacts: []),
            "100"
        )
    }

    func test_legacyPhoneHashPlaceholder_recoversExtensionFromTheStringItself() {
        // Even WITHOUT an explicit knownExtension, the legacy placeholder's
        // own embedded digits are recovered — rule 5 (defense in depth):
        // "Phone #100" was always literally "Phone #" + the real extension.
        XCTAssertEqual(
            DisplayName.forUser("u3", serverDisplay: "Phone #100", contacts: []),
            "100"
        )
    }

    func test_staleRubricaPlaceholder_isTreatedAsNoNameSet_fallsThroughToExtension() {
        // A cached "Phone #100" sitting in the LOCAL rubrica (not just the
        // wire) must be treated identically — rule 5's "stored/cached
        // value" clause, not just newly-created accounts.
        let contacts = [contact(userId: "u3", displayName: "Phone #100", extensionNumber: "100")]
        XCTAssertEqual(DisplayName.forUser("u3", contacts: contacts), "100")
    }

    // MARK: - Legacy placeholder detection — every documented shape

    func test_isPlaceholderName_recognisesEveryLegacyShape() {
        let placeholders = [
            "Phone #100", "Phone N100", "Phone100",
            "Extension #100", "Extension100",
            "Int. 100", "Int.100",
            "Interno 100",
            "Ext. 100", "Ext100",
            "(ext. 100)",
            "Nebenstelle 100",
            "New User", "new user", "NEW USER",
            "", "   ",
        ]
        for p in placeholders {
            XCTAssertTrue(DisplayName.isPlaceholderName(p), "expected placeholder: \"\(p)\"")
        }
    }

    func test_isPlaceholderName_recognisesUUIDShapes() {
        XCTAssertTrue(DisplayName.isPlaceholderName("a1b2c3d4-0000-0000-0000-0000000000aa"))
        XCTAssertTrue(DisplayName.isPlaceholderName(String(repeating: "a1b2c3d4", count: 4)))
    }

    func test_isPlaceholderName_recognisesOwnShortFallbackShapes() {
        XCTAssertTrue(DisplayName.isPlaceholderName("Utente a1b2c3d4…"))
        XCTAssertTrue(DisplayName.isPlaceholderName("Gruppo a1b2c3d4…"))
    }

    // W-DEVICEPLACEHOLDER — ported from Android's DEVICE_PLACEHOLDER_REGEX
    // (^Device-[0-9a-fA-F]{6,}$, PeerDisplayResolver.kt, 2026-08-07).
    func test_isPlaceholderName_recognisesDevicePlaceholder() {
        XCTAssertTrue(DisplayName.isPlaceholderName("Device-1a2b3c"))
        XCTAssertTrue(DisplayName.isPlaceholderName("Device-ABCDEF12"))
        XCTAssertTrue(DisplayName.isPlaceholderName("Device-000000"))
        // Fewer than 6 hex chars, a non-hex char, or a different prefix case
        // are NOT the shape Android's regex matches — must not over-trigger.
        XCTAssertFalse(DisplayName.isPlaceholderName("Device-abc"))
        XCTAssertFalse(DisplayName.isPlaceholderName("Device-1a2b3g"))
        XCTAssertFalse(DisplayName.isPlaceholderName("device-1a2b3c"))
        XCTAssertFalse(DisplayName.isPlaceholderName("Device-1a2b3c-extra"))
    }

    func test_isPlaceholderName_doesNotFlagARealName() {
        XCTAssertFalse(DisplayName.isPlaceholderName("Mario Rossi"))
        XCTAssertFalse(DisplayName.isPlaceholderName("Marta"))
    }

    func test_isPlaceholderName_doesNotFlagABareExtension() {
        // A bare "103" IS the correct rule-3 rendering, not an absence of a
        // name — must NOT be treated as "no name set" by the general
        // placeholder check (that would send an already-correct value back
        // through re-resolution at read-time call sites that guard on this).
        XCTAssertFalse(DisplayName.isPlaceholderName("103"))
        XCTAssertFalse(DisplayName.isPlaceholderName("7"))
    }

    // MARK: - W-PHONEVERIFY (2026-07-30): a synthetic bare-extension rubrica
    // name (NameResolutionService.apply()'s own fallback when a peer's
    // server display_name is empty) must not permanently outrank a phone
    // number that becomes known LATER — real-device regression (bug report
    // 59a01e0a, screenshot showed "135" in-call for a peer whose phone the
    // dialer had just resolved via discover-v2). isPlaceholderName itself
    // stays unchanged (rule above) — forUser's tier-1 rubrica check must
    // ALSO defer specifically when the stored name is bare-extension-shaped
    // AND a phone is available, without touching the general contract.

    func test_bareExtensionRubricaName_defersToPhoneNumber_whenPhoneAvailable() {
        let contacts = [contact(userId: "u5", displayName: "135", extensionNumber: "135")]
        XCTAssertEqual(
            DisplayName.forUser("u5", knownPhoneNumber: "+393472103420", contacts: contacts),
            "+393472103420"
        )
    }

    func test_bareExtensionRubricaName_stillFinal_whenNoPhoneAvailable() {
        // Non-regression: the 2026-07-29 design intent (isPlaceholderName
        // kdoc above) stands when there is genuinely no phone to defer to —
        // no flicker/re-resolution for peers who will never have one.
        let contacts = [contact(userId: "u5", displayName: "135", extensionNumber: "135")]
        XCTAssertEqual(DisplayName.forUser("u5", contacts: contacts), "135")
    }

    func test_realRubricaName_stillWinsOverPhoneNumber() {
        // Non-regression: a REAL human-set name (not bare-extension-shaped)
        // must keep winning outright — the defer-to-phone behavior is
        // narrowly scoped to the synthetic bare-extension case only.
        let contacts = [contact(userId: "u5", displayName: "Mario Rossi", extensionNumber: "135")]
        XCTAssertEqual(
            DisplayName.forUser("u5", knownPhoneNumber: "+393472103420", contacts: contacts),
            "Mario Rossi"
        )
    }

    // MARK: - W-PHONEVERIFY, SECOND fix same day (2026-07-30): the FIRST
    // fix above only deferred tier 1 when a phone arrived via
    // `knownPhoneNumber` (or the stored row's own `phoneNumber` field) —
    // still live-broken, because `startCall`'s real dial path never passes
    // `knownPhoneNumber` at all. It resolves the phone number to a string
    // ONCE in `dialAndCall` and threads it through every subsequent
    // `forUser` call as `serverDisplay` (`_candidateLabel` /
    // `_dialerLabel` in `AppState.startCall`). A phone arriving through
    // THIS channel was invisible to the first fix, so tier 1 kept winning
    // — this is the actual mechanism behind the still-reproducing bug.

    func test_bareExtensionRubricaName_defersToRealServerDisplay_evenWhenThatIsAPhoneNumber() {
        let contacts = [contact(userId: "u6", displayName: "135", extensionNumber: "135")]
        XCTAssertEqual(
            DisplayName.forUser("u6", serverDisplay: "+393472103420", contacts: contacts),
            "+393472103420"
        )
    }

    func test_bareExtensionRubricaName_defersToRealServerDisplay_whenItIsAName() {
        let contacts = [contact(userId: "u6", displayName: "135", extensionNumber: "135")]
        XCTAssertEqual(
            DisplayName.forUser("u6", serverDisplay: "Marta Rinaldi", contacts: contacts),
            "Marta Rinaldi"
        )
    }

    func test_bareExtensionRubricaName_stillFinal_whenServerDisplayIsAlsoPlaceholder() {
        // Non-regression: a placeholder-shaped serverDisplay ("Phone #100")
        // must NOT count as "something better available" — the bare
        // extension still stands rather than deferring to nothing real.
        let contacts = [contact(userId: "u6", displayName: "135", extensionNumber: "135")]
        XCTAssertEqual(
            DisplayName.forUser("u6", serverDisplay: "Phone #100", contacts: contacts),
            "135"
        )
    }

    // MARK: - isBareExtension (the narrower, write-path-only predicate)

    func test_isBareExtension_trueForDigitsOnly() {
        XCTAssertTrue(DisplayName.isBareExtension("103"))
        XCTAssertTrue(DisplayName.isBareExtension("7"))
    }

    func test_isBareExtension_falseForRealNameOrEmpty() {
        XCTAssertFalse(DisplayName.isBareExtension("Mario Rossi"))
        XCTAssertFalse(DisplayName.isBareExtension(""))
        XCTAssertFalse(DisplayName.isBareExtension("Phone #100"))
    }

    // MARK: - extensionDigits(fromLegacyLabel:) — recovery, one shape at a time

    func test_extensionDigitsFromLegacyLabel_phoneHash() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Phone #100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_phoneN() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Phone N100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_extensionHash() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Extension #7"), "7")
    }

    func test_extensionDigitsFromLegacyLabel_intDot() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Int. 100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_interno() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Interno 100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_extDot() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Ext. 100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_parenthesised() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "(ext. 100)"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_nebenstelle() {
        XCTAssertEqual(DisplayName.extensionDigits(fromLegacyLabel: "Nebenstelle 100"), "100")
    }

    func test_extensionDigitsFromLegacyLabel_bareDigitsAlone_yieldsNil() {
        // No label at all — this shape is handled by `bareDigits` directly,
        // not the legacy-label recovery path.
        XCTAssertNil(DisplayName.extensionDigits(fromLegacyLabel: "100"))
    }

    func test_extensionDigitsFromLegacyLabel_unrecognisedLabel_yieldsNil() {
        XCTAssertNil(DisplayName.extensionDigits(fromLegacyLabel: "Room #100"))
    }

    func test_extensionDigitsFromLegacyLabel_realNameWithNumber_yieldsNil() {
        // "Via Roma 100" is a real (if unusual) name, not a legacy
        // extension label — must not be misdetected as one.
        XCTAssertNil(DisplayName.extensionDigits(fromLegacyLabel: "Via Roma 100"))
    }

    // MARK: - bareDigits: no zero-padding, no prefix

    func test_bareDigits_stripsLeadingZeroPadding() {
        XCTAssertEqual(DisplayName.bareDigits("007"), "7")
        XCTAssertEqual(DisplayName.bareDigits("0100"), "100")
    }

    func test_bareDigits_leavesNormalDigitsUnchanged() {
        XCTAssertEqual(DisplayName.bareDigits("100"), "100")
        XCTAssertEqual(DisplayName.bareDigits("7"), "7")
    }

    func test_bareDigits_nilForNonDigitInput() {
        XCTAssertNil(DisplayName.bareDigits("Mario"))
        XCTAssertNil(DisplayName.bareDigits(""))
        XCTAssertNil(DisplayName.bareDigits("103a"))
    }

    // MARK: - Rule 2/3: bare-extension fallback — no padding, no prefix,
    // applies whether the peer has no name at all OR only a placeholder.

    func test_noRealName_knownExtension_yieldsBareDigitsNoPrefix() {
        XCTAssertEqual(
            DisplayName.forUser("u4", knownExtension: "100", contacts: []),
            "100"
        )
    }

    func test_noRealName_knownExtension_neverZeroPadded() {
        // Extension "7" renders "7", never "007" — even if some upstream
        // source handed it over zero-padded.
        XCTAssertEqual(
            DisplayName.forUser("u5", knownExtension: "007", contacts: []),
            "7"
        )
    }

    func test_rubricaStructuredExtensionField_isUsed_whenDisplayNameIsPlaceholder() {
        let contacts = [contact(userId: "u6", displayName: "New User", extensionNumber: "42")]
        XCTAssertEqual(DisplayName.forUser("u6", contacts: contacts), "42")
    }

    // MARK: - Rule 4: phone-number fallback

    func test_noNameNoExtension_knownPhoneNumber_isShownAsIs() {
        XCTAssertEqual(
            DisplayName.forUser("u7", knownPhoneNumber: "+391234567890", contacts: []),
            "+391234567890"
        )
    }

    func test_rubricaPhoneNumberField_isUsed_whenNoNameOrExtension() {
        let contacts = [contact(userId: "u8", displayName: "", phoneNumber: "+391234567890")]
        XCTAssertEqual(DisplayName.forUser("u8", contacts: contacts), "+391234567890")
    }

    // 2026-07-29 (Pavel, explicit product decision): a known phone number
    // only ever exists because its owner explicitly published/opted in
    // (opt-in profile field, or the wire caller_display self-disclosure
    // gated on the caller's own "show my phone number" preference) — so it
    // now outranks the always-present-but-never-chosen bare extension.
    func test_phoneNumberWinsOverExtension_whenBothKnown() {
        XCTAssertEqual(
            DisplayName.forUser("u9", knownExtension: "100", knownPhoneNumber: "+391234567890", contacts: []),
            "+391234567890"
        )
    }

    // MARK: - Rule 5: uuid / short8 fallback (kept unchanged, per task scope)

    func test_uuidShapedId_neverShownRaw_shortFallbackInstead() {
        let uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let result = DisplayName.forUser(uuid, contacts: [])
        XCTAssertFalse(result.contains(uuid), "raw UUID must never leak into the fallback")
        XCTAssertTrue(result.hasPrefix("Utente "))
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func test_shortHumanScaleId_passesThroughUnchanged_whenNothingElseResolves() {
        XCTAssertEqual(DisplayName.forUser("100", contacts: []), "100")
    }

    func test_devSeedConvention_userPrefixIsCapitalised() {
        XCTAssertEqual(DisplayName.forUser("user-mario", contacts: []), "Mario")
    }

    func test_emptyUserId_yieldsUnknownPlaceholder() {
        XCTAssertEqual(DisplayName.forUser("   ", contacts: []), "Sconosciuto")
    }

    // MARK: - resolvedExtension: the extension-only primitive used by
    // metadata rows (e.g. ContactDetailScreen's INTERNO row) independent of
    // whatever the main display name resolved to.

    func test_resolvedExtension_explicitParamWins() {
        XCTAssertEqual(
            DisplayName.resolvedExtension(for: "u10", knownExtension: "55", contacts: []),
            "55"
        )
    }

    func test_resolvedExtension_fromRubricaStructuredField() {
        let contacts = [contact(userId: "u11", displayName: "Mario Rossi", extensionNumber: "60")]
        XCTAssertEqual(DisplayName.resolvedExtension(for: "u11", contacts: contacts), "60")
    }

    func test_resolvedExtension_fromLegacyLabelInRubricaDisplayName() {
        let contacts = [contact(userId: "u12", displayName: "Phone #70")]
        XCTAssertEqual(DisplayName.resolvedExtension(for: "u12", contacts: contacts), "70")
    }

    func test_resolvedExtension_fromLegacyLabelInServerDisplay() {
        XCTAssertEqual(
            DisplayName.resolvedExtension(for: "u13", serverDisplay: "Interno 80", contacts: []),
            "80"
        )
    }

    func test_resolvedExtension_nilWhenNothingRecoverable() {
        XCTAssertNil(DisplayName.resolvedExtension(for: "u14", serverDisplay: "Mario Rossi", contacts: []))
    }

    // MARK: - formatExtension: the self-profile helper (no rubrica lookup)

    func test_formatExtension_stripsPadding() {
        XCTAssertEqual(DisplayName.formatExtension("007"), "7")
    }

    func test_formatExtension_passesThroughNormalDigits() {
        XCTAssertEqual(DisplayName.formatExtension("103"), "103")
    }

    // MARK: - resolveDialInput / dialAndCall convergence (the documented
    // contradiction this session closed): both now format an extension via
    // the identical `DisplayName.forUser` call, so — for the identical
    // profile data — they can no longer diverge. Exercised here at the
    // shared primitive level (AppState.resolveDialInput/dialAndCall
    // themselves need a live network stack and are not unit-testable).

    func test_dialByExtension_realProfileName_winsOverBareExtension() {
        // Mirrors the exact call both AppState.dialAndCall (extension
        // branch) and AppState.resolveDialInput (extension branch) now make.
        XCTAssertEqual(
            DisplayName.forUser("peer-uuid", serverDisplay: "Giulia Bianchi",
                                knownExtension: "210", contacts: []),
            "Giulia Bianchi"
        )
    }

    func test_dialByExtension_noProfileName_yieldsBareExtension_notPrefixed() {
        XCTAssertEqual(
            DisplayName.forUser("peer-uuid", serverDisplay: nil, knownExtension: "210", contacts: []),
            "210"
        )
    }

    func test_dialByExtension_uuidShapedProfileName_yieldsBareExtension_notTheUUID() {
        // The server sets display_name = userId (UUID) for accounts
        // registered without a real display name — must fall through to
        // the dialed extension, never leak the UUID.
        let uuidName = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        XCTAssertEqual(
            DisplayName.forUser("peer-uuid", serverDisplay: uuidName,
                                knownExtension: "210", contacts: []),
            "210"
        )
    }

    // MARK: - forGroup / shortGroupFallback (unchanged, sanity only)

    @MainActor
    func test_forGroup_explicitNameWins() {
        XCTAssertEqual(DisplayName.forGroup(id: "abcd1234", name: "Team Rocket"), "Team Rocket")
    }

    func test_shortGroupFallback_neverShowsRawId() {
        let groupId = "aa-bb-cc-dd-ee-ff-00-11-22-33-44-55-66-77-88-99"
        let result = DisplayName.shortGroupFallback(groupId)
        XCTAssertTrue(result.hasPrefix("Gruppo "))
        XCTAssertTrue(result.hasSuffix("…"))
    }
}
