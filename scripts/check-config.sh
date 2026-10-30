#!/bin/bash
# Prints (and optionally asserts) the build settings the Eve target will REALLY use, so a Config/Local.xcconfig that is
# ignored, shadowed or misspelled is caught before anything is built or installed.
#
#   scripts/check-config.sh                       # generate the project, print the resolved values
#   scripts/check-config.sh KEY=VALUE ...         # ... and fail unless every KEY resolves to VALUE
#   keys: PRODUCT_BUNDLE_IDENTIFIER DEVELOPMENT_TEAM EVE_HOST MARKETING_VERSION CURRENT_PROJECT_VERSION ...
#
# Needs macOS with Xcode and XcodeGen. Set NO_GENERATE=1 to skip `xcodegen generate`.
# Exit codes: 0 ok, 1 mismatch, 2 tooling/usage error.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${NO_GENERATE:-0}" != "1" ]; then
  command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 2; }
  xcodegen generate >/dev/null
fi
command -v xcodebuild >/dev/null || { echo "xcodebuild not found" >&2; exit 2; }

OUT="$(xcodebuild -project Eve.xcodeproj -scheme Eve -configuration "${CONFIGURATION:-Debug}" -showBuildSettings 2>/dev/null)" \
  || { echo "xcodebuild -showBuildSettings failed" >&2; exit 2; }

# One value per key; more than one distinct value (several targets/blocks disagree) is an error.
resolved() {
  local vals
  vals="$(printf '%s\n' "$OUT" | awk -v k="$1" '$1 == k && $2 == "=" { sub(/^[^=]*= ?/, ""); print }' | sort -u)"
  if [ "$(printf '%s' "$vals" | grep -c '')" -gt 1 ]; then echo "<ambiguous>"; else printf '%s' "$vals"; fi
}

fail=0
for key in PRODUCT_BUNDLE_IDENTIFIER DEVELOPMENT_TEAM EVE_HOST MARKETING_VERSION CURRENT_PROJECT_VERSION; do
  printf '%-26s %s\n' "$key" "$(resolved "$key")"
done
for pair in "$@"; do
  key="${pair%%=*}"; want="${pair#*=}"
  [ "$key" != "$pair" ] || { echo "bad argument '$pair' (use KEY=VALUE)" >&2; exit 2; }
  got="$(resolved "$key")"
  if [ "$got" != "$want" ]; then
    echo "MISMATCH: $key resolves to '${got:-<empty>}', expected '$want'" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && { [ "$#" -eq 0 ] || echo "ok: all expected values resolved"; }
exit "$fail"
