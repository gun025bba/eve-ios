import Foundation
import WebKit
import UIKit

/// JS bridge v1. Web→shell: window.webkit.messageHandlers.eve.postMessage(msg)
/// Shell→web: window.__eveShell.receive(msg). Never carries secrets, tokens or cookies.
/// L2: a reply is evaluated only in the frame that sent the request (never injected globally), and only if that
/// frame is still the same main-frame document on the configured origin.
final class Bridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "eve"
    static let features = ["haptics", "unpair", "notify"]

    let config: ShellConfig
    weak var webView: WKWebView?
    /// Called for the bridge `unpair` message (wipe local data + queue a server revoke).
    var onUnpair: (() async -> Void)?
    /// Incremented on every committed navigation (new document). A reply is dropped if the document changed since the request.
    var documentGeneration = 0
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
        handle(id: id, type: type, payload: payload, frame: message.frameInfo, generation: documentGeneration)
    }

    private func handle(id: String, type: String, payload: [String: Any], frame: WKFrameInfo, generation: Int) {
        switch type {
        case "hello":
            Task { await NotificationManager.shared.pairingHello() }   // reopens notify after a finished unpair
            reply(re: id, ok: true, to: frame, generation: generation)
            send(type: "capabilities", payload: [
                "bridge": Self.bridgeVersion, "shell": ShellConfig.shellVersion, "features": Self.features,
            ], to: frame, generation: generation)
        case "haptics":
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch payload["style"] as? String {
            case "light": style = .light
            case "heavy": style = .heavy
            default: style = .medium
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()
            reply(re: id, ok: true, to: frame, generation: generation)
        case "unpair":
            // The web may already have called its logout API. Either way, wipe local data now and queue a
            // server-side revoke (retried until the server answers) in case that call never reached the server.
            reply(re: id, ok: true, to: frame, generation: generation)
            Task { await self.onUnpair?() }
        case "notify_schedule":
            // Auxiliary local reminder (generic fixed text, no APNs). Validated here, replied to the sending frame only.
            switch NotifyValidation.parseSchedule(payload) {
            case .failure(let f):
                reply(re: id, ok: false, errorCode: f.rawValue, to: frame, generation: generation)
            case .success(let req):
                Task {
                    let failure = await NotificationManager.shared.schedule(id: req.id, afterSec: req.afterSec)
                    self.reply(re: id, ok: failure == nil, errorCode: failure?.rawValue, to: frame, generation: generation)
                }
            }
        case "notify_cancel":
            guard let nid = NotifyValidation.parseID(payload) else {
                reply(re: id, ok: false, errorCode: NotifyFailure.invalidArgument.rawValue, to: frame, generation: generation)
                return
            }
            Task {
                await NotificationManager.shared.cancel(id: nid)
                self.reply(re: id, ok: true, to: frame, generation: generation)
            }
        default:
            reply(re: id, ok: false, errorCode: "unknown_type", to: frame, generation: generation)
        }
    }

    static var bridgeVersion: String { ShellConfig.bridgeVersion }

    /// Reply to the frame that sent the request.
    func reply(re: String, ok: Bool, errorCode: String? = nil, to frame: WKFrameInfo, generation: Int) {
        var m: [String: Any] = ["v": 1, "re": re, "ok": ok]
        if let errorCode { m["error_code"] = errorCode }
        deliver(m, to: frame, generation: generation)
    }

    /// Send a message. With `frame` (a reply to a request) it goes only to that frame; without it
    /// (shell-initiated events such as `logout_requested`) it goes to the main frame of the configured origin.
    func send(type: String, payload: [String: Any], to frame: WKFrameInfo? = nil, generation: Int = 0) {
        deliver(["v": 1, "id": UUID().uuidString.lowercased(), "type": type, "payload": payload],
                to: frame, generation: generation)
    }

    private func deliver(_ m: [String: Any], to frame: WKFrameInfo?, generation: Int) {
        DispatchQueue.main.async {
            guard let wv = self.webView else { return }
            if let frame {
                // The requesting frame must be the main frame on the exact configured origin, and still the same document.
                let o = frame.securityOrigin
                guard frame.isMainFrame,
                      self.config.isAllowed(origin: (o.protocol, o.host, o.port)),
                      generation == self.documentGeneration,
                      let furl = frame.request.url, self.config.isAllowed(url: furl) else { return }
            }
            guard let url = wv.url, self.config.isAllowed(url: url) else { return }
            wv.callAsyncJavaScript(
                "if (window.__eveShell && typeof window.__eveShell.receive === 'function') { window.__eveShell.receive(m); }",
                arguments: ["m": m], in: frame, in: .page, completionHandler: nil)
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
