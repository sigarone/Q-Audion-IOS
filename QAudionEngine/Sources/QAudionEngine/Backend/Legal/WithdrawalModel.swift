import Combine
import Foundation

/// The withdrawal from the contract (art. 54-bis Codice del Consumo, art. 7.7 of the Terms).
///
/// States: `info` (the text of art. 7.7 and the "Conferma recesso" button), `sending` (the request is out),
/// `receipt` (the server recorded the withdrawal and returned the receipt) and `failed` (nothing was recorded
/// as far as the app knows: the same button tries again).
///
/// Rules, each pinned by `WithdrawalModelTests`:
///  - the request starts only from `info` or `failed`, so a second tap while it runs does nothing;
///  - the server's withdraw is idempotent per account, so a retry after an unclear failure is safe;
///  - a rejected session (`unauthorized`) after a withdraw that may have gone through is not told as a failure
///    of the contract: it is `failed` with `.sessionEnded`, and the screen offers to leave;
///  - the receipt is kept only in memory by whoever holds the model; `onReceipt` runs once, when it arrives.
@MainActor
public final class WithdrawalModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case info
        case sending
        case receipt(WithdrawalReceipt)
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        case network
        case sessionEnded
    }

    @Published public private(set) var state: State = .info

    private let api: LegalApi
    private let onReceipt: @MainActor (WithdrawalReceipt) -> Void

    public init(api: LegalApi, onReceipt: @escaping @MainActor (WithdrawalReceipt) -> Void = { _ in }) {
        self.api = api
        self.onReceipt = onReceipt
    }

    public var canConfirm: Bool {
        switch state {
        case .info, .failed: return true
        case .sending, .receipt: return false
        }
    }

    public func confirm() async {
        guard canConfirm else { return }
        state = .sending
        do {
            let receipt = try await api.withdraw()
            state = .receipt(receipt)
            onReceipt(receipt)
        } catch BCryptoError.unauthorized {
            state = .failed(.sessionEnded)
        } catch {
            state = .failed(.network)
        }
    }
}
