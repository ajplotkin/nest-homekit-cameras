#!/usr/bin/env bash
# Compare what is actually DEPLOYED against what this repo ships.
#
# Drift is normally found by accident — you go looking at one file for an
# unrelated reason and notice it is older than the repo. Everything else stays
# invisible. This makes it a command instead.
#
# STRICTLY READ-ONLY WITH RESPECT TO THE DEPLOYMENT. It never writes, patches or
# restarts anything on the target box, on purpose: a "checker" that can also fix is how a
# stale whole-file patch script silently reverted three weeks of hardening here on
# 2026-08-01. (It does copy deployed files OUT, into a local temp dir, and under --deep it
# npm-fetches the stock package and patches that local copy. Nothing it writes is ever on
# the deployment side.)
#
# Usage:
#   ./check-drift.sh                                  # everything on this machine
#   ./check-drift.sh --host you@your-pi.local   # everything on a remote Pi
#   ./check-drift.sh --deep --host pi        # also prove the patches reproduce dist/
#   ./check-drift.sh --host pi --homebridge /home/adamandaj/volumes/homebridge \
#                    --scripts /home/adamandaj/scripts
#
# With --host the install locations are resolved ON THE REMOTE (~/volumes/homebridge,
# ~/homebridge, /var/lib/homebridge are probed in that order), so --homebridge and
# --scripts are only needed for a non-standard layout.
#
# Exit: 0 = in sync, 1 = drift found, 2 = could not check.
# A run that compared nothing exits 2, never 0: "in sync" over zero comparisons is
# the one answer this script must never give.
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
    -h|--help)     sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

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

# --- where the deployment lives -------------------------------------------
# These MUST be resolved where the deployment is, not here. Defaulting to the
# local $HOME under --host silently built Mac paths, checked them on the Pi,
# found nothing, and still exited 0 — a false clean, which is precisely the
# failure this script exists to catch. Probe instead of assuming: the Pi keeps
# its Homebridge volume at ~/volumes/homebridge, a plain install uses
# ~/homebridge, and the Debian package uses /var/lib/homebridge.
BASE_HOME="$HOME"
if [ -n "$HOST" ]; then
  BASE_HOME="$(rexec 'echo $HOME' 2>/dev/null | tr -d '\r')"
  [ -n "$BASE_HOME" ] || {
    echo "ERROR: could not resolve \$HOME on $HOST (ssh failed?); pass --homebridge and --scripts"; exit 2; }
fi

if [ -z "$HB_DIR" ] && [ -z "${HOMEBRIDGE_DIR:-}" ]; then
  for cand in "$BASE_HOME/volumes/homebridge" "$BASE_HOME/homebridge" /var/lib/homebridge; do
    if rexec "[ -d '$cand/node_modules/homebridge-google-nest-sdm' ]" 2>/dev/null; then
      HB_DIR="$cand"; break
    fi
  done
fi
HB_DIR="${HB_DIR:-${HOMEBRIDGE_DIR:-$BASE_HOME/homebridge}}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$BASE_HOME/scripts}"
PLUGIN_DIR="$HB_DIR/node_modules/homebridge-google-nest-sdm"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; DIM=""; OFF=""; }

# `checked` counts comparisons ATTEMPTED; `verified` counts those that actually
# read both sides. Only the second can support a clean verdict — a run where every
# fetch failed still increments `checked`, which is how a wrong --homebridge path
# printed "in sync" over zero real comparisons.
drift=0; missing=0; checked=0; verified=0

