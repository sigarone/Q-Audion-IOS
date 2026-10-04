import XCTest

/// W-WIPECONTACTS (2026-10-03, delta review of #158 and #165) — what leaves memory when the account leaves.
///
/// `LocalCryptoWipe.wipeAll()` empties the persisted stores; `AppState.resetAccountScopedRuntimeState()` is its
/// in-memory counterpart. Two defects lived in the gap between them:
///
///  - `cachedContacts` (the snapshot that labels incoming calls, chat and call-history rows and the Siri donation)
///    was emptied only by `logout()`. `ContactsStore.wipeAll()` posts no `.contactsDidChange`, so after a remote wipe
///    or an account deletion the previous account's contact names stayed in memory until the next login refreshed
///    them. It is now emptied in `resetAccountScopedRuntimeState()`, the one function all three wipe paths call.
///  - The accept latch (#165) is re-armed in that same function, so an outgoing call id left over from the account
///    that left cannot reach the next session. It is only reachable through the reset, so the reset must keep doing it.
///
/// `AppState` cannot be driven here (no lightweight init: CallKit, live provider, WebSocket), so these are SOURCE
/// INVARIANTS, the same choice `CallerBusyWiringTests` and `EarbudRetiredWiringTests` make: dropping either line from
/// the reset, putting a second clear back in `logout()`, or adding a wipe path that forgets the reset fails one of
/// them. Comments are stripped and whitespace collapsed before matching, so only code counts.
final class AccountWipeRuntimeResetWiringTests: XCTestCase {

    // MARK: - reading the source

    /// A source file was not found, or its text was not in the expected shape: the test FAILS (it never skips). A
    /// silently skipped invariant is the failure this file exists to prevent.
    private struct SourceProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    /// The repository root: the first ancestor of this file that holds `QAudionApp/AppState.swift`.
    private func repoRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let marker = dir.appendingPathComponent("QAudionApp/AppState.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
        }
        XCTFail("QAudionApp/AppState.swift not found from \(file): the wipe invariants cannot run", file: file, line: line)
        throw SourceProblem(what: "repository root not found from \(file)")
    }

    /// `raw` with line comments stripped and every run of whitespace collapsed to one space.
    private func code(_ raw: String) -> String {
        let withoutComments = raw
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func appCode(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = try repoRoot(file: file, line: line).appendingPathComponent("QAudionApp/AppState.swift")
        return code(try String(contentsOf: url, encoding: .utf8))
    }

    /// The text between the braces of the function declared as `declaration` (which must end with its opening
    /// brace, e.g. `func logout() {`). The declaration must exist: a refactor that renames it must update this test,
    /// never silently stop checking.
    private func body(
        of declaration: String, in code: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let start = try XCTUnwrap(
            code.range(of: declaration), "declaration not found: \(declaration)", file: file, line: line)
        var depth = 1
        var index = start.upperBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(code[start.upperBound..<index]) }
            }
            index = code.index(after: index)
        }
        XCTFail("unbalanced braces after: \(declaration)", file: file, line: line)
        throw SourceProblem(what: "unbalanced braces after \(declaration)")
    }

    // MARK: - what the reset clears

    /// The contacts snapshot of the account that left is emptied by the reset, so the remote-wipe handler and the
    /// account deletion (which call the reset but never touched the cache) cannot leave its names behind.
    func testTheResetEmptiesTheContactsCache() throws {
        let reset = try body(of: "func resetAccountScopedRuntimeState() {", in: try appCode())
        XCTAssertTrue(reset.contains("cachedContacts = []"),
                      "resetAccountScopedRuntimeState() must empty cachedContacts: wipeAll() posts no .contactsDidChange")
    }

    /// #165: the accept latch is re-armed by the reset, so a call id from the previous account cannot stay latched.
    func testTheResetRearmsTheAcceptLatch() throws {
        let reset = try body(of: "func resetAccountScopedRuntimeState() {", in: try appCode())
        XCTAssertTrue(reset.contains("acceptLatch.reset()"),
                      "resetAccountScopedRuntimeState() must re-arm the accept latch (W-STALEENVELOPE, #165)")
    }

    /// One place, not two: `logout()` goes through the reset and carries no clear of its own, so the cache cannot
    /// again be emptied on one wipe path only.
    func testLogoutHasNoSeparateCacheClear() throws {
        let logout = try body(of: "func logout() {", in: try appCode())
        XCTAssertFalse(logout.contains("cachedContacts = []"),
                       "logout() must not clear cachedContacts itself: resetAccountScopedRuntimeState() is the one place")
        XCTAssertTrue(logout.contains("LocalCryptoWipe.wipeAll() resetAccountScopedRuntimeState()"),
                      "logout() must wipe and then reset the account-scoped runtime state")
    }

    // MARK: - every wipe path calls the reset

    /// Every `LocalCryptoWipe.wipeAll()` in the app (logout, the remote-wipe handler, the account deletion) is
    /// followed at once by `resetAccountScopedRuntimeState()`, on `self`, on `appState`, or bare. A new wipe path
    /// that forgets the reset leaves the previous account's contacts and latch in memory and fails here.
    func testEveryLocalWipeIsFollowedByTheReset() throws {
        let appDir = try repoRoot().appendingPathComponent("QAudionApp")
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil),
            "cannot enumerate \(appDir.path)")
        let wipeCall = "LocalCryptoWipe.wipeAll()"
        let resetRight = #"^\s*(self\.)?(appState\?\.)?resetAccountScopedRuntimeState\(\)"#
        var sites = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard raw.contains(wipeCall) else { continue }
            let text = code(raw)
            var from = text.startIndex
            while let hit = text.range(of: wipeCall, range: from..<text.endIndex) {
                sites += 1
                let after = String(text[hit.upperBound...].prefix(120))
                XCTAssertNotNil(
                    after.range(of: resetRight, options: .regularExpression),
                    "\(url.lastPathComponent): LocalCryptoWipe.wipeAll() must be followed at once by resetAccountScopedRuntimeState(); found: \(after)")
                from = hit.upperBound
            }
        }
        XCTAssertGreaterThanOrEqual(
            sites, 3, "expected the logout, remote-wipe and account-deletion wipe sites; found \(sites)")
    }
}
