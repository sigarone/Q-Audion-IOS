import Foundation
import QAudionEngine

/// FE-5 server exchange service — iOS mirror of Android `Fe5ExchangeRepository.kt`.
///
/// Three endpoints (all under /api/v1/diag/fe5):
///   POST  /publish      — upload own earbud's pk_se + material (pk_pq) so the peer phone can fetch
///   GET   /peer         — fetch peer phone's earbud data (polls until available)
///   POST  /publish_ct   — upload ct_ee after RESPONDER pairing so the INITIATOR can complete Stage-2
///
/// Auth: Bearer access token from TokenVault (Keychain, SECURITY C-5).
/// Pinning: SECURITY C-6 — cert-pinned URLSession via PinnedURLSession.
final class Fe5ExchangeService {

    struct PeerData {
        let pkSe: String     // hex
        let material: String // base64 (pk_pq or ct_ee)
        let ct: String?      // base64 ct_ee, present after RESPONDER publishes
    }

    private let session: URLSession
    private let baseUrl: String

    init(serverUrl: String = PinnedServerHost.url) {
        self.baseUrl = serverUrl
        self.session = PinnedURLSession.make(for: serverUrl)
    }

    // MARK: - Public API

    /// Upload own earbud's pk_se (hex) + material/pk_pq (base64).
    /// Returns true on HTTP 2xx.
    func publish(pkSeHex: String, materialB64: String) async -> Bool {
        guard let url = endpoint("/api/v1/diag/fe5/publish") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        let body: [String: Any] = ["pkSe": pkSeHex, "material": materialB64]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire2xx(req, label: "fe5.publish")
    }

    /// Fetch peer phone's earbud data. Returns nil if not yet available.
    /// `myPkSeHex` is used as the self-identifier so the server returns the OTHER side.
    func fetchPeer(myPkSeHex: String) async -> PeerData? {
        guard var comps = URLComponents(string: baseUrl + "/api/v1/diag/fe5/peer") else { return nil }
        comps.queryItems = [URLQueryItem(name: "myPkSe", value: myPkSeHex)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        addAuth(&req)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pkSe = json["pkSe"] as? String,
                  let material = json["material"] as? String else { return nil }
            let ct = json["ct"] as? String
            return PeerData(pkSe: pkSe, material: material, ct: ct)
        } catch {
            print("[Fe5Exchange] fetchPeer error: \(error)")
            return nil
        }
    }

    /// Upload ct_ee (base64) keyed by the connected earbud's pkSe (hex).
    /// Called after RESPONDER pairing so the INITIATOR phone can complete Stage-2.
    func publishCt(pkSeHex: String, ctB64: String) async -> Bool {
        guard let url = endpoint("/api/v1/diag/fe5/publish_ct") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        let body: [String: Any] = ["pkSe": pkSeHex, "ct": ctB64]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fire2xx(req, label: "fe5.publishCt")
    }

    // MARK: - Internals

    private func endpoint(_ path: String) -> URL? {
        URL(string: baseUrl + path)
    }

    private func addAuth(_ req: inout URLRequest) {
        if let token = TokenVault.loadAccessToken(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    @discardableResult
    private func fire2xx(_ req: URLRequest, label: String) async -> Bool {
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            let ok = (200..<300).contains(http.statusCode)
            if !ok { print("[Fe5Exchange] \(label) HTTP \(http.statusCode)") }
            return ok
        } catch {
            print("[Fe5Exchange] \(label) error: \(error)")
            return false
        }
    }
}
