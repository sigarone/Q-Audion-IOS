import Foundation

/// The `Retry-After` header (RFC 9110 section 10.2.3): delta-seconds, or an HTTP date. The result is a whole number of
/// seconds, never negative and never above `maxSeconds` (300): a server, a proxy or a broken clock that asks for an
/// hour parks a transfer for five minutes at most, and then the transfer asks again.
///
/// Pure: no clock of its own (`nowMs` is passed), no `DateFormatter` (it depends on the locale and on the calendar of the
/// device), no `String` comparison (the value is read as ASCII bytes).
public enum FileV2RetryAfter {

    public static let maxSeconds: Int = FileV2Wire.maxRetryAfterSeconds

    /// The seconds to wait, in `0...maxSeconds`, or `nil` when `header` is neither delta-seconds nor an HTTP date.
    ///
    /// - delta-seconds: only ASCII digits (no sign, no fraction, no exponent); a value too large for an integer is the cap.
    /// - an HTTP date, in any of the three forms a recipient must accept: `Sun, 06 Nov 1994 08:49:37 GMT`,
    ///   `Sunday, 06-Nov-94 08:49:37 GMT` (two-digit year: a date more than 50 years ahead is read as the past century)
    ///   and `Sun Nov  6 08:49:37 1994`. A date in the past is 0; a date in the future is the remaining time rounded up.
    public static func seconds(from header: String, nowMs: Int64) -> Int? {
        let all = Array(header.utf8)
        var start = 0
        var end = all.count
        while start < end, isOWS(all[start]) { start += 1 }
        while end > start, isOWS(all[end - 1]) { end -= 1 }
        guard start < end else { return nil }
        let value = Array(all[start..<end])

        if value.allSatisfy(isDigit) {
            return deltaSeconds(value)
        }
        guard let epoch = httpDateEpochSeconds(value, nowMs: nowMs) else { return nil }
        let (scaled, overflow) = epoch.multipliedReportingOverflow(by: 1000)
        guard !overflow else { return epoch > 0 ? maxSeconds : 0 }
        let remaining = scaled.subtractingReportingOverflow(nowMs)
        if remaining.overflow { return scaled > nowMs ? maxSeconds : 0 }
        if remaining.partialValue <= 0 { return 0 }
        let whole = remaining.partialValue / 1000 + (remaining.partialValue % 1000 == 0 ? 0 : 1)
        return whole > Int64(maxSeconds) ? maxSeconds : Int(whole)
    }

    // MARK: delta-seconds

    private static func deltaSeconds(_ digits: [UInt8]) -> Int {
        var value = 0
        for digit in digits {
            let (times, overflow) = value.multipliedReportingOverflow(by: 10)
            let (plus, overflow2) = times.addingReportingOverflow(Int(digit - 0x30))
            if overflow || overflow2 || plus > maxSeconds { return maxSeconds }
            value = plus
        }
        return value
    }

    // MARK: HTTP dates

    private static let shortDays: [[UInt8]] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map { Array($0.utf8) }
    private static let longDays: [[UInt8]] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        .map { Array($0.utf8) }
    private static let months: [[UInt8]] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .map { Array($0.utf8) }

