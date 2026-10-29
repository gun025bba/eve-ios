# Changelog

## shell-v0.1.1
Security follow-ups L1/L2 from the shell-v0.1.0 review. Bridge contract stays v1.0.0 (no new/changed messages, `features` unchanged).
- L1: unpair no longer leaves the server session alive when offline. Unpair copies the session cookie into the Keychain (this-device-only, after first unlock) as a pending revoke, wipes all website data immediately (no 2 s wait), then calls `DELETE /v1/session`. If that fails it is retried on launch, when the app becomes active and when the network path becomes satisfied; the Keychain item is deleted once the server answers 204 (or 401: already invalid). The token is never logged, put in UserDefaults, or sent over the bridge; redirects are not followed with it. The bridge `unpair` message uses the same path.
- L2: bridge replies (`re`, `capabilities`) are now evaluated only in the frame that sent the request (`callAsyncJavaScript(in: frameInfo)`), and only if that frame is the main frame on the exact configured origin (https, host, 443) and the document has not changed since the request (navigation generation check). Shell-initiated `logout_requested` still goes to the configured-origin main frame.

## shell-v0.1.0
- SwiftUI + single WKWebView shell loading `https://<EVE_HOST>/ui/` (build setting).
- Offline screen ("Tailscale 연결 확인") on network failure; no external fallback URL.
- Top blur removal: ignoresSafeArea, `contentInsetAdjustmentBehavior = .never`, matched background/underPage colors, iOS 26 edge effects hidden.
- Keyboard input accessory bar removed (guarded WKContentView runtime subclass; no-op if not found).
- JS bridge v1.0.0: hello → capabilities, haptics, unpair; unknown → `unknown_type`. Main-frame + exact https/host/443 origin check.
- Navigation restricted to configured origin; user-tapped external https links open in Safari; no new windows; no ATS exceptions.
- Auth: pairing → HttpOnly session cookie in default persistent WKWebsiteDataStore; nothing in Keychain/UserDefaults. Unpair wipes all website data.
- CI: unsigned IPA build (push to main / manual dispatch), sha256 + provenance attestation, 3-day artifact.
