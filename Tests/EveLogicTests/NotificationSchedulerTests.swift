import XCTest

/// In-memory center. `add` suspends once, so concurrent callers really interleave at that point.
actor FakeCenter: NotificationCentering {
    var status: NotifyAuthStatus
    var grantOnRequest: Bool
    private(set) var requestCount = 0
    private(set) var scheduled: [String: Int] = [:]
    private(set) var delivered: Set<String> = []
    var failAdd = false
    var seed: [PendingNotification] = []

    init(status: NotifyAuthStatus = .allowed, grantOnRequest: Bool = true) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    func setSeed(_ s: [PendingNotification]) { seed = s; for p in s { scheduled[p.identifier] = 0 } }
    func setFailAdd(_ v: Bool) { failAdd = v }
    func markDelivered(_ id: String) { delivered.insert(id) }

    func authorizationStatus() async -> NotifyAuthStatus { status }
    func requestAuthorization() async {
        requestCount += 1
        if status == .notDetermined { status = grantOnRequest ? .allowed : .denied }
    }
    func add(identifier: String, afterSec: Int) async throws {
        await Task.yield()
        if failAdd { throw NSError(domain: "fake", code: 1) }
        scheduled[identifier] = afterSec
    }
    func pending() async -> [PendingNotification] {
        scheduled.keys.map { PendingNotification(identifier: $0, fireDate: nil) }
    }
    func removePending(_ ids: [String]) async { for i in ids { scheduled[i] = nil } }
    func removeDelivered(_ ids: [String]) async { for i in ids { delivered.remove(i) } }
    func removeAllDelivered() async { delivered.removeAll() }
}

