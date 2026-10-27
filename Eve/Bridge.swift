import Foundation
import WebKit
import UIKit

/// JS bridge v1. Web→shell: window.webkit.messageHandlers.eve.postMessage(msg)
/// Shell→web: window.__eveShell.receive(msg). Never carries secrets, tokens or cookies.
final class Bridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "eve"
    static let features = ["haptics", "unpair"]

    let config: ShellConfig
    weak var webView: WKWebView?
    init(config: ShellConfig) { self.config = config }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // Security condition: main frame only, exact scheme/host/port match. Otherwise drop silently.
        guard message.frameInfo.isMainFrame else { return }
        let o = message.frameInfo.securityOrigin
        guard config.isAllowed(origin: (o.protocol, o.host, o.port)) else { return }
        guard let msg = message.body as? [String: Any],
              (msg["v"] as? Int) == 1,
              let id = msg["id"] as? String, !id.isEmpty, id.count <= 128,
              let type = msg["type"] as? String else { return }
        let payload = msg["payload"] as? [String: Any] ?? [:]
        handle(id: id, type: type, payload: payload)
    }

    private func handle(id: String, type: String, payload: [String: Any]) {
        switch type {
        case "hello":
            reply(re: id, ok: true)
            send(type: "capabilities", payload: [
                "bridge": Self.bridgeVersion, "shell": ShellConfig.shellVersion, "features": Self.features,
            ])
        case "haptics":
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch payload["style"] as? String {
            case "light": style = .light
            case "heavy": style = .heavy
            default: style = .medium
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()
            reply(re: id, ok: true)
        case "unpair":
            // Web has already called its logout API; wipe local data.
            reply(re: id, ok: true)
            Task {
                await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                await MainActor.run { self.webView?.load(URLRequest(url: self.config.startURL)) }
            }
        default:
            reply(re: id, ok: false, errorCode: "unknown_type")
        }
    }

    static var bridgeVersion: String { ShellConfig.bridgeVersion }

    func reply(re: String, ok: Bool, errorCode: String? = nil) {
        var m: [String: Any] = ["v": 1, "re": re, "ok": ok]
        if let errorCode { m["error_code"] = errorCode }
        deliver(m)
    }

    func send(type: String, payload: [String: Any]) {
        deliver(["v": 1, "id": UUID().uuidString.lowercased(), "type": type, "payload": payload])
    }

    private func deliver(_ m: [String: Any]) {
        DispatchQueue.main.async {
            guard let wv = self.webView, let url = wv.url, self.config.isAllowed(url: url) else { return }
            wv.callAsyncJavaScript(
                "if (window.__eveShell && typeof window.__eveShell.receive === 'function') { window.__eveShell.receive(m); }",
                arguments: ["m": m], in: nil, in: .page, completionHandler: nil)
        }
    }
}

/// Avoids the WKUserContentController → handler retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
