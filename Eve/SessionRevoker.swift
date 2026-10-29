import Foundation
import Network
import Security
import WebKit

/// Security follow-up L1: unpairing while offline must not leave the server session alive.
///
/// On unpair the shell copies the session cookie into the Keychain as a *pending revoke*, wipes all local website
/// data immediately, then calls `DELETE /v1/session` (the API the web's logout uses). If that fails it is retried
/// on launch, when the app becomes active and when the network path becomes usable, with bounds:
/// - TTL: the pending token is deleted after `RevokePolicy.maxAge` (30 days, the server's idle expiry).
/// - Attempts: server answers that are not success are counted; permanent rejections (403/404/...) delete the
///   token after a few tries, transient ones (5xx/429/408) after more. Network errors only wait for the TTL.
/// - Backoff: minimum interval between non-forced attempts grows exponentially up to 6 hours.
/// - Compare-and-clear: a result only deletes/updates the stored item if it still holds the token that was tried.
/// The token is never kept in UserDefaults, logged, or passed over the bridge.
enum RevokeState: Equatable {
    case none
    case pending               // a revoke is stored and will be retried
    case failed(String)        // gave up / could not store; server session may still be alive
}

@MainActor
final class SessionRevoker: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = SessionRevoker()

    @Published private(set) var state: RevokeState = .none

    private static let cookieName = "eve_session"
    private static let installMarker = "eve.shell.installed"   // not secret; deleted with the app, the Keychain item is not
    private var inFlight = false
    private var rerunForced = false
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
    func persistPending(_ token: String) -> Bool {
        let ok = PendingTokenStore.save(token)
        refreshState()
        return ok
    }

    // MARK: Revoke

    /// Revoke a token that was just captured. `persisted` is whether the Keychain accepted it.
    func revoke(token: String, persisted: Bool) async {
        if persisted {
            await processPending(force: true)
        } else {
            // Could not store it: one in-memory attempt, and tell the user if it does not succeed.
            let r = await send(token: token)
            state = (r == .done) ? .none : .failed("not_stored")
        }
    }

    /// Retry a persisted pending revoke, if any (honours backoff). Safe to call often.
    func retryPending() async { await processPending(force: false) }

    /// Call once at launch: first-launch cleanup, retry now, and retry whenever connectivity comes back.
    func start() {
        Task {
            await firstLaunchCleanup()
            await processPending(force: false)
        }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.processPending(force: false) }
        }
        m.start(queue: DispatchQueue(label: "eve.shell.revoker.path"))
        monitor = m
    }

    func dismissFailure() { if case .failed = state { state = .none } }

    /// Keychain items survive app deletion. A fresh install (no marker) with an item left over is stale:
    /// make one last forced attempt, then delete it regardless.
    private func firstLaunchCleanup() async {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.installMarker) else { return }
        d.set(true, forKey: Self.installMarker)
        guard let stale = PendingTokenStore.load() else { return }
        await processPending(force: true)
        PendingTokenStore.clear(ifToken: stale.token)
        refreshState()
    }

    private func refreshState() {
        if PendingTokenStore.load() != nil { state = .pending }
        else if case .pending = state { state = .none }
    }

    private func processPending(force: Bool) async {
        if inFlight { if force { rerunForced = true }; return }
        inFlight = true
        var forced = force
        repeat {
            rerunForced = false
            await processOnce(force: forced)
            forced = true
        } while rerunForced
        inFlight = false
    }

    private func processOnce(force: Bool) async {
        guard var e = PendingTokenStore.load() else { refreshState(); return }
        let now = Date().timeIntervalSince1970
        if RevokePolicy.isExpired(savedAt: e.savedAt, now: now) {
            PendingTokenStore.clear(ifToken: e.token)
            state = .failed("expired")
            return
        }
        if !force, now - e.lastAttempt < RevokePolicy.minInterval(attempts: e.attempts) { state = .pending; return }

        let tried = e.token
        e.lastAttempt = now
        let result = await send(token: tried)
        switch result {
        case .done:
            PendingTokenStore.clear(ifToken: tried)           // compare-and-clear
            refreshState()
            if case .pending = state { return }               // a newer token was queued meanwhile
            state = .none
        case .network:
            PendingTokenStore.update(e, onlyIfToken: tried)   // keep; wait for the next trigger or the TTL
            state = .pending
        case .permanent, .transient:
            e.attempts += 1
            if result == .permanent { e.permanentFailures += 1 }
            if RevokePolicy.shouldGiveUp(attempts: e.attempts, permanentFailures: e.permanentFailures) {
                PendingTokenStore.clear(ifToken: tried)
                state = .failed(result == .permanent ? "rejected" : "gave_up")
            } else {
                PendingTokenStore.update(e, onlyIfToken: tried)
                state = .pending
            }
        }
    }

    private enum SendResult { case done, permanent, transient, network }

    private func send(token: String) async -> SendResult {
        let cfg = ShellConfig.current
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = cfg.host
        comps.path = "/v1/session"
        guard let url = comps.url, cfg.isAllowed(url: url) else { return .permanent }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.httpShouldHandleCookies = false
        req.setValue("\(Self.cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("1", forHTTPHeaderField: "X-Eve-Request")           // gateway CSRF header
        req.setValue("https://\(cfg.host)", forHTTPHeaderField: "Origin") // must be in the gateway's allowed origins

        let sc = URLSessionConfiguration.ephemeral
        sc.httpCookieStorage = nil
        sc.httpShouldSetCookies = false
        sc.urlCache = nil
        sc.waitsForConnectivity = false
        let session = URLSession(configuration: sc, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, resp) = try await session.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode else { return .network }
            switch RevokePolicy.outcome(forStatus: code) {
            case .done: return .done
            case .permanent: return .permanent
            case .transient: return .transient
            }
        } catch {
            return .network   // offline or unreachable
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

/// Pure decisions (no I/O), kept separate so they can be unit-tested.
enum RevokePolicy {
    static let maxAge: TimeInterval = 30 * 24 * 3600        // matches the server's 30-day idle expiry
    static let maxPermanentResponses = 3
    static let maxFailedResponses = 10
    static let maxBackoff: TimeInterval = 6 * 3600

    enum Outcome { case done, permanent, transient }

    /// 204/200: revoked. 401: session already invalid. 5xx/408/429: try again later. Anything else
    /// (403 origin/identity rejection, 404, 3xx because redirects are not followed, other 4xx): permanent.
    static func outcome(forStatus code: Int) -> Outcome {
        switch code {
        case 200, 204, 401: return .done
        case 408, 429, 500...599: return .transient
        default: return .permanent
        }
    }

    static func isExpired(savedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - savedAt >= maxAge || savedAt > now + 24 * 3600   // also drop items with an implausible future timestamp
    }

    static func minInterval(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(min(max(attempts, 0), 20))), maxBackoff)
    }

    static func shouldGiveUp(attempts: Int, permanentFailures: Int) -> Bool {
        permanentFailures >= maxPermanentResponses || attempts >= maxFailedResponses
    }
}

