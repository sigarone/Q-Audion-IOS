import XCTest
@testable import QAudionEngine

/// What a client does with each row of the server's error table (docs/FILES_V2_PARTS_PROTOCOL.md, "Errors", checked against
/// internal/filesv2/handler.go) and the mapping of design 2.6. The same status means different things for different
/// operations, so every row names the operation that failed.
final class FileV2DispositionTests: XCTestCase {

    private let put = FileV2Op.putPart

    private func disposition(_ status: Int, _ code: String, _ op: FileV2Op = .putPart, retryAfter: Int? = nil) -> FileV2Disposition {
        FileV2ServerError(status: status, code: code, retryAfter: retryAfter).disposition(for: op)
    }

    private let retryNetwork = FileV2Disposition.retry(onExhausted: .network)
    private let retryRate = FileV2Disposition.retry(onExhausted: .rateLimited)

    private func fail(_ error: FileV2TransferError) -> FileV2Disposition { .fail(error) }

    // MARK: 4xx

    func test400TheRequestIsWrongFixItDoNotRetryUnchanged() {
        for code in ["bad_request", "bad_blob_len", "bad_part_size", "bad_head", "bad_part", "bad_length", "bad_token_request",
                     "bad_token_headers"] {
            XCTAssertEqual(disposition(400, code), fail(.badRequest), code)
        }
    }

    func test400DigestHeadersMissingOrMalformedAreAClientBug() {
        XCTAssertEqual(disposition(400, "digest_required"), fail(.badRequest))
        XCTAssertEqual(disposition(400, "digest_invalid"), fail(.badRequest))
    }

    func test400DigestMismatchAndShortBodyResendTheSamePart() {
        XCTAssertEqual(disposition(400, "digest_mismatch"), retryNetwork)
        XCTAssertEqual(disposition(400, "short_body"), retryNetwork)
    }

    func test401RefreshTheToken() {
        XCTAssertEqual(disposition(401, "unauthorized"), .refreshAuth)
    }

    func test402Entitlement() {
        XCTAssertEqual(disposition(402, "entitlement_required"), fail(.entitlement))
    }

    func test403OnTheSenderSideIsAFinalAuthFailure() {
        for code in ["not_owner", "not_group_member", "token_required", "token_rejected"] {
            XCTAssertEqual(disposition(403, code, .issueToken), fail(.auth), code)
        }
    }

    func test403TokenRejectedOnTheReceiversReadMeansTheFileIsNoLongerAvailableNotAuth() {
        XCTAssertEqual(disposition(403, "token_rejected", .fetchRange), .unavailable)
        // the other 403s of a read stay what they are
        XCTAssertEqual(disposition(403, "token_required", .fetchRange), fail(.auth))
        XCTAssertEqual(disposition(403, "not_owner", .fetchRange), fail(.auth))
    }

    func test404RecreatesOnTheSendersOperationsIsSuccessOnDeleteUnavailableOnARead() {
        for op in [FileV2Op.putPart, .partsMap, .complete, .issueToken] {
            XCTAssertEqual(disposition(404, "not_found", op), .recreate, op.rawValue)
        }
        XCTAssertEqual(disposition(404, "not_found", .delete), .done)
        XCTAssertEqual(disposition(404, "not_found", .fetchRange), .unavailable, "the receiver cannot recreate")
    }

    /// The routes of create and of the collection always exist: a 404 there is a server this client does not speak to, and
    /// "recreate" would loop for ever.
    func test404OnARouteThatAlwaysExistsIsNotARecreateLoop() {
        for op in [FileV2Op.create, .listUnfinished, .deleteUnfinished] {
            XCTAssertEqual(disposition(404, "not_found", op), fail(.badRequest), op.rawValue)
        }
    }

    func test405411And416AreClientBugs() {
        XCTAssertEqual(disposition(405, "method_not_allowed"), fail(.badRequest))
        XCTAssertEqual(disposition(411, "length_required"), fail(.badRequest))
        XCTAssertEqual(disposition(416, "range_not_satisfiable", .fetchRange), fail(.badRequest))
    }

    func test409PartConflictMeansTheSourceChanged() {
        XCTAssertEqual(disposition(409, "part_conflict"), fail(.sourceChanged))
    }

    func test409IncompleteSendsTheMissingParts() {
        XCTAssertEqual(disposition(409, "incomplete", .complete), .sendMissing)
    }

    func test409HeadConflictAndTooManyGroupScopesAreFinal() {
        XCTAssertEqual(disposition(409, "head_conflict", .create), fail(.badRequest))
        XCTAssertEqual(disposition(409, "too_many_group_scopes", .issueToken), fail(.badRequest))
    }

    func test413IsAQuotaErrorForBothCodes() {
        XCTAssertEqual(disposition(413, "blob_too_large", .create), fail(.quota))
        XCTAssertEqual(disposition(413, "quota_exceeded", .create), fail(.quota))
    }