compare() {  # $1=label  $2=repo-relative path  $3=deployed absolute path
  local label="$1" repo="$REPO_DIR/$2" dep="$3" tmp="$WORK/$(echo "$1" | tr '/ ' '__')"
  checked=$((checked + 1))
  if [ ! -f "$repo" ]; then
    printf "  %-34s %srepo file missing%s (%s)\n" "$label" "$YEL" "$OFF" "$2"; missing=$((missing+1)); return
  fi
  if ! rfetch "$dep" "$tmp" || [ ! -s "$tmp" ]; then
    printf "  %-34s %snot deployed%s %s(%s)%s\n" "$label" "$YEL" "$OFF" "$DIM" "$dep" "$OFF"; missing=$((missing+1)); return
  fi
  verified=$((verified + 1))
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
        # config.schema.json is patched above but was never COMPARED, so a wipe-recovery that
        # missed it stayed fully green. It drives the Homebridge UI's config form, so a stale
        # one hides hksvPrebuffer* from anyone editing through the UI.
        # NOTE: this list is hand-maintained. A new patched file must be added here or it is
        # silently uncovered -- the failure this very entry is fixing.
        for f in sdm/Api.js sdm/Camera.js HksvStreamer.js StreamingDelegate.js PrebufferManager.js ../config.schema.json; do
          mkdir -p "$B/live/$(dirname "$f")"
          label="${f#../}"
          if ! rfetch "$PLUGIN_DIR/dist/$f" "$B/live/$f" || [ ! -s "$B/live/$f" ]; then
            printf "  %-34s %snot deployed%s\n" "$label" "$YEL" "$OFF"; missing=$((missing+1)); continue
          fi
          if cmp -s "$B/package/dist/$f" "$B/live/$f"; then
            printf "  %-34s %sreproduced exactly%s\n" "$label" "$GRN" "$OFF"
            checked=$((checked + 1))
          else
            printf "  %-34s %sDIFFERS%s  %s lines\n" "$label" "$RED" "$OFF" \
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

# --- 2a. go2rtc: is the running binary the patched one? --------------------
# This was the script's largest blind spot, and it hid a real defect: the keyframe
# watchdog fix lived in patches/go2rtc-nest.patch for days while the fork tag the guide
# told people to build from still shipped the old 4s version, and a fully green drift
# report could never have revealed it.
#
# Byte-comparing the binary would need a rebuild, which this script must not do. Instead
# check for marker strings the patch introduces -- present in a patched build, absent from
# stock go2rtc. Cheap, read-only, and enough to catch "you are running a stock or older
# image" which is the failure that actually happens.
echo "go2rtc (running container vs this repo's patch)"
GO2RTC_CONTAINER="${GO2RTC_CONTAINER:-go2rtc}"
G_IMAGE="$(rexec "docker inspect --format '{{.Config.Image}}' $GO2RTC_CONTAINER 2>/dev/null" | tr -d '\r')"
if [ -z "$G_IMAGE" ]; then
  printf "  %-34s %snot running%s (container '%s')\n" "container" "$YEL" "$OFF" "$GO2RTC_CONTAINER"
  missing=$((missing+1))
else
  # Every marker below is added by patches/go2rtc-nest.patch.
  G_MISSING=""
  for marker in "producer ended without error" "closing stalled stream (no keyframe)" "nest: stall watchdog armed"; do
    n_hits="$(rexec "docker exec $GO2RTC_CONTAINER grep -c '$marker' /usr/local/bin/go2rtc 2>/dev/null || echo 0" | tr -d '\r' | head -1)"
    [ "${n_hits:-0}" = "0" ] && G_MISSING="$G_MISSING '$marker'"
  done
  if [ -n "$G_MISSING" ]; then
    printf "  %-34s %sUNPATCHED OR STALE%s  image=%s\n" "binary" "$RED" "$OFF" "$G_IMAGE"
    printf "      %smissing marker(s):%s%s\n" "$DIM" "$G_MISSING" "$OFF"
    printf "      %sRebuild from the fork tag in README Part 3 and redeploy.%s\n" "$DIM" "$OFF"
    drift=$((drift + 1))
  else
    printf "  %-34s %spatched%s %s(image %s)%s\n" "binary" "$GRN" "$OFF" "$DIM" "$G_IMAGE" "$OFF"
  fi

  # The markers above prove "not stock". They CANNOT prove "current": the changes in
  # nestfix-1.9.14-7/-8/-9 (writebuffer close semantics, preload cancel) introduced no new
  # string literals at all, so no grep can distinguish them from -6. A v13 image passed the
  # marker check while missing every one of those fixes.
  #
  # GENERATION. The binary self-reports the git revision it was built from
  # (GET /api -> .revision), and the fork tag resolves to a commit SHA. Comparing those two
  # is an actual proof of which code is running -- unlike the image NAME, which is a
  # convention anyone can typo, and unlike the marker strings above, which cannot separate
  # -7/-8/-9 from -6 because those tags added no new string literals at all.
  #
  # This was advisory-only until 2026-08-07 and printed IMAGE PREDATES without incrementing
  # drift -- so a go2rtc built from a stale tag still exited 0 under "Everything checked is
  # in sync." That is the exact failure class this script was written for, passing silently.
  # A revision mismatch is now real drift.
  WANT_TAG="$(grep -m1 '^FORK_BRANCH=' "$REPO_DIR/install.sh" 2>/dev/null | sed 's/.*:-//; s/}.*//')"
  if [ -n "$WANT_TAG" ]; then
    G_REV="$(rexec "curl -s --max-time 8 http://127.0.0.1:${GO2RTC_API_PORT:-1985}/api 2>/dev/null" \
             | tr -d '\r' | sed -n 's/.*"revision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    # Peeled ref (^{}) first: an annotated tag's own object is NOT the commit, and comparing
    # against the tag object would mismatch every time for annotated tags.
    WANT_SHA="$(git ls-remote "${FORK_URL:-https://github.com/ajplotkin/go2rtc}" \
                  "refs/tags/${WANT_TAG}^{}" 2>/dev/null | cut -f1)"
    [ -z "$WANT_SHA" ] && WANT_SHA="$(git ls-remote "${FORK_URL:-https://github.com/ajplotkin/go2rtc}" \
                  "refs/tags/${WANT_TAG}" 2>/dev/null | cut -f1)"

    if [ -n "$G_REV" ] && [ -n "$WANT_SHA" ]; then
      # go2rtc reports an abbreviated revision, so compare on its length.
      if [ "${WANT_SHA:0:${#G_REV}}" = "$G_REV" ]; then
        printf "  %-34s %sok%s %s(rev %s == %s)%s\n" "generation" "$GRN" "$OFF" "$DIM" "$G_REV" "$WANT_TAG" "$OFF"
      else
        printf "  %-34s %sWRONG BUILD%s\n" "generation" "$RED" "$OFF"
        printf "      %sRunning revision %s, but %s is %s.\n" "$DIM" "$G_REV" "$WANT_TAG" "${WANT_SHA:0:${#G_REV}}"
        printf "      The running binary was NOT built from the tag this repo ships. Rebuild\n"
        printf "      and redeploy -- see 'Building the go2rtc fork' in the README.%s\n" "$OFF"
        drift=$((drift + 1))
      fi
    else
      # Degrade to the old name check rather than failing: no network (git ls-remote) or the
      # API unreachable are both ordinary, and neither is evidence of drift.
      case "$G_IMAGE" in
        *"${WANT_TAG##*-}"*)
          printf "  %-34s %sname looks current%s %s(rev check unavailable)%s\n" "generation" "$YEL" "$OFF" "$DIM" "$OFF" ;;
        *)
          printf "  %-34s %sIMAGE PREDATES %s%s %s(rev check unavailable)%s\n" "generation" "$YEL" "$WANT_TAG" "$OFF" "$DIM" "$OFF" ;;
      esac
      printf "      %sCould not prove the build: %s.%s\n" "$DIM" \
        "$([ -z "$G_REV" ] && echo "go2rtc API unreachable" || echo "could not resolve $WANT_TAG (offline?)")" "$OFF"
    fi
  fi
  checked=$((checked + 1))
  verified=$((verified + 1))
