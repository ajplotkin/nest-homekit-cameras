#!/usr/bin/env bash
# Off-box test for install.sh --dry-run.   bash test/install-dry-run.test.sh [path/to/install.sh]
#
# Runs the real install.sh with a fake `docker` on PATH (it reports that the --image already
# exists, so the build is skipped) against a throwaway Homebridge config, and checks what the
# dry run says it would do. Nothing is installed; it needs no root, no Docker and no network.
#
#   1. --image <existing> with a --go2rtc-dir that does not exist: the directory must be
#      created BEFORE go2rtc.yaml is generated. On a fresh machine it was only created inside
#      the (skipped) build step, and the sync script died with FileNotFoundError.
#   2. The wedge detector is installed: script, unit, log directory, logrotate, enable.
#      Detect-only by default -- and still detect-only when an existing unit merely MENTIONS
#      --arm in a comment, as the hand-written unit on the author's Pi does -- but an existing
#      unit that IS armed stays armed on a re-run.
#   3. --dry-run changes nothing: the fresh --go2rtc-dir still does not exist afterwards.
#   4. The plugin patches run BEFORE go2rtc.yaml is regenerated, so a patcher refusal (an
#      upgraded install whose patch files changed) stops the installer before go2rtc moves to
#      keys the unpatched plugin does not use.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${1:-$HERE/../install.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }

mkdir -p "$T/bin" "$T/hb"
cat >"$T/bin/docker" <<'SH'
#!/bin/sh
# Fake docker: daemon reachable, every image present, no containers.
case "$1" in
  info) exit 0;;
  image) exit 0;;              # image inspect <IMAGE> -> present
  ps) exit 0;;                 # ps -a --format ... -> no containers
  *) exit 1;;                  # inspect <container> -> no such container
esac
SH
chmod +x "$T/bin/docker"
# A plugin install the patch phase will act on (version matches; dirs writable).
mkdir -p "$T/hb/node_modules/homebridge-google-nest-sdm/dist/sdm"
echo '{"version":"1.1.25"}' >"$T/hb/node_modules/homebridge-google-nest-sdm/package.json"
cat >"$T/hb/config.json" <<'JSON'
{"platforms":[{"platform":"homebridge-google-nest-sdm","clientId":"c","clientSecret":"s","projectId":"p","refreshToken":"r"}]}
JSON

mkdir -p "$T/logrotate.d"
run_install() {   # $1 = output file; extra env via the caller
  SUDO_USER=someone-else WEDGE_LOGROTATE="$T/logrotate.d/nest-wedge" PATH="$T/bin:$PATH" bash "$INSTALL" --dry-run --image go2rtc-nestfix:test \
    --hb-config "$T/hb/config.json" --homebridge-dir "$T/hb" --snaps-dir "$T/snaps" \
    --go2rtc-dir "$T/fresh/go2rtc" --scripts-dir "$T/scripts" >"$1" 2>&1
}

echo "fresh --go2rtc-dir, --image already present, no existing wedge unit"
WEDGE_UNIT="$T/none.service" run_install "$T/out1"; rc=$?
check "install.sh --dry-run exits 0 (got $rc)" '[ "$rc" = 0 ]'
check "build step skipped (image present)" 'grep -q "image already present" "$T/out1"'
mk=$(grep -n "\[dry-run\] mkdir -p '$T/fresh/go2rtc'\$" "$T/out1" | head -1 | cut -d: -f1)
sy=$(grep -n "\[dry-run\] python3 .*nest-go2rtc-sync.py" "$T/out1" | head -1 | cut -d: -f1)
check "go2rtc dir is created (line ${mk:-none}) before go2rtc.yaml is generated (line ${sy:-none})" \
  '[ -n "$mk" ] && [ -n "$sy" ] && [ "$mk" -lt "$sy" ]'
pa=$(grep -n "\[dry-run\] env HOMEBRIDGE_DIR=.*apply-snapshot-patch.sh" "$T/out1" | head -1 | cut -d: -f1)
check "plugin patches (line ${pa:-none}) run before go2rtc.yaml is generated (line ${sy:-none})" \
  '[ -n "$pa" ] && [ -n "$sy" ] && [ "$pa" -lt "$sy" ]'
check "wedge unit runs as the installing user" 'grep -q "^User=$(id -un)\$" "$T/out1"'
check "wedge detector script installed into --scripts-dir" \
  'grep -q "install -m 0755 .*/scripts/go2rtc-wedge-detector.py. .$T/scripts/go2rtc-wedge-detector.py" "$T/out1"'