    func test425WaitsItIsNotAFailure() {
        XCTAssertEqual(disposition(425, "parts_not_yet_received", .fetchRange, retryAfter: 1), .wait)
    }

    func test429TooManyUploadsAndTooManyObjectsDoNotClearByWaitingTheyAskTheUserToFreeSomething() {
        for code in ["too_many_uploads", "too_many_objects"] {
            XCTAssertEqual(disposition(429, code, .create, retryAfter: 30), .userRemedy(.quota), code)
        }
    }

    func test429PartBusyInFlightDownloadsAndCreateBusyAreRetriedAndBecomeRateLimitedOnlyAfterTheRetries() {
        XCTAssertEqual(disposition(429, "part_busy", put, retryAfter: 2), retryRate)
        XCTAssertEqual(disposition(429, "too_many_parts_in_flight", put, retryAfter: 1), retryRate)
        XCTAssertEqual(disposition(429, "too_many_downloads", .fetchRange, retryAfter: 5), retryRate)
        XCTAssertEqual(disposition(429, "create_busy", .create, retryAfter: 2), retryRate)
    }

    // MARK: 5xx

    func test500StorageErrorRetriesWithBackoff() {
        XCTAssertEqual(disposition(500, "storage_error"), retryNetwork)
    }

    func test503ServerSideCodesRetryWithBackoff() {
        for code in ["tokens_disabled", "groups_unavailable", "files_unavailable"] {
            XCTAssertEqual(disposition(503, code), retryNetwork, code)
        }
    }

    func test507ServerFullWithOrWithoutRetryAfter() {
        XCTAssertEqual(disposition(507, "insufficient_storage", .create), fail(.serverFull))
        XCTAssertEqual(disposition(507, "insufficient_storage", .create, retryAfter: 60), fail(.serverFull))
        XCTAssertEqual(disposition(507, "insufficient_storage", put), fail(.serverFull))
    }

    func testUnknown5xxRetriesUnknown4xxIsABadRequest() {
        XCTAssertEqual(disposition(502, "whatever"), retryNetwork)
        XCTAssertEqual(disposition(599, "whatever"), retryNetwork)
        XCTAssertEqual(disposition(418, "teapot"), fail(.badRequest))
        XCTAssertEqual(disposition(301, "moved"), fail(.badRequest))
        XCTAssertEqual(disposition(0, "zero"), fail(.badRequest))
    }

    // MARK: The whole table, for every operation

    /// Every (status, code) of the table in the protocol document, against every operation: none is unclassified, and the
    /// operation only ever changes what the table says it changes (404 and 403 `token_rejected`).
    func testEveryRowOfTheErrorTableHasADispositionForEveryOperation() {
        let table: [(Int, String)] = [
            (400, "bad_request"), (400, "bad_blob_len"), (400, "bad_part_size"), (400, "bad_head"), (400, "bad_part"),
            (400, "bad_length"), (400, "bad_token_request"), (400, "bad_token_headers"), (400, "digest_required"),
            (400, "digest_invalid"), (400, "digest_mismatch"), (400, "short_body"), (401, "unauthorized"),
            (402, "entitlement_required"), (403, "not_owner"), (403, "not_group_member"), (403, "token_required"),
            (403, "token_rejected"), (404, "not_found"), (405, "method_not_allowed"), (409, "part_conflict"),
            (409, "incomplete"), (409, "head_conflict"), (409, "too_many_group_scopes"), (411, "length_required"),
            (413, "blob_too_large"), (413, "quota_exceeded"), (416, "range_not_satisfiable"), (425, "parts_not_yet_received"),
            (429, "too_many_parts_in_flight"), (429, "too_many_downloads"), (429, "part_busy"), (429, "create_busy"),
            (429, "too_many_uploads"), (429, "too_many_objects"), (500, "storage_error"), (503, "tokens_disabled"),
            (503, "groups_unavailable"), (503, "files_unavailable"), (507, "insufficient_storage")
        ]
        XCTAssertEqual(table.count, 40)
        for (status, code) in table {
            var seen = Set<String>()
            for op in FileV2Op.allCases {
                seen.insert(String(describing: disposition(status, code, op)))
            }
            XCTAssertFalse(seen.isEmpty, "\(status) \(code)")
            if status != 404 && !(status == 403 && code == "token_rejected") {
                XCTAssertEqual(seen.count, 1, "\(status) \(code) must not depend on the operation, got \(seen)")
            }
        }
    }

