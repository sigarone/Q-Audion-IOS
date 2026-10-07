import Foundation
@testable import QAudionEngine

// Download: handler.go routing aside, download.go (check order, Range, Prefer: wait, streaming delivery) and the
// authorisation of a non-owner with a download token.

extension FakeFileV2Core {

    struct ByteRange {
        let start: Int64
        let length: Int64
        /// A `Range` header was given and honoured.
        let partial: Bool
    }

    enum PartsState {
        case ready
        case gone
        case notYet
    }

    // MARK: Parsing (download.go parseRange, preferWait; strconv)

    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        func space(_ byte: UInt8) -> Bool { byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) }
        var start = 0
        var end = bytes.count
        while start < end, space(bytes[start]) { start += 1 }
        while end > start, space(bytes[end - 1]) { end -= 1 }
        return Array(bytes[start..<end])
    }

    /// `strconv.ParseUint(s, 10, 63)`: digits only, at least one, at most 2^63 - 1.
    private static func parseUnsigned63(_ digits: [UInt8]) -> Int64? {
        guard !digits.isEmpty else { return nil }
        var value: Int64 = 0
        for digit in digits {
            guard digit >= 0x30 && digit <= 0x39 else { return nil }
            let (times, overflow) = value.multipliedReportingOverflow(by: 10)
            let (plus, overflow2) = times.addingReportingOverflow(Int64(digit - 0x30))
            if overflow || overflow2 { return nil }
            value = plus
        }
        return value
    }

    /// One range, `bytes=a-b`, `bytes=a-` or `bytes=-n`; anything else, a list of ranges included, is unsatisfiable.
    static func parseRange(_ header: String, size: Int64) -> ByteRange? {
        if header.isEmpty { return ByteRange(start: 0, length: size, partial: false) }
        let bytes = Array(header.utf8)
        let prefix = Array("bytes=".utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let spec = Array(bytes[prefix.count...])
        if spec.contains(0x2C) { return nil }
        let text = trimmed(spec)
        guard let dash = text.firstIndex(of: 0x2D) else { return nil }
        let first = Array(text[..<dash])
        let second = Array(text[(dash + 1)...])
        if first.isEmpty {
            guard var count = parseUnsigned63(second), count != 0 else { return nil }
            if count > size { count = size }
            return ByteRange(start: size - count, length: count, partial: true)
        }
        guard let start = parseUnsigned63(first), start < size else { return nil }
        var end = size - 1
        if !second.isEmpty {
            guard let last = parseUnsigned63(second), last >= start else { return nil }
            if last < end { end = last }
        }
        return ByteRange(start: start, length: end - start + 1, partial: true)
    }

    /// The payload parts that cover bytes `start`...`end`; `nil` when the range lies inside the header, which is always there.
    static func partSpan(start: Int64, end: Int64) -> (first: Int, last: Int)? {
        let header = Int64(FileV2.headerLength)
        if end < header { return nil }
        let from = max(start, header)
        return (Int((from - header) / Int64(FileV2Wire.partSize)), Int((end - header) / Int64(FileV2Wire.partSize)))
    }

    /// `strconv.Atoi`: an optional sign and at least one digit, within 64 bits; `nil` otherwise.
    static func goAtoi(_ bytes: [UInt8]) -> Int64? {
        var digits = bytes
        var negative = false
        if let first = digits.first, first == 0x2B || first == 0x2D {
            negative = first == 0x2D
            digits.removeFirst()
        }
        guard !digits.isEmpty else { return nil }
        var value: Int64 = 0
        for digit in digits {
            guard digit >= 0x30 && digit <= 0x39 else { return nil }
            let (times, overflow) = value.multipliedReportingOverflow(by: 10)
            let (plus, overflow2) = negative ? times.subtractingReportingOverflow(Int64(digit - 0x30))
                : times.addingReportingOverflow(Int64(digit - 0x30))
            if overflow || overflow2 { return nil }
            value = plus
        }
        return value
    }

    /// `strconv.ParseInt(s, 10, bits)` with the error ignored, as the server does: a syntax error is 0, a value out of range is
    /// the largest (or smallest) value of that size.
    static func goParseInt(_ text: String, bits: Int) -> Int64 {
        let limitHigh: Int64 = bits == 32 ? Int64(Int32.max) : Int64.max
        let limitLow: Int64 = bits == 32 ? Int64(Int32.min) : Int64.min
        var digits = Array(text.utf8)
        var negative = false
        if let first = digits.first, first == 0x2B || first == 0x2D {
            negative = first == 0x2D
            digits.removeFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return 0 }
        var value: Int64 = 0
        for digit in digits {
            let (times, overflow) = value.multipliedReportingOverflow(by: 10)
            let (plus, overflow2) = times.addingReportingOverflow(Int64(digit - 0x30))
            if overflow || overflow2 { return negative ? limitLow : limitHigh }
            value = plus
        }
        if negative { value = -value }
        return min(max(value, limitLow), limitHigh)
    }

    /// The wait preference (RFC 7240) of the `Prefer` headers, in milliseconds, capped at `limitMs`; 0 for none.
    static func preferWait(_ values: [String], limitMs: Int64) -> Int64 {
        for value in values {
            for token in Array(value.utf8).split(separator: 0x2C, omittingEmptySubsequences: false) {
                let member = trimmed(Array(token))
                guard let equals = member.firstIndex(of: 0x3D) else { continue }
                let key = trimmed(Array(member[..<equals]))
                guard asciiFold(String(decoding: key, as: UTF8.self)) == Array("wait".utf8) else { continue }
                var number = trimmed(Array(member[(equals + 1)...]))
                while number.first == 0x22 { number.removeFirst() }
                while number.last == 0x22 { number.removeLast() }
                guard let seconds = goAtoi(number), seconds > 0 else { continue }
                let (millis, overflow) = seconds.multipliedReportingOverflow(by: 1000)
                return overflow ? limitMs : min(millis, limitMs)
            }
        }
        return 0
    }

    // MARK: Download

    func handleDownload(_ request: FakeWireRequest, user: XferName, obj: String, async: Bool) -> FakeOutcome {
        guard let object = objects[obj] else { return .response(notFound()) }
        // authorised first: a caller who may not read the object is told nothing else about it, not even its size
        var grant: TokenGrant?
        if object.owner != user {
            switch authorizeDownload(request, object: object, user: user) {
            case .success(let granted): grant = granted
            case .failure(let refusal): return .response(refusal.response)
            }
        }
        guard let range = FakeFileV2Core.parseRange(request.headers.first("Range") ?? "", size: object.blobLength) else {
            return .response(failure(416, "range_not_satisfiable", headers: [("Content-Range", "bytes */\(object.blobLength)")]))
        }
        // the slot is taken BEFORE the token is charged: a request refused here must not have spent budget
        if (downloadsInFlight[user] ?? 0) >= config.maxDownloadsPerUser {
            return .response(failure(429, "too_many_downloads", "too many concurrent downloads",
                                     headers: [("Retry-After", "5")]))
        }
        downloadsInFlight[user, default: 0] += 1

        var carried = FakeHeaders()
        var first = 0
        var last = 0
        var waitMs: Int64 = 0
        if object.completedMs == 0, let span = FakeFileV2Core.partSpan(start: range.start, end: range.start + range.length - 1) {
            first = span.first
            last = span.last
            waitMs = FakeFileV2Core.preferWait(request.headers.values("Prefer"), limitMs: config.streamWaitMaxMs)
            if waitMs > 0 { carried.set("Preference-Applied", "wait=\(waitMs / 1000)") }
            switch partsState(obj: obj, first: first, last: last) {
            case .gone:
                downloadsInFlight[user, default: 1] -= 1
                return .response(failure(404, "not_found", headers: carried))
            case .notYet:
                if waitMs > 0 && async {
                    let id = newID()
                    let state = DownloadState(user: user, obj: obj, start: range.start, length: range.length,
                                              partial: range.partial, grant: grant, first: first, last: last,
                                              waitMs: waitMs, headers: carried)
                    pending[id] = Pending(id: id, kind: .waitingDownload(state))
                    return .pending(id)
                }
                if waitMs > 0 { advanceTimer(ms: waitMs) }
                downloadsInFlight[user, default: 1] -= 1
                return .response(notYetReceived(first: first, last: last, carried: carried))
            case .ready:
                break
            }
        }
        let response = serveDownload(object, start: range.start, length: range.length, partial: range.partial, grant: grant,
                                     carried: carried)
        downloadsInFlight[user, default: 1] -= 1
        return .response(response)
    }

    func notYetReceived(first: Int, last: Int, carried: FakeHeaders) -> FakeWireResponse {
        var response = failure(425, "parts_not_yet_received", "the requested range has not been uploaded yet",
                               extra: [("first_part", .int(Int64(first))), ("last_part", .int(Int64(last)))],
                               headers: [("Retry-After", "1")])
        for pair in carried.pairs { response.headers.set(pair.name, pair.value) }
        return response
    }

    func partsState(obj: String, first: Int, last: Int) -> PartsState {
        guard let object = objects[obj] else { return .gone }
        if object.completedMs != 0 { return .ready }
        for part in first...max(first, last) where object.digests[part] == nil { return .notYet }
        return .ready
    }

    /// Charges the token, then serves the bytes.
    func serveDownload(_ object: Object, start: Int64, length: Int64, partial: Bool, grant: TokenGrant?,
                       carried: FakeHeaders) -> FakeWireResponse {
        if let grant = grant, !chargeToken(grant, blobLength: object.blobLength, served: length, isStart: start == 0) {
            var response = failure(403, "token_rejected", "download token rejected")
            for pair in carried.pairs { response.headers.set(pair.name, pair.value) }
            return response
        }
        var response = FakeWireResponse(status: partial ? 206 : 200)
        response.headers.set("Cache-Control", "no-store")
        response.headers.set("Content-Type", "application/octet-stream")
        response.headers.set("Accept-Ranges", "bytes")
        response.headers.set("Content-Length", String(length))
        if partial {
            response.headers.set("Content-Range", "bytes \(start)-\(start + length - 1)/\(object.blobLength)")
        }
        for pair in carried.pairs { response.headers.set(pair.name, pair.value) }
        response.body = readBytes(object, start: start, length: length)
        return response
    }

    /// The bytes of the blob: the header, then the parts that are on the server (a part that is not is read as zeros, which
    /// the checks before it make unreachable).
    func readBytes(_ object: Object, start: Int64, length: Int64) -> Data {
        var out = Data()
        var position = start
        let end = start + length
        let header = Int64(FileV2.headerLength)
        while position < end {
            if position < header {
                let upTo = min(end, header)
                out.append(object.head[Int(position)..<Int(upTo)])
                position = upTo
                continue
            }
            let part = Int((position - header) / Int64(FileV2Wire.partSize))
            let partStart = header + Int64(part) * Int64(FileV2Wire.partSize)
            let partEnd = min(end, partStart + Int64(FileV2Wire.partLength(blobLength: object.blobLength, part: part)))
            let count = Int(partEnd - position)
            if let data = object.data[part] {
                let from = data.startIndex + Int(position - partStart)
                out.append(data[from..<from + count])
            } else {
                out.append(Data(count: count))
            }
            position = partEnd
        }
        return out
    }

    /// The checks of a non-owner (handler authorizeDownload): the server has a secret; a token is sent with its two claims;
    /// the token is valid for this account. The same refusal for a wrong token, an expired one, a wrong account and a
    /// non-member: there is no oracle.
    func authorizeDownload(_ request: FakeWireRequest, object: Object, user: XferName) -> Result<TokenGrant, FakeWireResponseError> {
        guard config.hasTokenSecret else {
            return .failure(FakeWireResponseError(failure(403, "not_owner", "only the owner can download from this server")))
        }
        let tokenText = request.headers.first("X-Download-Token") ?? ""
        if tokenText.isEmpty {
            return .failure(FakeWireResponseError(failure(403, "token_required", "a download token is required")))
        }
        let exp = FakeFileV2Core.goParseInt(request.headers.first("X-Download-Expires-Ms") ?? "", bits: 64)
        let maxUses = FakeFileV2Core.goParseInt(request.headers.first("X-Download-Max-Uses") ?? "", bits: 32)
        if exp <= 0 || maxUses <= 0 {
            return .failure(FakeWireResponseError(failure(400, "bad_token_headers",
                                                          "X-Download-Expires-Ms and X-Download-Max-Uses are required")))
        }
        switch authorizeToken(object: object, presenter: user, tokenHex: tokenText, expMs: exp, maxUses: maxUses) {
        case .success(let grant): return .success(grant)
        case .failure(.storage): return .failure(FakeWireResponseError(storageError()))
        case .failure(.invalid):
            return .failure(FakeWireResponseError(failure(403, "token_rejected", "download token rejected")))
        }
    }

    // MARK: Waiting downloads

    /// Answers the waiting downloads whose parts have arrived (or whose object has gone).
    func pumpDownloads() {
        for id in pending.keys.sorted() {
            guard let record = pending[id], record.response == nil, case .waitingDownload(let state) = record.kind else { continue }
            switch partsState(obj: state.obj, first: state.first, last: state.last) {
            case .gone:
                downloadsInFlight[state.user, default: 1] -= 1
                record.response = failure(404, "not_found", headers: state.headers)
            case .ready:
                guard let object = objects[state.obj] else { continue }
                downloadsInFlight[state.user, default: 1] -= 1
                record.response = serveDownload(object, start: state.start, length: state.length, partial: state.partial,
                                                grant: state.grant, carried: state.headers)
            case .notYet:
                continue
            }
        }
    }
}

/// A refusal carried as an `Error`, so that a check can return `Result`.
struct FakeWireResponseError: Error {
    let response: FakeWireResponse

    init(_ response: FakeWireResponse) { self.response = response }
}
