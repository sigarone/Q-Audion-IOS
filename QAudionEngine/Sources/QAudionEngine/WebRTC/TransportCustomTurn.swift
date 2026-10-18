import Foundation

/// The TURN server a user types in Settings > Trasporto, split into what libwebrtc needs: the address, a user name and a
/// password.
///
/// The screen has three fields: the address, the user name and the password (a secure field). The address field holds
/// the server alone, the credentials never go into it:
///
///     turn:hostname:3478                         the address field
///
/// `make(address:username:password:)` builds the server from the three fields. The same server is also written as one
/// text, `turn:user:password@hostname:3478`, which is the form `parse(_:)` reads and the form the calls pass around in
/// memory (`TransportChoice.customTurnUrl`, `QAudionWebRtcCallController.customTurnUrl`); it is never stored in one piece
/// (`TransportPreferences` keeps the address in `UserDefaults` and the credentials in the Keychain).
///
/// `turns:` instead of `turn:` and a `?transport=udp` / `?transport=tcp` tail work in both shapes. The host is a name
/// (letters, digits, dot, dash, underscore) or an IPv4 address, the port is optional and between 1 and 65535.
///
/// libwebrtc rejects the WHOLE configuration (no PeerConnection, so no call) when a TURN server has an empty user name or
/// password, and it does not read `user:password@` inside the URL. So a server typed without credentials is never handed
/// to libwebrtc: the screen refuses to save it and the transport check refuses to run with it. The server typed by the
/// user also never receives the temporary TURN credentials the BCrypto server gives the app (those belong to the BCrypto
/// pool and to the WSS bridge): it gets the user name and password the user wrote, and nothing else.
///
/// In the one-text form, user name and password stand between `turn:` and the last `@`, joined by a single `:`. A
/// character that would end or split the address (`@`, `:`, `?`, `/`, `%`, space, ...) is written as `%` and two
/// hexadecimal digits, `@` as `%40` for example; the value used for the TURN server is the decoded one. Letters, digits and
/// `- . _ ~ ! $ & ' ( ) * + , ; =` are written as they are. `make(address:username:password:)` does that writing itself:
/// the fields take the user name and the password as plain text.
///
/// The password is never in `description`: a print or an assertion message shows `TransportCustomTurn(credentials
/// hidden)`.
public struct TransportCustomTurn: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {

    /// What a typed address is.
    public enum Parsed: Equatable, Sendable {
        /// A usable address: host, port and both credentials.
        case server(TransportCustomTurn)
        /// A well formed `turn:`/`turns:` address with no user name or no password (for example `turn:hostname:3478`).
        case missingCredentials
        /// Anything else: not `turn:`/`turns:`, a bad host or port, a credential that cannot be read.
        case malformed

        /// The server, when the address is usable.
        public var server: TransportCustomTurn? {
            if case .server(let server) = self { return server }
            return nil
        }
    }

    /// A well formed `turn:`/`turns:` address, read without looking at the credentials.
    public struct Address: Equatable, Sendable {
        /// `turn:host:port` with the optional `?query`, no credentials in it: the URL libwebrtc gets, and the text the
        /// storage keeps in `UserDefaults`.
        public let url: String
        /// The host, lower case: the name the credentials are kept under in the Keychain.
        public let host: String
        /// The text has an `@`: a user name, a password or part of them is written inside the address.
        public let hasCredentialsInside: Bool
    }

    /// The address libwebrtc gets as the server URL: `turn:host:port` with the optional `?query`, no credentials in it.
    public let iceUrl: String
    /// The user name, decoded.
    public let username: String
    /// The password, decoded.
    public let credential: String
    /// The address as one text: the trimmed text with a lower case scheme, credentials in it. It holds the password, so it
    /// is only ever kept in memory (the storage keeps `iceUrl` and the credentials apart).
    public let storedText: String
    /// The host, lower case. The Keychain item of this server has it as its account.
    public let host: String

    public var description: String { "TransportCustomTurn(credentials hidden)" }
    public var debugDescription: String { description }

    /// The one-text form as a URL (what the calls pass around in memory). It holds the password.
    public var storedURL: URL? { URL(string: storedText) }

    /// The same address without user name and password, for the copies that do not need them.
    public var urlWithoutCredentials: URL? { URL(string: iceUrl) }

    /// Longest address text accepted, credentials included.
    public static let maxLength = 512

    private static let hostScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    private static let credentialScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=%")

    // MARK: - Parsing

    /// An address text cut into the pieces both readers need.
    fileprivate struct AddressParts {
        /// `turn:` or `turns:`, lower case.
        let scheme: String
        /// Everything after the scheme, as typed.
        let rest: String
        let hostPort: String
        /// The host, lower case.
        let host: String
        let query: String
        /// The text before the last `@`; `nil` when there is no `@`.
        let credentialText: String?

        var iceUrl: String { scheme + hostPort + (query.isEmpty ? "" : "?" + query) }
    }