fi
echo

# --- 2a2. recovery kit freshness -------------------------------------------
# The kit staged on the box is what actually runs after a wipe, and it silently went
# stale within 38 minutes of being staged on 2026-08-07: it held the old sentinel-based
# apply script and a StreamingDelegate patch missing a hunk. A stale kit is worse than
# none — it restores an older generation and reports success.
echo "Recovery kit (${DIM}${BASE_HOME}/nest-recovery${OFF})"
KIT="$BASE_HOME/nest-recovery"
if ! rexec "[ -d '$KIT' ]" 2>/dev/null; then
  printf "  %-34s %snot staged%s — a wipe would need files copied over first\n" "kit" "$YEL" "$OFF"
  missing=$((missing+1))
else
  kit_bad=""
  for pair in "scripts/apply-snapshot-patch.sh|scripts/apply-snapshot-patch.sh" \
              "patches/homebridge-plugin/StreamingDelegate.js.patch|patches/homebridge-plugin/StreamingDelegate.js.patch" \
              "patches/homebridge-plugin/Camera.js.patch|patches/homebridge-plugin/Camera.js.patch" \
              "patches/homebridge-plugin/Api.js.patch|patches/homebridge-plugin/Api.js.patch" \
              "patches/homebridge-plugin/HksvStreamer.js.patch|patches/homebridge-plugin/HksvStreamer.js.patch" \
              "patches/homebridge-plugin/config.schema.json.patch|patches/homebridge-plugin/config.schema.json.patch" \
              "patches/homebridge-plugin/new-files/PrebufferManager.js|patches/homebridge-plugin/new-files/PrebufferManager.js"; do
    kf="${pair%%|*}"; rf="${pair##*|}"
    tmp="$WORK/kit_$(echo "$kf" | tr '/.' '__')"
    if rfetch "$KIT/$kf" "$tmp" && [ -s "$tmp" ]; then
      cmp -s "$REPO_DIR/$rf" "$tmp" || kit_bad="$kit_bad $kf"
    else
      kit_bad="$kit_bad $kf(missing)"
    fi
  done
  if [ -n "$kit_bad" ]; then
    printf "  %-34s %sSTALE%s —%s\n" "kit" "$RED" "$OFF" "$kit_bad"
    printf "      %sAfter a wipe this restores an OLDER generation and reports success.\n" "$DIM"
    printf "      Re-stage: scp the repo's scripts/apply-snapshot-patch.sh and\n"
    printf "      patches/homebridge-plugin/ to %s/%s\n" "$KIT" "$OFF"
    drift=$((drift + 1))
  else
    printf "  %-34s %smatches the repo%s\n" "kit" "$GRN" "$OFF"
  fi
  verified=$((verified + 1))
