#!/usr/bin/env bash
# Compare what is actually DEPLOYED against what this repo ships.
#
# Drift is normally found by accident — you go looking at one file for an
# unrelated reason and notice it is older than the repo. Everything else stays
# invisible. This makes it a command instead.
#
# STRICTLY READ-ONLY. It never writes, copies, patches or restarts anything,
# on purpose: a "checker" that can also fix is how a stale whole-file patch
# script silently reverted three weeks of hardening here on 2026-08-01.
#
# Usage:
#   ./check-drift.sh                                  # everything on this machine
#   ./check-drift.sh --host pi@192.168.1.50   # everything on a remote Pi
#   ./check-drift.sh --deep --host pi        # also prove the patches reproduce dist/
#   ./check-drift.sh --host pi --homebridge /home/pi/volumes/homebridge \
#                    --scripts /home/pi/scripts
#
# Exit: 0 = in sync, 1 = drift found, 2 = could not check.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HOST=""
HB_DIR=""
SCRIPTS_DIR=""
DEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST="$2"; shift 2 ;;
    --repo)        REPO_DIR="$2"; shift 2 ;;
    --homebridge)  HB_DIR="$2"; shift 2 ;;
    --scripts)     SCRIPTS_DIR="$2"; shift 2 ;;
    --deep)        DEEP=1; shift ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Defaults differ local vs remote only in the usual install locations.
HB_DIR="${HB_DIR:-${HOMEBRIDGE_DIR:-$HOME/homebridge}}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/scripts}"
PLUGIN_DIR="$HB_DIR/node_modules/homebridge-google-nest-sdm"

[ -d "$REPO_DIR/scripts" ] || { echo "ERROR: no repo at $REPO_DIR (use --repo)"; exit 2; }

# --- remote/local plumbing ------------------------------------------------
# One code path for both: fetch into a temp dir, compare locally.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

rexec() {  # run a read-only shell snippet where the deployment lives
  if [ -n "$HOST" ]; then ssh -o ConnectTimeout=30 "$HOST" "$@"; else bash -c "$@"; fi
}
rfetch() {  # $1=remote path  $2=local dest; silent failure means "not deployed"
  if [ -n "$HOST" ]; then scp -q "$HOST:$1" "$2" 2>/dev/null
  else [ -f "$1" ] && cp "$1" "$2" 2>/dev/null; fi
}

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; DIM=""; OFF=""; }

drift=0; missing=0; checked=0

compare() {  # $1=label  $2=repo-relative path  $3=deployed absolute path
  local label="$1" repo="$REPO_DIR/$2" dep="$3" tmp="$WORK/$(echo "$1" | tr '/ ' '__')"
  checked=$((checked + 1))
  if [ ! -f "$repo" ]; then
    printf "  %-34s %srepo file missing%s (%s)\n" "$label" "$YEL" "$OFF" "$2"; missing=$((missing+1)); return
  fi
  if ! rfetch "$dep" "$tmp" || [ ! -s "$tmp" ]; then
    printf "  %-34s %snot deployed%s %s(%s)%s\n" "$label" "$YEL" "$OFF" "$DIM" "$dep" "$OFF"; missing=$((missing+1)); return
  fi
  if cmp -s "$repo" "$tmp"; then
    printf "  %-34s %sin sync%s\n" "$label" "$GRN" "$OFF"
  else
    printf "  %-34s %sDRIFTED%s  %s lines differ\n" "$label" "$RED" "$OFF" "$(diff "$repo" "$tmp" | grep -c '^[<>]')"
    printf "      %srepo:%s     %s\n" "$DIM" "$OFF" "$repo"
    printf "      %sdeployed:%s %s%s\n" "$DIM" "$OFF" "${HOST:+$HOST:}" "$dep"
    printf "      %sdiff:%s     diff %s <(%s)%s\n" "$DIM" "$OFF" "$repo" \
      "${HOST:+ssh $HOST }cat $dep" "$OFF"
    drift=$((drift + 1))
  fi
}

echo
echo "Drift check  ${HOST:+($HOST) }"
echo "  repo: $REPO_DIR"
echo

# --- 1. files that must be byte-identical ---------------------------------
echo "Byte-identical artifacts"
compare "go2rtc-snapshot-warmer.sh" "scripts/go2rtc-snapshot-warmer.sh" "$SCRIPTS_DIR/go2rtc-snapshot-warmer.sh"
compare "nest-go2rtc-sync.py"       "scripts/nest-go2rtc-sync.py"       "$SCRIPTS_DIR/nest-go2rtc-sync.py"
compare "go2rtc-wedge-detector.py"  "scripts/go2rtc-wedge-detector.py"  "$SCRIPTS_DIR/go2rtc-wedge-detector.py"
compare "PrebufferManager.js"       "patches/homebridge-plugin/new-files/PrebufferManager.js" \
                                    "$PLUGIN_DIR/dist/PrebufferManager.js"
echo

# --- 2. plugin version ----------------------------------------------------
# package.json is METADATA and can lie. Patching dist/ in place does not make
# npm rewrite the version field, so a plugin whose dist/ is 1.1.24 can still
# report 1.1.23. Trusting this field alone produced a wrong public claim on
# 2026-08-01. It is reported for information; --deep is what actually decides.
echo "Plugin version ${DIM}(metadata — see --deep for the authoritative check)${OFF}"
EXPECT_VER="$(grep -m1 '^EXPECT_VER=' "$REPO_DIR/scripts/apply-snapshot-patch.sh" 2>/dev/null | cut -d'"' -f2)"
CUR_VER="$(rexec "python3 -c \"import json;print(json.load(open('$PLUGIN_DIR/package.json'))['version'])\" 2>/dev/null" | tr -d '\r')"
if [ -z "$CUR_VER" ]; then
  printf "  %-34s %scould not read%s %s(%s)%s\n" "package.json" "$YEL" "$OFF" "$DIM" "$PLUGIN_DIR/package.json" "$OFF"; missing=$((missing+1))
