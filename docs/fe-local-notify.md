# Local reminders from the web (bridge 1.1.0, FE guide)

Auxiliary only. A free Apple ID has no APNs, so this is **not push**: the shell can only ask iOS to show a generic reminder after a delay. It cannot know when a generation really finishes and does not run while the app is suspended. Design context: `eve-serving/docs/architecture/ios-shell.md`.

## Detect
After `hello`, check `capabilities.features` for `"notify"`. If missing (old shell / plain browser), do nothing.

## Messages (web → shell, `window.webkit.messageHandlers.eve.postMessage`)
| type | payload | reply `{re, ok, error_code?}` |
|---|---|---|
| `notify_schedule` | `{ id, afterSec }` | `ok:true` once scheduled. `error_code`: `invalid_argument` (bad id or `afterSec` outside 5–3600), `permission_denied` (user declined notifications), `limit_reached` (8 pending), `notify_failed` |
| `notify_cancel` | `{ id }` | `ok:true` (idempotent; removes the pending and the already delivered reminder) |

- `id`: 1–64 chars `[A-Za-z0-9_-]`, e.g. the generation/message id. Scheduling the same `id` again replaces the pending reminder.
- `afterSec`: number, 5 to 3600.
- **No text field.** The shell shows a fixed generic text ("Eve" / "응답이 준비되었을 수 있어요. 앱을 열어 확인하세요."). Never put message content anywhere in this API; the shell ignores extra fields.
- The first `notify_schedule` shows the iOS permission prompt (lazy). Handle `permission_denied` quietly (don't retry in a loop).
- Replies arrive through `window.__eveShell.receive` as before, only in the sending frame.

## Recommended use (long generation)
1. A generation is running and `document.visibilityState` becomes `hidden`: send `notify_schedule {id: <generation id>, afterSec: 30}` (pick a value near your typical answer time; it fires once at that time whether or not the answer is done).
2. The page becomes `visible` again, or the generation completes while visible: send `notify_cancel {id}`.
3. If the generation fails or the user stops it: `notify_cancel {id}`.
4. Shell behavior: if the app is in the foreground no banner is shown; delivered reminders are cleared when the app returns to the foreground; unpair cancels everything.

## Limits (do not promise more in the UI)
- Fires at a fixed delay, not at real completion. Wording in the UI: "알림이 올 수 있어요" rather than "완료되면 알려드려요".
- If the user force-quits the app or turns notifications/Focus off, nothing is shown. No lock-screen content, no badge, no server-initiated notifications.
