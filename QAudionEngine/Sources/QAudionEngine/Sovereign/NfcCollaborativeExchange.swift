import Foundation
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// Drives an iOS-reader NFC collaborative pairing session.
///
/// Owns an `NfcExchangeViewModel` and an underlying `NFCTagReaderSession`
/// (created in `start()`). When a tag is detected, performs SELECT-AID
/// → 64-byte payload exchange → PSK derivation, then transitions to
/// `.success` or `.error`.
///
/// On non-iOS builds (e.g. macOS unit tests), the CoreNFC layer is absent
/// and the service exposes `simulate*ForTesting()` methods to drive the
/// state machine deterministically.
public final class NfcCollaborativeExchange {

    public private(set) var viewModel: NfcExchangeViewModel

    public init() {
        self.viewModel = .mock  // starts in .idle
    }

    public func start() {
        viewModel.transition(to: .waiting)
        #if canImport(CoreNFC) && os(iOS)
        beginNfcReaderSession()
        #endif
    }

    public func cancel() {
        viewModel.transition(to: .idle)
        #if canImport(CoreNFC) && os(iOS)
        endNfcReaderSessionIfActive()
        #endif
    }

    // MARK: - Test seams

    /// Test-only: pretend a tag was detected. Drives `.waiting → .exchanging`.
    public func simulateTagDetectedForTesting() {
        viewModel.transition(to: .exchanging)
    }

    public func simulateExchangeCompletedForTesting(peerDeviceName: String) {
        viewModel.transition(to: .success(peerDeviceName: peerDeviceName))
    }

    public func simulateExchangeFailedForTesting(message: String) {
        viewModel.transition(to: .error(message: message))
    }

    // MARK: - CoreNFC integration (iOS-only, skeleton — concrete APDU exchange in B.2)

    #if canImport(CoreNFC) && os(iOS)
    private var session: NFCTagReaderSession?

    private func beginNfcReaderSession() {
        // Concrete CXProvider integration in Task B.2 (iOS-device-only).
    }

    private func endNfcReaderSessionIfActive() {
        session?.invalidate()
        session = nil
    }
    #endif
}
