import Foundation
import Network
import Security
import WebKit

/// Security follow-up L1: unpairing while offline must not leave the server session alive.
///
/// On unpair the shell wipes all local website data immediately. Before that, it copies the
/// session cookie value into the Keychain (this-device-only, after first unlock) as a *pending revoke*.
/// The revoke (`DELETE /v1/session`, the same API the web's logout uses) is retried on launch, when the
/// app becomes active and when the network path becomes usable, until the server answers.
/// The token is never kept in UserDefaults, logged, or passed over the JS bridge, and the Keychain
/// item is deleted as soon as the server confirms (or says the session no longer exists).
@MainActor
final class SessionRevoker: NSObject, URLSessionTaskDelegate {
    static let shared = SessionRevoker()

    private static let cookieName = "eve_session"
    private var inFlight = false
    private var monitor: NWPathMonitor?

    // MARK: Capture

    /// Returns the current session cookie value for the configured host, if any.
    func currentSessionToken(from store: WKHTTPCookieStore) async -> String? {
        let host = ShellConfig.current.host
        let cookies = await store.allCookies()
        let match = cookies.first { c in
            c.name == Self.cookieName && c.isSecure
                && c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == host
                && !c.value.isEmpty
        }
        return match?.value
    }

    /// Persists the token as a pending revoke. Returns false if the Keychain refused it.
    @discardableResult
    func persistPending(_ token: String) -> Bool { PendingTokenStore.save(token) }

    // MARK: Revoke

    /// Revoke a token that was just captured (and persisted if possible).
    func revoke(token: String) async {
        await attempt(token: token)
    }

    /// Retry a persisted pending revoke, if any. Safe to call often.
    func retryPending() async {
        guard let token = PendingTokenStore.load() else { return }
        await attempt(token: token)
    }

    /// Call once at launch: retry now and whenever connectivity comes back.
    func start() {
        Task { await retryPending() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.retryPending() }
        }
        m.start(queue: DispatchQueue(label: "eve.shell.revoker.path"))
        monitor = m
    }

    private func attempt(token: String) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let cfg = ShellConfig.current
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = cfg.host
        comps.path = "/v1/session"
        guard let url = comps.url, cfg.isAllowed(url: url) else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.httpShouldHandleCookies = false
        req.setValue("\(Self.cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("1", forHTTPHeaderField: "X-Eve-Request")           // gateway CSRF header
        req.setValue("https://\(cfg.host)", forHTTPHeaderField: "Origin") // gateway CSRF origin allowlist

        let sc = URLSessionConfiguration.ephemeral
        sc.httpCookieStorage = nil
        sc.httpShouldSetCookies = false
        sc.urlCache = nil
        sc.waitsForConnectivity = false
        let session = URLSession(configuration: sc, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, resp) = try await session.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode else { return }
            // 204: revoked. 401: the session is already invalid/expired, nothing left to revoke.
            if code == 204 || code == 200 || code == 401 { PendingTokenStore.clear() }
            // Any other status (5xx, 429, CSRF rejection, ...): keep the pending revoke and retry later.
        } catch {
            // Offline or unreachable: keep the pending revoke; the next launch/foreground/network change retries.
        }
    }

    // Never follow redirects with the token attached.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Keychain wrapper for the single pending-revoke token.
enum PendingTokenStore {
    private static let service = "eve.shell.pending-revoke"
    private static let account = "session"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