fi
echo

# --- 2b. deployed-but-not-loaded ------------------------------------------
# Everything above compares BYTES ON DISK. Node reads its modules once, at startup,
# so a dist/ file newer than the running Homebridge process is deployed and NOT
# executing -- and every check above still says "in sync". That is the failure this
# whole script exists to make impossible, and it had a live instance on 2026-08-06:
# dist/sdm/Api.js was installed at 17:26 while the process had been up since Aug 3,
# seven minutes after a commit that added a "restart Homebridge" warning elsewhere.
# It was comment-only that time. Next time it will not be.
echo "Deployed but not loaded (on-disk newer than the running process)"
# Match the process whose command IS homebridge, not merely anything mentioning it.
# `pgrep -f homebridge | head -1` picks whatever has the lowest pid, which on this Pi
# was `tail -f --follow=name /homebridge/homebridge.log` — a log tailer restarted
# minutes ago. That reported "all loaded" over a bridge that had actually been up for
# three days, i.e. this check's own false clean, on its first run. `pgrep -x` matches
# the executable name exactly, which also excludes the two `s6-supervise homebridge`
# supervisors.
HB_PID="$(rexec "pgrep -x homebridge 2>/dev/null | head -1" | tr -d '\r')"
HB_START="$([ -n "$HB_PID" ] && rexec "ps -o lstart= -p $HB_PID 2>/dev/null" | tr -d '\r' | sed 's/^ *//')"
if [ -z "$HB_START" ]; then
  printf "  %-34s %scannot determine%s — is Homebridge running?\n" "process age" "$YEL" "$OFF"
  missing=$((missing+1))
else
  HB_EPOCH="$(rexec "date -d '$HB_START' +%s 2>/dev/null" | tr -d '\r')"
  if [ -z "$HB_EPOCH" ]; then
    printf "  %-34s %scannot parse start time%s (%s)\n" "process age" "$YEL" "$OFF" "$HB_START"
    missing=$((missing+1))
  else
    NEWER="$(rexec "find '$PLUGIN_DIR/dist' -name '*.js' -newermt '@$HB_EPOCH' 2>/dev/null | sed 's|.*/dist/||' | sort | tr '\n' ' '")"
    NEWER="$(echo "$NEWER" | tr -d '\r' | sed 's/ *$//')"
    if [ -n "$NEWER" ]; then
      printf "  %-34s %sSTALE IN MEMORY%s  %s\n" "running process" "$RED" "$OFF" "$NEWER"
      printf "      %sThose files are on disk but were installed AFTER Homebridge started\n" "$DIM"
      printf "      (%s). The running code does not include them.\n" "$HB_START"
      printf "      Restart Homebridge, or accept that they land on the next restart.%s\n" "$OFF"
      drift=$((drift + 1))
    else
      printf "  %-34s %sall loaded%s %s(process up since %s)%s\n" "running process" "$GRN" "$OFF" "$DIM" "$HB_START" "$OFF"
    fi
    verified=$((verified + 1))
  fi
