import Foundation
import WebKit

/// Keeps the pairing across reinstalls (design: docs/session-persistence.md). Glue only; the rules are in
/// `SessionBackup` (unit-tested) and the Keychain access in `SessionBackupStore`.
///
/// - Save: whenever the WebView's cookie store changes (and on lifecycle nudges as a safety net) the `eve_session`
///   cookie is copied into the Keychain.
/// - Restore: at launch, before the first page load, an EMPTY cookie store gets the stored cookie back.
/// - Delete: when the cookie disappears after this process had seen it (web logout, expiry), and on every unpair.
///   An unpair suspends saving until its wipe has finished, so nothing can write the token back.
final class SessionPersistence: NSObject, WKHTTPCookieStoreObserver {
    static let shared = SessionPersistence()

    @MainActor private var store: WKHTTPCookieStore?
    @MainActor private var seenPresent = false
    @MainActor private var suspendCount = 0
    @MainActor private var epoch = 0                  // bumped by unpair start/end: an older in-flight sync is dropped
    @MainActor private var restoreRetryNeeded = false // the Keychain could not be read at launch (e.g. locked)
    @MainActor private var deleteFailed = false

    /// A delete of the backup that failed (web logout/expiry, launch cleanup) is remembered across launches, so the next
    /// launch/active/nudge retries it and the stale record is never restored meanwhile. Not secret: a bare boolean.
    private static let deletePendingKey = "eve.shell.session-backup.delete-pending"
    @MainActor private var deletePending: Bool {
        get { UserDefaults.standard.bool(forKey: Self.deletePendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.deletePendingKey) }
    }

    /// Every delete of the backup goes through here: success clears the retry flag, failure sets it.
    @MainActor @discardableResult
    private func removeBackup() -> Bool {
        let ok = SessionBackupStore.delete()
        deletePending = !ok
        return ok
    }

    // MARK: Setup / launch

    /// Call once with the WebView's cookie store, before the first load.
    @MainActor func attach(to cookieStore: WKHTTPCookieStore) {
        guard store == nil else { return }
        store = cookieStore
        cookieStore.add(self)
    }

    /// Before the first load (and again, once, if the Keychain was not readable then). Returns true if a cookie was restored.
    @MainActor @discardableResult
    func restoreIfNeeded() async -> Bool {
        guard let store, suspendCount == 0 else { return false }
        let startEpoch = epoch
        let host = ShellConfig.current.host
        let all = await store.allCookies()
        let cookie = SessionBackup.sessionCookie(in: all, host: host)
        guard startEpoch == epoch, suspendCount == 0 else { return false }
        if cookie != nil { seenPresent = true }
        let action = SessionBackup.onLaunch(cookie: cookie, stored: SessionBackupStore.load(),
                                            pendingRevoke: Self.pendingRevoke(), deletePending: deletePending,
                                            now: Date().timeIntervalSince1970)
        switch action {
        case .none:
            restoreRetryNeeded = false
            return false
        case .retryLater:
            restoreRetryNeeded = true
            return false
        case .deleteBackup:
            restoreRetryNeeded = !removeBackup()          // a failed delete is retried on the next active/launch
            return false
        case .discardAndRevoke(let record):
            // The pending-revoke list is damaged and may hide this very token: never restore it; queue its revoke
            // (this also rewrites the damaged list) and delete the backup.
            restoreRetryNeeded = false
            let persisted = SessionRevoker.shared.persistPending(record.token)
            removeBackup()
            Task { await SessionRevoker.shared.revoke(token: record.token, persisted: persisted) }
            return false
        case .restore(let record):
            restoreRetryNeeded = false
            guard let c = SessionBackup.makeCookie(for: record, host: host) else {
                removeBackup()
                return false
            }
            await store.setCookie(c)
            guard startEpoch == epoch, suspendCount == 0 else { return false }   // an unpair started meanwhile: it wipes
            // M-1: do not trust that WebKit stored what we asked for. Read it back and compare.
            let after = await store.allCookies()
            guard startEpoch == epoch, suspendCount == 0 else { return false }
            let check = SessionBackup.checkRestored(token: record.token, in: after, host: host)
            if check != .ok {
                await rejectRestored(record, check: check, cookies: after, store: store)
                return false
            }
            seenPresent = true
            return true
        }
    }

