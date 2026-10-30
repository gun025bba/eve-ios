#!/bin/bash
# Fresh-clone setup: writes Config/Local.xcconfig (gitignored), regenerates the project and checks that the values
# really reach the build. The team ID is read from your Apple Development certificate (the OU field of its subject);
# the number in the certificate's name is a different ID and must not be used.
#
#   scripts/setup-local.sh --host eve.example --bundle-id com.yourname.eve [--team ABCDE12345] [--force]
#
# --host       bare host name of your Eve web UI (no https://, no port)
# --bundle-id  your own, fixed reverse-DNS ID; changing it later installs a second app and forgets the pairing
# --team       10-character team ID; found automatically when exactly one Apple Development team exists in your keychain
# Run `scripts/setup-local.sh --print-team` to only print the detected team ID(s).
set -euo pipefail
cd "$(dirname "$0")/.."

# Prints the distinct team IDs (OU of the subject) of the Apple Development certificates in the keychain search list.
detect_teams() {
  local tmp n=0 f
  tmp="$(mktemp -d)"
  security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/ { n++ } n > 0 { print > (dir "/c" n ".pem") }'
  for f in "$tmp"/c*.pem; do
    [ -e "$f" ] || continue
    openssl x509 -in "$f" -noout -subject 2>/dev/null \
      | tr ',/' '\n\n' | sed -n 's/^ *OU *= *\([A-Z0-9]\{10\}\) *$/\1/p'
  done | sort -u
  rm -rf "$tmp"
}

HOST=""; BUNDLE=""; TEAM=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE="${2:-}"; shift 2 ;;
    --team) TEAM="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --print-team) detect_teams; exit 0 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$HOST" ] && [ -n "$BUNDLE" ] || { echo "--host and --bundle-id are required (see --help)" >&2; exit 2; }
printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
  || { echo "--host must be a bare host name (no scheme, port or path)" >&2; exit 2; }
printf '%s' "$BUNDLE" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' && printf '%s' "$BUNDLE" | grep -q '\.' \
  || { echo "--bundle-id must look like com.yourname.eve" >&2; exit 2; }

if [ -z "$TEAM" ]; then
  TEAMS="$(detect_teams)"
  case "$(printf '%s' "$TEAMS" | grep -c '[A-Z0-9]')" in
    1) TEAM="$TEAMS" ;;
    0) echo "No Apple Development certificate found. Sign in to Xcode (Settings > Accounts), build once, or pass --team." >&2; exit 2 ;;
    *) echo "Several teams found; pass --team with one of:" >&2; printf '%s\n' "$TEAMS" >&2; exit 2 ;;
  esac
fi
printf '%s' "$TEAM" | grep -Eq '^[A-Z0-9]{10}$' || { echo "--team must be 10 characters (A-Z, 0-9)" >&2; exit 2; }

if [ -e Config/Local.xcconfig ] && [ "$FORCE" -ne 1 ]; then
  echo "Config/Local.xcconfig already exists; use --force to overwrite it." >&2
  exit 2
fi
umask 077
printf '%s\n' \
  "// Written by scripts/setup-local.sh. Local to this machine, gitignored: never commit it." \
  "EVE_HOST = $HOST" \
  "EVE_BUNDLE_ID = $BUNDLE" \
  "DEVELOPMENT_TEAM = $TEAM" > Config/Local.xcconfig
echo "Wrote Config/Local.xcconfig"

# Fail loudly if any value does not reach the build.
"$(dirname "$0")/check-config.sh" "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE" "DEVELOPMENT_TEAM=$TEAM" "EVE_HOST=$HOST"
