import Foundation
import CryptoKit

/// Decides when the store key is read or created, so that a key is never replaced while stored data may still need it.
///
/// - A key that exists is used. Nothing else is asked and nothing is deleted.
/// - No key and no data: a key is created at once.
/// - No key and data exists: the lookup is repeated after each pause of `backoffMs` before a new key is created, because a
///   read can come back empty for a moment while the system is busy. A key that is still missing after the last look is
///   created (the old records are then unreadable), and `log` gets one fixed line without any id.
///
/// Any error of the key lookup, and any error of the question "does data exist" (a directory that cannot be listed), is thrown
/// and never read as "missing" or "no data": nothing is created and nothing is deleted because of it.
///
/// Whether a key is a leftover of a deleted installation is not decided here: the store decides that once, when it creates
/// `meta.bin` (`VoiceTemplateStore`).
struct VoiceKeyGuard {
    static let logRecreated = "voice store key missing with data present, created again"

    let existing: () throws -> SymmetricKey?
    let create: () throws -> SymmetricKey
    let dataExists: () throws -> Bool
    var log: (String) -> Void = { _ in }
    var backoffMs: [Int] = [50, 150, 400]
    var sleep: (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000.0) }

    func get() throws -> SymmetricKey {
        if let key = try existing() { return key }
        if try dataExists() {
            for pause in backoffMs {
                sleep(pause)
                if let key = try existing() { return key }
            }
            log(Self.logRecreated)
        }
        return try create()
    }
}
