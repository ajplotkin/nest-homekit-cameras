#!/bin/bash
# Off-box test for scripts/apply-snapshot-patch.sh: patching, and upgrading a plugin that
# carries an older generation of this repo's patches.
#
#     bash test/apply-patch-upgrade.test.sh [STOCK_TGZ]     # exits non-zero on failure
#
# Builds a small synthetic plugin (the five patched targets, each a few lines carrying the
# script's sentinel strings), synthetic "generation 1" and "generation 2" patches, a
# known-generations.txt, and a fake npm registry served over file:// with a stock tarball.
# No network, no Homebridge, and nothing outside a temp directory is touched.
#
# With STOCK_TGZ (the real homebridge-google-nest-sdm-1.1.25.tgz) it also runs the REAL
# patches: a plugin unpacked from the tarball and patched with main's a025ce2 generation
# (taken from git) must be upgraded to this checkout's patches, byte for byte what a fresh
# patch of stock gives, and known-generations.txt must be current for this tarball.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
SCRIPT="$REPO/scripts/apply-snapshot-patch.sh"
STOCK_TGZ="${1:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0
check() { if [ "$1" = 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; fails=$((fails+1)); fi; }
is() { [ "$1" = "$2" ]; echo $?; }
has() { grep -qF -- "$2" "$1"; echo $?; }
sha() { python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
integrity() { python3 -c "import base64,hashlib,sys;print('sha512-'+base64.b64encode(hashlib.sha512(open(sys.argv[1],'rb').read()).digest()).decode())" "$1"; }
tree() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$(sha "$f") $f"; done); }
mode() { python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$1"; }

TARGETS="dist/sdm/Camera.js:nest-snaps dist/sdm/Api.js:subscribeToEvents dist/StreamingDelegate.js:go2rtcKey dist/HksvStreamer.js:SIGKILL config.schema.json:hksvPrebufferSeconds"
PATCHES="Camera.js.patch Api.js.patch StreamingDelegate.js.patch HksvStreamer.js.patch config.schema.json.patch"

content() {  # $1=target $2=sentinel $3=generation (0 = stock)
  printf 'first %s\nsecond\nthird\n' "$1"
  [ "$3" -ge 1 ] && printf '// %s generation %s\n' "$2" "$3"
  [ "$3" -ge 2 ] && printf '// added by generation 2\n'
  printf 'fourth\nfifth\nsixth\n'
}

# make_env DIR: stock plugin in DIR/plugin, generation-2 patches in DIR/patches (with a
# manifest naming generations 1 and 2), a registry in DIR/registry. Prints nothing.
make_env() {
  local d="$1" t s pf
  mkdir -p "$d/plugin" "$d/patches/new-files" "$d/registry/homebridge-google-nest-sdm" "$d/gen" "$d/stockpkg/package"
  echo '{"name":"homebridge-google-nest-sdm","version":"1.1.25"}' >"$d/plugin/package.json"
  cp "$d/plugin/package.json" "$d/stockpkg/package/package.json"
  echo "// new file" >"$d/patches/new-files/PrebufferManager.js"
  echo "// new file" >"$d/patches/new-files/StreamKey.js"
  : >"$d/patches/known-generations.txt"
  for ts in $TARGETS; do
    t="${ts%%:*}"; s="${ts#*:}"; pf="$(basename "$t").patch"
    mkdir -p "$d/plugin/$(dirname "$t")" "$d/stockpkg/package/$(dirname "$t")" "$d/gen/1/$(dirname "$t")" "$d/gen/2/$(dirname "$t")"
    content "$t" "$s" 0 >"$d/plugin/$t"; cp "$d/plugin/$t" "$d/stockpkg/package/$t"
    content "$t" "$s" 1 >"$d/gen/1/$t"
    content "$t" "$s" 2 >"$d/gen/2/$t"
    diff -u --label "a/$t" --label "b/$t" "$d/plugin/$t" "$d/gen/2/$t" >"$d/patches/$pf"
    echo "$(sha "$d/gen/1/$t")  $t  gen1" >>"$d/patches/known-generations.txt"
    echo "$(sha "$d/gen/2/$t")  $t  gen2" >>"$d/patches/known-generations.txt"
  done
  (cd "$d/stockpkg" && tar czf "$d/registry/stock.tgz" package)
  write_meta "$d" "1.1.25" "$(integrity "$d/registry/stock.tgz")"
  echo "$(integrity "$d/registry/stock.tgz")" >"$d/pinned"
}
write_meta() {  # $1=dir $2=version $3=integrity
  printf '{"version":"%s","dist":{"tarball":"file://%s/registry/stock.tgz","integrity":"%s"}}\n' \
    "$2" "$1" "$3" >"$1/registry/homebridge-google-nest-sdm/1.1.25"
}
run_patcher() {  # $1=dir, rest = args; output in $1/out, exit code echoed
  local d="$1"; shift
  env PLUGIN="$d/plugin" PATCH_DIR="$d/patches" HOMEBRIDGE_DIR="$d" NPM_REGISTRY="file://$d/registry" \
      STOCK_INTEGRITY="$(cat "$d/pinned" 2>/dev/null || true)" PATCH_BACKUP_DIR="$d/backups" \
      bash "$SCRIPT" "$@" >"$d/out" 2>&1 </dev/null
  echo $?
}
put_gen() { cp "$1/gen/$2/$3" "$1/plugin/$3"; }   # dir generation target

echo "stock plugin: every file is patched"
D="$T/stock"; make_env "$D"
rc="$(run_patcher "$D")"
check "$(is "$rc" 0)" "exit 0 (got $rc)"
ok=0; for ts in $TARGETS; do t="${ts%%:*}"; cmp -s "$D/plugin/$t" "$D/gen/2/$t" || ok=1; done
check "$ok" "all five targets now equal generation 2"
check "$([ -f "$D/plugin/dist/StreamKey.js" ] && [ -f "$D/plugin/dist/PrebufferManager.js" ]; echo $?)" "new files installed"
check "$([ ! -d "$D/backups" ]; echo $?)" "no backup made when nothing was upgraded"
rc="$(run_patcher "$D")"
check "$(is "$rc" 0)" "second run: exit 0 (got $rc)"
check "$(has "$D/out" 'All patches already present')" "second run reports all patches present"

echo "a patch that applies with an offset leaves no .orig behind (GNU patch keeps one by default)"
D="$T/offset"; make_env "$D"
{ echo "an extra first line"; cat "$D/plugin/dist/sdm/Camera.js"; } >"$D/plugin/x" && mv "$D/plugin/x" "$D/plugin/dist/sdm/Camera.js"
rc="$(run_patcher "$D")"
check "$(is "$rc" 0)" "exit 0 (got $rc)"
check "$(has "$D/plugin/dist/sdm/Camera.js" "nest-snaps generation 2")" "offset target patched"
check "$([ -z "$(find "$D/plugin" -name '*.orig' -o -name '*.rej')" ]; echo $?)" "no .orig/.rej left in the plugin"

echo "older generation on Api.js and StreamingDelegate.js: upgraded in place"
D="$T/upgrade"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js; put_gen "$D" 1 dist/StreamingDelegate.js
chmod 640 "$D/plugin/dist/sdm/Api.js"
rc="$(run_patcher "$D")"
check "$(is "$rc" 0)" "exit 0 (got $rc) -- $(tail -1 "$D/out")"
ok=0; for ts in $TARGETS; do t="${ts%%:*}"; cmp -s "$D/plugin/$t" "$D/gen/2/$t" || ok=1; done
check "$ok" "all five targets now equal generation 2"
check "$(has "$D/out" 'UPGRADED: dist/sdm/Api.js')" "Api.js reported UPGRADED"
check "$(has "$D/out" 'UPGRADED: dist/StreamingDelegate.js')" "StreamingDelegate.js reported UPGRADED"
check "$(has "$D/out" 'PATCHED: dist/sdm/Camera.js')" "a stock target in the same run is PATCHED"
B="$(ls -d "$D"/backups/* 2>/dev/null | head -1)"
check "$([ -n "$B" ] && cmp -s "$B/dist/sdm/Api.js" "$D/gen/1/dist/sdm/Api.js" && cmp -s "$B/dist/StreamingDelegate.js" "$D/gen/1/dist/StreamingDelegate.js"; echo $?)" "old copies backed up under PATCH_BACKUP_DIR"
check "$([ -n "$B" ] && [ ! -e "$B/dist/sdm/Camera.js" ]; echo $?)" "files that were not upgraded are not in the backup"
check "$(is "$(mode "$D/plugin/dist/sdm/Api.js")" 0o640)" "upgraded file keeps its mode"
check "$([ -z "$(find "$D/plugin" -name '*.orig' -o -name '*.rej')" ]; echo $?)" "no .orig/.rej left in the plugin"

echo "--dry-run on an older generation: shows the plan, changes nothing"
D="$T/dry"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
before="$(tree "$D/plugin")"
rc="$(run_patcher "$D" --dry-run)"
check "$(is "$rc" 0)" "exit 0 (got $rc)"
check "$(is "$(tree "$D/plugin")" "$before")" "plugin directory byte-identical"
check "$([ ! -d "$D/backups" ]; echo $?)" "no backup directory created"
check "$(has "$D/out" 'carries an older generation of Api.js.patch')" "names the file it would upgrade"
check "$(has "$D/out" 'would download homebridge-google-nest-sdm@1.1.25')" "says it would download stock"
check "$(has "$D/out" 'would patch: dist/sdm/Camera.js')" "names a stock file it would patch"
check "$(has "$D/out" 'would install: dist/StreamKey.js')" "names a new file it would install"

# Every refusal below must leave the plugin exactly as it was, including the OTHER file
# that could have been upgraded: nothing is touched until every target is resolved.
refuses() {  # $1=label $2=dir $3=expected text in the output
  local before rc
  before="$(tree "$2/plugin")"
  rc="$(run_patcher "$2")"
  check "$([ "$rc" != 0 ]; echo $?)" "$1: exits non-zero (got $rc)"
  check "$(is "$(tree "$2/plugin")" "$before")" "$1: plugin directory unchanged"
  check "$([ ! -d "$2/backups" ]; echo $?)" "$1: no backup directory created"
  check "$(has "$2/out" "$3")" "$1: says '$3'"
}

echo "hand-edited file (sentinel present, content unknown): refused"
D="$T/edited"; make_env "$D"
put_gen "$D" 1 dist/StreamingDelegate.js
put_gen "$D" 1 dist/sdm/Api.js; echo "// my local tweak" >>"$D/plugin/dist/sdm/Api.js"
refuses "hand edit" "$D" "matches no generation in known-generations.txt"

echo "older generation, but known-generations.txt missing: refused"
D="$T/nomanifest"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js; rm "$D/patches/known-generations.txt"
refuses "no manifest" "$D" "matches no generation"

echo "manifest entry for a different target does not count"
D="$T/wrongtarget"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
python3 - "$D/patches/known-generations.txt" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("  dist/sdm/Api.js  gen1", "  dist/sdm/Camera.js  gen1"))
PY
refuses "wrong target" "$D" "matches no generation"

echo "tarball does not match the pinned integrity: refused"
D="$T/badhash"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
echo "tampered" >>"$D/stockpkg/package/dist/sdm/Api.js"
(cd "$D/stockpkg" && tar czf "$D/registry/stock.tgz" package)   # metadata still names the pinned value
refuses "bad hash" "$D" "hashes to"

echo "registry metadata reports a different integrity than the pin: refused"
D="$T/badmeta"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
write_meta "$D" 1.1.25 "sha512-AAAA"
refuses "metadata integrity" "$D" "differs from the pinned"

echo "registry metadata for another version: refused"
D="$T/badver"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
write_meta "$D" 1.1.26 "$(cat "$D/pinned")"
refuses "metadata version" "$D" "not 1.1.25"

echo "registry unreachable: refused"
D="$T/nonet"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
rm "$D/registry/homebridge-google-nest-sdm/1.1.25"
refuses "no registry" "$D" "could not fetch registry metadata"

echo "tarball download fails: refused"
D="$T/notgz"; make_env "$D"
put_gen "$D" 1 dist/sdm/Api.js
rm "$D/registry/stock.tgz"
refuses "no tarball" "$D" "could not download"

echo "installed plugin is not the pinned version: refused"
D="$T/plugver"; make_env "$D"
echo '{"name":"homebridge-google-nest-sdm","version":"1.1.24"}' >"$D/plugin/package.json"
refuses "plugin version" "$D" "REFUSING: plugin is '1.1.24'"

# Permission checks mean nothing to root, which can write anything.
if [ "$(id -u)" != 0 ]; then
  echo "a file it would change is not writable: refused before anything is touched"
  D="$T/readonly"; make_env "$D"
  put_gen "$D" 1 dist/sdm/Api.js; put_gen "$D" 1 dist/StreamingDelegate.js
  chmod 444 "$D/plugin/dist/StreamingDelegate.js"
  refuses "read-only file" "$D" "cannot write dist/StreamingDelegate.js"
  check "$([ ! -e "$D/plugin/dist/StreamKey.js" ]; echo $?)" "read-only file: new files not installed either"

  echo "a new file's directory is not writable: refused"
  # Every patch target is current except Api.js (in dist/sdm/, still writable), so the only
  # thing that needs dist/ itself is the new files.
  D="$T/rodir"; make_env "$D"
  run_patcher "$D" >/dev/null
  rm "$D/plugin/dist/PrebufferManager.js" "$D/plugin/dist/StreamKey.js"
  put_gen "$D" 1 dist/sdm/Api.js
  chmod 555 "$D/plugin/dist"
  refuses "read-only dist/" "$D" "cannot write dist/PrebufferManager.js"
  chmod 755 "$D/plugin/dist"
fi

if [ -n "$STOCK_TGZ" ]; then
  echo "real patches: a025ce2 generation upgraded to this checkout's"
  R="$T/real"; mkdir -p "$R/a" "$R/b" "$R/registry/homebridge-google-nest-sdm" "$R/oldpatches"
  tar xzf "$STOCK_TGZ" -C "$R/a"; tar xzf "$STOCK_TGZ" -C "$R/b"
  check "$(python3 "$REPO/scripts/known-generations.py" "$R/a/package" --repo "$REPO" --check >/dev/null; echo $?)" "known-generations.txt is current"
  for pf in $PATCHES; do git -C "$REPO" show "a025ce2:patches/homebridge-plugin/$pf" >"$R/oldpatches/$pf"; done
  for pf in $PATCHES; do patch -s -p1 -d "$R/a/package" <"$R/oldpatches/$pf" || echo "old patch $pf failed"; done
  cp "$STOCK_TGZ" "$R/registry/stock.tgz"
  printf '{"version":"1.1.25","dist":{"tarball":"file://%s/registry/stock.tgz","integrity":"%s"}}\n' "$R" "$(integrity "$STOCK_TGZ")" \
    >"$R/registry/homebridge-google-nest-sdm/1.1.25"
  # No STOCK_INTEGRITY override: the script's own pin must match the real tarball.
  env PLUGIN="$R/a/package" HOMEBRIDGE_DIR="$R" NPM_REGISTRY="file://$R/registry" PATCH_BACKUP_DIR="$R/backups" \
      bash "$SCRIPT" >"$R/out" 2>&1 </dev/null; rc=$?
  check "$(is "$rc" 0)" "exit 0 (got $rc) -- $(tail -1 "$R/out")"
  env PLUGIN="$R/b/package" HOMEBRIDGE_DIR="$R" PATCH_BACKUP_DIR="$R/backups-b" bash "$SCRIPT" >/dev/null 2>&1 </dev/null
  check "$(diff -r "$R/a/package" "$R/b/package" >/dev/null; echo $?)" "upgraded plugin is byte-identical to freshly patched stock"

  echo "known-generations.py: refuses a shallow clone, never drops an entry"
  git clone -q --depth 1 "file://$(cd "$REPO" && pwd)" "$R/shallow" 2>/dev/null
  mkdir -p "$R/stockonly"; tar xzf "$STOCK_TGZ" -C "$R/stockonly"
  python3 "$REPO/scripts/known-generations.py" "$R/stockonly/package" --repo "$R/shallow" >"$R/kg.out" 2>&1; rc=$?
  check "$([ "$rc" != 0 ] && grep -q "shallow clone" "$R/kg.out"; echo $?)" "shallow clone refused (exit $rc)"
  mkdir -p "$R/full" && cp -R "$REPO/." "$R/full/"
  KG="$R/full/patches/homebridge-plugin/known-generations.txt"
  echo "$(printf '%064d' 0)  dist/sdm/Api.js  from-a-commit-no-longer-in-history" >>"$KG"
  python3 "$R/full/scripts/known-generations.py" "$R/stockonly/package" --repo "$R/full" >/dev/null 2>&1
  check "$(grep -q "^$(printf '%064d' 0)  dist/sdm/Api.js" "$KG"; echo $?)" "an entry this run did not regenerate is kept"
fi

echo
if [ "$fails" -gt 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all checks passed"
