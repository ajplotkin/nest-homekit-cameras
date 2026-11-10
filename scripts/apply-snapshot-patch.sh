#!/bin/bash
# Re-applies the homebridge-google-nest-sdm plugin patches after any `npm install`
# of the plugin (npm re-extracts the plugin's directory, taking the patches with it).
#
# It applies the unified diffs in ../patches/homebridge-plugin/ to your installed
# plugin. Each patch is idempotent (skipped if already present) and the script exits
# NON-ZERO and loudly if anything is missing or does not apply — so a re-apply can
# never silently leave you unpatched.
#
# A file patched by an EARLIER version of these diffs is upgraded: if its SHA-256 is in
# known-generations.txt, the script downloads the stock tarball from the npm registry,
# checks it against a pinned integrity hash, backs the file up, restores it from stock and
# patches it again. Every file is checked before any is changed; anything it cannot resolve
# safely is refused with the reason, and then nothing is changed.
#
#   ./apply-snapshot-patch.sh --dry-run    # print what it would do, change nothing
#
# Override any path via env vars:
#   HOMEBRIDGE_DIR=/path/to/homebridge \
#   HOMEBRIDGE_CONTAINER=my-homebridge \
#   ./apply-snapshot-patch.sh
#
# With Homebridge in Docker the plugin's files are usually root-owned on the host (npm runs
# as root in the container); if so, run it with sudo:
#   sudo env HOMEBRIDGE_DIR=/path/to/homebridge bash ./apply-snapshot-patch.sh
# DOCKER_CMD (default "docker") only changes the reload command printed at the end,
# e.g. DOCKER_CMD="sudo docker" when your user is not in the docker group.
set -uo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1;;
  "") ;;
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0;;
  *) echo "usage: $0 [--dry-run]"; exit 2;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/../patches/homebridge-plugin}"
HOMEBRIDGE_DIR="${HOMEBRIDGE_DIR:-$HOME/homebridge}"
PLUGIN="${PLUGIN:-$HOMEBRIDGE_DIR/node_modules/homebridge-google-nest-sdm}"
CONTAINER="${HOMEBRIDGE_CONTAINER:-homebridge}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
EXPECT_VER="1.1.25"

[ -d "$PLUGIN" ] || { echo "ERROR: plugin not found at $PLUGIN (set HOMEBRIDGE_DIR)"; exit 1; }
[ -d "$PATCH_DIR" ] || { echo "ERROR: patch dir not found at $PATCH_DIR"; exit 1; }

# python3 first: the Pi HOST has no node (only the container does), so a node-only read came back
# empty and the script refused with "plugin is ''" on the host it exists to recover. (2026-10-29)
CUR_VER=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$PLUGIN/package.json" 2>/dev/null \
  || node -e "console.log(require(process.argv[1]).version)" "$PLUGIN/package.json" 2>/dev/null)
if [ "$CUR_VER" != "$EXPECT_VER" ]; then
  echo "REFUSING: plugin is '$CUR_VER' but these patches were cut from $EXPECT_VER."
  echo "The compiled dist/ layout moves between releases — re-cut the diffs against"
  echo "$CUR_VER before applying (see the guide), or pin the plugin to $EXPECT_VER."
  exit 1
fi

# patchfile | dist-relative target | sentinel string proving it's already applied
# NOTE: as of plugin 1.1.24, upstream merged our recording-lifecycle (#217/#223) and
# stale-event (#219) and relation-crash (#218) fixes, so the Doorbell.js / HksvStreamer.js
# patches and the Camera.js stale-event hunk are gone (redundant). What remains is our
# go2rtc integration: snapshot-from-disk + warmer .refresh (Camera.js), the Pub/Sub
# auto-reconnect that is still open as #216 (Api.js), and the go2rtc RTSP live/record
# routing (StreamingDelegate.js). Sentinels must match OUR additions, NOT anything now in
# stock — Camera.js uses 'nest-snaps'. (Camera.js.patch DOES still modify stale-event
# handling: it raises MAX_EVENT_AGE_SECONDS 30->120 and adds a throttled drop warning, per
# issue #231. Upstream's isEventStale from PR #219 is the base it builds on.)
# 1.1.25 (2026-10-29) added upstream #225 (token-safe API error logging, new dist/sdm/ApiError.js).
# Re-cut against it: only line numbers moved in Api.js / Camera.js; config.schema.json.patch only
# lost its ---/+++ header timestamps.
# 2026-07-29: added the HKSV prebuffer. HksvStreamer.js is patched again (it must accept a
# Readable on stdin, not only an SDP string), and PrebufferManager.js is a NEW file that has
# to be COPIED IN before StreamingDelegate.js can require() it.
patches=(
  "Camera.js.patch|dist/sdm/Camera.js|nest-snaps"
  "Api.js.patch|dist/sdm/Api.js|subscribeToEvents"
  "StreamingDelegate.js.patch|dist/StreamingDelegate.js|go2rtcKey"
  "HksvStreamer.js.patch|dist/HksvStreamer.js|SIGKILL"
  # Not under dist/: this is the Homebridge Config UI schema at the plugin root.
  # Without it the hksvPrebuffer* keys work at runtime (config.json is read directly)
  # but are invisible and uneditable in the UI, so nobody discovers the feature.
  "config.schema.json.patch|config.schema.json|hksvPrebufferSeconds"
)