/// The single pending-revoke item in the Keychain (JSON: token + bookkeeping).
struct PendingEntry: Codable, Equatable {
    var token: String
    var savedAt: TimeInterval
    var lastAttempt: TimeInterval = 0
    var attempts: Int = 0
    var permanentFailures: Int = 0
}

enum PendingTokenStore {
    private static let service = "eve.shell.pending-revoke"
    private static let account = "session"
    // Stricter than AfterFirstUnlock: retries only run while the app is in use (unlocked), never in the background.
    private static let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// New pending entry for `token`. Uses update-then-add so a failure never destroys an existing item.
    static func save(_ token: String) -> Bool {
        write(PendingEntry(token: token, savedAt: Date().timeIntervalSince1970))
    }

    /// Update bookkeeping, but only if the stored item still holds `token` (compare-and-set).
    @discardableResult
    static func update(_ entry: PendingEntry, onlyIfToken token: String) -> Bool {
        guard let cur = load(), cur.token == token else { return false }
        var next = entry
        next.token = token
        next.savedAt = cur.savedAt
        return write(next)
    }

    /// Delete only if the stored item still holds `token` (compare-and-clear).
    static func clear(ifToken token: String) {
        guard let cur = load(), cur.token == token else { return }
        SecItemDelete(query as CFDictionary)
    }

    static func load() -> PendingEntry? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        if let e = try? JSONDecoder().decode(PendingEntry.self, from: data) { return e }
        // Legacy/raw value: treat as a fresh entry so it is still bounded by the TTL from now.
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return nil }
        return PendingEntry(token: raw, savedAt: Date().timeIntervalSince1970)
    }

    private static func write(_ entry: PendingEntry) -> Bool {
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
