import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // HTTPCookie on Linux (the box runs the logic tests there); a no-op on Apple platforms
#endif

// Pure logic for keeping the pairing across a reinstall (no Keychain, no WebKit, Foundation only), so it can be
// unit-tested in the EveLogicTests target (this file is compiled into both the app and the tests).
//
// What is kept: only the value of the `eve_session` cookie (+ its expiry), as one Keychain item owned by this app.
// What is decided here: which cookie counts, whether a stored record is still usable, and the three actions
// (save / delete / restore). The Keychain and WKHTTPCookieStore calls live in SessionBackupStore / SessionPersistence.

enum SessionBackup {
    static let cookieName = "eve_session"
    /// The server's absolute session lifetime (and the cookie's Max-Age). A record is never used past it.
    static let maxLifetime: TimeInterval = 180 * 24 * 3600
    /// A record saved "in the future" by more than this means the clock moved: do not trust it.
    static let maxFutureSkew: TimeInterval = 24 * 3600
    static let schemaVersion = 1

    // MARK: Token

    /// The gateway's token is `base64.RawURLEncoding` of 32 random bytes = exactly 43 characters (eve-serving
    /// internal/session/session.go). Anything else is refused, so a value can never carry cookie attributes or control
    /// characters when it is put back into a cookie, and a bogus value is never stored.
    static let tokenLength = 43

    static func isValidToken(_ s: String) -> Bool {
        guard s.utf8.count == tokenLength else { return false }
        return s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }

    // MARK: Record

    struct Record: Codable, Equatable {
        var v: Int = SessionBackup.schemaVersion
        var token: String
        var expires: TimeInterval     // seconds since 1970, the cookie's expiry (capped at saveTime + maxLifetime)
        var savedAt: TimeInterval     // when this token was first stored (kept when the same token is stored again)
    }

    /// Strict decode: wrong schema version, invalid token or a nonsensical lifetime gives nil (the caller deletes it).
    static func decode(_ data: Data) -> Record? {
        guard let r = try? JSONDecoder().decode(Record.self, from: data),
              r.v == schemaVersion, isValidToken(r.token),
              r.expires.isFinite, r.savedAt.isFinite,
              r.expires - r.savedAt <= maxLifetime + maxFutureSkew else { return nil }
        return r
    }

    static func encode(_ r: Record) -> Data? { try? JSONEncoder().encode(r) }

    enum Freshness: Equatable { case fresh, expired, clockSkew }

    static func freshness(_ r: Record, now: TimeInterval) -> Freshness {
        if r.savedAt > now + maxFutureSkew { return .clockSkew }
        if r.expires <= now || now - r.savedAt >= maxLifetime { return .expired }
        return .fresh
    }

    // MARK: Cookie <-> record

    /// The session cookie of the configured host, exactly as the gateway sets it: name, Secure, HttpOnly, Path=/,
    /// host-only (domain is exactly the host: no leading dot, so no Domain attribute), a valid value. A cookie that
    /// differs in any of these (e.g. a domain cookie ".host", or one a page script could read) is never backed up and
    /// never counts as "the cookie is there". (Unpair uses the more tolerant `SessionRevoker.currentSessionToken`.)
    static func sessionCookie(in cookies: [HTTPCookie], host: String) -> HTTPCookie? {
        cookies.first { c in
            c.name == cookieName && isValidToken(c.value) && attributeMismatches(of: c, host: host).isEmpty
        }
    }

    // MARK: Read-back check after a restore (M-1)

    enum Mismatch: String, Equatable, Hashable { case notHttpOnly, notSecure, notHostOnly, wrongPath }

    /// Attributes that must be what the gateway sets: HttpOnly, Secure, host-only (domain exactly the host, no
    /// leading dot), Path "/". Empty = as expected.
    static func attributeMismatches(of c: HTTPCookie, host: String) -> [Mismatch] {
        var m: [Mismatch] = []
        if !c.isHTTPOnly { m.append(.notHttpOnly) }
        if !c.isSecure { m.append(.notSecure) }
        if c.domain.lowercased() != host.lowercased() { m.append(.notHostOnly) }
        if c.path != "/" { m.append(.wrongPath) }
        return m
    }

    enum RestoreCheck: Equatable {
        case ok
        case missing                    // setCookie left nothing for this token on the host
        case mismatch([Mismatch])       // it is there but not as the server's cookie: the caller must remove it
    }

    /// Looks at what the WKHTTPCookieStore really holds after `setCookie` of the restored `token`. Every
    /// `eve_session` cookie of the host (domain with or without a leading dot) carrying that token must match.
    static func checkRestored(token: String, in cookies: [HTTPCookie], host: String) -> RestoreCheck {
        let mine = cookiesToRemove(token: token, in: cookies, host: host)
        if mine.isEmpty { return .missing }
        var bad: [Mismatch] = []
        for c in mine { for m in attributeMismatches(of: c, host: host) where !bad.contains(m) { bad.append(m) } }
        return bad.isEmpty ? .ok : .mismatch(bad)
    }

