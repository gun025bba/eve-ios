import Foundation
import Network
import Security
import WebKit

/// Security follow-up L1: unpairing while offline must not leave the server session alive.
///
/// On unpair the shell copies the session cookie into the Keychain as a *pending revoke*, wipes all local website
/// data immediately, then calls `DELETE /v1/session` (the API the web's logout uses). If that fails it is retried
/// on launch, when the app becomes active and when the network path becomes usable, with bounds (see `RevokePolicy`):
/// - TTL: a pending token gets one last attempt and is then deleted after 30 days (the server's idle expiry); the
///   same applies when the clock looks wrong (saved in the future).
/// - Attempts: server answers that are not success are counted; permanent rejections (403/404/...) delete the
///   token after a few tries, transient ones (5xx/429/408) after more. Network errors only wait for the TTL.
/// - Backoff: minimum interval between non-forced attempts grows exponentially up to 6 hours.
/// - Up to `PendingList.maxEntries` tokens are kept (a second unpair does not overwrite an unfinished first one).
/// - Compare-and-clear: a result only touches the entry holding the token that was tried.
/// The token is never kept in UserDefaults, logged, or passed over the bridge.
enum RevokeState: Equatable {
    case none
    case pending               // a revoke is stored and will be retried
    case failed(String)        // gave up / could not store; the server session may still be alive
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
        var dropped = 0
        let ok = PendingTokenStore.mutate { dropped = $0.add(token: token, now: Date().timeIntervalSince1970) }
        if dropped > 0 { state = .failed("overflow") }   // an older unfinished revoke was dropped
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

    /// Retry persisted pending revokes, if any (honours backoff). Safe to call often.
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

    func dismissFailure() {
        if case .failed = state { state = .none }
        refreshState()
    }

    /// Keychain items survive app deletion, so entries found on the first launch of an install (no marker) are
    /// leftovers of a previous install. Each gets one forced attempt and is deleted if the server answered at all;
    /// if we are offline it stays pending (TTL and caps still apply). The marker is only set once the Keychain was
    /// read successfully and the cleanup ran, so a locked-device launch does not skip it.
    private func firstLaunchCleanup() async {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.installMarker) else { return }
        switch PendingTokenStore.load() {
        case .unavailable:
            return                                   // try again next launch
        case .none:
            break
        case .corrupt:
            PendingTokenStore.deleteItem()
            state = .failed("corrupt")
        case .list(let list):
            for stale in list.entries {
                let r = await send(token: stale.token)
                if r != .network { PendingTokenStore.mutate { $0.remove(token: stale.token) } }
            }
        }
        d.set(true, forKey: Self.installMarker)
        refreshState()
    }

    private func refreshState() {
        if case .failed = state { return }          // a failure stays visible until dismissed
        switch PendingTokenStore.load() {
        case .list(let l) where !l.isEmpty: state = .pending
        default: state = .none
        }
    }

    private func processPending(force: Bool) async {
        if inFlight { if force { rerunForced = true }; return }
        inFlight = true
        var forced = force
        repeat {
            rerunForced = false
            await processAll(force: forced)
            forced = true
        } while rerunForced
        inFlight = false
    }

    private func processAll(force: Bool) async {
        switch PendingTokenStore.load() {
        case .none, .unavailable:
            refreshState()
        case .corrupt:
            PendingTokenStore.deleteItem()             // never interpret an unreadable item as a token
            state = .failed("corrupt")
        case .list(let list):
            for entry in list.entries { await process(entry, force: force) }
            refreshState()
        }
    }

    private func process(_ entry: PendingEntry, force: Bool) async {
        var e = entry
        let tried = e.token
        let now = Date().timeIntervalSince1970

        switch RevokePolicy.expiry(savedAt: e.savedAt, now: now) {
        case .expired, .clockSkew:
            // Last attempt before deleting, so a wrong clock or a long absence does not silently keep the session alive.
            let r = await send(token: tried)
            PendingTokenStore.mutate { $0.remove(token: tried) }
            if r != .done { state = .failed("expired") }
            return
        case .fresh:
            break
        }
        if !force, RevokePolicy.shouldWait(lastAttempt: e.lastAttempt, attempts: e.attempts, now: now) { return }

        e.lastAttempt = now
        let result = await send(token: tried)
        switch result {
        case .done:
            PendingTokenStore.mutate { $0.remove(token: tried) }          // compare-and-clear
        case .network:
            PendingTokenStore.mutate { $0.update(e) }                      // keep; wait for the next trigger or the TTL
        case .permanent, .transient:
            e.attempts += 1
            if result == .permanent { e.permanentFailures += 1 }
            if RevokePolicy.shouldGiveUp(attempts: e.attempts, permanentFailures: e.permanentFailures) {
                PendingTokenStore.mutate { $0.remove(token: tried) }
                state = .failed(result == .permanent ? "rejected" : "gave_up")
            } else {
                PendingTokenStore.mutate { $0.update(e) }
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

/// The pending-revoke list in the Keychain: one generic-password item holding a versioned JSON `PendingList`.
/// Read-modify-write happens synchronously on the main actor, so there is no interleaving between load and write.
enum PendingTokenStore {
    enum Loaded {
        case none                  // no item
        case list(PendingList)
        case corrupt               // item exists but is not a valid current-version list: delete, never use as a token
        case unavailable           // Keychain could not be read right now (e.g. device locked): do not decide anything
    }

    private static let service = "eve.shell.pending-revoke"
    private static let account = "session"
    // Stricter than AfterFirstUnlock: retries only run while the app is in use (unlocked), never in the background.
    private static let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Loaded {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess else { return .unavailable }
        guard let data = out as? Data, let list = PendingList.decode(data) else { return .corrupt }
        return .list(list)
    }

    /// Applies `change` to the stored list (a corrupt item counts as empty) and writes it back, deleting the item when
    /// the list is empty. Uses SecItemUpdate then SecItemAdd, never delete-then-add. Returns false if it could not be
    /// stored (or the Keychain could not be read), in which case nothing was changed.
    @discardableResult
    static func mutate(_ change: (inout PendingList) -> Void) -> Bool {
        var list: PendingList
        switch load() {
        case .none, .corrupt: list = PendingList()
        case .list(let l): list = l
        case .unavailable: return false
        }
        change(&list)
        if list.isEmpty { return deleteItem() }
        guard let data = list.encode() else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteItem() -> Bool {
        let s = SecItemDelete(query as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
