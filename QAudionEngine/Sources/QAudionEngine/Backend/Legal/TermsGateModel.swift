import Combine
import Foundation

/// Re-acceptance of the Terms for an account that already exists.
///
/// The server never blocks an endpoint over this (a call must not break): the app asks `GET /legal/status` at
/// launch and on return to the foreground, and when `acceptance_required` is true it shows a blocking screen
/// with the same screen as at registration.
///
/// Rules, each pinned by `TermsGateModelTests`:
///  - the screen is up only while the status says it is required, the document is loaded and NO call is active
///    or ringing; a call that starts while it is up takes it down, and it comes back once the call is over,
///    with the boxes already ticked kept;
///  - a status or document that cannot be read never raises the screen: nothing is blocked on a guess;
///  - a refused acceptance (`409`, the edition moved) reads the status and the document again and starts over;
///  - requests do not overlap: a refresh asked while one runs is dropped, and so is a second submit;
///  - `reset()` (logout, another account, a wipe) drops every piece of state.
@MainActor
public final class TermsGateModel: ObservableObject {
    public enum Requirement: Equatable, Sendable {
        case unknown
        case notRequired
        case required
    }

    public enum Problem: Equatable, Sendable {
        /// The acceptance could not be sent: try again.
        case submitFailed
        /// The edition changed while the screen was up: the texts were loaded again and the boxes cleared.
        case editionChanged
    }

    @Published public private(set) var requirement: Requirement = .unknown
    @Published public private(set) var fetch: LegalTermsFetch?
    @Published public private(set) var isPresented = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var problem: Problem?
    @Published public var draft = TermsAcceptanceDraft()

    private let api: LegalApi
    private let languageCode: @MainActor () -> String
    private var callBusy = false
    private var isRefreshing = false
    private var epoch = 0

    public init(api: LegalApi, languageCode: @escaping @MainActor () -> String) {
        self.api = api
        self.languageCode = languageCode
    }

    /// Reads the status; when the acceptance is required, loads the document too.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let startEpoch = epoch
        defer { isRefreshing = false }
        let status: LegalStatus
        do {
            status = try await api.status()
        } catch {
            return
        }
        guard startEpoch == epoch else { return }
        guard status.acceptanceRequired else {
            requirement = .notRequired
            fetch = nil
            reevaluate()
            return
        }
        if fetch == nil || fetch?.document.version != status.currentVersion {
            guard let loaded = try? await api.fetchTerms(lang: languageCode()), startEpoch == epoch else { return }
            fetch = loaded
            draft = TermsAcceptanceDraft()
        }
        requirement = .required
        reevaluate()
    }

    /// Tells the model whether a call is active or ringing. Called whenever that changes.
    public func setCallBusy(_ busy: Bool) {
        callBusy = busy
        reevaluate()
    }

    private func reevaluate() {
        isPresented = requirement == .required && fetch != nil && !callBusy
    }

    /// Sends the acceptance. Ignored while the boxes are not all on or a send is already running.
    public func submit() async {
        guard !isSubmitting, let fetch, let acceptance = draft.acceptance(for: fetch) else { return }
        isSubmitting = true
        problem = nil
        let startEpoch = epoch
        defer { isSubmitting = false }
        do {
            try await api.accept(acceptance)
            guard startEpoch == epoch else { return }
            requirement = .notRequired
            self.fetch = nil
            draft = TermsAcceptanceDraft()
            reevaluate()
        } catch LegalApiError.versionStale {
            guard startEpoch == epoch else { return }
            self.fetch = nil
            draft = TermsAcceptanceDraft()
            problem = .editionChanged
            isSubmitting = false
            await refresh()
        } catch {
            guard startEpoch == epoch else { return }
            problem = .submitFailed
        }
    }

    /// Drops everything: another account, a logout, a wipe.
    public func reset() {
        epoch += 1
        requirement = .unknown
        fetch = nil
        draft = TermsAcceptanceDraft()
        problem = nil
        isSubmitting = false
        isRefreshing = false
        isPresented = false
    }
}