check "wedge unit ExecStart: the installed script, port 1985, interval 30" \
  'grep -q "^ExecStart=.* $T/scripts/go2rtc-wedge-detector.py --api http://127.0.0.1:1985/api/streams --interval 30\$" "$T/out1"'
check "wedge unit is detect-only (no --arm on ExecStart)" '! grep "^ExecStart=.*wedge-detector" "$T/out1" | grep -q -- "--arm"'
check "wedge unit Documentation= points at nest-homekit-cameras" \
  'grep -q "^Documentation=https://github.com/ajplotkin/nest-homekit-cameras" "$T/out1"'
check "wedge unit logs to /var/log/nest/wedge-detector.log" \
  'grep -q "^StandardOutput=append:/var/log/nest/wedge-detector.log\$" "$T/out1"'
check "log directory created" 'grep -q "\[dry-run\] sudo mkdir -p /var/log/nest" "$T/out1"'
check "logrotate entry written, with copytruncate (systemd holds the log open)" \
  'grep -q "sudo tee .$T/logrotate.d/nest-wedge." "$T/out1" && grep -q "^    copytruncate\$" "$T/out1"'
check "wedge unit enabled and (re)started" \
  'grep -q "systemctl enable go2rtc-wedge-detector.service" "$T/out1" && grep -q "systemctl restart go2rtc-wedge-detector.service" "$T/out1"'
check "dry run created nothing: $T/fresh does not exist" '[ ! -e "$T/fresh" ]'

echo "existing unit that only mentions --arm in comments (the author's hand-written unit)"
cat >"$T/commented.service" <<'UNIT'
[Service]
# NOTE: no --arm. This only observes and logs; it cannot restart anything.
# To arm it: append --arm below, then
ExecStart=/usr/bin/python3 /home/someone/scripts/go2rtc-wedge-detector.py \
  --api http://127.0.0.1:1985/api/streams --interval 30
UNIT
WEDGE_UNIT="$T/commented.service" run_install "$T/out2"; rc=$?
check "exits 0 (got $rc)" '[ "$rc" = 0 ]'
check "still detect-only" '! grep "^ExecStart=.*wedge-detector" "$T/out2" | grep -q -- "--arm"'

echo "existing unit that mentions --arm only in its Description"
cat >"$T/described.service" <<'UNIT'
[Unit]
Description=go2rtc wedge detector (append --arm to ExecStart to arm it)
[Service]
ExecStart=/usr/bin/python3 /home/someone/scripts/go2rtc-wedge-detector.py --interval 30
UNIT
WEDGE_UNIT="$T/described.service" run_install "$T/out4"; rc=$?
check "exits 0 (got $rc)" '[ "$rc" = 0 ]'
check "still detect-only" '! grep "^ExecStart=.*wedge-detector" "$T/out4" | grep -q -- "--arm"'

echo "existing unit with a drop-in"
mkdir -p "$T/dropin.service.d" && cp "$T/commented.service" "$T/dropin.service"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 /x/go2rtc-wedge-detector.py --arm\n' >"$T/dropin.service.d/override.conf"
WEDGE_UNIT="$T/dropin.service" run_install "$T/out5"; rc=$?
check "exits 0 (got $rc)" '[ "$rc" = 0 ]'
check "warns that a drop-in overrides the unit" 'grep -q "drop-ins in $T/dropin.service.d/ override" "$T/out5"'

echo "existing unit that is armed (on a continuation line)"
cat >"$T/armed.service" <<'UNIT'
[Service]
ExecStart=/usr/bin/python3 /home/someone/scripts/go2rtc-wedge-detector.py \
  --api http://127.0.0.1:1985/api/streams --interval 30 --arm
UNIT
WEDGE_UNIT="$T/armed.service" run_install "$T/out3"; rc=$?
check "exits 0 (got $rc)" '[ "$rc" = 0 ]'
check "--arm kept on ExecStart" 'grep "^ExecStart=.*wedge-detector" "$T/out3" | grep -q -- " --arm\$"'
check "says it kept --arm" 'grep -qi "kept --arm" "$T/out3"'

echo
if [ "$fails" -gt 0 ]; then echo "FAILED: $fails check(s)"; echo "--- last output ($T/out1) ---"; tail -40 "$T/out1"; exit 1; fi
echo "all checks passed"
