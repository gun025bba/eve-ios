import XCTest

final class RevokePolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testOutcomeMapping() {
        for c in [200, 204, 401] { XCTAssertEqual(RevokePolicy.outcome(forStatus: c), .done, "\(c)") }
        for c in [408, 429, 500, 502, 503, 599] { XCTAssertEqual(RevokePolicy.outcome(forStatus: c), .transient, "\(c)") }
        for c in [301, 302, 400, 403, 404, 410, 418] { XCTAssertEqual(RevokePolicy.outcome(forStatus: c), .permanent, "\(c)") }
    }

    func testExpiry() {
        let now: TimeInterval = 1_000_000_000
        XCTAssertEqual(RevokePolicy.expiry(savedAt: now, now: now), .fresh)
        XCTAssertEqual(RevokePolicy.expiry(savedAt: now - 29 * day, now: now), .fresh)
        XCTAssertEqual(RevokePolicy.expiry(savedAt: now - 30 * day, now: now), .expired)
        XCTAssertEqual(RevokePolicy.expiry(savedAt: now + 23 * 3600, now: now), .fresh)       // small skew tolerated
        XCTAssertEqual(RevokePolicy.expiry(savedAt: now + 25 * 3600, now: now), .clockSkew)   // clock moved back
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(RevokePolicy.minInterval(attempts: 0), 30)
        XCTAssertEqual(RevokePolicy.minInterval(attempts: 1), 60)
        XCTAssertEqual(RevokePolicy.minInterval(attempts: 3), 240)
        XCTAssertEqual(RevokePolicy.minInterval(attempts: 50), RevokePolicy.maxBackoff)
        XCTAssertEqual(RevokePolicy.minInterval(attempts: -5), 30)
    }

    func testShouldWaitTreatsFutureLastAttemptAsNever() {
        let now: TimeInterval = 1_000_000
        XCTAssertTrue(RevokePolicy.shouldWait(lastAttempt: now - 10, attempts: 0, now: now))
        XCTAssertFalse(RevokePolicy.shouldWait(lastAttempt: now - 31, attempts: 0, now: now))
        XCTAssertFalse(RevokePolicy.shouldWait(lastAttempt: 0, attempts: 0, now: now))
        // lastAttempt in the future (clock moved back): do not block retries.
        XCTAssertFalse(RevokePolicy.shouldWait(lastAttempt: now + 10 * day, attempts: 5, now: now))
    }

    func testGiveUpCaps() {
        XCTAssertFalse(RevokePolicy.shouldGiveUp(attempts: 2, permanentFailures: 2))
        XCTAssertTrue(RevokePolicy.shouldGiveUp(attempts: 3, permanentFailures: 3))
        XCTAssertFalse(RevokePolicy.shouldGiveUp(attempts: 9, permanentFailures: 0))
        XCTAssertTrue(RevokePolicy.shouldGiveUp(attempts: 10, permanentFailures: 0))
    }

    func testSameTokenKeepsCounters() {
        var l = PendingList()
        l.add(token: "A", now: 100)
        var e = l.entries[0]
        e.attempts = 4; e.permanentFailures = 2; e.lastAttempt = 150
        l.update(e)
        XCTAssertEqual(l.add(token: "A", now: 999), 0)
        XCTAssertEqual(l.entries.count, 1)
        XCTAssertEqual(l.entries[0].attempts, 4)
        XCTAssertEqual(l.entries[0].permanentFailures, 2)
        XCTAssertEqual(l.entries[0].savedAt, 100)
    }

    func testListIsBoundedAndDropsOldest() {
        var l = PendingList()
        XCTAssertEqual(l.add(token: "A", now: 1), 0)
        XCTAssertEqual(l.add(token: "B", now: 2), 0)
        XCTAssertEqual(l.add(token: "C", now: 3), 0)
        XCTAssertEqual(l.add(token: "D", now: 4), 1)
        XCTAssertEqual(l.entries.map(\.token), ["B", "C", "D"])
    }

    func testEmptyTokenIgnored() {
        var l = PendingList()
        XCTAssertEqual(l.add(token: "", now: 1), 0)
        XCTAssertTrue(l.isEmpty)
    }

    func testRemoveOnlyMatchingTokenAndUpdateKeepsSavedAt() {
        var l = PendingList()
        l.add(token: "A", now: 1); l.add(token: "B", now: 2)
        l.remove(token: "A")
        XCTAssertEqual(l.entries.map(\.token), ["B"])
        l.remove(token: "A")                       // already gone: no effect on B
        XCTAssertEqual(l.entries.map(\.token), ["B"])
        var changed = PendingEntry(token: "B", savedAt: 999); changed.attempts = 2
        l.update(changed)
        XCTAssertEqual(l.entries[0].savedAt, 2)
        XCTAssertEqual(l.entries[0].attempts, 2)
        l.update(PendingEntry(token: "gone", savedAt: 5))   // unknown token: no-op
        XCTAssertEqual(l.entries.count, 1)
    }

    func testRoundTrip() throws {
        var l = PendingList()
        l.add(token: "A", now: 10)
        let data = try XCTUnwrap(l.encode())
        XCTAssertEqual(PendingList.decode(data), l)
    }

    func testBareTokenAndGarbageAreNeverTokens() {
        XCTAssertNil(PendingList.decode(Data("abcdef0123456789".utf8)))
        XCTAssertNil(PendingList.decode(Data("\"abcdef\"".utf8)))
        XCTAssertNil(PendingList.decode(Data("{}".utf8)))
        XCTAssertNil(PendingList.decode(Data()))
        XCTAssertNil(PendingList.decode(Data([0xff, 0xfe, 0x00])))
    }

    func testUnsupportedVersionOversizeAndEmptyTokenRejected() {
        XCTAssertNil(PendingList.decode(Data(#"{"v":2,"entries":[{"token":"A","savedAt":1}]}"#.utf8)))
        XCTAssertNil(PendingList.decode(Data(#"{"v":1,"entries":[{"token":"","savedAt":1}]}"#.utf8)))
        let four = (1...4).map { #"{"token":"T\#($0)","savedAt":1}"# }.joined(separator: ",")
        XCTAssertNil(PendingList.decode(Data(#"{"v":1,"entries":[\#(four)]}"#.utf8)))
    }

    func testMissingBookkeepingFieldsDefault() throws {
        let l = try XCTUnwrap(PendingList.decode(Data(#"{"v":1,"entries":[{"token":"A","savedAt":5}]}"#.utf8)))
        XCTAssertEqual(l.entries[0].attempts, 0)
        XCTAssertEqual(l.entries[0].lastAttempt, 0)
        XCTAssertEqual(l.entries[0].permanentFailures, 0)
    }

    func testLegacySingleEntryIsMigrated() throws {
        let legacy = Data(#"{"token":"A","savedAt":5,"attempts":2,"lastAttempt":0,"permanentFailures":1}"#.utf8)
        let l = try XCTUnwrap(PendingList.decode(legacy))
        XCTAssertEqual(l.entries.map(\.token), ["A"])
        XCTAssertEqual(l.entries[0].attempts, 2)
        XCTAssertNil(PendingList.decode(Data(#"{"token":"","savedAt":5}"#.utf8)))
    }
}