/// Mutable clock for the tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class NotificationSchedulerTests: XCTestCase {
    private func make(_ center: FakeCenter, active: Bool = true, clock: TestClock = TestClock()) -> NotificationScheduler {
        NotificationScheduler(center: center, isAppActive: { active }, now: { clock.now })
    }

    // M-1: one Task per bridge message, many in flight at once.
    func testConcurrentSchedulesNeverExceedLimit() async {
        let center = FakeCenter()
        let s = make(center)
        let results = await withTaskGroup(of: NotifyFailure?.self, returning: [NotifyFailure?].self) { group in
            for i in 0..<20 { group.addTask { await s.schedule(id: "gen-\(i)", afterSec: 30) } }
            var out: [NotifyFailure?] = []
            for await r in group { out.append(r) }
            return out
        }
        let accepted = results.filter { $0 == nil }.count
        XCTAssertEqual(accepted, NotifyValidation.maxPending)
        XCTAssertEqual(results.filter { $0 == .limitReached }.count, 20 - NotifyValidation.maxPending)
        let scheduledCount = await center.scheduled.count
        XCTAssertEqual(scheduledCount, NotifyValidation.maxPending)
    }

    func testSameIDReplacesAndDoesNotCountTwice() async {
        let center = FakeCenter()
        let s = make(center)
        for _ in 0..<5 { let r = await s.schedule(id: "same", afterSec: 30); XCTAssertNil(r) }
        let n = await s.acceptedCount
        XCTAssertEqual(n, 1)
        // Fill up, then re-scheduling an existing id is still allowed at the limit.
        for i in 0..<7 { let r = await s.schedule(id: "o\(i)", afterSec: 30); XCTAssertNil(r) }
        let again = await s.schedule(id: "same", afterSec: 60)
        XCTAssertNil(again)
        let over = await s.schedule(id: "extra", afterSec: 30)
        XCTAssertEqual(over, .limitReached)
    }

    func testFiredEntriesFreeTheirSlot() async {
        let center = FakeCenter()
        let clock = TestClock()
        let s = make(center, clock: clock)
        for i in 0..<8 { let r = await s.schedule(id: "g\(i)", afterSec: 30); XCTAssertNil(r) }
        let full = await s.schedule(id: "x", afterSec: 30)
        XCTAssertEqual(full, .limitReached)
        clock.advance(31)
        let after = await s.schedule(id: "x", afterSec: 30)
        XCTAssertNil(after)
    }

    func testCancelFreesSlot() async {
        let center = FakeCenter()
        let s = make(center)
        for i in 0..<8 { _ = await s.schedule(id: "g\(i)", afterSec: 30) }
        await s.cancel(id: "g3")
        let r = await s.schedule(id: "new", afterSec: 30)
        XCTAssertNil(r)
        let sched = await center.scheduled
        XCTAssertNil(sched[NotifyValidation.idPrefix + "g3"])
    }

    func testFailedAddReleasesReservation() async {
        let center = FakeCenter()
        await center.setFailAdd(true)
        let s = make(center)
        let r = await s.schedule(id: "a", afterSec: 30)
        XCTAssertEqual(r, .failed)
        let n = await s.acceptedCount
        XCTAssertEqual(n, 0)
    }

    // Reminders that survived an app restart count against the limit.
    func testSeedFromSystemPending() async {
        let center = FakeCenter()
        let clock = TestClock()
        let seed = (0..<8).map { PendingNotification(identifier: NotifyValidation.idPrefix + "old\($0)", fireDate: clock.now.addingTimeInterval(600)) }
        await center.setSeed(seed + [PendingNotification(identifier: "other.app.thing", fireDate: nil)])
        let s = make(center, clock: clock)
        let r = await s.schedule(id: "new", afterSec: 30)
        XCTAssertEqual(r, .limitReached)
    }

    // L-1
    func testClosedRefusesAndReopensOnlyAfterFinishedUnpairAndHello() async {
        let center = FakeCenter()
        let s = make(center)
        _ = await s.schedule(id: "a", afterSec: 30)
        await s.closeAndCancelAll()
        var sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
        let closedNow = await s.isClosed
        XCTAssertTrue(closedNow)
        let refused = await s.schedule(id: "b", afterSec: 30)
        XCTAssertEqual(refused, .failed)

        await s.pairingHello()                       // wipe not finished yet: stays closed
        let stillClosed = await s.isClosed
        XCTAssertTrue(stillClosed)

        await s.finishUnpair()
        let closedAfterFinish = await s.isClosed
        XCTAssertTrue(closedAfterFinish)             // finishing alone does not reopen
        await s.pairingHello()
        let reopened = await s.isClosed
        XCTAssertFalse(reopened)
        let ok = await s.schedule(id: "c", afterSec: 30)
        XCTAssertNil(ok)
        sched = await center.scheduled
        XCTAssertEqual(Array(sched.keys), [NotifyValidation.idPrefix + "c"])
    }

    func testFinishUnpairRemovesReminderThatSlippedIn() async {
        let center = FakeCenter()
        let s = make(center)
        await s.closeAndCancelAll()
        // Something got into the system list anyway (e.g. an add in flight across the close).
        await center.setSeed([PendingNotification(identifier: NotifyValidation.idPrefix + "late", fireDate: nil)])
        await s.finishUnpair()
        let sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
    }

    func testCancelAllClearsDelivered() async {
        let center = FakeCenter()
        await center.markDelivered("x")
        let s = make(center)
        await s.cancelAll()
        let d = await center.delivered
        XCTAssertTrue(d.isEmpty)
    }

    // L-2
    func testNoPromptWhenAppNotActive() async {
        let center = FakeCenter(status: .notDetermined)
        let s = make(center, active: false)
        let r = await s.schedule(id: "a", afterSec: 30)
        XCTAssertEqual(r, .permissionDenied)
        let n = await center.requestCount
        XCTAssertEqual(n, 0)
        let count = await s.acceptedCount
        XCTAssertEqual(count, 0)
    }

    func testPromptWhenActiveThenScheduled() async {
        let center = FakeCenter(status: .notDetermined)
        let s = make(center, active: true)
        let r = await s.schedule(id: "a", afterSec: 30)
        XCTAssertNil(r)
        let n = await center.requestCount
        XCTAssertEqual(n, 1)
    }

    func testDeniedAndDeclinedPrompt() async {
        let denied = FakeCenter(status: .denied)
        let r1 = await make(denied).schedule(id: "a", afterSec: 30)
        XCTAssertEqual(r1, .permissionDenied)
        let declines = FakeCenter(status: .notDetermined, grantOnRequest: false)
        let r2 = await make(declines).schedule(id: "a", afterSec: 30)
        XCTAssertEqual(r2, .permissionDenied)
    }

    /// Already authorized: scheduling while the app is going to the background must still work.
    func testAuthorizedSchedulesWhileInactive() async {
        let center = FakeCenter(status: .allowed)
        let r = await make(center, active: false).schedule(id: "a", afterSec: 30)
        XCTAssertNil(r)
    }
}
