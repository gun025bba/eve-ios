# Changelog

## shell-v0.3.0
Pairing survives a reinstall, and `Config/Local.xcconfig` now reliably wins. Minor release: no bridge change (stays v1.1.0), no change for the web.
- Session backup (`docs/session-persistence.md`): the `eve_session` cookie (value + expiry only) is copied into its own Keychain item (`eve.shell.session-backup`, `WhenUnlockedThisDeviceOnly`, not synchronizable, same access class as the pending-revoke item). At launch, before the first page load, an EMPTY cookie store gets the cookie back with the server's attributes (host-only, `/`, Secure, HttpOnly, SameSite=Strict, original expiry); an existing cookie is never replaced. A restore that cannot run because the Keychain is locked is retried when the app becomes active (then the page reloads).
- Deleted on every unpair (after the pending revoke is stored, before the wipe; saving is suspended until the wipe is done, and a sync that was in flight can no longer write it back), when the cookie disappears after the shell had seen it (web logout, expiry), and when a record is expired (cookie expiry or 180 days), saved in the future (clock), corrupt, or its token is waiting in the pending-revoke list. An unpair also queues a server revoke for the backed-up token when the cookie store is empty.
- Tokens are validated (base64url, 16-128 bytes) before storing and before building the cookie.
- Tests (`EveLogicTests`, 24 new): token/record validation, strict decode, freshness and clock skew, cookie selection and attributes, launch and observer decisions, and end-to-end scenarios (pair then reinstall, overwrite install, unpair, web logout, pair again, failed delete + pending revoke, expired backup).
- Fix: `Config/Local.xcconfig` now always takes precedence. New `Config/Shell.xcconfig` (Base defaults, derived `PRODUCT_BUNDLE_IDENTIFIER`/`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, then `#include? "Local.xcconfig"` last) is the project and target xcconfig; those three settings are no longer hardcoded in `project.yml` (target build settings sit above every xcconfig and could not be overridden). `Base.xcconfig` is defaults only. Local may now also set `PRODUCT_BUNDLE_IDENTIFIER`/`DEVELOPMENT_TEAM` directly.
- New `scripts/setup-local.sh` (writes Local.xcconfig for a fresh clone, reads the team ID from the Apple Development certificate's OU, regenerates, verifies) and `scripts/check-config.sh` (prints/asserts the resolved build settings via `xcodebuild -showBuildSettings`).
- CI (`compile`): new step builds the project without Local, with Local, and with Local setting the final setting directly, and fails if the resolved bundle ID, team, host, version or build number differ; also fails if `ShellConfig.shellVersion` differs from `EVE_SHELL_VERSION`.
- README: full fresh-clone install procedure, team ID extraction, reinstall behaviour table. `ShellConfig.shellVersion` was stale (0.2.2) and is now 0.3.0. Build number 8.

## shell-v0.2.3
Follow-up Low L-8 of the PR #16 security review. Patch release: no bridge change (stays v1.1.0), no change for the web.
- L-8: when a second unpair started while the first one was still wiping, the first `finishUnpair` read the (already newer) epoch on entry and armed the reopen, so a newer document's `hello` could reopen notify before the second wipe had finished. `closeAndCancelAll` now returns the epoch it created (taken before its first `await`), `ShellModel.wipeAndRevoke` hands it to `finishUnpair(epoch:)`, and only the unpair whose epoch is still the latest arms the reopen (a stale finish still cancels once more, harmlessly). Only the last of several overlapping unpairs opens the reopen window.
- Tests (`EveLogicTests`): first finish after the second close does not arm, stale finish after the last finish is harmless, a stale finish still cancels everything, only the last of three unpairs arms, second close during the first close's cancelling. Existing tests now pass the epoch.
- Build number 7.

## shell-v0.2.2
Follow-up Lows L-6 / L-7 of the PR #11 security review (issue #12). Patch release: no new bridge message, bridge stays v1.1.0.
- L-6: the notify scheduler reopens only for a document newer than the one that was current when the unpair started. The scheduler is closed at the current `Bridge.documentGeneration` G; a `hello` reopens it only if its generation is > G, so a `hello` of the old document (or an older one) can never do it. A newer document's `hello` that arrives before the wipe has finished is remembered and honoured in `finishUnpair`; one that arrives afterwards reopens right away. A second unpair that starts while the first one is still finishing keeps the larger generation, drops a remembered `hello`, and the first `finishUnpair` no longer arms the reopen.
- L-7: reminder slots now expire on the monotonic `ProcessInfo.systemUptime` clock instead of the wall clock, so changing the date/time cannot free a slot early or keep it forever (a reminder from a previous run is converted once from its fire date, capped at 3600 s). `systemUptime` does not advance while the device sleeps, so a slot may be freed later than the real fire time, never earlier: the limit of 8 stays safe.
- L-7 tests (`EveLogicTests`): close and cancel racing with an add in flight (the reminder that lands later is removed, nothing stays counted), a failed add never releases a newer entry of the same id, the limit holds while adds are in flight, hello/generation rules (old/same/older document, remembered hello, second unpair, overlapping finish), wall-clock jumps, and `NSNumber`/`NSString`/`NSNull` inputs as WKWebView delivers them.
- No change for the web: `hello` is already sent on every load. Build number 6.

## shell-v0.2.1
App icon F (designer-approved) added as `AppIcon`. No code or bridge change; bridge stays v1.1.0.
- `Eve/Assets.xcassets/AppIcon.appiconset`: single 1024 universal icon with any / dark / tinted appearances (iOS 18+ icon modes; on iOS 17 the "any" image is used). Any = opaque RGB, no alpha, full bleed (iOS applies the corner mask); dark = transparent background with the glyph only; tinted = grayscale glyph on transparent background.
- `project.yml`: `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` (the asset catalog is picked up by the existing `Eve` sources).
- Build number 5.

## shell-v0.2.0 (bridge v1.1.0)
Depends on shell-v0.1.1/v0.1.2 (merged: L1/L2 frame-scoped replies, bounded pending revoke). Bridge 1.1.0 is a backward-compatible minor: only additions, `features` gains `"notify"`.
- New bridge messages `notify_schedule {id, afterSec}` and `notify_cancel {id}`: local reminder via `UNUserNotificationCenter` (no APNs, works with a free Apple ID). Auxiliary only; fires at a fixed delay.
- Fixed generic notification text; the web cannot supply title/body (no message content on the lock screen). `id` is 1-64 chars `[A-Za-z0-9_-]`, `afterSec` 5-3600, at most 8 pending. Errors: `invalid_argument`, `permission_denied`, `limit_reached`, `notify_failed`.
- Notification permission is requested lazily on the first `notify_schedule`, and the system prompt is only shown while the app is active (otherwise `permission_denied`; an already authorized app can still schedule while going to the background).
- Same L2 path as every message: main frame on the configured origin only, reply only to the sending frame.
- No banner while the app is in the foreground; delivered reminders cleared on foreground; unpair cancels all pending reminders (see below).
- Security review of PR #11 (M-1, L-1..L-5):
  - M-1: the limit of 8 is enforced atomically. The scheduler is an actor that counts reserved/scheduled ids itself (no `await` between the count and the reservation), so concurrent messages cannot exceed it; entries expire at their fire time, and reminders that survived an app restart are counted once at first use. Unit test: 20 concurrent schedules, exactly 8 accepted, via an injected fake notification center.
  - L-1: unpair closes the scheduler first (new `notify_schedule` gets `notify_failed`) and cancels everything, then cancels once more after wipe + reload; a schedule that was in flight across the close removes what it added. The scheduler reopens on the first `hello` of a document loaded after the unpair finished (next pairing).
  - L-2: the permission prompt is only requested while the app is active.
  - L-3: the id length is checked in UTF-8 bytes before any per-character check.
  - L-4: validation moved to `Eve/NotificationValidation.swift`, the limit/closed logic to `Eve/NotificationScheduler.swift` (Foundation only); both are compiled into `EveLogicTests` with new tests.
  - L-5: FE guide describes rounding of fractional `afterSec`, the limit of 8 and the exact behavior on logout.
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
