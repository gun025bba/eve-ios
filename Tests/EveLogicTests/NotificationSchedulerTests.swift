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
    private var fireDates: [String: Date] = [:]   // what `pending()` reports as the fire date of seeded entries
    // Optional gates: while closed, `add` / `pending` suspend until `release...()` so a test can interleave other calls.
    private var holdAdd = false
    private var addWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var addStarted = 0
    private var holdPending = false
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingStarted = 0

    init(status: NotifyAuthStatus = .allowed, grantOnRequest: Bool = true) {
        self.status = status
        self.grantOnRequest = grantOnRequest
    }

    func setSeed(_ s: [PendingNotification]) { seed = s; for p in s { scheduled[p.identifier] = 0; fireDates[p.identifier] = p.fireDate } }
    func setFailAdd(_ v: Bool) { failAdd = v }
    func setHoldAdd(_ v: Bool) { holdAdd = v }
    func setHoldPending(_ v: Bool) { holdPending = v }
    func releaseAdd() {
        holdAdd = false
        let w = addWaiters; addWaiters = []
        for c in w { c.resume() }
    }
    func releasePending() {
        holdPending = false
        let w = pendingWaiters; pendingWaiters = []
        for c in w { c.resume() }
    }
    func markDelivered(_ id: String) { delivered.insert(id) }
    func markScheduledForTest(_ id: String) { scheduled[id] = 0 }

    func authorizationStatus() async -> NotifyAuthStatus { status }
    func requestAuthorization() async {
        requestCount += 1
        if status == .notDetermined { status = grantOnRequest ? .allowed : .denied }
    }
    func add(identifier: String, afterSec: Int) async throws {
        addStarted += 1
        let fails = failAdd                          // decided when the call starts, not when it resumes
        if holdAdd { await withCheckedContinuation { addWaiters.append($0) } }
        await Task.yield()
        if fails { throw NSError(domain: "fake", code: 1) }
        scheduled[identifier] = afterSec
    }
    func pending() async -> [PendingNotification] {
        pendingStarted += 1
        if holdPending { await withCheckedContinuation { pendingWaiters.append($0) } }
        return scheduled.keys.map { PendingNotification(identifier: $0, fireDate: fireDates[$0] ?? nil) }
    }
    func removePending(_ ids: [String]) async { for i in ids { scheduled[i] = nil } }
    func removeDelivered(_ ids: [String]) async { for i in ids { delivered.remove(i) } }
    func removeAllDelivered() async { delivered.removeAll() }
}

