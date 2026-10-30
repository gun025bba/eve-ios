# Keeping the pairing across reinstalls (shell 0.3.0)

Status: implemented in shell 0.3.0; security review round 1 (M-1, L-9..L-14) applied. Not yet verified on a real device (see "To check on a real device").

## Problem
A free Apple ID signs apps for 7 days, so Eve is reinstalled weekly. Each reinstall asked for a new 8-character pairing code.

## Root-cause analysis
How the web session works (eve-serving gateway, `internal/handlers/pair.go`, `internal/session/session.go`):
`POST /v1/pair` redeems a one-time code and sets `eve_session` = 256-bit random token, `Path=/`, `HttpOnly`, `Secure`,
`SameSite=Strict`, `Max-Age` = 180 days, no `Domain` (host-only). The server stores only an HMAC of it. The session ends
after 30 days idle, 180 days absolute, or when revoked (`DELETE /v1/session`).

So the cookie is persistent (not a session cookie) and a normal 7-day refresh should not lose it:

| Case | Data container | WebView cookie | Pairing |
|---|---|---|---|
| Install over the existing app (same bundle ID + team) | kept | kept | **kept** (no re-pair needed) |
| Delete the app, install again (same bundle ID + team) | deleted | gone | **lost** before 0.3.0; kept with the Keychain copy |
| Different bundle ID (typo; `Config/Local.xcconfig` not applied so it fell back to the placeholder ID; Xcode vs SideStore re-signing; other team) | other app, new container | gone | **lost**: a different app. The Keychain copy is not readable either (access group = team prefix + bundle ID) |
| Unpair / web logout | wiped | gone | lost by design |
| Session expired or revoked server-side | kept | kept but rejected | lost by design |
| App killed right after pairing, before WebKit flushed cookies to disk | partly | maybe gone | the Keychain copy also covers this |

A likely cause of the repeated codes is therefore a *changed bundle ID* (a fresh clone, a switch between install methods, or a
build that did not pick up the configured ID and used the placeholder `com.example.eve`), not Apple signing itself. The
config layering is hardened in this release (see CHANGELOG), but the exact cause on the user's Mac was not reproduced. The Keychain copy fixes the remaining "delete and reinstall with the
same ID" case and the flush race.

