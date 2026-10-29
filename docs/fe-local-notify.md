# Local reminders from the web (bridge 1.1.0, FE guide)

Auxiliary only. A free Apple ID has no APNs, so this is **not push**: the shell can only ask iOS to show a generic reminder after a delay. It cannot know when a generation really finishes and does not run while the app is suspended. Design context: `eve-serving/docs/architecture/ios-shell.md`.

## Detect
After `hello`, check `capabilities.features` for `"notify"`. If missing (old shell / plain browser), do nothing.

## Messages (web → shell, `window.webkit.messageHandlers.eve.postMessage`)
| type | payload | reply `{re, ok, error_code?}` |
|---|---|---|
| `notify_schedule` | `{ id, afterSec }` | `ok:true` once scheduled. `error_code`: `invalid_argument` (bad id or `afterSec` outside 5–3600), `permission_denied` (user declined notifications), `limit_reached` (8 pending), `notify_failed` (system error, or the shell is unpairing / has not been paired again yet) |
| `notify_cancel` | `{ id }` | `ok:true` (idempotent; removes the pending and the already delivered reminder) |

- `id`: 1–64 chars `[A-Za-z0-9_-]`, e.g. the generation/message id. Scheduling the same `id` again replaces the pending reminder.
- `afterSec`: number, 5 to 3600. The range is checked on the value you send; a fractional value inside the range is rounded to the nearest whole second (5.4 → 5, 5.5 → 6), so 4.6 and 3600.4 are rejected.
- **Limit: the shell enforces at most 8 pending reminders** (not the web, not iOS's own limit), counted atomically across concurrent messages. Re-scheduling an existing `id` replaces it and does not use a new slot. A slot is freed when the reminder's time has passed, on `notify_cancel`, or on unpair. Reminders that survived an app restart still count. Beyond 8 you get `limit_reached`.
- **No text field.** The shell shows a fixed generic text ("Eve" / "응답이 준비되었을 수 있어요. 앱을 열어 확인하세요."). Never put message content anywhere in this API; the shell ignores extra fields.
- The first `notify_schedule` shows the iOS permission prompt (lazy), and the prompt is only requested while the app is in the foreground and active. If the permission was never decided and the app is not active (e.g. you schedule right as the page goes `hidden`), you get `permission_denied` without a prompt: schedule once while the page is visible (e.g. when the user sends a message) so the prompt can appear. Once permission is granted, scheduling while the page goes hidden works. Handle `permission_denied` quietly (don't retry in a loop).
- Replies arrive through `window.__eveShell.receive` as before, only in the sending frame.

## Recommended use (long generation)
1. A generation is running and `document.visibilityState` becomes `hidden`: send `notify_schedule {id: <generation id>, afterSec: 30}` (pick a value near your typical answer time; it fires once at that time whether or not the answer is done).
2. The page becomes `visible` again, or the generation completes while visible: send `notify_cancel {id}`.
3. If the generation fails or the user stops it: `notify_cancel {id}`.
4. Shell behavior: if the app is in the foreground no banner is shown; delivered reminders are cleared when the app returns to the foreground; see "Logout / unpair" below.

## Logout / unpair (exact behavior)
When the user unpairs (settings or the bridge `unpair` message), the shell, in this order:
1. closes notify: from now on `notify_schedule` replies `notify_failed` (`notify_cancel` still works), and every pending reminder and every delivered reminder of the app is removed;
2. wipes the website data and reloads the page;
3. cancels everything once more after the reload has been started (this removes a reminder that was still being scheduled when step 1 ran).
Notify stays closed until the next pairing: it reopens on the first `hello` of a document that was loaded after the unpair started (a `hello` of the page that was open at that moment never reopens it; one that arrives before step 2 has finished is held and takes effect when it finishes). So after a logout/login, send `hello` (as you do on every load) and do not schedule before its reply. A reminder scheduled in one session is never delivered after an unpair.

## Limits (do not promise more in the UI)
- Fires at a fixed delay, not at real completion. Wording in the UI: "알림이 올 수 있어요" rather than "완료되면 알려드려요".
- If the user force-quits the app or turns notifications/Focus off, nothing is shown. No lock-screen content, no badge, no server-initiated notifications.
