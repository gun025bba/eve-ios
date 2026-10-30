# Keeping the pairing across reinstalls (shell 0.3.0)

Status: implemented in shell 0.3.0. Security review requested. Not yet verified on a real device.

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
   changes phase). When the `eve_session` cookie of the configured host (exact name, Secure, exact host, valid value, with
   an expiry) changes, its value and expiry are written to one Keychain item.
2. **Restore.** At launch, before the first page load, if the cookie store has **no** `eve_session` cookie and the
   Keychain holds a usable record, the shell puts the cookie back with the same attributes as the server's (host-only,
   `/`, Secure, HttpOnly, SameSite=Strict, original expiry). A cookie that is already present is never replaced. If the
   Keychain cannot be read yet (device locked at launch), the restore is retried when the app becomes active and the page
   is reloaded.
3. **Delete.** On every unpair (settings dialog, offline screen, bridge `unpair`): saving is suspended first; the pending
   server revoke is stored (including the token of the backup if the cookie store is empty); the backup is deleted; website
   data is wiped; saving resumes only after the wipe. When the cookie disappears after this process had seen it (web
   logout, expiry), the backup is deleted too. Expired / future-dated / corrupt / unreadable-schema records are deleted
   at launch.
4. **Never restored:** a token that is in the pending-revoke list; a record past its expiry or older than 180 days; a record
   saved with a clock more than 24 h in the future; anything that is not a valid base64url token (16..128 bytes), so a stored
   value can never inject cookie attributes.

### Keychain item
- Service `eve.shell.session-backup`, account `session`, generic password, JSON `{v, token, expires, savedAt}`.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`: no iCloud Keychain, not in backups, not
  migrated to another device. This is the same class as the pending-revoke item and is stricter than
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
- **Device handover / sale.** A reset/erase removes Keychain items. Without an erase, unpair first. The item is `ThisDeviceOnly`,
  so a restore from an iCloud/iTunes backup onto a new device does not bring it.
- **Theft before expiry.** The attacker needs the unlocked device (or jailbreak-level access) to read the Keychain, which is
  no easier than reading the WebView cookie from the app sandbox. A second copy of a bearer token does add a place to
  protect; the token is not reachable from the web, the bridge or backups.
- **Stale token.** A restored token that the server has revoked or expired is rejected (401) and the web shows the pairing
  screen; pairing again replaces the cookie and the backup. No loop.
- **Failed Keychain delete on unpair.** Retried after the wipe; the stored pending revoke makes the leftover token useless
  on the server, and a pending-revoke token is never restored. Residual: if both the Keychain delete and the revoke fail
  persistently, the revoke banner is shown and the session can be revoked on the server.
- **Different bundle ID or team** means no restore (and a separate app), by design of the Keychain access group.
- Not covered: the cookie store being emptied by iOS storage pressure while the app is installed is restored on next launch
  (same rules), not live.

## Out of scope / next
- A native "pairing code" screen, or a server-side long-lived device credential, would remove the cookie copy
  entirely but needs a server change.
- Unpair confirmation from the web and background blur are tracked separately (eve-serving #166, eve-ios #17-#19).