fi
echo

# --- 3. landmines: stale whole-file patch blobs ---------------------------
# The repo shipped whole-file copies until 2026-07-19 (446b29f) and then moved
# to unified diffs, precisely because pasting a stale whole file reverts
# everything done since. Any surviving *.patched tree can still do that.
# --- 2c. things the fixes DEPEND on, which nothing else covered ---------------
# The plugin dist can be byte-perfect and the deployment still broken, because three
# inputs live outside every check above:
#   * config.json keys -- vEncoder:copy is what makes live view a remux instead of an
#     encode, and hksvPrebufferSeconds is what makes the ring serve pre-trigger footage.
#     Lose either and nothing DIFFERS; the box just quietly gets slower or shorter clips.
#   * go2rtc stream keys -- the plugin derives them by slugifying the camera's room name
#     and never checks that go2rtc serves them, so a Google Home rename kills a camera
#     with no drift anywhere. (Values are never printed: config.json holds OAuth secrets.)
#   * systemd units -- ~/scripts/systemd-units/ is what the config tarball captures, but
#     /etc/systemd/system/ is what actually runs.
# --- 2b. repo go2rtc patch  <->  fork tag ------------------------------------
# The generation check above proves the RUNNING BINARY matches the fork tag. It says
# nothing about whether this repo's go2rtc-nest.patch still matches that tag -- and those
# are what a stranger following the README actually builds from. They have drifted before:
# a watchdog fix lived on the Pi and in the patch but was never pushed to the fork, so the
# tag and the patch described different code while everything else reported green.
#
# Compares only the files the patch touches. The tag's diff against v1.9.14 covers ~109
# files, but the rest is upstream dev churn (website, README, xiaomi/tutk/kasa) that this
# patch deliberately does not carry.
if [ "$DEEP" = "1" ] && command -v gh >/dev/null 2>&1; then
  echo "Repo go2rtc patch vs fork tag"
  G2P="$REPO_DIR/patches/go2rtc-nest.patch"
  WANT_TAG="$(grep -m1 '^FORK_BRANCH=' "$REPO_DIR/install.sh" 2>/dev/null | sed 's/.*:-//; s/}.*//')"
  if [ -f "$G2P" ] && [ -n "$WANT_TAG" ]; then
    TAGDIFF="$WORK/tagdiff.patch"
    if gh api "repos/ajplotkin/go2rtc/compare/v1.9.14...$WANT_TAG" \
         -H "Accept: application/vnd.github.v3.diff" > "$TAGDIFF" 2>/dev/null && [ -s "$TAGDIFF" ]; then
      # Per file: normalise to the hunk BODIES only. Index lines and hunk headers carry
      # blob SHAs and line offsets that legitimately differ between a rebased tag and a
      # flat patch, so comparing raw text would cry wolf on every rebase.
      MISMATCH=""; NCHECK=0
      for pf in $(grep '^+++ b/' "$G2P" | sed 's|^+++ b/||' | sort -u); do
        NCHECK=$((NCHECK + 1))
        a="$(awk -v F="$pf" '/^\+\+\+ b\//{on=($3=="b/"F)} on && /^[-+ ]/ && !/^(\+\+\+|---)/' "$G2P" | md5)"
        b="$(awk -v F="$pf" '/^\+\+\+ b\//{on=($3=="b/"F)} on && /^[-+ ]/ && !/^(\+\+\+|---)/' "$TAGDIFF" | md5)"
        [ "$a" = "$b" ] || MISMATCH="$MISMATCH $pf"
      done
      if [ -z "$MISMATCH" ]; then
        printf "  %-34s %sall %s files match %s%s\n" "go2rtc-nest.patch" "$GRN" "$NCHECK" "$WANT_TAG" "$OFF"
      else
        printf "  %-34s %sDIFFERS from %s%s\n" "go2rtc-nest.patch" "$RED" "$WANT_TAG" "$OFF"
        for m in $MISMATCH; do printf "      %s%s%s\n" "$DIM" "$m" "$OFF"; done
        printf "      %sThe patch in this repo and the tag the guide builds describe different\n" "$DIM"
        printf "      code. Anyone following the README gets something you are not running.%s\n" "$OFF"
        drift=$((drift + 1))
      fi
      checked=$((checked + 1))
    else
      printf "  %-34s %scould not fetch tag diff%s (offline?)\n" "go2rtc-nest.patch" "$YEL" "$OFF"
    fi
  fi
  verified=$((verified + 1))
  echo
