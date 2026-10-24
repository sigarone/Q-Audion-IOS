import Foundation
@testable import QAudionEngine

/// Process-local `RatchetVault` for unit tests. Keeps v3.1 snapshots and v4
/// session blobs in separate maps, mirroring the production vault's keyspaces.
/// Never use outside tests: nothing is persisted.
final class TestRatchetVault: RatchetVault, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: RatchetSnapshot] = [:]
    private var storeV4: [String: Data] = [:]

    init() {}

    func load(epochId: String, peerId: String) -> RatchetSnapshot? {
        lock.withLock { store[Self.key(epochId, peerId)] }
    }

    func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {
        lock.withLock { store[Self.key(epochId, peerId)] = snapshot }
    }

    func delete(epochId: String, peerId: String) {
        lock.withLock { _ = store.removeValue(forKey: Self.key(epochId, peerId)) }
    }

    func loadV4(epochId: String, peerId: String) -> Data? {
        lock.withLock { storeV4[Self.key(epochId, peerId)] }
    }

    func saveV4(epochId: String, peerId: String, blob: Data) throws {
        lock.withLock { storeV4[Self.key(epochId, peerId)] = blob }
    }

    func deleteV4(epochId: String, peerId: String) {
        lock.withLock { _ = storeV4.removeValue(forKey: Self.key(epochId, peerId)) }
    }

    var count: Int {
        lock.withLock { store.count }
    }

    private static func key(_ epoch: String, _ peer: String) -> String {
        "\(epoch)|\(peer)"
    }
}
