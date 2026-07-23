#!/usr/bin/env bash
#
# install.sh — set up the go2rtc warm-stream + snapshot layer for
# Nest-cameras-in-HomeKit, everything AFTER you have Google Device Access
# credentials in a working Homebridge + homebridge-google-nest-sdm install.
#
# It is idempotent: re-running skips work already done. It changes nothing it
# can't safely own — the one step it can't do for you (mounting the snapshot
# dir into YOUR Homebridge container) is detected and printed as an exact
# instruction rather than guessed at.
#
# Prereqs you must already have (see the guide, Parts 1–2):
#   - Docker
#   - Homebridge running with homebridge-google-nest-sdm 1.1.23 configured
#     (clientId/clientSecret/projectId/refreshToken in its config.json)
#
# Usage:
#   ./install.sh [--hb-config PATH] [--homebridge-dir DIR] [--snaps-dir DIR]
#                [--go2rtc-dir DIR] [--scripts-dir DIR]
#                [--homebridge-container NAME] [--go2rtc-container NAME]
#                [--image NAME:TAG] [--rebuild] [--dry-run] [--help]
#
set -euo pipefail

# ---- defaults (all overridable) --------------------------------------------
HOMEBRIDGE_DIR="${HOMEBRIDGE_DIR:-$HOME/homebridge}"
HB_CONFIG=""                       # defaults to $HOMEBRIDGE_DIR/config.json
SNAPS_DIR="${SNAPS_DIR:-/run/nest-snaps}"
GO2RTC_DIR="${GO2RTC_DIR:-$HOME/go2rtc-nest}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/scripts}"
HB_CONTAINER="${HOMEBRIDGE_CONTAINER:-homebridge}"
GO2RTC_CONTAINER="${GO2RTC_CONTAINER:-go2rtc}"
IMAGE="${GO2RTC_IMAGE:-go2rtc-nestfix:1.9.14}"
FORK_URL="${FORK_URL:-https://github.com/ajplotkin/go2rtc.git}"
# Pinned to a stable TAG, not a moving branch. The dev branch carries in-progress
# work (and at times debug logging), which must never land in someone's install.
# `git clone --branch` accepts a tag, so this needs no other change. Override to
# test a branch: FORK_BRANCH=fix/nest-ipv6-ice-failure ./install.sh
FORK_BRANCH="${FORK_BRANCH:-nestfix-1.9.14-1}"
BASE_IMAGE="${BASE_IMAGE:-alexxit/go2rtc:1.9.14}"
PLUGIN_VER="1.1.23"
REBUILD=0
DRY_RUN=0

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hb-config) HB_CONFIG="$2"; shift 2;;
    --homebridge-dir) HOMEBRIDGE_DIR="$2"; shift 2;;
    --snaps-dir) SNAPS_DIR="$2"; shift 2;;
    --go2rtc-dir) GO2RTC_DIR="$2"; shift 2;;
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2;;
    --homebridge-container) HB_CONTAINER="$2"; shift 2;;
    --go2rtc-container) GO2RTC_CONTAINER="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --rebuild) REBUILD=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done
HB_CONFIG="${HB_CONFIG:-$HOMEBRIDGE_DIR/config.json}"

