import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SessionBackupPolicyTests: XCTestCase {
    private let host = "eve.example.invalid"
    private let day: TimeInterval = 86_400
    private let now: TimeInterval = 1_800_000_000
    private let tokenA = String(repeating: "A", count: 43)   // the gateway's format: base64url of 32 bytes = 43 chars
    private let tokenB = String(repeating: "b", count: 43)

    private func cookie(_ value: String? = nil, name: String = "eve_session", domain: String? = nil, secure: Bool = true,
                        httpOnly: Bool = true, path: String = "/", expires: TimeInterval? = nil, session: Bool = false) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value ?? tokenA, .domain: domain ?? host, .path: path]
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if !session { p[.expires] = Date(timeIntervalSince1970: expires ?? (now + 180 * day)) }
        return HTTPCookie(properties: p)!
    }

    private func record(_ token: String? = nil, savedAt: TimeInterval? = nil, expires: TimeInterval? = nil) -> SessionBackup.Record {
        let s = savedAt ?? now - day
        return SessionBackup.Record(token: token ?? tokenA, expires: expires ?? s + 180 * day, savedAt: s)
    }

    // MARK: token / record

    func testTokenValidation() {
        XCTAssertTrue(SessionBackup.isValidToken(tokenA))
        XCTAssertEqual(tokenA.utf8.count, 43)
        XCTAssertTrue(SessionBackup.isValidToken("Ab-_09" + String(repeating: "x", count: 37)))
        // L-14: exactly the server's length (32 random bytes, RawURLEncoding = 43 chars), no range
        XCTAssertFalse(SessionBackup.isValidToken(""))
        for n in [1, 16, 42, 44, 64, 128, 129] { XCTAssertFalse(SessionBackup.isValidToken(String(repeating: "a", count: n)), "\(n)") }
        let base = String(tokenA.dropLast())                     // 42 valid chars + one bad char = 43
        var bads: [String] = ["a;Path=/;" + String(repeating: "a", count: 34), "한글" + String(repeating: "a", count: 37)]
        for c in [" ", "\n", "=", "\u{0}", ",", "+", "/", ";", "\t", "\r"] { bads.append(base + c) }
        for bad in bads {
            XCTAssertFalse(SessionBackup.isValidToken(bad), bad)
        }
    }

    func testRecordRoundTripAndStrictDecode() {
        let r = record()
        XCTAssertEqual(SessionBackup.decode(SessionBackup.encode(r)!), r)
        XCTAssertNil(SessionBackup.decode(Data()))
        XCTAssertNil(SessionBackup.decode(Data(tokenA.utf8)))                                   // a bare token is never a record
        XCTAssertNil(SessionBackup.decode(Data("{\"v\":2,\"token\":\"\(tokenA)\",\"expires\":1,\"savedAt\":1}".utf8)))   // other schema
        XCTAssertNil(SessionBackup.decode(Data("{\"v\":1,\"token\":\"x\",\"expires\":1,\"savedAt\":1}".utf8)))          // invalid token
        XCTAssertNil(SessionBackup.decode(Data("{\"v\":1,\"token\":\"\(tokenA)A\",\"expires\":1,\"savedAt\":1}".utf8)))    // 44 chars
        XCTAssertNil(SessionBackup.decode(Data("{\"v\":1,\"token\":\"\(tokenA)\",\"expires\":1}".utf8)))                // missing field
        // lifetime longer than the server's absolute TTL (+skew) is nonsense
        let long = SessionBackup.Record(token: tokenA, expires: now + 400 * day, savedAt: now)
        XCTAssertNil(SessionBackup.decode(SessionBackup.encode(long)!))
    }

    func testFreshness() {
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now - day), now: now), .fresh)
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now - 10 * day, expires: now + 1), now: now), .fresh)
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now - 10 * day, expires: now), now: now), .expired)
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now - 181 * day, expires: now + 5 * day), now: now), .expired)   // absolute cap
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now + 23 * 3600, expires: now + 100 * day), now: now), .fresh)    // small skew tolerated
        XCTAssertEqual(SessionBackup.freshness(record(savedAt: now + 25 * 3600, expires: now + 100 * day), now: now), .clockSkew)
    }

    // MARK: cookie selection

    func testSessionCookieSelection() {
        XCTAssertNotNil(SessionBackup.sessionCookie(in: [cookie()], host: host))
        XCTAssertNotNil(SessionBackup.sessionCookie(in: [cookie(domain: host.uppercased())], host: host))
        // L-9: only the cookie exactly as the gateway sets it: HttpOnly, Path=/, host-only (no leading dot)
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(domain: "." + host)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(httpOnly: false)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(path: "/ui")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(path: "/ui"), cookie(domain: "." + host), cookie(httpOnly: false)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(name: "other")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(secure: false)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(domain: "other.example.invalid")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(domain: "sub." + host)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie("short")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(tokenA + "A")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [], host: host))
        // the right one wins among several
        let found = SessionBackup.sessionCookie(in: [cookie(domain: "other.example.invalid"), cookie(httpOnly: false), cookie(tokenB), cookie(name: "x")], host: host)
        XCTAssertEqual(found?.value, tokenB)
    }

    func testMakeRecord() {
        let r = SessionBackup.makeRecord(from: cookie(expires: now + 100 * day), existing: nil, now: now)
        XCTAssertEqual(r, SessionBackup.Record(token: tokenA, expires: now + 100 * day, savedAt: now))
        // a session cookie (no expiry) and an expired cookie are never stored
        XCTAssertNil(SessionBackup.makeRecord(from: cookie(session: true), existing: nil, now: now))
        XCTAssertNil(SessionBackup.makeRecord(from: cookie(expires: now - 1), existing: nil, now: now))
        XCTAssertNil(SessionBackup.makeRecord(from: cookie(expires: now), existing: nil, now: now))
        // expiry is capped at savedAt + 180 days (a far-future cookie cannot extend the server's absolute lifetime)
        let far = SessionBackup.makeRecord(from: cookie(expires: now + 3650 * day), existing: nil, now: now)
        XCTAssertEqual(far?.expires, now + 180 * day)
        // the same token keeps its original savedAt (and therefore its cap); another token starts over
        let old = record(tokenA, savedAt: now - 100 * day)
        let same = SessionBackup.makeRecord(from: cookie(expires: now + 3650 * day), existing: old, now: now)
        XCTAssertEqual(same?.savedAt, now - 100 * day)
        XCTAssertEqual(same?.expires, now - 100 * day + 180 * day)
        let other = SessionBackup.makeRecord(from: cookie(tokenB, expires: now + 50 * day), existing: old, now: now)
        XCTAssertEqual(other?.savedAt, now)
    }

    func testMakeCookieMirrorsServerCookie() throws {
        let c = try XCTUnwrap(SessionBackup.makeCookie(for: record(), host: host))
        XCTAssertEqual(c.name, "eve_session")
        XCTAssertEqual(c.value, tokenA)
        XCTAssertEqual(c.domain, host)                 // host-only: no leading dot
        XCTAssertEqual(c.path, "/")
        XCTAssertTrue(c.isSecure)
        XCTAssertTrue(c.isHTTPOnly)
        XCTAssertEqual(c.expiresDate?.timeIntervalSince1970 ?? 0, record().expires, accuracy: 1)
        #if !canImport(FoundationNetworking)
        XCTAssertEqual(c.sameSitePolicy, HTTPCookieStringPolicy.sameSiteStrict)   // Apple Foundation only
        #endif
        // and it is the cookie `sessionCookie` would pick up again
        XCTAssertNotNil(SessionBackup.sessionCookie(in: [c], host: host))
        // refused inputs
        XCTAssertNil(SessionBackup.makeCookie(for: record(), host: ""))
        XCTAssertNil(SessionBackup.makeCookie(for: record(), host: "a/b"))
        XCTAssertNil(SessionBackup.makeCookie(for: record(), host: "a:443"))
        XCTAssertNil(SessionBackup.makeCookie(for: SessionBackup.Record(token: "bad;value", expires: now + day, savedAt: now), host: host))
    }

    // MARK: launch decisions

    func testOnLaunchRestoresOnlyIntoAnEmptyStore() {
        let r = record()
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevoke: .tokens([]), now: now), .restore(r))
        // a cookie that is already there is never replaced
        XCTAssertEqual(SessionBackup.onLaunch(cookie: cookie(tokenB), stored: .record(r), pendingRevoke: .tokens([]), now: now), .none)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .none, pendingRevoke: .tokens([]), now: now), .none)
    }

    func testOnLaunchKeychainStates() {
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .unavailable, pendingRevoke: .tokens([]), now: now), .retryLater)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .corrupt, pendingRevoke: .tokens([]), now: now), .deleteBackup)
        // the pending-revoke list is not readable yet: do not decide
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record()), pendingRevoke: .unavailable, now: now), .retryLater)
        // ... but an expired record is deleted without needing it
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now - 200 * day)), pendingRevoke: .unavailable, now: now), .deleteBackup)
    }

    func testOnLaunchNeverRestoresExpiredFutureOrPendingRevoke() {
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now - 10 * day, expires: now - 1)), pendingRevoke: .tokens([]), now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now + 3 * day, expires: now + 100 * day)), pendingRevoke: .tokens([]), now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(tokenA)), pendingRevoke: .tokens([tokenA]), now: now), .deleteBackup)
        let r = record(tokenA)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevoke: .tokens([tokenB]), now: now), .restore(r))
    }

    // MARK: observer decisions

    private func observe(_ c: HTTPCookie?, _ stored: SessionBackup.Stored, seen: Bool = false, suspended: Bool = false) -> SessionBackup.ObserveAction {
        SessionBackup.onCookiesChanged(cookie: c, stored: stored, seenPresent: seen, suspended: suspended, now: now)
    }

    func testObserveSavesAFreshPairing() {
        let a = observe(cookie(), .none)
        XCTAssertEqual(a, .save(SessionBackup.Record(token: tokenA, expires: now + 180 * day, savedAt: now)))
        XCTAssertEqual(observe(cookie(), .corrupt), a)    // a corrupt item is simply overwritten
    }

    func testObserveUnchangedCookieWritesNothing() {
        let first = SessionBackup.makeRecord(from: cookie(), existing: nil, now: now - 3600)!
        XCTAssertEqual(observe(cookie(expires: now - 3600 + 180 * day), .record(first)), .none)
    }

    func testObserveRotatedTokenIsSaved() {
        let stored = record(tokenA)
        guard case .save(let r) = observe(cookie(tokenB), .record(stored)) else { return XCTFail("expected save") }
        XCTAssertEqual(r.token, tokenB)
        XCTAssertEqual(r.savedAt, now)
    }

    func testObserveDoesNothingWhileKeychainUnavailable() {
        XCTAssertEqual(observe(cookie(), .unavailable), .none)
        XCTAssertEqual(observe(nil, .unavailable, seen: true), .delete)   // a delete is still attempted: it is the safe direction
    }

    func testObserveAbsenceMeansLogoutOnlyAfterTheCookieWasSeen() {
        // empty store at launch (before the restore ran): the backup must survive
        XCTAssertEqual(observe(nil, .record(record()), seen: false), .none)
        // the cookie was there and is gone (web logout, expiry): delete the backup
        XCTAssertEqual(observe(nil, .record(record()), seen: true), .delete)
        XCTAssertEqual(observe(nil, .none, seen: true), .delete)
    }

    func testObserveIsSilentDuringUnpair() {
        XCTAssertEqual(observe(cookie(), .none, suspended: true), .none)
        XCTAssertEqual(observe(cookie(), .record(record(tokenB)), seen: true, suspended: true), .none)
        XCTAssertEqual(observe(nil, .record(record()), seen: true, suspended: true), .none)
    }

    func testObserveUnbackupableCookieDropsAnOlderBackup() {
        XCTAssertEqual(observe(cookie(session: true), .none), .none)
        XCTAssertEqual(observe(cookie(session: true), .record(record(tokenB))), .delete)
        XCTAssertEqual(observe(cookie(session: true), .corrupt), .delete)
    }

    // MARK: scenarios (the whole flow with the two pure functions)

    /// Tiny model of the app: a cookie store, a Keychain, the pending-revoke list and `seenPresent`.
    private struct Sim {
        var store: HTTPCookie?
        var keychain: SessionBackup.Stored = .none
        var pending: Set<String> = []
        var pendingCorrupt = false
        var deletePending = false
        var keychainDeleteFails = false
        var seen = false
        var suspended = false
        let now: TimeInterval

        mutating func launch() {
            let sel = store.flatMap { SessionBackup.sessionCookie(in: [$0], host: "eve.example.invalid") }
            switch SessionBackup.onLaunch(cookie: sel, stored: keychain, pendingRevoke: pendingCorrupt ? .corrupt : .tokens(pending),
                                          deletePending: deletePending, now: now) {
            case .restore(let r):
                store = webKit(SessionBackup.makeCookie(for: r, host: "eve.example.invalid"))
                // M-1: read back what WebKit kept and compare
                switch SessionBackup.checkRestored(token: r.token, in: store.map { [$0] } ?? [], host: "eve.example.invalid") {
                case .ok: seen = true
                case .missing, .mismatch:
                    store = nil; removeBackup(); pending.insert(r.token); seen = false
                }
            case .deleteBackup: removeBackup()
            case .discardAndRevoke(let r): pending.insert(r.token); pendingCorrupt = false; removeBackup()
            case .none, .retryLater: if sel != nil { seen = true }
            }
        }
        /// What WebKit does to a cookie we set (identity unless a test makes it misbehave).
        var webKit: (HTTPCookie?) -> HTTPCookie? = { $0 }
        mutating func removeBackup() {
            if keychainDeleteFails { deletePending = true } else { keychain = .none; deletePending = false }
        }
        mutating func storeChanged() {
            switch SessionBackup.onCookiesChanged(cookie: store.flatMap { SessionBackup.sessionCookie(in: [$0], host: "eve.example.invalid") },
                                                  stored: keychain, seenPresent: seen, suspended: suspended, deletePending: deletePending, now: now) {
            case .save(let r): keychain = .record(r); deletePending = false
            case .delete: removeBackup()
            case .none: break
            }
            if !suspended, store != nil { seen = true }
        }
        mutating func unpair() {
            suspended = true
            if let t = store?.value { pending.insert(t) }
            if case .record(let r) = keychain { pending.insert(r.token) }
            keychain = .none            // discardBackup
            store = nil                 // wipe
            suspended = false           // endUnpair
            seen = false
        }
    }

    func testScenarioPairThenReinstallKeepsThePairing() throws {
        var s = Sim(now: now)
        s.launch()                                            // first launch, nothing anywhere
        XCTAssertNil(s.store)
        s.store = cookie()                                    // user pairs
        s.storeChanged()
        guard case .record(let r) = s.keychain else { return XCTFail("not saved") }
        // app deleted and installed again: container (cookie store) is gone, the Keychain item is not
        s.store = nil; s.seen = false
        s.launch()
        XCTAssertEqual(s.store?.value, tokenA)
        XCTAssertEqual(s.keychain, .record(r))
        XCTAssertTrue(try XCTUnwrap(s.store).isHTTPOnly)
    }

    func testScenarioOverwriteInstallLeavesBothAlone() {
        var s = Sim(now: now)
        s.store = cookie(); s.storeChanged()
        let kc = s.keychain
        s.seen = false
        s.launch()                                            // container kept: cookie present, nothing restored
        XCTAssertEqual(s.store?.value, tokenA)
        XCTAssertEqual(s.keychain, kc)
    }

    func testScenarioUnpairLeavesNothingToRestore() {
        var s = Sim(now: now)
        s.store = cookie(); s.storeChanged()
        s.unpair()
        s.storeChanged()                                      // late callback after the wipe: store is empty
        XCTAssertEqual(s.keychain, .none)
        s.launch()                                            // next launch: nothing is restored
        XCTAssertNil(s.store)
    }

    func testScenarioUnpairWithBackupButEmptyStoreStillQueuesRevoke() {
        var s = Sim(now: now)
        s.keychain = .record(record(tokenA))                  // backup exists, cookie store empty (restore had not run)
        s.unpair()
        XCTAssertEqual(s.pending, [tokenA])
        XCTAssertEqual(s.keychain, .none)
    }

    func testScenarioFailedBackupDeleteIsNeverRestoredBecauseItIsPendingRevoke() {
        var s = Sim(now: now)
        s.store = cookie(); s.storeChanged()
        s.pending = [tokenA]                                   // unpair queued the revoke ...
        s.store = nil; s.seen = false                          // ... wiped the store ...
        s.launch()                                             // ... but the Keychain delete had failed
        XCTAssertNil(s.store)
        XCTAssertEqual(s.keychain, .none)
    }

    func testScenarioPairAgainAfterUnpairIsSaved() {
        var s = Sim(now: now)
        s.store = cookie(tokenA); s.storeChanged(); s.unpair()
        s.store = cookie(tokenB); s.storeChanged()
        guard case .record(let r) = s.keychain else { return XCTFail("not saved") }
        XCTAssertEqual(r.token, tokenB)
    }

    func testScenarioWebLogoutDeletesTheBackup() {
        var s = Sim(now: now)
        s.store = cookie(); s.storeChanged()
        s.store = nil                                          // Set-Cookie with Max-Age -1 from DELETE /v1/session
        s.storeChanged()
        XCTAssertEqual(s.keychain, .none)
    }

    func testScenarioExpiredBackupIsDroppedAtLaunch() {
        var s = Sim(now: now)
        s.keychain = .record(record(savedAt: now - 200 * day))
        s.launch()
        XCTAssertNil(s.store)
        XCTAssertEqual(s.keychain, .none)
    }

    // MARK: M-1: read-back guard after a restore

    func testAttributeMismatches() {
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(), host: host), [])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(domain: host.uppercased()), host: host), [])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(httpOnly: false), host: host), [.notHttpOnly])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(secure: false), host: host), [.notSecure])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(domain: "." + host), host: host), [.notHostOnly])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(path: "/ui"), host: host), [.wrongPath])
        XCTAssertEqual(SessionBackup.attributeMismatches(of: cookie(secure: false, httpOnly: false, path: "/x"), host: host),
                       [.notHttpOnly, .notSecure, .wrongPath])
    }

    func testCheckRestoredAcceptsOnlyTheServersCookieShape() throws {
        let restored = try XCTUnwrap(SessionBackup.makeCookie(for: record(), host: host))
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [restored], host: host), .ok)
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(tokenB, httpOnly: false), restored], host: host), .ok)   // other tokens are not ours
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [], host: host), .missing)
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(tokenB)], host: host), .missing)
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(domain: "other.example.invalid")], host: host), .missing)
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(httpOnly: false)], host: host), .mismatch([.notHttpOnly]))
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(secure: false)], host: host), .mismatch([.notSecure]))
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(domain: "." + host)], host: host), .mismatch([.notHostOnly]))
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(path: "/ui")], host: host), .mismatch([.wrongPath]))
        // a good cookie next to a domain-cookie twin is still a mismatch (the twin is sent to subdomains too)
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [restored, cookie(domain: "." + host)], host: host), .mismatch([.notHostOnly]))
        XCTAssertEqual(SessionBackup.checkRestored(token: tokenA, in: [cookie(httpOnly: false, path: "/a"), cookie(domain: "." + host, httpOnly: false)], host: host),
                       .mismatch([.notHttpOnly, .wrongPath, .notHostOnly]))
    }

    func testCookiesToRemoveCoversTheTokenOnTheHostWithAndWithoutDot() {
        let mine1 = cookie(), mine2 = cookie(domain: "." + host, httpOnly: false), mine3 = cookie(path: "/ui")
        let others = [cookie(tokenB), cookie(domain: "other.example.invalid"), cookie(name: "x")]
        let r = SessionBackup.cookiesToRemove(token: tokenA, in: others + [mine1, mine2, mine3], host: host)
        XCTAssertEqual(r.count, 3)
        XCTAssertTrue(r.allSatisfy { $0.value == tokenA && $0.name == "eve_session" })
    }

    func testScenarioWebKitStoresAWeakerCookieIsRejectedAndRevoked() {
        var s = Sim(now: now)
        s.keychain = .record(record(tokenA))
        // WebKit turns the host-only cookie into a domain cookie readable by scripts
        s.webKit = { c in c.flatMap { _ in HTTPCookie(properties: [.name: "eve_session", .value: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                                                                    .domain: "." + "eve.example.invalid", .path: "/", .secure: "TRUE"]) } }
        s.launch()
        XCTAssertNil(s.store)                                  // the cookie is removed again
        XCTAssertEqual(s.keychain, .none)                      // the backup is deleted
        XCTAssertEqual(s.pending, [tokenA])                    // and the token is queued for revoke
        XCTAssertFalse(s.seen)
        s.webKit = { $0 }
        s.launch()                                             // never restored afterwards
        XCTAssertNil(s.store)
    }

    func testScenarioWebKitDropsTheCookieIsAlsoRejected() {
        var s = Sim(now: now)
        s.keychain = .record(record(tokenA))
        s.webKit = { _ in nil }
        s.launch()
        XCTAssertNil(s.store)
        XCTAssertEqual(s.keychain, .none)
        XCTAssertEqual(s.pending, [tokenA])
    }

    func testScenarioAWeakCookieInTheStoreIsNeverBackedUp() {
        var s = Sim(now: now)
        s.store = cookie(httpOnly: false)                      // not the server's shape (e.g. set by a script)
        s.storeChanged()
        XCTAssertEqual(s.keychain, .none)
        s.store = cookie(domain: "." + host)
        s.storeChanged()
        XCTAssertEqual(s.keychain, .none)
    }

    // MARK: L-11: a failed delete is retried (also in a new process) and never restored meanwhile

    func testObserveRetriesAPendingDeleteEvenInANewProcess() {
        XCTAssertEqual(SessionBackup.onCookiesChanged(cookie: nil, stored: .record(record()), seenPresent: false, suspended: false,
                                                      deletePending: true, now: now), .delete)
        XCTAssertEqual(SessionBackup.onCookiesChanged(cookie: nil, stored: .record(record()), seenPresent: false, suspended: false,
                                                      deletePending: false, now: now), .none)
        // suspended wins (an unpair deletes it itself)
        XCTAssertEqual(SessionBackup.onCookiesChanged(cookie: nil, stored: .record(record()), seenPresent: true, suspended: true,
                                                      deletePending: true, now: now), .none)
    }

    func testOnLaunchPendingDeleteWinsOverRestore() {
        let r = record()
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevoke: .tokens([]), deletePending: true, now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .none, pendingRevoke: .tokens([]), deletePending: true, now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .unavailable, pendingRevoke: .tokens([]), deletePending: true, now: now), .retryLater)
        // an existing cookie is never touched
        XCTAssertEqual(SessionBackup.onLaunch(cookie: cookie(), stored: .record(r), pendingRevoke: .tokens([]), deletePending: true, now: now), .none)
    }

    func testScenarioFailedDeleteAfterWebLogoutIsRetriedAndNotRestored() {
        var s = Sim(now: now)
        s.store = cookie(); s.storeChanged()
        s.keychainDeleteFails = true
        s.store = nil; s.storeChanged()                        // web logout, the Keychain refuses the delete
        XCTAssertNotEqual(s.keychain, .none)
        XCTAssertTrue(s.deletePending)
        // new process, locked/failing Keychain still: the record is not restored
        s.seen = false
        s.launch()
        XCTAssertNil(s.store)
        XCTAssertTrue(s.deletePending)
        // Keychain works again at the next active/launch: deleted, flag cleared
        s.keychainDeleteFails = false
        s.launch()
        XCTAssertEqual(s.keychain, .none)
        XCTAssertFalse(s.deletePending)
        XCTAssertNil(s.store)
    }

    func testScenarioNewPairingClearsAFailedDeleteFlag() {
        var s = Sim(now: now)
        s.keychain = .record(record(tokenA)); s.deletePending = true
        s.store = cookie(tokenB); s.storeChanged()
        guard case .record(let r) = s.keychain else { return XCTFail("not saved") }
        XCTAssertEqual(r.token, tokenB)
        XCTAssertFalse(s.deletePending)
    }

    // MARK: L-13: a damaged pending-revoke list fails closed

    func testOnLaunchCorruptPendingListNeverRestores() {
        let r = record()
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevoke: .corrupt, now: now), .discardAndRevoke(r))
        // no backup, or an unusable one: nothing special
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .none, pendingRevoke: .corrupt, now: now), .none)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now - 200 * day)), pendingRevoke: .corrupt, now: now), .deleteBackup)
        // a cookie that is already there is left alone
        XCTAssertEqual(SessionBackup.onLaunch(cookie: cookie(), stored: .record(r), pendingRevoke: .corrupt, now: now), .none)
        // unreadable (locked) is "retry", not "restore"
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevoke: .unavailable, now: now), .retryLater)
    }

    func testScenarioCorruptPendingListDiscardsAndRevokesTheBackup() {
        var s = Sim(now: now)
        s.keychain = .record(record(tokenA)); s.pendingCorrupt = true
        s.launch()
        XCTAssertNil(s.store)
        XCTAssertEqual(s.keychain, .none)
        XCTAssertEqual(s.pending, [tokenA])
        XCTAssertFalse(s.pendingCorrupt)                       // persisting the revoke rewrote the list
    }
}