    /// The scheme, the host and the port, the query and the text before `@`, or `nil` when the text is not a well formed
    /// `turn:`/`turns:` address (credentials are not looked at here).
    private static func splitAddress(_ raw: String) -> AddressParts? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let lower = trimmed.lowercased()
        let scheme: String
        if lower.hasPrefix("turns:") {
            scheme = "turns:"
        } else if lower.hasPrefix("turn:") {
            scheme = "turn:"
        } else {
            return nil
        }
        let rest = String(trimmed.dropFirst(scheme.count))
        let queryParts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let authority: String = queryParts.isEmpty ? "" : String(queryParts[0])
        let query: String = queryParts.count > 1 ? String(queryParts[1]) : ""

        let authorityParts = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard authorityParts.count == 1 || authorityParts.count == 2 else { return nil }
        let hostPort = String(authorityParts[authorityParts.count - 1])
        guard isValidHostAndPort(hostPort) else { return nil }
        let host: String = hostPort.split(separator: ":", omittingEmptySubsequences: false).first
            .map { String($0).lowercased() } ?? ""
        return AddressParts(scheme: scheme, rest: rest, hostPort: hostPort, host: host, query: query,
                            credentialText: authorityParts.count == 2 ? String(authorityParts[0]) : nil)
    }

    /// Reads `turn:user:password@host:port` (credentials percent-encoded).
    public static func parse(_ raw: String) -> Parsed {
        guard let parts = splitAddress(raw) else { return .malformed }
        guard let credentialText = parts.credentialText else { return .missingCredentials }

        let credentialParts = credentialText.split(separator: ":", omittingEmptySubsequences: false)
        guard credentialParts.count <= 2 else { return .malformed }
        guard credentialParts.count == 2, !credentialParts[0].isEmpty, !credentialParts[1].isEmpty else {
            return .missingCredentials
        }
        guard let username = decodedCredential(String(credentialParts[0])),
              let credential = decodedCredential(String(credentialParts[1])) else { return .malformed }

        var storedText = parts.scheme + parts.rest
        if storedText.hasSuffix("?") { storedText.removeLast() }
        let iceUrl = parts.iceUrl
        guard URL(string: storedText) != nil, URL(string: iceUrl) != nil else { return .malformed }
        return .server(TransportCustomTurn(iceUrl: iceUrl, username: username, credential: credential,
                                           storedText: storedText, host: parts.host))
    }

    /// Reads a TURN address on its own: `turn:host:port`, whether or not credentials are written inside it. `nil` when the
    /// text is not a well formed `turn:`/`turns:` address.
    public static func parseAddress(_ raw: String) -> Address? {
        guard let parts = splitAddress(raw), URL(string: parts.iceUrl) != nil else { return nil }
        return Address(url: parts.iceUrl, host: parts.host, hasCredentialsInside: parts.credentialText != nil)
    }

    /// The server of the three fields of Settings: the address (`turn:host:port`, with nothing before the host), the user
    /// name and the password as plain text, no URL encoding. `nil` when the address is not a well formed TURN address,
    /// when credentials are already written inside it, or when the user name or the password is empty or has a control
    /// character. The rules are the ones of `parse(_:)`: the three fields are written as the one-text form and read by it.
    public static func make(address: String, username: String, password: String) -> TransportCustomTurn? {
        guard let parts = splitAddress(address), parts.credentialText == nil else { return nil }
        let text = parts.scheme + encodedCredential(username) + ":" + encodedCredential(password) + "@" + parts.rest
        return parse(text).server
    }

    private init(iceUrl: String, username: String, credential: String, storedText: String, host: String) {
        self.iceUrl = iceUrl
        self.username = username
        self.credential = credential
        self.storedText = storedText
        self.host = host
    }

    /// `host` or `host:port`, with the rules the address always had: no leading dot or dash, 253 characters at most, a
    /// port made of digits between 1 and 65535.
    private static func isValidHostAndPort(_ hostPort: String) -> Bool {
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        let host = String(parts[0])
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasPrefix("-") else { return false }
        guard host.unicodeScalars.allSatisfy({ hostScalars.contains($0) }) else { return false }
        if parts.count == 2 {
            let portText = String(parts[1])
            guard !portText.isEmpty, portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let port = Int(portText), port >= 1, port <= 65535 else { return false }
        }
        return true
    }

    /// A user name or a password as written in the address: only the characters listed above, `%xx` read as the byte it
    /// stands for, the result not empty and free of control characters. `nil` when it cannot be read.
    private static func decodedCredential(_ raw: String) -> String? {
        guard raw.unicodeScalars.allSatisfy({ credentialScalars.contains($0) }) else { return nil }
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty else { return nil }
        guard decoded.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return decoded
    }

    /// The inverse of `decodedCredential`: every byte that is not a letter, a digit or one of `- . _ ~ ! $ & ' ( ) * + , ; =`
    /// is written as `%` and two hexadecimal digits (the `%` itself too), so what is read back is the text as typed.
    private static func encodedCredential(_ value: String) -> String {
        let percent = UInt8(ascii: "%")
        var out = ""
        for byte in value.utf8 {
            let scalar = Unicode.Scalar(byte)
            if byte != percent && credentialScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
