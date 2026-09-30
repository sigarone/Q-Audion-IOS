import Foundation
@testable import QAudionEngine

/// Shared fixtures of the group-calls-v2 tests. Every value is synthetic
/// (`example.invalid`, repeated hex): the iOS repo is public, so no real host,
/// address or id appears anywhere in these tests.
enum GroupCallFixtures {

    static let pseudoA = String(repeating: "a1", count: 16)
    static let pseudoB = String(repeating: "b2", count: 16)
    static let pseudoC = String(repeating: "c3", count: 16)
    static let room = String(repeating: "0f", count: 16)
    static let joinToken = String(repeating: "9e", count: 16)

    /// "sha-256 AA:BB:.." with `pair` repeated 32 times.
    static func fingerprint(_ pair: String = "AB") -> String {
        "sha-256 " + Array(repeating: pair, count: 32).joined(separator: ":")
    }

    static func readyDictionary(
        wsUrl: String = "wss://media.example.invalid/janus",
        pseudonym: String = pseudoA,
        fingerprint fp: String = fingerprint()
    ) -> [String: Any] {
        [
            "call_id": "11111111-2222-3333-4444-555555555555",
            "node_id": "node-a",
            "ws_url": wsUrl,
            "room": room,
            "pseudonym": pseudonym,
            "session_token": "1893456000,janus,janus.plugin.videoroom:c2lnbmF0dXJl",
            "join_token": joinToken,
            "dtls_fingerprint": fp,
            "ice_servers": [
                ["urls": ["turns:turn.example.invalid:5349?transport=tcp", "turn:turn.example.invalid:3478?transport=udp"],
                 "username": "user", "credential": "secret"],
            ],
            "ttl_s": 21600,
        ]
    }

    static func keyBytes(_ fill: UInt8) -> Data { Data(repeating: fill, count: 32) }
}
