#!/bin/bash
# Re-applies all homebridge-google-nest-sdm patches. MUST run after any npm install
# of the plugin (npm wipes node_modules; the backup tar excludes node_modules too).
#
# Patches (all whole-file copies from patches/):
#   Camera.js            -> getSnapshot() reads /homebridge/nest-snaps/<key>.jpg; event() touches .refresh
#   Api.js               -> pubsub handler guard (relationUpdate events with no resourceUpdate)
#   StreamingDelegate.js -> live streams via go2rtc RTSP + initial inactivity watchdog
#
# The .patched files were cut from plugin version below. A plugin UPGRADE moves internals;
# blindly pasting old files over a new version can revert upstream fixes or break. So we
# ABORT on version mismatch and require re-cutting the patches against the new version.
set -uo pipefail
# Point HOMEBRIDGE_DIR at your Homebridge data directory (the one holding node_modules/
# and where you keep this patches/ folder). Override any of these via env vars:
#   HOMEBRIDGE_DIR=/path/to/homebridge PATCH_DIR=/path/to/patches ./apply-snapshot-patch.sh
HOMEBRIDGE_DIR="${HOMEBRIDGE_DIR:-$HOME/homebridge}"
PLUGIN="${PLUGIN:-$HOMEBRIDGE_DIR/node_modules/homebridge-google-nest-sdm}"
D="${PATCH_DIR:-$HOMEBRIDGE_DIR/patches}"
CONTAINER="${HOMEBRIDGE_CONTAINER:-homebridge}"
EXPECT_VER="1.1.23"

[ -d "$PLUGIN" ] || { echo "plugin not installed"; exit 1; }
CUR_VER=$(python3 -c "import json;print(json.load(open('$PLUGIN/package.json'))['version'])")
if [ "$CUR_VER" != "$EXPECT_VER" ]; then
  echo "REFUSING: plugin is $CUR_VER but patches were cut from $EXPECT_VER."
  echo "Re-cut the patches against $CUR_VER before re-applying (internals may have moved)."
  exit 1
fi

stamp=$(date +%Y%m%d-%H%M%S)
applied=0
apply_one() {  # $1=dist-relative path  $2=sentinel  $3=patched-filename
  local f="$PLUGIN/$1" sentinel="$2" src="$D/$3"
  [ -f "$f" ] || { echo "  MISSING: $1 (skipped)"; return; }
  [ -f "$src" ] || { echo "  NO PATCH FILE: $3 (skipped)"; return; }
  if grep -q "$sentinel" "$f"; then echo "  ok: $1 already patched"; return; fi
  cp "$f" "$f.bak-$stamp" || { echo "  BACKUP FAILED: $1 (skipped)"; return; }
  cp "$src" "$f" || { echo "  COPY FAILED: $1 — restoring backup"; cp "$f.bak-$stamp" "$f"; return; }
  echo "  PATCHED: $1"
  applied=1
}

apply_one "dist/sdm/Camera.js"          "nest-snaps"              "Camera.js.patched"
apply_one "dist/sdm/Api.js"             "relationUpdate), ignoring" "Api.js.patched"
apply_one "dist/StreamingDelegate.js"   "go2rtcKey"               "StreamingDelegate.js.patched"

if [ "$applied" = 1 ]; then
  echo "Done. Restart: docker restart $CONTAINER"
else
  echo "Nothing to do (all patched)."
fi
