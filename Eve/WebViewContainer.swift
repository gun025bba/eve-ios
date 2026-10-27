import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let model: ShellModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent store; session cookie lives here (HttpOnly)
        config.allowsInlineMediaPlayback = true
        let bridge = Bridge(config: ShellConfig.current)
        config.userContentController.add(WeakMessageHandler(bridge), name: Bridge.handlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        bridge.webView = webView
        model.bridge = bridge
        model.webView = webView

        // Top blur / safe-area handling.
        let bg = UIColor.systemBackground
        webView.isOpaque = false
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        webView.underPageBackgroundColor = bg
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26, *) {
            webView.scrollView.topEdgeEffect.isHidden = true
            webView.scrollView.bottomEdgeEffect.isHidden = true
        }
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        KeyboardAccessoryRemover.apply(to: webView)

        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.settingsGesture(_:)))
        press.numberOfTouchesRequired = 3
        press.minimumPressDuration = 0.8
        webView.addGestureRecognizer(press)

        webView.load(URLRequest(url: ShellConfig.current.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: ShellModel
        init(model: ShellModel) { self.model = model }

        @objc func settingsGesture(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { Task { @MainActor in model.showUnpairConfirm = true } }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if ShellConfig.current.isAllowed(url: url) { return decisionHandler(.allow) }
            // Only a user-tapped external https link in the main frame goes to Safari. file:, data:, javascript:, etc. are dropped.
            if action.navigationType == .linkActivated, url.scheme?.lowercased() == "https",
               action.targetFrame?.isMainFrame ?? true {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        // Never create new windows.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               url.scheme?.lowercased() == "https", !ShellConfig.current.isAllowed(url: url) {
                UIApplication.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in model.offline = false }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }
        private func handle(_ error: Error) {
            let e = error as NSError
            if e.domain == NSURLErrorDomain && e.code != NSURLErrorCancelled {
                Task { @MainActor in model.offline = true }   // never fall back to an external URL
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    }
}