elif [ "$CUR_VER" = "$EXPECT_VER" ]; then
  printf "  %-34s %s%s%s, matching the patch base\n" "package.json" "$GRN" "$CUR_VER" "$OFF"
else
  printf "  %-34s %s%s%s vs patch base %s %s(may just be stale metadata)%s\n" \
    "package.json" "$YEL" "$CUR_VER" "$OFF" "$EXPECT_VER" "$DIM" "$OFF"
  printf "      %sNOT counted as drift. apply-snapshot-patch.sh reads this field and\n" "$DIM"
  printf "      would refuse to run, so it matters for recovery after an npm install —\n"
  printf "      but it says nothing about what the running code is. Use --deep.%s\n" "$OFF"
fi
echo

# --- 2b. deep check: do the repo's patches REPRODUCE the deployed dist? ----
# The only claim that matters: stock EXPECT_VER + this repo's diffs == what is
# running. Byte-identical or it is not reproducible.
if [ "$DEEP" = "1" ]; then
  echo "Reproducibility ${DIM}(stock $EXPECT_VER + repo patches vs deployed dist)${OFF}"
  if ! command -v npm >/dev/null 2>&1; then
    printf "  %-34s %snpm not available%s — cannot fetch stock %s\n" "reproduce" "$YEL" "$OFF" "$EXPECT_VER"; missing=$((missing+1))
  else
    B="$WORK/deep"; mkdir -p "$B"
    if ( cd "$B" && npm pack "homebridge-google-nest-sdm@$EXPECT_VER" >/dev/null 2>&1 \
         && tar xzf "homebridge-google-nest-sdm-$EXPECT_VER.tgz" ); then
      pfail=0
      for p in "$REPO_DIR"/patches/homebridge-plugin/*.patch; do
        patch -p1 -d "$B/package" <"$p" >/dev/null 2>&1 || {
          printf "  %-34s %sPATCH FAILED%s on stock %s\n" "$(basename "$p")" "$RED" "$OFF" "$EXPECT_VER"
          pfail=1; drift=$((drift + 1)); }
      done
      cp "$REPO_DIR/patches/homebridge-plugin/new-files/PrebufferManager.js" "$B/package/dist/" 2>/dev/null
      if [ "$pfail" -eq 0 ]; then
        for f in sdm/Api.js sdm/Camera.js HksvStreamer.js StreamingDelegate.js PrebufferManager.js; do
          mkdir -p "$B/live/$(dirname "$f")"
          if ! rfetch "$PLUGIN_DIR/dist/$f" "$B/live/$f" || [ ! -s "$B/live/$f" ]; then
            printf "  %-34s %snot deployed%s\n" "$f" "$YEL" "$OFF"; missing=$((missing+1)); continue
          fi
          if cmp -s "$B/package/dist/$f" "$B/live/$f"; then
            printf "  %-34s %sreproduced exactly%s\n" "$f" "$GRN" "$OFF"
          else
            printf "  %-34s %sDIFFERS%s  %s lines\n" "$f" "$RED" "$OFF" \
              "$(diff "$B/package/dist/$f" "$B/live/$f" | grep -c '^[<>]')"
            drift=$((drift + 1))
          fi
        done
      fi
    else
      printf "  %-34s %scould not fetch%s stock %s from npm\n" "reproduce" "$YEL" "$OFF" "$EXPECT_VER"; missing=$((missing+1))
    fi
  fi
  echo
fi

# --- 3. landmines: stale whole-file patch blobs ---------------------------
# The repo shipped whole-file copies until 2026-07-19 (446b29f) and then moved
# to unified diffs, precisely because pasting a stale whole file reverts
# everything done since. Any surviving *.patched tree can still do that.
echo "Stale whole-file patch blobs"
BLOBS="$(rexec "ls -1 $HB_DIR/patches/*.patched 2>/dev/null | wc -l" | tr -d ' \r')"
if [ "${BLOBS:-0}" -gt 0 ]; then
  printf "  %-34s %s%s found%s in %s/patches/\n" "*.patched" "$RED" "$BLOBS" "$OFF" "$HB_DIR"
  printf "      %sThese are whole-file snapshots. Applying them reverts any later\n" "$DIM"
  printf "      hardening. Use the repo's unified diffs instead.%s\n" "$OFF"
  drift=$((drift + 1))
else
  printf "  %-34s %snone%s\n" "*.patched" "$GRN" "$OFF"
fi
echo

# --- verdict --------------------------------------------------------------
if [ "$drift" -eq 0 ] && [ "$missing" -eq 0 ]; then
  echo "${GRN}Everything checked is in sync.${OFF} ($checked artifacts)"
  exit 0
fi
[ "$missing" -gt 0 ] && echo "${YEL}$missing not deployed / unreadable${OFF} — expected if you run a subset."
if [ "$drift" -gt 0 ]; then
  echo "${RED}$drift drifted.${OFF} Decide direction before copying anything:"
  echo "  repo ahead  -> deploy the repo version"
  echo "  Pi ahead    -> commit the deployed version (it is an undeployed hotfix)"
  exit 1
fi
exit 0
