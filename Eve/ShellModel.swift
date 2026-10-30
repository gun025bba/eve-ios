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
    /// 1) copy the session cookie into the Keychain as a pending revoke, 2) wipe all website data now (no waiting),
    /// 3) reload, 4) try the revoke; if it fails it is retried on launch, foreground and when the network returns.
    func wipeAndRevoke() async {
        await NotificationManager.shared.closeForUnpair(generation: bridge?.documentGeneration ?? 0)   // refuse new reminders, drop all pending ones; only a later document's hello reopens
        let store = WKWebsiteDataStore.default()
        let revoker = SessionRevoker.shared
        let token = await revoker.currentSessionToken(from: store.httpCookieStore)
        var persisted = false
        if let token { persisted = revoker.persistPending(token) }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        reload()
        await NotificationManager.shared.finishUnpair()   // once more after wipe+reload; the next pairing's hello (newer document) reopens
        if let token { await revoker.revoke(token: token, persisted: persisted) }
    }
}
