import SwiftUI
import WebKit

@MainActor
final class ShellModel: ObservableObject {
    @Published var offline = false
    @Published var showUnpairConfirm = false
    weak var webView: WKWebView?
    var bridge: Bridge?

    func reload() {
        offline = false
        webView?.load(URLRequest(url: ShellConfig.current.startURL))
    }

    /// Design §4 + L1. Ask the web to log out (contract v1.0.0), then immediately wipe local data and make sure
    /// the server session is revoked even if we are offline right now.
    func unpair() {
        bridge?.send(type: "logout_requested", payload: [:])
        Task { await wipeAndRevoke() }
    }

    /// Shared by the settings dialog and the bridge `unpair` message.
    /// 1) copy the session token(s) into the Keychain as a pending revoke, 2) delete the reinstall backup of the
    /// session (`SessionPersistence`) and wipe all website data now (no waiting), 3) reload, 4) try the revoke; if it
    /// fails it is retried on launch, foreground and when the network returns.
    func wipeAndRevoke() async {
        SessionPersistence.shared.beginUnpair()           // stop saving the cookie; nothing may write it back during the wipe
        let unpairEpoch = await NotificationManager.shared.closeForUnpair(generation: bridge?.documentGeneration ?? 0)   // refuse new reminders, drop all pending ones; only a later document's hello reopens
        let store = WKWebsiteDataStore.default()
        let revoker = SessionRevoker.shared
        var tokens: [String] = []
        if let t = await revoker.currentSessionToken(from: store.httpCookieStore) { tokens.append(t) }
        if let b = SessionPersistence.shared.backupToken(), !tokens.contains(b) { tokens.append(b) }
        let persisted = tokens.map { revoker.persistPending($0) }
        SessionPersistence.shared.discardBackup()          // after the revoke is queued, before the wipe
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        SessionPersistence.shared.endUnpair()              // store is empty now; the next pairing is saved again
        reload()
        await NotificationManager.shared.finishUnpair(epoch: unpairEpoch)   // once more after wipe+reload; only the last overlapping unpair arms; the next pairing's hello (newer document) reopens
        for (token, ok) in zip(tokens, persisted) { await revoker.revoke(token: token, persisted: ok) }
    }
}