## Design
1. **Save.** The shell observes the WebView's cookie store (`WKHTTPCookieStoreObserver`, plus a nudge when the scene
   changes phase). When the `eve_session` cookie of the configured host changes, its value and expiry are written to one
   Keychain item. Only a cookie in exactly the server's shape counts (L-9): name, valid token, Secure, **HttpOnly**,
   **Path=/**, **host-only** (domain exactly the configured host, no leading dot), with an expiry. A cookie that differs
   (a domain cookie, one readable by scripts, another path) is never backed up and does not count as "the cookie is there".
2. **Restore.** At launch, before the first page load, if the cookie store has **no** `eve_session` cookie and the
   Keychain holds a usable record, the shell puts the cookie back with the same attributes as the server's (host-only,
   `/`, Secure, HttpOnly, SameSite=Strict, original expiry). A cookie that is already present is never replaced. If the
   Keychain cannot be read yet (device locked at launch), the restore is retried when the app becomes active and the page
   is reloaded.
   **Read-back guard (M-1).** WebKit is not trusted to have stored what was asked for. Right after `setCookie` the shell
   reads the store back (`allCookies`) and compares every `eve_session` cookie of the host that carries the restored token
   (domain with or without a leading dot): it must be **HttpOnly, Secure, host-only (domain exactly the configured host)
   and Path=/** (`SessionBackup.checkRestored`, pure and unit-tested). If one attribute differs, or the cookie is missing,
   the shell removes those cookies from the store (`deleteCookie`), deletes the Keychain backup, queues the token as a
   pending revoke (and starts the revoke), and does **not** restore: the user pairs again. Expiry and SameSite are not part
   of the comparison (SameSite is not exposed uniformly, the expiry is already capped).
3. **Delete.** On every unpair (settings dialog, offline screen, bridge `unpair`): saving is suspended first; the pending
   server revoke is stored (including the token of the backup if the cookie store is empty); the backup is deleted; website
   data is wiped; saving resumes only after the wipe. When the cookie disappears after this process had seen it (web
   logout, expiry), the backup is deleted too. Expired / future-dated / corrupt / unreadable-schema records are deleted
   at launch. **A delete that fails (L-11)** is remembered in a boolean in `UserDefaults`
   (`eve.shell.session-backup.delete-pending`, not secret) and retried at the next launch, when the app becomes active and on
   every lifecycle nudge, also in a new process; while it is set the record is never restored. A new pairing that is saved
   successfully clears it.
4. **Never restored:** a token that is in the pending-revoke list; **any record while the pending-revoke list is damaged
   (L-13, fail closed)**: the backup is deleted and its token is queued for revoke, which also rewrites the damaged list (an
   unreadable/locked list only delays the restore); a record past its expiry or older than 180 days; a record saved with a
   clock more than 24 h in the future; anything that is not a valid token, so a stored value can never inject cookie
   attributes. **Token format (L-14):** exactly 43 characters of base64url (`A-Za-z0-9-_`), which is what the gateway issues
   (`eve-serving` `internal/session/session.go`: 32 random bytes, `base64.RawURLEncoding`), no longer a 16..128 range.

### Keychain item
- Service `eve.shell.session-backup`, account `session`, generic password, JSON `{v, token, expires, savedAt}`.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`: not synced through iCloud Keychain.
  `ThisDeviceOnly` items **are** part of an *encrypted* device backup (Finder/iTunes; the backup key is needed), but they are
  restored only onto the same device, never onto another one. This is the same class as the pending-revoke item and is stricter than
  `AfterFirstUnlockThisDeviceOnly`: the shell only needs it in the foreground, so it does not need background access. If a
  background launch is ever required, it is a one-line change in `SessionBackupStore.accessible`.
- Default access group (team prefix + bundle ID): only this app, signed by this team, can read it.
- The token never goes to logs, `UserDefaults`, the bridge or the web. The expiry is capped at 180 days after the first
  save, so the copy never extends the server's lifetime.
- Written with update-then-add, never delete-then-add.

### Code
- `Eve/SessionBackupPolicy.swift`: all rules, Foundation only, unit-tested (`EveLogicTests/SessionBackupPolicyTests.swift`).
- `Eve/SessionBackupStore.swift`: the Keychain item (Security).
- `Eve/SessionPersistence.swift`: glue to `WKHTTPCookieStore`, epoch-guarded so a sync that was in flight during an unpair
  can never write the token back.
- `ShellModel.wipeAndRevoke`: begin/discard/end around the existing wipe.

## Characteristics and risks (for review)
- **Survives app deletion.** That is the feature, and also the risk: if someone deletes the app without unpairing, the
  token stays in the Keychain, and a later install of the same app ID from the same team gets it back. The server session is
  alive until it expires (30 days idle / 180 absolute) or is revoked, exactly as it already was while the cookie was
  unreachable. Only code signed by the same team with the same bundle ID can read the item (the Apple ID owner).
  Mitigation: Unpair before deleting; revoke sessions on the server; the record is dropped after 180 days.
- **Device handover / sale.** A reset/erase removes Keychain items. Without an erase, unpair first. The item is `ThisDeviceOnly`:
  it can be contained in an encrypted device backup, but a restore of that backup onto a different device does not bring
  it (only a restore onto the same device does).
- **Theft before expiry.** The attacker needs the unlocked device (or jailbreak-level access) to read the Keychain, which is
  no easier than reading the WebView cookie from the app sandbox. A second copy of a bearer token does add a place to
  protect; the token is not reachable from the web or the bridge, and is only in an encrypted backup of this same device.
- **Stale token.** A restored token that the server has revoked or expired is rejected (401) and the web shows the pairing
  screen; pairing again replaces the cookie and the backup. No loop.
- **Weaker cookie after a restore (M-1).** If WebKit ever stored the restored cookie with other attributes (domain cookie,
  readable by scripts, other path), that cookie and the backup are removed and the token is revoked on the server; see the
  read-back guard above. The comparison is only as good as `WKHTTPCookieStore.allCookies`.
- **Failed Keychain delete after web logout/expiry.** The retry flag above; a stale token is dead on the server anyway
  (web logout calls `DELETE /v1/session`). The flag lives in `UserDefaults`, so it is gone if the app is deleted at that
  moment; the server session is then already revoked or expired, and a 401 leads to pairing again.
- **Failed Keychain delete on unpair.** Retried after the wipe; the stored pending revoke makes the leftover token useless
  on the server, and a pending-revoke token is never restored. Residual: if both the Keychain delete and the revoke fail
  persistently, the revoke banner is shown and the session can be revoked on the server.
- **Different bundle ID or team** means no restore (and a separate app), by design of the Keychain access group.
- Not covered: the cookie store being emptied by iOS storage pressure while the app is installed is restored on next launch
  (same rules), not live.

## To check on a real device (not verified yet)
These cannot be tested on the box or in CI; the first two are what the M-1 guard is about.
1. **Restored cookie attributes.** After delete + reinstall (cookie restored from the Keychain), read the cookie store once
   (a debug log of `name, domain, path, isSecure, isHTTPOnly`, never the value) and confirm: domain is exactly the host
   (no leading dot), path `/`, Secure and HttpOnly true. If the guard rejects a restore on a healthy device, the shell shows
   the pairing screen and the token is revoked: that would show WebKit normalises `setCookie` differently than assumed.
2. **The server's own cookie as WebKit reports it.** After a normal pairing, the same read must show the same attributes;
   otherwise `sessionCookie` (strict since L-9) selects nothing and no backup is ever written.
3. **Keychain item after deleting the app.** Pair, delete the app, install the same build again (same team, same bundle ID):
   the item must still be there and the pairing restored without a code. Then unpair, delete, reinstall: nothing restored.
   Also: install with another bundle ID: nothing restored.
4. **Locked at launch.** Reboot, launch before first unlock (e.g. from a notification): the restore is retried on the next
   active state and the page reloads once.
5. **Web logout** with the device locked is not reachable; check instead that after a web logout + relaunch there is no restore.

## Out of scope / next
- A native "pairing code" screen, or a server-side long-lived device credential, would remove the cookie copy
  entirely but needs a server change.
- Unpair confirmation from the web and background blur are tracked separately (eve-serving #166, eve-ios #17-#19).