    /// The cookies the guard removes when a restore does not read back as expected: same name, value and host
    /// (any leading dot) as the restored token.
    static func cookiesToRemove(token: String, in cookies: [HTTPCookie], host: String) -> [HTTPCookie] {
        let h = host.lowercased()
        return cookies.filter { c in
            c.name == cookieName && c.value == token
                && c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == h
        }
    }

    /// Record to store for `cookie`, or nil if it must not be stored: no expiry (a session cookie would not survive
    /// a restart anyway), already expired, or an invalid value. The expiry is capped at now + maxLifetime so a cookie
    /// can never extend the server's absolute lifetime. The same token as `existing` keeps its original `savedAt`.
    static func makeRecord(from cookie: HTTPCookie, existing: Record?, now: TimeInterval) -> Record? {
        guard isValidToken(cookie.value), let exp = cookie.expiresDate?.timeIntervalSince1970, exp > now else { return nil }
        let savedAt = (existing?.token == cookie.value) ? existing!.savedAt : now
        return Record(token: cookie.value, expires: min(exp, savedAt + maxLifetime), savedAt: savedAt)
    }

    /// The cookie to put back into the WebView: host-only, path /, Secure, HttpOnly, SameSite=Strict like the
    /// server's own cookie. nil if the host or the record is not acceptable.
    static func makeCookie(for r: Record, host: String) -> HTTPCookie? {
        guard isValidToken(r.token), !host.isEmpty, !host.contains("/"), !host.contains(":") else { return nil }
        var p: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: r.token,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
            .expires: Date(timeIntervalSince1970: r.expires),
        ]
        p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        #if !canImport(FoundationNetworking)
        p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict   // not in swift-corelibs; asserted by the macOS test run
        #endif
        return HTTPCookie(properties: p)
    }

    // MARK: Decisions

    /// What the Keychain held when it was last read.
    enum Stored: Equatable {
        case none
        case record(Record)
        case corrupt           // an item exists but is not a valid current record: delete it, never interpret it
        case unavailable       // could not be read right now (e.g. device locked): decide nothing
    }

    enum RestoreAction: Equatable {
        case none
        case retryLater        // the Keychain (or the pending-revoke list) could not be read yet
        case deleteBackup
        case discardAndRevoke(Record)   // the pending-revoke list is damaged: do not restore, delete the backup, revoke its token
        case restore(Record)
    }

    /// The pending-revoke list as last read.
    enum PendingRevoke: Equatable {
        case tokens(Set<String>)
        case unavailable       // could not be read right now (locked): decide nothing
        case corrupt           // damaged: it may hide a token that must not come back, so fail closed
    }

    /// At launch, before the first page load. Restores only into an EMPTY cookie store (a cookie that is already
    /// there is never replaced), and never a token that is waiting to be revoked or that is expired / from the future.
    /// `deletePending` = an earlier delete of the backup failed (web logout/expiry): it is retried first and the
    /// record is never restored. A damaged pending-revoke list fails closed (nothing is restored).
    static func onLaunch(cookie: HTTPCookie?, stored: Stored, pendingRevoke: PendingRevoke, deletePending: Bool = false,
                         now: TimeInterval) -> RestoreAction {
        if cookie != nil { return .none }
        if deletePending { return stored == .unavailable ? .retryLater : .deleteBackup }
        switch stored {
        case .none: return .none
        case .unavailable: return .retryLater
        case .corrupt: return .deleteBackup
        case .record(let r):
            guard freshness(r, now: now) == .fresh else { return .deleteBackup }
            switch pendingRevoke {
            case .unavailable: return .retryLater
            case .corrupt: return .discardAndRevoke(r)
            case .tokens(let pending): return pending.contains(r.token) ? .deleteBackup : .restore(r)
            }
        }
    }

    enum ObserveAction: Equatable {
        case none
        case save(Record)
        case delete
    }

    /// After the cookie store changed (or on a lifecycle nudge). `seenPresent` = this process has seen (or restored)
    /// the cookie, so its absence now means logout/expiry/unpair, not "the store was empty at launch".
    /// `suspended` = an unpair is in progress: do nothing (the unpair itself deletes the backup).
    /// `deletePending` = an earlier delete failed: with no cookie it is retried, even in a new process (`seenPresent` false).
    static func onCookiesChanged(cookie: HTTPCookie?, stored: Stored, seenPresent: Bool, suspended: Bool,
                                 deletePending: Bool = false, now: TimeInterval) -> ObserveAction {
        if suspended { return .none }
        guard let cookie else { return (seenPresent || deletePending) ? .delete : .none }
        var existing: Record?
        switch stored {
        case .unavailable: return .none               // cannot read or write now; the next change/nudge retries
        case .record(let r): existing = r
        case .none, .corrupt: existing = nil
        }
        guard let next = makeRecord(from: cookie, existing: existing, now: now) else {
            // A live cookie we must not back up (no expiry, expired): drop an older backup of another token.
            if case .none = stored { return .none }
            return .delete
        }
        if existing == next { return .none }
        return .save(next)
    }
}
