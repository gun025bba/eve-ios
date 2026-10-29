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
actor NotificationScheduler {
    private struct Entry { let fire: Date; let token: UInt64 }

    private let center: NotificationCentering
    private let isAppActive: @Sendable () async -> Bool
    private let now: @Sendable () -> Date

    private var accepted: [String: Entry] = [:]
    private var nextToken: UInt64 = 0
    private var seeded = false
    private var seedTask: Task<[PendingNotification], Never>?
    /// While closed (unpair in progress / not yet paired again) no new reminder is accepted.
    private var closed = false
    /// Incremented on every close: a schedule that was in flight across a close removes what it just added.
    private var epoch: UInt64 = 0
    /// Set when the unpair wipe has fully finished; the next `hello` of a new document reopens the scheduler.
    private var reopenArmed = false

    init(center: NotificationCentering,
         isAppActive: @escaping @Sendable () async -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.center = center
        self.isAppActive = isAppActive
        self.now = now
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
        accepted[identifier] = Entry(fire: now().addingTimeInterval(TimeInterval(afterSec)), token: token)
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
    func closeAndCancelAll() async {
        closed = true
        epoch &+= 1
        reopenArmed = false
        await cancelAll()
    }

    /// Unpair step 2 (after wipe + reload finished): drop whatever slipped in meanwhile and allow reopening.
    func finishUnpair() async {
        await cancelAll()
        reopenArmed = true
    }

    /// Called on the bridge `hello` of a document loaded after a finished unpair (next pairing).
    func pairingHello() {
        if closed, reopenArmed {
            closed = false
            reopenArmed = false
        }
    }

    var isClosed: Bool { closed }
    var acceptedCount: Int { accepted.count }

    // MARK: internals

    /// Forget entries whose fire time has passed (they were delivered and no longer count as pending).
    private func prune() {
        let t = now()
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
        let t = now()
        for p in items where p.identifier.hasPrefix(NotifyValidation.idPrefix) && accepted[p.identifier] == nil {
            nextToken &+= 1
            // Unknown fire time: assume the latest possible one (conservative for the limit).
            let fire = p.fireDate ?? t.addingTimeInterval(TimeInterval(NotifyValidation.maxAfterSec))
            accepted[p.identifier] = Entry(fire: fire, token: nextToken)
        }
    }
}
