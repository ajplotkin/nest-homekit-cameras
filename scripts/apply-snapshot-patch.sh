#!/bin/bash
# Re-applies the homebridge-google-nest-sdm plugin patches after any `npm install`
# of the plugin (npm wipes node_modules, taking the patches with it).
#
# It applies the unified diffs in ../patches/homebridge-plugin/ to your installed
# plugin. Each patch is idempotent (skipped if already present) and the script exits
# NON-ZERO and loudly if anything is missing or does not apply — so a re-apply can
# never silently leave you unpatched.
#
# Override any path via env vars:
#   HOMEBRIDGE_DIR=/path/to/homebridge \
#   HOMEBRIDGE_CONTAINER=my-homebridge \
#   ./apply-snapshot-patch.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/../patches/homebridge-plugin}"
HOMEBRIDGE_DIR="${HOMEBRIDGE_DIR:-$HOME/homebridge}"
PLUGIN="${PLUGIN:-$HOMEBRIDGE_DIR/node_modules/homebridge-google-nest-sdm}"
CONTAINER="${HOMEBRIDGE_CONTAINER:-homebridge}"
EXPECT_VER="1.1.23"

[ -d "$PLUGIN" ] || { echo "ERROR: plugin not found at $PLUGIN (set HOMEBRIDGE_DIR)"; exit 1; }
[ -d "$PATCH_DIR" ] || { echo "ERROR: patch dir not found at $PATCH_DIR"; exit 1; }

CUR_VER=$(node -e "console.log(require('$PLUGIN/package.json').version)" 2>/dev/null)
if [ "$CUR_VER" != "$EXPECT_VER" ]; then
  echo "REFUSING: plugin is '$CUR_VER' but these patches were cut from $EXPECT_VER."
  echo "The compiled dist/ layout moves between releases — re-cut the diffs against"
  echo "$CUR_VER before applying (see the guide), or pin the plugin to $EXPECT_VER."
  exit 1
fi

# patchfile | dist-relative target | sentinel string proving it's already applied
patches=(
  "Camera.js.patch|dist/sdm/Camera.js|isEventStale"
  "Doorbell.js.patch|dist/sdm/Doorbell.js|isEventStale"
  "Api.js.patch|dist/sdm/Api.js|subscribeToEvents"
  "StreamingDelegate.js.patch|dist/StreamingDelegate.js|go2rtcKey"
  "HksvStreamer.js.patch|dist/HksvStreamer.js|hang forever"
)

applied=0
failed=0
for entry in "${patches[@]}"; do
  IFS='|' read -r pf target sentinel <<<"$entry"
  patchfile="$PATCH_DIR/$pf"
  tgt="$PLUGIN/$target"
  [ -f "$patchfile" ] || { echo "  ERROR: missing patch file $patchfile"; failed=1; continue; }
  [ -f "$tgt" ]       || { echo "  ERROR: target not found: $target"; failed=1; continue; }
  if grep -qF "$sentinel" "$tgt"; then
    echo "  ok: $target already patched"
    continue
  fi
  if patch -p1 -d "$PLUGIN" --dry-run <"$patchfile" >/dev/null 2>&1; then
    patch -p1 -d "$PLUGIN" <"$patchfile" >/dev/null && { echo "  PATCHED: $target"; applied=1; }
  else
    echo "  ERROR: $pf does not apply cleanly to $target (wrong plugin version, or already edited?)"
    failed=1
  fi
done

if [ "$failed" = 1 ]; then
  echo "FAILED: one or more patches did not apply — the plugin is NOT fully patched."
  exit 1
fi
if [ "$applied" = 1 ]; then
  echo "Done. Restart Homebridge:  docker restart $CONTAINER"
else
  echo "All patches already present; nothing to do."
fi