# New files, copied rather than patched. Must land BEFORE the patches that require them,
# otherwise a patched StreamingDelegate.js would throw MODULE_NOT_FOUND at startup.
# StreamKey.js (2026-11-09) is required by the patched Api.js: it gives two or more cameras in
# one room distinct names and stream keys, by the same rule as nest-go2rtc-sync.py.
new_files=(
  "PrebufferManager.js|dist/PrebufferManager.js"
  "StreamKey.js|dist/StreamKey.js"
)

# ---- upgrade support ------------------------------------------------------------
# A target that carries an OLDER generation of our patch (every upgraded install, after a
# patch file in this repo changes) is put back to stock and patched again, automatically,
# when its exact content is one this repo produced: known-generations.txt lists the SHA-256
# of every past and current generation applied to stock $EXPECT_VER (rebuild it with
# scripts/known-generations.py after re-cutting a patch). The stock file comes from the npm
# registry tarball, checked against the integrity hash pinned below before anything is used.
# Anything else -- hand-edited content, a generation this list does not know, a failed
# download or hash check -- is refused with the reason, and nothing is changed.
MANIFEST="$PATCH_DIR/known-generations.txt"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
# dist.integrity of homebridge-google-nest-sdm@1.1.25 on registry.npmjs.org (checked 2026-11-09).
# The registry's metadata must report this value AND the downloaded tarball must hash to it.
STOCK_INTEGRITY="${STOCK_INTEGRITY:-sha512-ipMBmrep/Y+a7ESdHw5kdXBP/5gjvIb2d48nnmx0Z1sbLA8XLGPCI/n1XH1xnpRAY9saP69wSxgT9A0XQmsDbQ==}"
BACKUP_ROOT="${PATCH_BACKUP_DIR:-$HOMEBRIDGE_DIR/nest-patch-backups}"

sha256_of() { python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
known_generation() {  # $1=target (dist-relative) $2=file -> 0 if its hash is listed for that target
  [ -f "$MANIFEST" ] || return 1
  local h; h="$(sha256_of "$2")" || return 1
  awk -v h="$h" -v t="$1" '$1==h && $2==t {f=1} END {exit !f}' "$MANIFEST"
}

# ---- 1. classify every target before changing anything ----------------------------
# state per patch: current (this exact diff is in), apply (stock: forward-applies),
# upgrade (a known older generation), refuse (reason printed). A single refusal stops the
# run before any file is touched. That includes a file it would change but cannot write: a
# write failing halfway through used to leave some files upgraded and others not.
states=(); refusals=0
for entry in "${new_files[@]}"; do
  IFS='|' read -r src target <<<"$entry"
  [ -f "$PATCH_DIR/new-files/$src" ] || { echo "  REFUSE: missing new file $PATCH_DIR/new-files/$src"; refusals=1; continue; }
  t="$PLUGIN/$target"
  if ! cmp -s "$PATCH_DIR/new-files/$src" "$t" && { [ -e "$t" ] && [ ! -w "$t" ] || [ ! -w "$(dirname "$t")" ]; }; then
    echo "  REFUSE: cannot write $target (permissions? run with sudo)"; refusals=1
  fi
done
for entry in "${patches[@]}"; do
  IFS='|' read -r pf target sentinel <<<"$entry"
  patchfile="$PATCH_DIR/$pf"
  tgt="$PLUGIN/$target"
  st=refuse
  if [ ! -f "$patchfile" ]; then
    echo "  REFUSE: missing patch file $patchfile"
  elif [ ! -f "$tgt" ]; then
    echo "  REFUSE: target not found: $target"
  # Was this file patched with THIS generation of the diff? A sentinel string cannot
  # answer that -- it stays present after an OLDER generation was applied, so a re-cut
  # patch gets silently skipped and the file keeps stale hunks. That happened on
  # 2026-08-07: the cameraStreamCount hunk never reached the Pi because `go2rtcKey` was
  # already there from an earlier run, and the script cheerfully said "already patched".
  # A reverse dry-run compares CONTENT, so it succeeds only if the target already
  # contains exactly this patch.
  elif patch -p1 -d "$PLUGIN" --dry-run --reverse --force <"$patchfile" >/dev/null 2>&1; then
    st=current
  elif known_generation "$target" "$tgt"; then
    st=upgrade
  elif grep -qF "$sentinel" "$tgt"; then
    echo "  REFUSE: $target contains this repo's patch (sentinel '$sentinel'), but its content"
    echo "          matches no generation in known-generations.txt: edited by hand, or patched by"
    echo "          a version of these patches this script does not know. Restore it from stock"
    echo "          $EXPECT_VER yourself (see the README's upgrade section) if you don't need the edits."
  elif patch -p1 -d "$PLUGIN" --dry-run <"$patchfile" >/dev/null 2>&1; then
    st=apply
  else
    echo "  REFUSE: $pf does not apply cleanly to $target (wrong plugin version, or already edited?)"
  fi
  # patch writes the result as a new file in the target's directory, so both must be writable.
  if [ "$st" = apply ] || [ "$st" = upgrade ]; then
    if [ ! -w "$tgt" ] || [ ! -w "$(dirname "$tgt")" ]; then
      echo "  REFUSE: cannot write $target (permissions? run with sudo)"; st=refuse
    fi
  fi
  [ "$st" = refuse ] && refusals=1
  states+=("$st")
done
if [ "$refusals" = 1 ]; then
  echo "FAILED: nothing was changed -- fix the REFUSE lines above and re-run."
  exit 1
fi

i=0; n_upgrade=0
for entry in "${patches[@]}"; do
  IFS='|' read -r pf target sentinel <<<"$entry"
  case "${states[$i]}" in
    current) echo "  ok: $target already patched (this exact diff)";;
    apply)   [ "$DRY_RUN" = 1 ] && echo "  would patch: $target";;
    upgrade) n_upgrade=$((n_upgrade+1))
             echo "  $target carries an older generation of $pf: will back it up, restore stock $EXPECT_VER, patch";;
  esac
  i=$((i+1))
