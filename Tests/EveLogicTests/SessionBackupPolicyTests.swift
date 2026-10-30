import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SessionBackupPolicyTests: XCTestCase {
    private let host = "eve.example.invalid"
    private let day: TimeInterval = 86_400
    private let now: TimeInterval = 1_800_000_000
    private let tokenA = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"   // 43 chars, base64url alphabet
    private let tokenB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func cookie(_ value: String? = nil, name: String = "eve_session", domain: String? = nil, secure: Bool = true,
                        expires: TimeInterval? = nil, session: Bool = false) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value ?? tokenA, .domain: domain ?? host, .path: "/"]
        if secure { p[.secure] = "TRUE" }
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
        XCTAssertTrue(SessionBackup.isValidToken("Ab-_09" + String(repeating: "x", count: 10)))
        XCTAssertFalse(SessionBackup.isValidToken(""))
        XCTAssertFalse(SessionBackup.isValidToken(String(repeating: "a", count: 15)))
        XCTAssertFalse(SessionBackup.isValidToken(String(repeating: "a", count: 129)))
        XCTAssertTrue(SessionBackup.isValidToken(String(repeating: "a", count: 128)))
        for bad in ["a;Path=/;" + String(repeating: "a", count: 20), tokenA + " ", tokenA + "\n", tokenA + "=", "한글" + tokenA,
                    tokenA + "\u{0}", tokenA + ","] {
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
        XCTAssertNotNil(SessionBackup.sessionCookie(in: [cookie(domain: "." + host)], host: host))
        XCTAssertNotNil(SessionBackup.sessionCookie(in: [cookie(domain: host.uppercased())], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(name: "other")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(secure: false)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(domain: "other.example.invalid")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie(domain: "sub." + host)], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [cookie("short")], host: host))
        XCTAssertNil(SessionBackup.sessionCookie(in: [], host: host))
        // the right one wins among several
        let found = SessionBackup.sessionCookie(in: [cookie(domain: "other.example.invalid"), cookie(tokenB), cookie(name: "x")], host: host)
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
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevokeTokens: [], now: now), .restore(r))
        // a cookie that is already there is never replaced
        XCTAssertEqual(SessionBackup.onLaunch(cookie: cookie(tokenB), stored: .record(r), pendingRevokeTokens: [], now: now), .none)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .none, pendingRevokeTokens: [], now: now), .none)
    }

    func testOnLaunchKeychainStates() {
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .unavailable, pendingRevokeTokens: [], now: now), .retryLater)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .corrupt, pendingRevokeTokens: [], now: now), .deleteBackup)
        // the pending-revoke list is not readable yet: do not decide
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record()), pendingRevokeTokens: nil, now: now), .retryLater)
        // ... but an expired record is deleted without needing it
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now - 200 * day)), pendingRevokeTokens: nil, now: now), .deleteBackup)
    }

    func testOnLaunchNeverRestoresExpiredFutureOrPendingRevoke() {
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now - 10 * day, expires: now - 1)), pendingRevokeTokens: [], now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(savedAt: now + 3 * day, expires: now + 100 * day)), pendingRevokeTokens: [], now: now), .deleteBackup)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(record(tokenA)), pendingRevokeTokens: [tokenA], now: now), .deleteBackup)
        let r = record(tokenA)
        XCTAssertEqual(SessionBackup.onLaunch(cookie: nil, stored: .record(r), pendingRevokeTokens: [tokenB], now: now), .restore(r))
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
        var seen = false
        var suspended = false
        let now: TimeInterval

        mutating func launch() {
            switch SessionBackup.onLaunch(cookie: store, stored: keychain, pendingRevokeTokens: pending, now: now) {
            case .restore(let r): store = SessionBackup.makeCookie(for: r, host: "eve.example.invalid"); seen = true
            case .deleteBackup: keychain = .none
            case .none, .retryLater: if store != nil { seen = true }
            }
        }
        mutating func storeChanged() {
            switch SessionBackup.onCookiesChanged(cookie: store.flatMap { SessionBackup.sessionCookie(in: [$0], host: "eve.example.invalid") },
                                                  stored: keychain, seenPresent: seen, suspended: suspended, now: now) {
            case .save(let r): keychain = .record(r)
            case .delete: keychain = .none
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
}
