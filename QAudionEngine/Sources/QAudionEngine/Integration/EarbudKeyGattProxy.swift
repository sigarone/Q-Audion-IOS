import Foundation

/// Abstraction over the earbud BLE GATT operations needed for KEY_IMPORT relay.
/// The concrete iOS implementation (using CoreBluetooth) wires into this via
/// the app layer. Tests use a stub conformance.
public protocol EarbudKeyGattProxy: AnyObject, Sendable {
    /// True when a BLE connection to the earbud is active.
    var isConnected: Bool { get }

    /// Write the PoP-INPUTS frame + package fragments to KEY_IMPORT (c3),
    /// then read the status+slot response. Returns the KEY_IMPORT result.
    ///
    /// - Parameters:
    ///   - pkg:       1668-byte raw package (KEYIMPORT_PKG_LEN)
    ///   - popInputs: 82-byte PoP-INPUTS frame (KEYIMPORT_POP_FRAME_LEN)
    func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome

    /// Read the ATTEST_POP characteristic (c1) after a successful KEY_IMPORT.
    /// Returns the 32-byte SE PoP.
    func readAttestPop() async throws -> Data
}

public enum KeyImportOutcome {
    case ok(status: UInt8, slot: UInt8)
    case err(String)
}