done

# ---- 2. fetch and verify the stock tarball, only if something needs it ---------------
if [ "$n_upgrade" -gt 0 ]; then
  BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  would download homebridge-google-nest-sdm@$EXPECT_VER from $NPM_REGISTRY, check its"
    echo "  integrity against $STOCK_INTEGRITY, and back up the files above to $BACKUP_DIR"
  else
    command -v curl >/dev/null || { echo "REFUSING: curl is needed to fetch stock $EXPECT_VER; nothing was changed."; exit 1; }
    STOCK_TMP="$(mktemp -d)" && [ -d "$STOCK_TMP" ] \
      || { echo "REFUSING: could not create a temporary directory; nothing was changed."; exit 1; }
    trap 'rm -rf "$STOCK_TMP"' EXIT
    if ! curl -fsSL --max-time 60 -o "$STOCK_TMP/meta.json" "$NPM_REGISTRY/homebridge-google-nest-sdm/$EXPECT_VER"; then
      echo "REFUSING: could not fetch registry metadata for homebridge-google-nest-sdm@$EXPECT_VER; nothing was changed."; exit 1
    fi
    # Prints the tarball URL, or a reason on stderr and exits 1.
    if ! TARBALL_URL="$(python3 - "$STOCK_TMP/meta.json" "$EXPECT_VER" "$STOCK_INTEGRITY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit("registry metadata is not JSON")
dist = d.get("dist") or {}
if d.get("version") != sys.argv[2]:
    sys.exit("registry metadata is for version %r, not %s" % (d.get("version"), sys.argv[2]))
if dist.get("integrity") != sys.argv[3]:
    sys.exit("registry integrity %r differs from the pinned %s" % (dist.get("integrity"), sys.argv[3]))
if not dist.get("tarball"):
    sys.exit("registry metadata has no tarball URL")