DOCKER="docker"; command -v docker >/dev/null 2>&1 || die "docker not found"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# ---- phase 0: preflight -----------------------------------------------------
say "Preflight checks"
for c in git curl python3; do command -v "$c" >/dev/null 2>&1 || die "$c not found (install it first)"; done
$DOCKER info >/dev/null 2>&1 || die "cannot talk to docker (need sudo or docker group)"
[ -f "$HB_CONFIG" ] || die "Homebridge config not found: $HB_CONFIG (pass --hb-config)"
python3 - "$HB_CONFIG" <<'PY' || die "no homebridge-google-nest-sdm platform (with clientId/refreshToken) in the config"
import json,sys
c=json.load(open(sys.argv[1]))
p=next((p for p in c.get("platforms",[]) if p.get("platform")=="homebridge-google-nest-sdm"),None)
sys.exit(0 if p and all(p.get(k) for k in ("clientId","clientSecret","projectId","refreshToken")) else 1)
PY
ok "Homebridge config has Nest credentials: $HB_CONFIG"
PLUGIN_DIR="$HOMEBRIDGE_DIR/node_modules/homebridge-google-nest-sdm"
if [ -f "$PLUGIN_DIR/package.json" ]; then
  cur=$(python3 -c "import json;print(json.load(open('$PLUGIN_DIR/package.json'))['version'])" 2>/dev/null || echo "?")
  [ "$cur" = "$PLUGIN_VER" ] && ok "plugin version $cur" || warn "plugin is $cur, patches are cut for $PLUGIN_VER — patch step will refuse; re-cut diffs first"
else
  warn "plugin not found at $PLUGIN_DIR — the plugin-patch step will be skipped (set --homebridge-dir)"
fi

# ---- phase 1: build the patched go2rtc image --------------------------------
say "Build patched go2rtc image ($IMAGE)"
if [ "$REBUILD" = 0 ] && $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image already present (use --rebuild to force)"
else
  BUILD_TMP="$GO2RTC_DIR/.build"
  run "mkdir -p '$GO2RTC_DIR'"
  run "rm -rf '$BUILD_TMP' && git clone --quiet --branch '$FORK_BRANCH' --depth 1 '$FORK_URL' '$BUILD_TMP'"
  say "  compiling (arm64/amd64 native, a few minutes)…"
  run "$DOCKER run --rm -v '$BUILD_TMP':/src -w /src -e GOCACHE=/src/.gocache -e GOMODCACHE=/src/.gomod golang:1.24-alpine sh -c 'CGO_ENABLED=0 go build -trimpath -ldflags \"-s -w\" -o go2rtc_patched .'"
  run "printf 'FROM %s\nCOPY go2rtc_patched /usr/local/bin/go2rtc\n' '$BASE_IMAGE' > '$BUILD_TMP/Dockerfile'"
  run "$DOCKER build -t '$IMAGE' '$BUILD_TMP'"
  ok "built $IMAGE"
fi

# ---- phase 2: tmpfs for snapshots -------------------------------------------
say "Snapshot directory ($SNAPS_DIR)"
if [ "$SNAPS_DIR" = "/run/nest-snaps" ]; then
  TMPFILE=/etc/tmpfiles.d/nest-snaps.conf
  if [ ! -f "$TMPFILE" ]; then
    run "echo 'd $SNAPS_DIR 0755 $(id -u) $(id -g) -' | sudo tee $TMPFILE >/dev/null"
    run "sudo systemd-tmpfiles --create $TMPFILE"
    ok "tmpfs entry created (survives reboot, spares SD-card wear)"
  else ok "tmpfs entry already present"; fi
fi
run "mkdir -p '$SNAPS_DIR'"

# ---- phase 3: scripts + generate config + start go2rtc ----------------------
say "Install helper scripts into $SCRIPTS_DIR"
run "mkdir -p '$SCRIPTS_DIR'"
for s in nest-go2rtc-sync.py go2rtc-snapshot-warmer.sh; do
  run "install -m 0755 '$REPO_DIR/scripts/$s' '$SCRIPTS_DIR/$s'"
done
ok "sync + warmer installed"

say "Generate go2rtc.yaml from your Homebridge credentials"
run "python3 '$SCRIPTS_DIR/nest-go2rtc-sync.py' --hb-config '$HB_CONFIG' --out '$GO2RTC_DIR/go2rtc.yaml' --container '$GO2RTC_CONTAINER'"
run "chmod 600 '$GO2RTC_DIR/go2rtc.yaml' || true"   # contains the OAuth secret
ok "wrote $GO2RTC_DIR/go2rtc.yaml (chmod 600)"