fi

echo "Deployment inputs (outside the patch set)"
HB_CONF="$HB_DIR/config.json"
for k in '"vEncoder"[[:space:]]*:[[:space:]]*"copy"' '"hksvPrebufferSeconds"'; do
  label="$(echo "$k" | sed 's/\[\[:space:\]\]\*//g; s/"//g; s/:.*//')"
  if rexec "grep -qE '$k' '$HB_CONF' 2>/dev/null"; then
    printf "  %-34s %spresent%s\n" "config.json $label" "$GRN" "$OFF"
  else
    printf "  %-34s %sMISSING%s in %s\n" "config.json $label" "$RED" "$OFF" "$HB_CONF"
    printf "      %sNo file DIFFERS when this is lost -- live view silently starts\n" "$DIM"
    printf "      re-encoding, or the prebuffer stops serving pre-trigger footage.%s\n" "$OFF"
    drift=$((drift + 1))
  fi
  checked=$((checked + 1))
done

# Every go2rtc stream should have a producer configured. A key present in go2rtc but with
# no matching camera (or the reverse after a rename) is the failure this cannot otherwise see.
# Parsed, not grepped: a regex over the JSON also matches NESTED keys ("producers",
# "consumers", ...) and reported 14 streams for a 4-camera deployment.
NSTREAM="$(rexec "curl -s --max-time 8 http://127.0.0.1:${GO2RTC_API_PORT:-1985}/api/streams 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null" | tr -d ' \r')"
if [ -n "$NSTREAM" ]; then
  printf "  %-34s %s%s configured%s\n" "go2rtc streams" "$GRN" "$NSTREAM" "$OFF"
  printf "      %sRename a camera in Google Home and the plugin dials a slug go2rtc does\n" "$DIM"
  printf "      not serve. Re-run nest-go2rtc-sync.py after ANY rename.%s\n" "$OFF"
  checked=$((checked + 1))
else
  printf "  %-34s %sAPI unreachable%s\n" "go2rtc streams" "$YEL" "$OFF"; missing=$((missing + 1))
fi

# Units: staged copy (what the tarball restores) vs /etc (what actually runs), plus enabled.
UNIT_DIFF="$(rexec "for u in \$(ls /home/adamandaj/scripts/systemd-units/*.service 2>/dev/null); do n=\$(basename \$u); if ! sudo diff -q \$u /etc/systemd/system/\$n >/dev/null 2>&1; then echo \$n; fi; done" | tr -d '\r' | tr '\n' ' ' | sed 's/ *$//')"
if [ -z "$UNIT_DIFF" ]; then
  printf "  %-34s %sstaged copies match /etc%s\n" "systemd units" "$GRN" "$OFF"
else
  printf "  %-34s %sDIFFER%s: %s\n" "systemd units" "$RED" "$OFF" "$UNIT_DIFF"
  printf "      %s~/scripts/systemd-units/ is what the backup tarball restores; /etc is\n" "$DIM"
  printf "      what runs. A restore would put back the wrong unit.%s\n" "$OFF"
  drift=$((drift + 1))
fi
checked=$((checked + 1))
echo

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
# Nothing readable is NOT a clean bill of health. Reporting "in sync" after
# comparing zero artifacts is how a wrong --homebridge path reads as success.
if [ "$verified" -eq 0 ]; then
  echo "${RED}Nothing could be checked.${OFF} $missing path(s) unreadable under:"
  echo "  homebridge: $HB_DIR"
  echo "  scripts:    $SCRIPTS_DIR"
  echo "Pass --homebridge / --scripts if the deployment lives elsewhere."
  exit 2
fi

if [ "$drift" -eq 0 ] && [ "$missing" -eq 0 ]; then
  echo "${GRN}Everything checked is in sync.${OFF} ($checked artifacts, $verified checks)"
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
