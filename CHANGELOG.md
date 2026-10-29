# Changelog

## shell-v0.2.0 (bridge v1.1.0)
Depends on shell-v0.1.1 (PR #7: L1/L2 frame-scoped replies). Bridge 1.1.0 is a backward-compatible minor: only additions, `features` gains `"notify"`.
- New bridge messages `notify_schedule {id, afterSec}` and `notify_cancel {id}`: local reminder via `UNUserNotificationCenter` (no APNs, works with a free Apple ID). Auxiliary only; fires at a fixed delay.
- Fixed generic notification text; the web cannot supply title/body (no message content on the lock screen). `id` is 1-64 chars `[A-Za-z0-9_-]`, `afterSec` 5-3600, at most 8 pending. Errors: `invalid_argument`, `permission_denied`, `limit_reached`, `notify_failed`.
- Notification permission is requested lazily on the first `notify_schedule`.
- Same L2 path as every message: main frame on the configured origin only, reply only to the sending frame.
- No banner while the app is in the foreground; delivered reminders cleared on foreground; unpair cancels all pending reminders.
- FE guide: `docs/fe-local-notify.md`.

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
