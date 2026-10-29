# eve-ios

Eve's thin iOS shell (SwiftUI + WKWebView). All UI lives in the web app; the shell only does native-only work.
Design: `eve-serving/docs/architecture/ios-shell.md`.

## Config
```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # gitignored
# set EVE_HOST (bare hostname, https:443 only) and optionally DEVELOPMENT_TEAM / EVE_BUNDLE_ID
```
Never commit real hostnames, tailnet addresses, Team IDs or secrets. The bundle ID must stay fixed once installed.

## Build
Requires Xcode 26.x and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
```sh
xcodegen generate && open Eve.xcodeproj
```

## Install
- **Xcode**: select your free Apple ID team in Signing, connect the iPhone (Developer Mode on), Run. Trust the developer under Settings › General › VPN & Device Management.
- **SideStore/AltStore**: take the unsigned `Eve.ipa` (CI artifact `Eve-unsigned-ipa`, or your own build) and open it in SideStore (Files/AirDrop); SideStore signs with your free Apple ID and refreshes every 7 days. Distribution stays inside the tailnet behind session auth; if SideStore can't fetch the source, install manually — no token/unauthenticated workarounds.

## Use
- First launch: pair in the web UI (session cookie is stored only in the WebView's persistent data store). Pair separately from Safari.
- Shell settings: three-finger long press → Unpair (asks the web to log out, wipes all cookies/website data immediately, and revokes the server session; if offline, the revoke is kept in the Keychain and retried on launch/foreground/network return). Also on the offline screen.

## Bridge (v1.1.0)
Web → shell `window.webkit.messageHandlers.eve.postMessage({v:1,id,type,payload})`; shell → web `window.__eveShell.receive(msg)`.
Types: `hello` → `capabilities {bridge, shell, features}`, `haptics {style}`, `unpair`, `notify_schedule {id, afterSec}`, `notify_cancel {id}` (local reminders, generic fixed text, see `docs/fe-local-notify.md`). Shell → web: `logout_requested` (web should call its logout API then send `unpair`). Unknown → `{ok:false,error_code:"unknown_type"}`. Replies go only to the frame that sent the request (main frame, configured origin, same document).