    /// Every error the real server produced in the conformance transcript has a classification pinned here, so a code that
    /// a later revision of the server adds fails this test until a client decides what to do with it.
    func testEveryErrorOfTheTranscriptIsClassified() throws {
        let classified: [String: FileV2Disposition] = [
            "400 bad_request": fail(.badRequest), "400 bad_blob_len": fail(.badRequest), "400 bad_part_size": fail(.badRequest),
            "400 bad_head": fail(.badRequest), "400 bad_part": fail(.badRequest), "400 bad_length": fail(.badRequest),
            "400 bad_token_request": fail(.badRequest), "400 bad_token_headers": fail(.badRequest),
            "400 digest_required": fail(.badRequest), "400 digest_invalid": fail(.badRequest),
            "400 digest_mismatch": retryNetwork, "400 short_body": retryNetwork, "401 unauthorized": .refreshAuth,
            "402 entitlement_required": fail(.entitlement), "403 not_owner": fail(.auth),
            "403 not_group_member": fail(.auth), "403 token_required": fail(.auth), "403 token_rejected": fail(.auth),
            "404 not_found": .recreate, "405 method_not_allowed": fail(.badRequest), "409 part_conflict": fail(.sourceChanged),
            "409 incomplete": .sendMissing, "409 head_conflict": fail(.badRequest), "409 too_many_group_scopes": fail(.badRequest),
            "411 length_required": fail(.badRequest), "413 blob_too_large": fail(.quota), "413 quota_exceeded": fail(.quota),
            "416 range_not_satisfiable": fail(.badRequest), "425 parts_not_yet_received": .wait,
            "429 too_many_parts_in_flight": retryRate, "429 too_many_downloads": retryRate, "429 part_busy": retryRate,
            "429 create_busy": retryRate, "429 too_many_uploads": .userRemedy(.quota), "429 too_many_objects": .userRemedy(.quota),
            "500 storage_error": retryNetwork, "503 tokens_disabled": retryNetwork, "503 groups_unavailable": retryNetwork,
            "507 insufficient_storage": fail(.serverFull)
        ]
        let transcript = try XferTranscript.load()
        var seen = Set<String>()
        for scenario in transcript.scenarios {
            for step in scenario.steps {
                guard let status = step.expect?.member("status")?.intValue, status >= 400,
                      let code = step.expect?.member("code")?.stringValue else { continue }
                seen.insert("\(status) \(code)")
            }
        }
        XCTAssertGreaterThan(seen.count, 30)
        for key in seen.sorted() {
            guard let expected = classified[key] else {
                XCTFail("the transcript has an error that no client classification covers: \(key)")
                continue
            }
            let parts = key.split(separator: " ")
            XCTAssertEqual(disposition(Int(parts[0]) ?? 0, String(parts[1]), .putPart), expected, key)
        }
        // the transcript says which code of the table it cannot produce, and the table here has no other
        let notInTranscript = transcript.constants.member("error_codes_not_in_the_transcript")?.objectMembers?.map { $0.key } ?? []
        XCTAssertEqual(notInTranscript, ["files_unavailable"])
    }

    // MARK: Transport errors

    func testIOErrorsAreANetworkErrorToRetry() throws {
        XCTAssertEqual(try fileV2TransportDisposition(URLError(.timedOut), op: put), retryNetwork)
        XCTAssertEqual(try fileV2TransportDisposition(URLError(.networkConnectionLost), op: put), retryNetwork)
        XCTAssertEqual(try fileV2TransportDisposition(URLError(.notConnectedToInternet), op: .fetchRange), retryNetwork)
        XCTAssertEqual(try fileV2TransportDisposition(POSIXError(.ECONNRESET), op: put), retryNetwork)
        XCTAssertEqual(try fileV2TransportDisposition(NSError(domain: NSURLErrorDomain, code: -1005), op: put), retryNetwork)
        XCTAssertEqual(try fileV2TransportDisposition(NSError(domain: NSPOSIXErrorDomain, code: 54), op: put), retryNetwork)
    }

    func testAnythingElseIsAFinalNetworkFailure() throws {
        struct Strange: Error {}
        XCTAssertEqual(try fileV2TransportDisposition(Strange(), op: put), fail(.network))
        XCTAssertEqual(try fileV2TransportDisposition(FileV2Error.chunkAuth, op: put), fail(.network))
        XCTAssertEqual(try fileV2TransportDisposition(FileV2WireFormatError.malformedAnswer, op: put), fail(.network))
    }

    func testATypedServerErrorGoesThroughTheSameMappingAndKeepsTheOperation() throws {
        XCTAssertEqual(try fileV2TransportDisposition(FileV2ServerError(status: 425, code: "parts_not_yet_received", retryAfter: 1),
                                                      op: .fetchRange), .wait)
        XCTAssertEqual(try fileV2TransportDisposition(FileV2ServerError(status: 404, code: "not_found"), op: .delete), .done)
        XCTAssertEqual(try fileV2TransportDisposition(FileV2ServerError(status: 404, code: "not_found"), op: .putPart), .recreate)
    }

