# eve-ios

Eve's thin iOS shell (SwiftUI + WKWebView). All UI lives in the web app; the shell only does native-only work.
Design: `eve-serving/docs/architecture/ios-shell.md`.

## Install on your iPhone (fresh clone, free Apple ID)
Needs a Mac with Xcode 26.x, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), Developer Mode on the iPhone, and your Apple ID added in Xcode (Settings › Accounts). The script reads your team ID from the development certificate Xcode creates for that account (see "Team ID" if there is none yet).
```sh
git clone https://github.com/gun025bba/eve-ios.git && cd eve-ios

# 1) Local settings (Config/Local.xcconfig is gitignored; nothing real is ever committed).
#    --host: bare host name of your Eve web UI (https, 443 only)   --bundle-id: your own ID, keep it fixed forever
scripts/setup-local.sh --host <your-eve-host> --bundle-id com.<yourname>.eve
#    It finds your team ID itself (see below), writes Config/Local.xcconfig, runs xcodegen and then
#    prints the values the build REALLY uses; it fails if the bundle ID, team or host did not reach the build.

# 2) Build + install (iPhone connected by cable and unlocked)
xcodebuild -project Eve.xcodeproj -scheme Eve -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
DEV=$(xcrun devicectl list devices | awk '/connected/ {print $3; exit}')
xcrun devicectl device install app --device "$DEV" build/Build/Products/Debug-iphoneos/Eve.app
```
Then trust the developer under Settings › General › VPN & Device Management, open Eve and pair once in the web UI.

**Every 7 days** (free Apple ID): `git pull --ff-only`, run `scripts/check-config.sh` (prints the bundle ID/team that will be used; add `PRODUCT_BUNDLE_IDENTIFIER=com.<yourname>.eve` to assert it), then repeat step 2. Install **over** the existing app; the pairing stays. Do not delete the app first and do not change the bundle ID: see "Pairing and reinstalls" below.

### Team ID
The team ID is the `OU` field of your *Apple Development* certificate's subject (10 characters). `scripts/setup-local.sh --print-team` prints it; by hand:
```sh
security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject | tr ',/' '\n\n' | grep 'OU *='
```
The number in parentheses in the certificate *name* (`Apple Development: you (XXXXXXXXXX)`) is a different ID: do not use it. If you have several teams, pass `--team ABCDE12345`. No certificate yet (nothing built from this Mac so far)? Run `xcodegen generate`, open `Eve.xcodeproj` once and pick your team under Signing & Capabilities (that creates the certificate), or read the Team ID on developer.apple.com/account (Membership details) and pass it with `--team`.

### How the config layers (and why Local always wins)
`project.yml` points the project and the Eve target at `Config/Shell.xcconfig`. It includes `Base.xcconfig` (placeholder defaults), sets `PRODUCT_BUNDLE_IDENTIFIER`/`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` from `EVE_*`, and includes `Config/Local.xcconfig` **last** (`#include?`, so a missing file is fine). In an xcconfig the last assignment wins, so Local overrides everything above it, and it may also set `PRODUCT_BUNDLE_IDENTIFIER` or `DEVELOPMENT_TEAM` directly. Do not add those settings to `project.yml`: target build settings sit above every xcconfig and would silently ignore Local. CI checks all of this on every PR with `xcodebuild -showBuildSettings` (`scripts/check-config.sh`).

Manual alternative to the script: `cp Config/Local.xcconfig.example Config/Local.xcconfig`, edit `EVE_HOST`, `EVE_BUNDLE_ID`, `DEVELOPMENT_TEAM`, `xcodegen generate`, then `scripts/check-config.sh`.

## Build
Requires Xcode 26.x and XcodeGen. `xcodegen generate && open Eve.xcodeproj` for the Xcode UI (select your free Apple ID team in Signing, Run).
Alternative: **SideStore/AltStore**: take the unsigned `Eve.ipa` (CI artifact `Eve-unsigned-ipa`, or your own build) and open it in SideStore (Files/AirDrop); SideStore signs with your free Apple ID and refreshes every 7 days. Distribution stays inside the tailnet behind session auth; if SideStore can't fetch the source, install manually — no token/unauthenticated workarounds. SideStore may rewrite the bundle ID when it signs, so switching between an Xcode install and a SideStore install can give a second app that needs its own pairing.

## Use
- First launch: pair in the web UI (the session cookie lives in the WebView's persistent data store; a copy is kept in the Keychain, see below). Pair separately from Safari.
- Shell settings: three-finger long press → Unpair (asks the web to log out, wipes all cookies/website data immediately, deletes the Keychain copy of the session, and revokes the server session; if offline, the revoke is kept in the Keychain and retried on launch/foreground/network return). Also on the offline screen.

## Pairing and reinstalls
| Situation | Pairing kept? |
|---|---|
| Install over the existing app (same bundle ID, same team) — the normal 7-day refresh | yes: the app's data container, including the WebView cookie, is kept |
| Delete the app, then install again (same bundle ID, same team) | yes: the shell restores the session cookie from its Keychain copy before the first page load |
| Different bundle ID (typo, Local.xcconfig not applied, Xcode vs SideStore) or another team | no: that is a different app with its own data and Keychain; pair again |
| Unpair, web logout, or the server session expired (30 days idle / 180 days) or was revoked | no, by design |

Design and security notes: `docs/session-persistence.md`.

## Bridge (v1.1.0)
Web → shell `window.webkit.messageHandlers.eve.postMessage({v:1,id,type,payload})`; shell → web `window.__eveShell.receive(msg)`.
Types: `hello` → `capabilities {bridge, shell, features}`, `haptics {style}`, `unpair`, `notify_schedule {id, afterSec}`, `notify_cancel {id}` (local reminders, generic fixed text, see `docs/fe-local-notify.md`). Shell → web: `logout_requested` (web should call its logout API then send `unpair`). Unknown → `{ok:false,error_code:"unknown_type"}`. Replies go only to the frame that sent the request (main frame, configured origin, same document).