    /// M-1 guard: the cookie WebKit holds after a restore is not (host-only, Path=/, Secure, HttpOnly) as the server's
    /// cookie, or is missing. Remove it from the store, delete the Keychain backup and queue a revoke of the token
    /// (a cookie with other attributes may be sent to, or readable by, more than the gateway). No restore happens.
    @MainActor private func rejectRestored(_ record: SessionBackup.Record, check: SessionBackup.RestoreCheck,
                                           cookies: [HTTPCookie], store: WKHTTPCookieStore) async {
        for c in SessionBackup.cookiesToRemove(token: record.token, in: cookies, host: ShellConfig.current.host) {
            await store.deleteCookie(c)
        }
        removeBackup()
        let persisted = SessionRevoker.shared.persistPending(record.token)
        seenPresent = false
        Task { await SessionRevoker.shared.revoke(token: record.token, persisted: persisted) }
    }

    /// App became active: retry a restore that could not run at launch (the caller reloads if this returns true),
    /// otherwise just sync.
    @MainActor
    func onActive() async -> Bool {
        if restoreRetryNeeded, await restoreIfNeeded() { return true }
        await sync()
        return false
    }

    /// Safety net for lifecycle changes in case a cookie change did not produce a callback.
    @MainActor func nudge() async { await sync() }

    // MARK: Unpair (called by ShellModel.wipeAndRevoke)

    /// First thing of an unpair: stop saving, drop in-flight syncs.
    @MainActor func beginUnpair() {
        suspendCount += 1
        epoch += 1
    }

    /// The token held by the backup, if any. An unpair revokes it too, even when the cookie store is empty
    /// (e.g. the restore has not run yet), so a backed-up session can never outlive an unpair on the server.
    @MainActor func backupToken() -> String? {
        if case .record(let r) = SessionBackupStore.load() { return r.token }
        return nil
    }

    /// After the pending revoke was stored: the backup must be gone before the wipe starts. If the Keychain refuses,
    /// it is tried again by `endUnpair`; the stored pending revoke makes a leftover token useless on the server,
    /// and `onLaunch` never restores a token that is pending revoke.
    @MainActor func discardBackup() {
        deleteFailed = !removeBackup()
    }

    /// After the wipe finished (store is empty): resume. The next pairing is saved by the observer.
    @MainActor func endUnpair() {
        if deleteFailed { deleteFailed = !removeBackup() }
        suspendCount = max(0, suspendCount - 1)
        epoch += 1
        if suspendCount == 0 { seenPresent = false }
    }

    // MARK: Observer

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.sync() }
    }

    @MainActor private func sync() async {
        guard let store else { return }
        let startEpoch = epoch
        let all = await store.allCookies()
        let cookie = SessionBackup.sessionCookie(in: all, host: ShellConfig.current.host)
        guard startEpoch == epoch else { return }            // an unpair started or finished while we were reading
        let action = SessionBackup.onCookiesChanged(cookie: cookie, stored: SessionBackupStore.load(),
                                                    seenPresent: seenPresent, suspended: suspendCount > 0,
                                                    deletePending: deletePending, now: Date().timeIntervalSince1970)
        if suspendCount == 0, cookie != nil { seenPresent = true }
        switch action {
        case .none:
            if suspendCount == 0, cookie != nil { deletePending = false }   // a live pairing supersedes an old failed delete
        case .save(let record):
            if SessionBackupStore.save(record) { deletePending = false }
        case .delete:
            removeBackup()                                                    // failure is remembered and retried
        }
        if suspendCount == 0, cookie == nil { seenPresent = false }
    }

    /// The pending-revoke list (tokens that must never be restored).
    private static func pendingRevoke() -> SessionBackup.PendingRevoke {
        switch PendingTokenStore.load() {
        case .none: return .tokens([])
        case .corrupt: return .corrupt
        case .unavailable: return .unavailable
        case .list(let l): return .tokens(Set(l.entries.map { $0.token }))
        }
    }
}