    func testCancellationIsNeverATransportFailureItIsRethrown() {
        XCTAssertThrowsError(try fileV2TransportDisposition(CancellationError(), op: put)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testAURLCancelledOfACancelledTaskIsRethrownAndOtherwiseRetried() async throws {
        // outside a cancelled task, "cancelled" is just a request that was cancelled for another reason: retry
        XCTAssertEqual(try fileV2TransportDisposition(URLError(.cancelled), op: put), retryNetwork)
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try fileV2TransportDisposition(URLError(.cancelled), op: .putPart)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let rethrown = await task.value
        XCTAssertTrue(rethrown)
    }

    // MARK: The taxonomy

    func testTransferErrorCodesAreSeparateFromTheFormatCodes() {
        let names = Set(FileV2TransferError.allCases.map { $0.rawValue })
        XCTAssertEqual(names, ["entitlement", "quota", "serverFull", "rateLimited", "network", "auth", "noSpace", "sourceChanged",
                               "badRequest", "announceNotSent", "descriptorTooLarge"])
        let codes = Set(FileV2TransferError.allCases.map { $0.code })
        XCTAssertEqual(codes.count, FileV2TransferError.allCases.count)
        XCTAssertEqual(codes, ["entitlement", "quota", "server_full", "rate_limited", "network", "auth", "no_space",
                               "source_changed", "bad_request", "announce_not_sent", "descriptor_too_large"])
        // none of them is a code of the file format (WIRE_SPEC 12.9, or the local ones of FileV2Error)
        let format: Set<String> = ["bad_descriptor", "bad_header", "commit_mismatch", "header_mismatch", "chunk_auth", "bad_padding",
                                   "size_mismatch", "cancelled", "unsupported_version", "closed", "invalid_argument"]
        XCTAssertTrue(codes.isDisjoint(with: format))
        XCTAssertTrue(codes.isDisjoint(with: [FileV2Error.chunkAuth.code, FileV2Error.cancelled.code, FileV2Error.closed.code]))
    }

    // MARK: The error value

    func testTheErrorCarriesStatusCodeRetryAfterMissingAndDetailsAndNothingElseInItsMessage() {
        let plain = FileV2ServerError(status: 429, code: "part_busy", retryAfter: 2)
        XCTAssertEqual(plain.status, 429)
        XCTAssertEqual(plain.code, "part_busy")
        XCTAssertEqual(plain.retryAfter, 2)
        XCTAssertEqual(plain.description, "429 part_busy")
        XCTAssertEqual(plain.localizedDescription, "429 part_busy")
        XCTAssertEqual(plain.details, FileV2ErrorDetails.none)
        XCTAssertTrue(plain.missing.isEmpty)

        let incomplete = FileV2ServerError(status: 409, code: "incomplete", missing: [3, 4], details: FileV2ErrorDetails(parts: 12))
        XCTAssertEqual(incomplete.missing, [3, 4])
        XCTAssertEqual(incomplete.details.parts, 12)

        let quota = FileV2ServerError(status: 413, code: "quota_exceeded", details: FileV2ErrorDetails(used: 5, limit: 9))
        XCTAssertEqual(quota.details.used, 5)
        XCTAssertEqual(quota.details.limit, 9)
        XCTAssertEqual(quota.disposition(for: .create), .fail(.quota), "the numbers for the UI stay on the error")

        let big = FileV2ServerError(status: 413, code: "blob_too_large", details: FileV2ErrorDetails(maxBlobLength: 5_368_791_104))
        XCTAssertEqual(big.details.maxBlobLength, 5_368_791_104)

        let entitlement = FileV2ServerError(status: 402, code: "entitlement_required",
                                            details: FileV2ErrorDetails(feature: "feat.files", packageName: "pro"))
        XCTAssertEqual(entitlement.details.feature, "feat.files")
        XCTAssertEqual(entitlement.details.packageName, "pro")
    }

    func testACodeThatIsNotALowercaseAsciiTokenNeverReachesALog() {
        for hostile in ["", "Bad", "has space", "scheme:/path", "k\u{212A}", "a\nb", String(repeating: "a", count: 65), "é"] {
            let error = FileV2ServerError(status: 500, code: hostile)
            XCTAssertEqual(error.code, "invalid_code", hostile)
            XCTAssertEqual(error.description, "500 invalid_code")
        }
        XCTAssertEqual(FileV2ServerError(status: 400, code: String(repeating: "a", count: 64)).code.count, 64)
        XCTAssertEqual(FileV2ServerError(status: 400, code: "a_1").code, "a_1")
        // an invalid code is classified by its status alone
        XCTAssertEqual(FileV2ServerError(status: 429, code: "Too Many Uploads").disposition(for: .create), .retry(onExhausted: .rateLimited))
    }
}
