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
                                            pendingRevokeTokens: Self.pendingRevokeTokens(),
                                            now: Date().timeIntervalSince1970)
        switch action {
        case .none:
            restoreRetryNeeded = false
            return false
        case .retryLater:
            restoreRetryNeeded = true
            return false
        case .deleteBackup:
            restoreRetryNeeded = false
            SessionBackupStore.delete()
            return false
        case .restore(let record):
            restoreRetryNeeded = false
            guard let c = SessionBackup.makeCookie(for: record, host: host) else {
                SessionBackupStore.delete()
                return false
            }
            await store.setCookie(c)
            guard startEpoch == epoch, suspendCount == 0 else { return false }   // an unpair started meanwhile: it wipes
            seenPresent = true
            return true
        }
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
        deleteFailed = !SessionBackupStore.delete()
    }

    /// After the wipe finished (store is empty): resume. The next pairing is saved by the observer.
    @MainActor func endUnpair() {
        if deleteFailed { deleteFailed = !SessionBackupStore.delete() }
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
                                                    now: Date().timeIntervalSince1970)
        if suspendCount == 0, cookie != nil { seenPresent = true }
        switch action {
        case .none: break
        case .save(let record): SessionBackupStore.save(record)
        case .delete: SessionBackupStore.delete()
        }
        if suspendCount == 0, cookie == nil { seenPresent = false }
    }

    /// Tokens waiting to be revoked (never restored). nil = the list could not be read right now.
    private static func pendingRevokeTokens() -> Set<String>? {
        switch PendingTokenStore.load() {
        case .none, .corrupt: return []
        case .unavailable: return nil
        case .list(let l): return Set(l.entries.map { $0.token })
        }
    }
}
