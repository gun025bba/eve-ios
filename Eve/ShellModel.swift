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

    /// Design §4: try server-side revoke via the web's logout first, then wipe all website data.
    func unpair() {
        bridge?.send(type: "logout_requested", payload: [:])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let store = WKWebsiteDataStore.default()
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            self.reload()
        }
    }
}