/// Mutable clock for the tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    private var up: TimeInterval = 5_000
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    var uptime: TimeInterval { lock.lock(); defer { lock.unlock() }; return up }
    /// Real time passes: both clocks move.
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); up += s; lock.unlock() }
    /// The user (or NTP) changes the wall clock; the monotonic clock does not move.
    func jumpWallClock(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class NotificationSchedulerTests: XCTestCase {
    private func make(_ center: FakeCenter, active: Bool = true, clock: TestClock = TestClock()) -> NotificationScheduler {
        NotificationScheduler(center: center, isAppActive: { active }, now: { clock.now }, uptime: { clock.uptime })
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
        let e1 = await s.closeAndCancelAll(generation: 1)
        var sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
        let closedNow = await s.isClosed
        XCTAssertTrue(closedNow)
        let refused = await s.schedule(id: "b", afterSec: 30)
        XCTAssertEqual(refused, .failed)

        await s.pairingHello(generation: 2)          // newer document, wipe not finished yet: stays closed (remembered)
        let stillClosed = await s.isClosed
        XCTAssertTrue(stillClosed)

        await s.finishUnpair(epoch: e1)
        // L-6: the newer document's hello arrived before the wipe finished, so finishing opens it right away.
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
        let e1 = await s.closeAndCancelAll(generation: 1)
        // Something got into the system list anyway (e.g. an add in flight across the close).
        await center.setSeed([PendingNotification(identifier: NotifyValidation.idPrefix + "late", fireDate: nil)])
        await s.finishUnpair(epoch: e1)
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

    // MARK: L-6 hello bound to the document generation

    private func isClosed(_ s: NotificationScheduler) async -> Bool { await s.isClosed }

    /// The page that was current when the unpair started (or an older one) must never reopen the scheduler.
    func testHelloOfOldOrSameDocumentNeverReopens() async {
        let s = make(FakeCenter())
        let e1 = await s.closeAndCancelAll(generation: 5)
        await s.finishUnpair(epoch: e1)                       // armed
        for g in [0, 3, 5] {
            await s.pairingHello(generation: g)
            let c = await s.isClosed
            XCTAssertTrue(c, "generation \(g) must not reopen")
        }
        await s.pairingHello(generation: 6)
        let c = await s.isClosed
        XCTAssertFalse(c)
    }

    /// Armed, but the hello comes from the old document: nothing is remembered for later either.
    func testOldHelloBeforeArmedIsNotRemembered() async {
        let s = make(FakeCenter())
        let e1 = await s.closeAndCancelAll(generation: 5)
        await s.pairingHello(generation: 5)
        await s.pairingHello(generation: 4)
        await s.finishUnpair(epoch: e1)
        let c = await s.isClosed
        XCTAssertTrue(c)
    }

    /// A newer document's hello that arrives before `finishUnpair` is recorded and opens in `finishUnpair`.
    func testNewerHelloBeforeFinishIsRecordedAndOpensAtFinish() async {
        let s = make(FakeCenter())
        let e1 = await s.closeAndCancelAll(generation: 5)
        await s.pairingHello(generation: 6)
        let before = await s.isClosed
        XCTAssertTrue(before)                        // not armed yet
        await s.finishUnpair(epoch: e1)
        let after = await s.isClosed
        XCTAssertFalse(after)
        let r = await s.schedule(id: "a", afterSec: 30)
        XCTAssertNil(r)
    }

    /// A newer document that has not said hello yet: finishing alone does not open.
    func testFinishWithoutHelloStaysClosedUntilNewerHello() async {
        let s = make(FakeCenter())
        let e1 = await s.closeAndCancelAll(generation: 5)
        await s.finishUnpair(epoch: e1)
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.pairingHello(generation: 6)
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    /// Opening is one-shot: a later close at a higher generation needs a still newer document.
    func testSecondUnpairNeedsAnotherNewerDocument() async {
        let s = make(FakeCenter())
        _ = await s.closeAndCancelAll(generation: 5)
        await s.pairingHello(generation: 6)          // remembered
        let e2 = await s.closeAndCancelAll(generation: 7)     // second unpair before the first finished: remembered hello is dropped
        await s.finishUnpair(epoch: e2)
        var c = await s.isClosed
        XCTAssertTrue(c)
        await s.pairingHello(generation: 6)
        await s.pairingHello(generation: 7)
        c = await s.isClosed
        XCTAssertTrue(c)
        await s.pairingHello(generation: 8)
        c = await s.isClosed
        XCTAssertFalse(c)
    }

    /// A close at a lower generation never lowers the bar of an earlier close.
    func testCloseKeepsLargestGeneration() async {
        let s = make(FakeCenter())
        _ = await s.closeAndCancelAll(generation: 9)
        let e2 = await s.closeAndCancelAll(generation: 2)
        await s.finishUnpair(epoch: e2)
        await s.pairingHello(generation: 5)
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.pairingHello(generation: 10)
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    /// While the scheduler is open a hello changes nothing, whatever its generation.
    func testHelloWhenOpenIsNoop() async {
        let s = make(FakeCenter())
        await s.pairingHello(generation: 1)
        let c = await s.isClosed
        XCTAssertFalse(c)
    }

    /// A second unpair that starts while the first `finishUnpair` is still cancelling owns the state: the first one
    /// must not arm the reopen (a hello of the document of the second unpair's wipe must not slip through early).
    func testFinishOverlappedByNewCloseDoesNotArm() async {
        let center = FakeCenter()
        let s = make(center)
        let e1 = await s.closeAndCancelAll(generation: 5)
        await center.setHoldPending(true)
        let base = await center.pendingStarted
        let first = Task { await s.finishUnpair(epoch: e1) }
        while await center.pendingStarted <= base { await Task.yield() }   // first finish is inside cancelAll
        await center.setHoldPending(false)
        let e2 = await s.closeAndCancelAll(generation: 6)                       // second unpair overlaps
        await center.releasePending()
        await first.value
        await s.pairingHello(generation: 7)                            // newer than both, but nothing is armed
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.finishUnpair(epoch: e2)                                         // the second unpair finishes: remembered hello opens
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    // MARK: L-8 overlapping unpairs: only the last one arms the reopen

    /// A closes (g5), B closes (g6) while A's wipe is still running, A's `finishUnpair` starts only afterwards.
    /// A is stale (epoch of A != current epoch): it must not arm, so a newer document's hello stays closed until B finishes.
    func testFirstFinishAfterSecondCloseDoesNotArm() async {
        let s = make(FakeCenter())
        let a = await s.closeAndCancelAll(generation: 5)
        let b = await s.closeAndCancelAll(generation: 6)
        XCTAssertNotEqual(a, b)
        await s.finishUnpair(epoch: a)                 // stale: B owns the state
        await s.pairingHello(generation: 7)            // newer than both, but nothing is armed
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.finishUnpair(epoch: b)                 // B finishes: the remembered hello opens
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    /// B finishes first, A's late finish must neither re-close nor change anything.
    func testStaleFinishAfterLastFinishIsHarmless() async {
        let s = make(FakeCenter())
        let a = await s.closeAndCancelAll(generation: 5)
        let b = await s.closeAndCancelAll(generation: 6)
        await s.finishUnpair(epoch: b)                 // armed
        await s.finishUnpair(epoch: a)                 // stale, late
        await s.pairingHello(generation: 6)            // same document as B's close: no
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.pairingHello(generation: 7)            // armed by B: opens
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    /// A stale finish still cancels again (it is harmless and keeps the "drop what slipped in" guarantee).
    func testStaleFinishStillCancelsEverything() async {
        let center = FakeCenter()
        let s = make(center)
        let a = await s.closeAndCancelAll(generation: 1)
        _ = await s.closeAndCancelAll(generation: 2)
        await center.markScheduledForTest("eve.notify.x")
        await s.finishUnpair(epoch: a)
        let sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
        let c = await s.isClosed
        XCTAssertTrue(c)
    }

    /// Three unpairs in a row: only the epoch of the last close arms.
    func testOnlyLastOfThreeUnpairsArms() async {
        let s = make(FakeCenter())
        let a = await s.closeAndCancelAll(generation: 1)
        let b = await s.closeAndCancelAll(generation: 2)
        let c = await s.closeAndCancelAll(generation: 3)
        await s.finishUnpair(epoch: b)
        await s.finishUnpair(epoch: a)
        await s.pairingHello(generation: 4)
        let stillClosed = await s.isClosed
        XCTAssertTrue(stillClosed)
        await s.finishUnpair(epoch: c)
        let open = await s.isClosed
        XCTAssertFalse(open)
    }

    /// Two unpairs that really overlap in time (the first wipe is slow): the first finish arriving after the second
    /// close must not arm even when the first close itself was still cancelling when the second started.
    func testSecondCloseDuringFirstCloseCancelling() async {
        let center = FakeCenter()
        let s = make(center)
        await s.cancel(id: "warm")                                         // seed first, so the gate below hits cancelAll's own `pending()`
        await center.setHoldPending(true)
        let base = await center.pendingStarted
        let first = Task { await s.closeAndCancelAll(generation: 5) }
        while await center.pendingStarted <= base { await Task.yield() }   // first close is inside cancelAll
        await center.setHoldPending(false)
        let b = await s.closeAndCancelAll(generation: 6)                   // second unpair starts meanwhile
        await center.releasePending()
        let a = await first.value
        XCTAssertNotEqual(a, b)
        await s.finishUnpair(epoch: a)
        await s.pairingHello(generation: 7)
        let c = await s.isClosed
        XCTAssertTrue(c)
        await s.finishUnpair(epoch: b)
        let o = await s.isClosed
        XCTAssertFalse(o)
    }

    // MARK: L-7 races with an add in flight

    private func waitForAddStarted(_ center: FakeCenter) async {
        while await center.addStarted < 1 { await Task.yield() }
    }

    /// close while the add is in flight: the add result is `notify_failed` and the reminder is removed again.
    func testCloseWhileAddInFlightRemovesReminder() async {
        let center = FakeCenter()
        await center.setHoldAdd(true)
        let s = make(center)
        let inFlight = Task { await s.schedule(id: "a", afterSec: 30) }
        await waitForAddStarted(center)
        let e1 = await s.closeAndCancelAll(generation: 1)
        await center.releaseAdd()
        let r = await inFlight.value
        XCTAssertEqual(r, .failed)
        let sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
        let n = await s.acceptedCount
        XCTAssertEqual(n, 0)
        await s.finishUnpair(epoch: e1)
        let sched2 = await center.scheduled
        XCTAssertTrue(sched2.isEmpty)
    }

    /// cancel while the add is in flight: the reminder that lands afterwards is removed, nothing stays counted.
    func testCancelWhileAddInFlightRemovesReminder() async {
        let center = FakeCenter()
        await center.setHoldAdd(true)
        let s = make(center)
        let inFlight = Task { await s.schedule(id: "a", afterSec: 30) }
        await waitForAddStarted(center)
        await s.cancel(id: "a")
        await center.releaseAdd()
        _ = await inFlight.value
        let sched = await center.scheduled
        XCTAssertTrue(sched.isEmpty)
        let n = await s.acceptedCount
        XCTAssertEqual(n, 0)
    }

    /// An add that fails after a cancel and a new schedule of the same id must not drop the new entry's slot.
    func testFailedAddDoesNotReleaseNewerEntryOfSameID() async {
        let center = FakeCenter()
        await center.setHoldAdd(true)
        await center.setFailAdd(true)
        let s = make(center)
        let first = Task { await s.schedule(id: "a", afterSec: 30) }
        await waitForAddStarted(center)
        await s.cancel(id: "a")
        await center.setFailAdd(false)
        let second = Task { await s.schedule(id: "a", afterSec: 60) }
        while await center.addStarted < 2 { await Task.yield() }
        await center.releaseAdd()
        _ = await first.value
        let r2 = await second.value
        XCTAssertNil(r2)
        let n = await s.acceptedCount
        XCTAssertEqual(n, 1)
    }

    /// 8 in flight, a ninth is refused while they are still being added (the reservation is made before the add).
    func testLimitHoldsWhileAddsAreInFlight() async {
        let center = FakeCenter()
        await center.setHoldAdd(true)
        let s = make(center)
        var tasks: [Task<NotifyFailure?, Never>] = []
        for i in 0..<NotifyValidation.maxPending { tasks.append(Task { await s.schedule(id: "g\(i)", afterSec: 30) }) }
        while await center.addStarted < NotifyValidation.maxPending { await Task.yield() }
        let ninth = await s.schedule(id: "extra", afterSec: 30)
        XCTAssertEqual(ninth, .limitReached)
        await center.releaseAdd()
        for t in tasks { let r = await t.value; XCTAssertNil(r) }
    }

    // MARK: L-7 monotonic clock

    /// Moving the wall clock forward must not free slots early; moving it back must not keep them forever.
    func testWallClockJumpsDoNotAffectSlots() async {
        let center = FakeCenter()
        let clock = TestClock()
        let s = make(center, clock: clock)
        for i in 0..<8 { _ = await s.schedule(id: "g\(i)", afterSec: 30) }
        clock.jumpWallClock(+86_400)                 // wall clock a day ahead
        let stillFull = await s.schedule(id: "x", afterSec: 30)
        XCTAssertEqual(stillFull, .limitReached)
        clock.jumpWallClock(-172_800)                // two days back
        clock.advance(31)                            // real time passes
        let freed = await s.schedule(id: "x", afterSec: 30)
        XCTAssertNil(freed)
    }

    /// A reminder from a previous run is seeded with its remaining time on the monotonic clock.
    func testSeededEntryExpiresAfterItsRemainingTime() async {
        let center = FakeCenter()
        let clock = TestClock()
        let seed = (0..<8).map { PendingNotification(identifier: NotifyValidation.idPrefix + "old\($0)", fireDate: clock.now.addingTimeInterval(60)) }
        await center.setSeed(seed)
        let s = make(center, clock: clock)
        let full = await s.schedule(id: "new", afterSec: 30)
        XCTAssertEqual(full, .limitReached)
        clock.advance(61)
        let freed = await s.schedule(id: "new", afterSec: 30)
        XCTAssertNil(freed)
    }

    /// A seed whose fire date is far in the future (clock changed) is capped at the maximum delay.
    func testSeededFarFutureEntryIsCapped() async {
        let center = FakeCenter()
        let clock = TestClock()
        await center.setSeed((0..<8).map { PendingNotification(identifier: NotifyValidation.idPrefix + "old\($0)", fireDate: clock.now.addingTimeInterval(10_000_000)) })
        let s = make(center, clock: clock)
        let full = await s.schedule(id: "new", afterSec: 30)
        XCTAssertEqual(full, .limitReached)
        clock.advance(TimeInterval(NotifyValidation.maxAfterSec) + 1)
        let freed = await s.schedule(id: "new", afterSec: 30)
        XCTAssertNil(freed)
    }
}
