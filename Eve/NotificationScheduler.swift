import Foundation

// Foundation-only so it can be unit-tested on the macOS runner with a fake center (see EveLogicTests).

enum NotifyAuthStatus: Sendable { case notDetermined, allowed, denied }

struct PendingNotification: Sendable, Equatable {
    let identifier: String
    let fireDate: Date?
}

/// Thin seam over UNUserNotificationCenter. All identifiers are full identifiers (prefix included).
protocol NotificationCentering: Sendable {
    func authorizationStatus() async -> NotifyAuthStatus
    func requestAuthorization() async
    func add(identifier: String, afterSec: Int) async throws
    func pending() async -> [PendingNotification]
    func removePending(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
    func removeAllDelivered() async
}

/// All state lives in this actor. The limit check and the reservation happen in ONE synchronous section (no `await`
/// between reading the count and adding to `accepted`), so concurrent bridge messages cannot exceed `maxPending`.
/// `accepted` is the shell's own bookkeeping (reserved + scheduled ids with their fire time), not a re-read of the
/// OS list, because actor methods are re-entrant at every `await`.
///
/// Time: fire times are kept on the monotonic `ProcessInfo.systemUptime` clock (L-7), so a wall-clock change (manual
/// time, timezone/NTP jump) can neither free a slot early nor keep one forever. `systemUptime` does not advance while
/// the device sleeps, so a slot can be freed later than the real fire time, never earlier: the limit stays safe.
/// The wall clock `now` is only used to translate the fire date of a reminder that survived an app restart.
///
/// Reopen (L-6): the scheduler is closed on unpair at document generation G (`Bridge.documentGeneration`). Only a
/// `hello` from a document with generation > G can reopen it, so a `hello` of the document that was current when
/// the unpair started (or any older one) can never do it.
actor NotificationScheduler {
    private struct Entry { let fire: TimeInterval; let token: UInt64 }

    private let center: NotificationCentering
    private let isAppActive: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    private var accepted: [String: Entry] = [:]
    private var nextToken: UInt64 = 0
    private var seeded = false
    private var seedTask: Task<[PendingNotification], Never>?
    /// While closed (unpair in progress / not yet paired again) no new reminder is accepted.
    private var closed = false
    /// Incremented on every close: a schedule that was in flight across a close removes what it just added.
    private var epoch: UInt64 = 0
    /// Set when the unpair wipe has fully finished; a `hello` of a newer document then reopens the scheduler.
    private var reopenArmed = false
    /// Document generation at the time of the last close. Only a `hello` with a larger generation may reopen.
    private var closedAtGeneration = 0
    /// Generation of a `hello` of a newer document that arrived before the wipe finished (before `reopenArmed`).
    /// It is remembered and honoured in `finishUnpair`.
    private var pendingHelloGeneration: Int?

    init(center: NotificationCentering,
         isAppActive: @escaping @Sendable () async -> Bool,
         now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.center = center
        self.isAppActive = isAppActive
        self.now = now
        self.uptime = uptime
    }

    // MARK: schedule

    func schedule(id: String, afterSec: Int) async -> NotifyFailure? {
        await ensureSeeded()
        if closed { return .failed }

        // Authorization. The system prompt is only ever triggered while the app is active.
        var status = await center.authorizationStatus()
        if status == .notDetermined {
            guard await isAppActive() else { return .permissionDenied }   // defer: the web retries while visible
            await center.requestAuthorization()
            status = await center.authorizationStatus()
        }
        guard status == .allowed else { return .permissionDenied }

        // ---- atomic section: no `await` between the closed check, the count and the reservation ----
        if closed { return .failed }
        let identifier = NotifyValidation.idPrefix + id
        prune()
        if accepted[identifier] == nil, accepted.count >= NotifyValidation.maxPending { return .limitReached }
        nextToken &+= 1
        let token = nextToken
        let myEpoch = epoch
        accepted[identifier] = Entry(fire: uptime() + TimeInterval(afterSec), token: token)
        // ---- end atomic section ----

        do { try await center.add(identifier: identifier, afterSec: afterSec) }
        catch {
            if accepted[identifier]?.token == token { accepted[identifier] = nil }
            return .failed
        }
        if epoch != myEpoch {                       // unpair happened while the add was in flight
            await center.removePending([identifier])
            return .failed
        }
        if accepted[identifier] == nil {            // cancelled while the add was in flight
            await center.removePending([identifier])
        }
        return nil
    }

    // MARK: cancel / unpair

    /// Idempotent: forgets the id and removes the pending and the delivered notification.
    func cancel(id: String) async {
        await ensureSeeded()
        let identifier = NotifyValidation.idPrefix + id
        accepted[identifier] = nil
        await center.removePending([identifier])
        await center.removeDelivered([identifier])
    }

    /// Everything of this app that is scheduled or delivered.
    func cancelAll() async {
        await ensureSeeded()
        var ids = Set(accepted.keys)
        for p in await center.pending() where p.identifier.hasPrefix(NotifyValidation.idPrefix) { ids.insert(p.identifier) }
        accepted.removeAll()
        await center.removePending(Array(ids))
        await center.removeAllDelivered()
    }

    /// Unpair step 1 (before the wipe): refuse new reminders and drop everything.
    /// `generation` is the current `Bridge.documentGeneration`; only a `hello` of a later document can reopen.
    /// A second unpair while still closed keeps the larger generation and forgets any remembered `hello`.
    /// Returns the epoch this close created. The caller hands it to `finishUnpair(epoch:)` so that only the LAST
    /// unpair can arm the reopen (L-8): the epoch is taken synchronously, before the first `await`.
    @discardableResult
    func closeAndCancelAll(generation: Int) async -> UInt64 {
        closed = true
        epoch &+= 1
        let mine = epoch
        reopenArmed = false
        closedAtGeneration = max(closedAtGeneration, generation)
        pendingHelloGeneration = nil
        await cancelAll()
        return mine
    }

    /// Unpair step 2 (after wipe + reload finished): drop whatever slipped in meanwhile and allow reopening.
    /// `epoch` is the value `closeAndCancelAll` returned for THIS unpair. If another unpair closed the scheduler
    /// after that (its wipe is still running), the newer unpair owns the state: this one only cancels again and
    /// does not arm (L-8). If a `hello` of a newer document already arrived, the scheduler opens now.
    func finishUnpair(epoch mine: UInt64) async {
        await cancelAll()
        guard epoch == mine else { return }
        reopenArmed = true
        if let g = pendingHelloGeneration, g > closedAtGeneration { open() }
    }

    /// Called on every bridge `hello`, with the generation of the document that sent it.
    /// Reopens only when closed, the document is newer than the one current at close time, and the wipe finished;
    /// a newer document's `hello` that comes first is remembered for `finishUnpair`.
    func pairingHello(generation: Int) {
        guard closed, generation > closedAtGeneration else { return }
        if reopenArmed { open() } else { pendingHelloGeneration = generation }
    }

    private func open() {
        closed = false
        reopenArmed = false
        pendingHelloGeneration = nil
    }

    var isClosed: Bool { closed }
    var acceptedCount: Int { accepted.count }

    // MARK: internals

    /// Forget entries whose fire time has passed (they were delivered and no longer count as pending).
    private func prune() {
        let t = uptime()
        accepted = accepted.filter { $0.value.fire > t }
    }

    /// Once: adopt reminders that survived an app restart so the limit also counts them.
    private func ensureSeeded() async {
        if seeded { return }
        let task: Task<[PendingNotification], Never> = seedTask ?? Task { [center] in await center.pending() }
        seedTask = task
        let items = await task.value
        if seeded { return }
        seeded = true
        let wall = now()
        let up = uptime()
        for p in items where p.identifier.hasPrefix(NotifyValidation.idPrefix) && accepted[p.identifier] == nil {
            nextToken &+= 1
            // Translate the wall-clock fire date into the monotonic clock once. Unknown fire time: assume the
            // latest possible one (conservative for the limit). The wait never exceeds `maxAfterSec`.
            let remaining = p.fireDate.map { min(max($0.timeIntervalSince(wall), 0), TimeInterval(NotifyValidation.maxAfterSec)) }
                ?? TimeInterval(NotifyValidation.maxAfterSec)
            accepted[p.identifier] = Entry(fire: up + remaining, token: nextToken)
        }
    }
}