print(dist["tarball"])
PY
)"; then
      echo "REFUSING: registry metadata check failed (reason above); nothing was changed."; exit 1
    fi
    if ! curl -fsSL --max-time 120 -o "$STOCK_TMP/stock.tgz" "$TARBALL_URL"; then
      echo "REFUSING: could not download $TARBALL_URL; nothing was changed."; exit 1
    fi
    got="$(python3 -c "import base64,hashlib,sys;print('sha512-'+base64.b64encode(hashlib.sha512(open(sys.argv[1],'rb').read()).digest()).decode())" "$STOCK_TMP/stock.tgz")"
    if [ "$got" != "$STOCK_INTEGRITY" ]; then
      echo "REFUSING: the downloaded tarball hashes to $got, not the pinned $STOCK_INTEGRITY; nothing was changed."; exit 1
    fi
    mkdir -p "$STOCK_TMP/stock"
    i=0
    for entry in "${patches[@]}"; do
      IFS='|' read -r pf target sentinel <<<"$entry"
      if [ "${states[$i]}" = upgrade ]; then
        if ! tar xzf "$STOCK_TMP/stock.tgz" -C "$STOCK_TMP/stock" "package/$target" 2>/dev/null \
           || ! patch -p1 -d "$STOCK_TMP/stock/package" --dry-run <"$PATCH_DIR/$pf" >/dev/null 2>&1; then
          echo "REFUSING: $pf does not apply to $target from the stock tarball; nothing was changed."; exit 1
        fi
      fi
      i=$((i+1))
    done
    mkdir -p "$BACKUP_DIR" || { echo "REFUSING: cannot create $BACKUP_DIR; nothing was changed."; exit 1; }
    i=0
    for entry in "${patches[@]}"; do
      IFS='|' read -r pf target sentinel <<<"$entry"
      if [ "${states[$i]}" = upgrade ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$target")" && cp -p "$PLUGIN/$target" "$BACKUP_DIR/$target" \
          || { echo "REFUSING: could not back up $target to $BACKUP_DIR; nothing was changed."; exit 1; }
      fi
      i=$((i+1))
    done
    echo "  backed up $n_upgrade file(s) to $BACKUP_DIR"
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  for entry in "${new_files[@]}"; do
    IFS='|' read -r src target <<<"$entry"
    cmp -s "$PATCH_DIR/new-files/$src" "$PLUGIN/$target" || echo "  would install: $target"
  done
  echo "Dry run: nothing was changed."
  exit 0
fi

# ---- 3. change things --------------------------------------------------------------
applied=0
failed=0
for entry in "${new_files[@]}"; do
  IFS='|' read -r src target <<<"$entry"
  s="$PATCH_DIR/new-files/$src"
  t="$PLUGIN/$target"
  if [ -f "$t" ] && cmp -s "$s" "$t"; then
    echo "  ok: $target already present and identical"
  elif cp "$s" "$t"; then
    echo "  INSTALLED: $target"; applied=1
  else
    # A failed cp used to set neither applied nor failed, so a re-run whose sentinels were
    # all present would report success with this file missing -- and the patched
    # StreamingDelegate requires it, so Homebridge dies with MODULE_NOT_FOUND.
    echo "  ERROR: could not install $target (permissions? root-owned node_modules?)"; failed=1
  fi
done

i=0
for entry in "${patches[@]}"; do
  IFS='|' read -r pf target sentinel <<<"$entry"
  patchfile="$PATCH_DIR/$pf"
  tgt="$PLUGIN/$target"
  st="${states[$i]}"; i=$((i+1))
  [ "$st" = current ] && continue
  if [ "$st" = upgrade ]; then
    # Overwrite in place (cat >), so the file keeps its mode; patch below keeps it as well.
    if ! cat "$STOCK_TMP/stock/package/$target" >"$tgt"; then
      echo "  ERROR: could not restore stock $target; putting the backup back"
      cat "$BACKUP_DIR/$target" >"$tgt"; failed=1; continue
    fi
  fi
  if patch -p1 -d "$PLUGIN" <"$patchfile" >/dev/null; then
    [ "$st" = upgrade ] && echo "  UPGRADED: $target (old copy in $BACKUP_DIR)" || echo "  PATCHED: $target"
    # GNU patch keeps a .orig when a hunk applied with an offset or fuzz; it is not ours to leave.
    rm -f "$tgt.orig"
    applied=1
  else
    # Dry-run passing does not guarantee the real apply succeeds (disk, permissions).
    echo "  ERROR: $pf passed --dry-run but failed to apply to $target"; failed=1
    if [ "$st" = upgrade ]; then cat "$BACKUP_DIR/$target" >"$tgt" && echo "         restored the old copy from $BACKUP_DIR"; fi
    rm -f "$tgt.rej" "$tgt.orig"
  fi
done

if [ "$failed" = 1 ]; then
  echo "FAILED: one or more patches did not apply — the plugin is NOT fully patched."
  exit 1
fi
if [ "$applied" = 1 ]; then
  echo "Done. Reload the plugin WITHOUT restarting the container:"
  echo "    $DOCKER_CMD exec $CONTAINER pkill -x homebridge"
  echo
  echo "  Prefer this to 'docker restart $CONTAINER'. Every container start runs npm install"
  echo "  against Homebridge's package.json; if the pinned plugin version differs from the"
  echo "  installed one, npm reinstalls the plugin and deletes every patch just applied --"
  echo "  including dist/PrebufferManager.js and dist/StreamKey.js. Killing the homebridge process lets s6 respawn"
  echo "  it in place without that step: new code is loaded, the patches survive."
else
  echo "All patches already present; nothing to do."
fi
