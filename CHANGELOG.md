# Changelog

## shell-v0.2.0 (bridge v1.1.0)
Depends on shell-v0.1.1/v0.1.2 (merged: L1/L2 frame-scoped replies, bounded pending revoke). Bridge 1.1.0 is a backward-compatible minor: only additions, `features` gains `"notify"`.
- New bridge messages `notify_schedule {id, afterSec}` and `notify_cancel {id}`: local reminder via `UNUserNotificationCenter` (no APNs, works with a free Apple ID). Auxiliary only; fires at a fixed delay.
- Fixed generic notification text; the web cannot supply title/body (no message content on the lock screen). `id` is 1-64 chars `[A-Za-z0-9_-]`, `afterSec` 5-3600, at most 8 pending. Errors: `invalid_argument`, `permission_denied`, `limit_reached`, `notify_failed`.
- Notification permission is requested lazily on the first `notify_schedule`.
- Same L2 path as every message: main frame on the configured origin only, reply only to the sending frame.
- No banner while the app is in the foreground; delivered reminders cleared on foreground; unpair cancels all pending reminders.
- FE guide: `docs/fe-local-notify.md`.

## shell-v0.1.2
Low-severity security follow-ups (N-1..N-6) to the shell-v0.1.1 review. Bridge contract stays v1.0.0.
- N-1: a pending revoke that hits the 30-day TTL, or whose `savedAt` is in the future (clock moved back), gets one last forced attempt before it is deleted. A `lastAttempt` in the future counts as "never attempted", so a wrong clock cannot block retries.
- N-2: saving the same token again changes nothing (savedAt and attempt counters are kept).
- N-3: the install marker is only set after the Keychain was read successfully and the cleanup ran (a locked-device launch retries next time). Leftover entries from a previous install get one forced attempt and are deleted only if the server answered; if the first launch is offline they stay pending (TTL and caps still apply).
- N-4: up to 3 pending tokens are kept (a second unpair no longer overwrites an unfinished first one; the oldest is dropped with a visible failure banner when the list is full).
- N-5: the Keychain item is a versioned JSON list with optional bookkeeping fields. An item that cannot be decoded is deleted and reported in the banner; it is never interpreted as a token (the single-entry JSON written by early 0.1.1 builds is migrated).
- N-6: the PR source leak check now also scans `.github/workflows`, fails closed on git errors, also flags RFC1918/link-local IPs and mDNS-style local host names, and tests its own pattern. `build-ipa.yml` self-test fixtures are split so the repo scan does not match them (behaviour unchanged).
- Tests: new `EveLogicTests` unit-test target (macOS, no simulator) for `RevokePolicy` / `PendingList`, run by `compile.yml`. The pure logic moved to `Eve/RevokePolicy.swift`.

## shell-v0.1.1
Security follow-ups L1/L2 from the shell-v0.1.0 review. Bridge contract stays v1.0.0 (no new/changed messages, `features` unchanged).
- L1: unpair no longer leaves the server session alive when offline. Unpair copies the session cookie into the Keychain (this-device-only, `WhenUnlocked`) as a pending revoke, wipes all website data immediately (no 2 s wait), then calls `DELETE /v1/session`. The token never goes to UserDefaults, logs, or the bridge; redirects are not followed with it. The bridge `unpair` message uses the same path.
  - Bounded retries (security review M-1): the Keychain item is JSON with `savedAt`, attempt counters and `lastAttempt`. Retried at launch, on foreground and when the network returns, with exponential backoff (30 s up to 6 h). Deleted on 204/200/401; after 30 days (TTL); after 3 permanent rejections (403/404/other 4xx/3xx); after 10 failed server answers (5xx/408/429). Network errors only wait for the TTL.
  - Reinstall: Keychain items survive app deletion, so a first launch of a fresh install (UserDefaults install marker absent) makes one last forced attempt and then deletes any leftover item.
  - Compare-and-clear/update: a result only deletes or updates the stored item if it still holds the token that was tried; a revoke requested while another is in flight is re-run afterwards.
  - Keychain writes use SecItemUpdate then SecItemAdd (never delete-then-add). If the token cannot be stored, one in-memory attempt is made and a failure banner is shown.
  - A banner shows "revoke pending" or "revoke failed" instead of silently pending.
- L2: bridge replies (`re`, `capabilities`) are now evaluated only in the frame that sent the request (`callAsyncJavaScript(in: frameInfo)`), and only if that frame is the main frame on the exact configured origin (https, host, 443) the frame's own request URL is on the configured origin, and the document has not changed since the request (navigation generation check). Shell-initiated `logout_requested` still goes to the configured-origin main frame.

## shell-v0.1.0
- SwiftUI + single WKWebView shell loading `https://<EVE_HOST>/ui/` (build setting).
- Offline screen ("Tailscale 연결 확인") on network failure; no external fallback URL.
- Top blur removal: ignoresSafeArea, `contentInsetAdjustmentBehavior = .never`, matched background/underPage colors, iOS 26 edge effects hidden.
- Keyboard input accessory bar removed (guarded WKContentView runtime subclass; no-op if not found).
- JS bridge v1.0.0: hello → capabilities, haptics, unpair; unknown → `unknown_type`. Main-frame + exact https/host/443 origin check.
- Navigation restricted to configured origin; user-tapped external https links open in Safari; no new windows; no ATS exceptions.
- Auth: pairing → HttpOnly session cookie in default persistent WKWebsiteDataStore; nothing in Keychain/UserDefaults. Unpair wipes all website data.
- CI: unsigned IPA build (push to main / manual dispatch), sha256 + provenance attestation, 3-day artifact.