    /// Seconds since 1970-01-01T00:00:00Z of an HTTP date, or `nil`.
    static func httpDateEpochSeconds(_ value: [UInt8], nowMs: Int64) -> Int64? {
        var cursor = ByteCursor(value)
        let dayName = cursor.letters()
        guard !dayName.isEmpty else { return nil }

        // asctime: `Sun Nov  6 08:49:37 1994`
        if cursor.peek() == 0x20 {
            guard shortDays.contains(dayName), cursor.take(0x20) else { return nil }
            guard let month = cursor.monthIndex(), cursor.take(0x20) else { return nil }
            let day: Int
            if cursor.take(0x20) {
                guard let single = cursor.number(digits: 1) else { return nil }
                day = single
            } else {
                guard let double = cursor.number(digits: 2) else { return nil }
                day = double
            }
            guard cursor.take(0x20), let time = cursor.timeOfDay(), cursor.take(0x20),
                  let year = cursor.number(digits: 4), cursor.atEnd else { return nil }
            return epoch(year: year, month: month, day: day, time: time)
        }

        // IMF-fixdate `Sun, 06 Nov 1994 08:49:37 GMT` or rfc850 `Sunday, 06-Nov-94 08:49:37 GMT`
        guard cursor.take(0x2C), cursor.take(0x20), let day = cursor.number(digits: 2) else { return nil }
        if cursor.take(0x20) {
            guard shortDays.contains(dayName), let month = cursor.monthIndex(), cursor.take(0x20),
                  let year = cursor.number(digits: 4), cursor.take(0x20), let time = cursor.timeOfDay(),
                  cursor.take(0x20), cursor.literal("GMT"), cursor.atEnd else { return nil }
            return epoch(year: year, month: month, day: day, time: time)
        }
        guard longDays.contains(dayName), cursor.take(0x2D), let month = cursor.monthIndex(), cursor.take(0x2D),
              let twoDigitYear = cursor.number(digits: 2), cursor.take(0x20), let time = cursor.timeOfDay(),
              cursor.take(0x20), cursor.literal("GMT"), cursor.atEnd else { return nil }
        let currentYear = civilYear(ofEpochSeconds: floorDiv(nowMs, 1000))
        var year = (currentYear / 100) * 100 + twoDigitYear
        if year > currentYear + 50 { year -= 100 }
        return epoch(year: year, month: month, day: day, time: time)
    }

    private static func epoch(year: Int, month: Int, day: Int, time: (hour: Int, minute: Int, second: Int)) -> Int64? {
        guard month >= 1, month <= 12, day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return days * 86_400 + Int64(time.hour * 3600 + time.minute * 60 + time.second)
    }

    private static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthShifted = Int64(month > 2 ? month - 3 : month + 9)
        let dayOfYear = (153 * monthShifted + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilYear(ofEpochSeconds seconds: Int64) -> Int {
        let z = floorDiv(seconds, 86_400) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthShifted = (5 * dayOfYear + 2) / 153
        let month = monthShifted < 10 ? monthShifted + 3 : monthShifted - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return Int(year)
    }

    private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    private static func isOWS(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// A cursor over ASCII bytes.
    private struct ByteCursor {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { position == bytes.count }

        func peek() -> UInt8? { position < bytes.count ? bytes[position] : nil }

        mutating func take(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            position += 1
            return true
        }

        mutating func literal(_ text: String) -> Bool {
            let wanted = Array(text.utf8)
            guard position + wanted.count <= bytes.count, Array(bytes[position..<position + wanted.count]) == wanted else {
                return false
            }
            position += wanted.count
            return true
        }

        mutating func letters() -> [UInt8] {
            let start = position
            while let byte = peek(), (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) { position += 1 }
            return Array(bytes[start..<position])
        }

        /// Exactly `digits` ASCII digits.
        mutating func number(digits: Int) -> Int? {
            guard position + digits <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<digits {
                let byte = bytes[position + offset]
                guard byte >= 0x30 && byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            position += digits
            return value
        }

        /// A three-letter month name: 1 for `Jan` ... 12 for `Dec`.
        mutating func monthIndex() -> Int? {
            guard position + 3 <= bytes.count else { return nil }
            let name = Array(bytes[position..<position + 3])
            guard let index = FileV2RetryAfter.months.firstIndex(of: name) else { return nil }
            position += 3
            return index + 1
        }

        /// `HH:MM:SS`, seconds up to 60 (a leap second).
        mutating func timeOfDay() -> (hour: Int, minute: Int, second: Int)? {
            guard let hour = number(digits: 2), take(0x3A), let minute = number(digits: 2), take(0x3A),
                  let second = number(digits: 2), hour <= 23, minute <= 59, second <= 60 else { return nil }
            return (hour, minute, second)
        }
    }
}