say "Start go2rtc container ($GO2RTC_CONTAINER)"
if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$GO2RTC_CONTAINER"; then
  run "$DOCKER rm -f '$GO2RTC_CONTAINER' >/dev/null 2>&1 || true"
fi
run "$DOCKER run -d --name '$GO2RTC_CONTAINER' --restart unless-stopped --network host -v '$GO2RTC_DIR/go2rtc.yaml':/config/go2rtc.yaml '$IMAGE' >/dev/null"
ok "go2rtc running"

# ---- phase 4: warmer systemd service ----------------------------------------
say "Install snapshot-warmer service"
UNIT=/etc/systemd/system/go2rtc-snapshot-warmer.service
run "sudo tee $UNIT >/dev/null <<UNIT
[Unit]
Description=Keep go2rtc snapshot cache warm for Homebridge/HomeKit
After=docker.service
Wants=docker.service
[Service]
ExecStart=$SCRIPTS_DIR/go2rtc-snapshot-warmer.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT"
run "sudo systemctl daemon-reload"
run "sudo systemctl enable --now go2rtc-snapshot-warmer.service"
ok "warmer service enabled + started"

# ---- phase 5: plugin patches ------------------------------------------------
if [ -f "$PLUGIN_DIR/package.json" ]; then
  say "Patch the Homebridge plugin"
  run "HOMEBRIDGE_DIR='$HOMEBRIDGE_DIR' HOMEBRIDGE_CONTAINER='$HB_CONTAINER' PATCH_DIR='$REPO_DIR/patches/homebridge-plugin' bash '$REPO_DIR/scripts/apply-snapshot-patch.sh'"
fi

# ---- phase 6: homebridge snapshot mount (detect, can't safely auto-do) ------
say "Check Homebridge sees the snapshot directory"
MOUNTED=0
if $DOCKER inspect "$HB_CONTAINER" >/dev/null 2>&1; then
  if $DOCKER inspect "$HB_CONTAINER" --format '{{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' 2>/dev/null | grep -q "$SNAPS_DIR->/homebridge/nest-snaps"; then
    MOUNTED=1
  fi
fi
if [ "$MOUNTED" = 1 ]; then
  ok "$SNAPS_DIR is mounted into $HB_CONTAINER at /homebridge/nest-snaps"
else
  warn "Homebridge does NOT have the snapshot dir mounted — tiles will stay on the placeholder until you add it."
  cat <<EOF
   Add this bind mount to how you run the Homebridge container and restart it:
       -v $SNAPS_DIR:/homebridge/nest-snaps
   (docker-compose: under the homebridge service's 'volumes:', add
        - $SNAPS_DIR:/homebridge/nest-snaps )
   This is the one step this installer can't do for you, because how you run
   Homebridge (compose / systemd / homebridge-config-ui) is yours to own.
EOF
fi

# ---- phase 7: verify --------------------------------------------------------
say "Verify"
[ "$DRY_RUN" = 1 ] && { ok "dry-run complete — no changes made"; exit 0; }
sleep 20
API="http://127.0.0.1:1985"
warm=$(curl -s -m 8 "$API/api/streams" 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for s in d.values() for p in (s.get("producers") or []) for r in (p.get("receivers") or []) if (r.get("bytes") or 0)>0))' 2>/dev/null || echo 0)
ok "go2rtc reports $warm warm receiver(s)"
sleep 12
n=$(ls "$SNAPS_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && ok "$n snapshot file(s) on disk in $SNAPS_DIR" || warn "no snapshot files yet — check 'journalctl -u go2rtc-snapshot-warmer' and that cameras are on"
echo
say "Done. Open Apple Home — tiles should show real images within a minute."
[ "$MOUNTED" = 0 ] && warn "…once you add the snapshot bind mount to Homebridge (see above)."
