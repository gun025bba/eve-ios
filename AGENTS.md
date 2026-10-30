# AGENTS.md — eve-ios

Thin iOS shell (SwiftUI + WKWebView) around the Eve web UI. All UI lives in eve-web; this repo only does native-only work. See [README.md](README.md) and `docs/`.

## Build / check
```sh
xcodegen generate                 # needs XcodeGen + Xcode 26.x
scripts/check-config.sh           # prints the bundle ID / team / host the build will use
```
Device install steps are in the README. `Config/Local.xcconfig` is gitignored: never commit it.

## Workflow
- One issue → one PR. CI (`compile.yml`) must pass before merge. No force-push.
- Major changes (signing, pairing/session, anything touching the security boundary) need security review.
- Never commit secrets, real hosts/addresses, team or bundle IDs, or the server machine's name. CI scans for these.
- Bot commits carry only `Co-authored-by: Grok <grok-bot@noreply.invalid>`. Codex commits: no extra trailers.

## Codex
Not the primary worker here. If used: implementation only, open a PR and stop. Do not deploy, touch signing/config files, handle secrets, or edit `.github/workflows/`.
