#!/usr/bin/env bash
#
# install.sh — set up the go2rtc warm-stream + snapshot layer for
# Nest-cameras-in-HomeKit, everything AFTER you have Google Device Access
# credentials in a working Homebridge + homebridge-google-nest-sdm install.
#
# Re-running is safe but not a no-op: it skips the image build and patches that are
# already applied, but it recreates the go2rtc container (dropping every warm stream)
# and rewrites the warmer unit. It changes nothing it can't safely own — the one
# step it can't do for you (mounting the snapshot dir into YOUR Homebridge
# container) is detected and printed as an exact instruction rather than guessed at.
#
# Prereqs you must already have (see the guide, Parts 1–2):
#   - Docker
#   - Homebridge running with homebridge-google-nest-sdm 1.1.25 configured
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
# Pinned to a release TAG. The nestfix tags are a branchless chain on top of upstream
# master, so there is no branch to build from; work in progress is never tagged and so
# never lands in someone's install. `git clone --branch` accepts a tag. Override to
# build a different tag: FORK_BRANCH=nestfix-1.9.14-10 ./install.sh
FORK_BRANCH="${FORK_BRANCH:-nestfix-1.9.14-21}"
BASE_IMAGE="${BASE_IMAGE:-alexxit/go2rtc:1.9.14}"
PLUGIN_VER="1.1.25"
REBUILD=0
DRY_RUN=0

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
# For results of a `run` step: in --dry-run nothing ran, so do not print "ok".
did()  { if [ "$DRY_RUN" = 1 ]; then printf '   [dry-run] would have: %s\n' "$*"; else ok "$*"; fi; }
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
    -h|--help) awk 'NR>2 && /^#/{sub(/^# ?/,""); print; next} NR>2{exit}' "$0"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done
HB_CONFIG="${HB_CONFIG:-$HOMEBRIDGE_DIR/config.json}"

DOCKER="docker"; command -v docker >/dev/null 2>&1 || die "docker not found"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# ---- phase 0: preflight -----------------------------------------------------
say "Preflight checks"
# python3 and patch are needed by the plugin-patch phase, so check them here: a missing one
# used to surface as "REFUSING: plugin is ''" long after containers and services were up.
# node is NOT needed on the host: the patcher reads the plugin version with python3 (node
# only as a fallback), and a Homebridge-in-Docker host usually has no node outside the
# container. Requiring it here refused to install on exactly that host. (2026-10-29)
for c in git curl python3 patch; do command -v "$c" >/dev/null 2>&1 || die "$c not found (install it first)"; done
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
  cur=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$PLUGIN_DIR/package.json" 2>/dev/null || echo "?")
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
  # Go writes its module cache read-only, so a plain `rm -rf` of a previous build fails even
  # for its owner; make it writable first. A build dir left root-owned by an older install.sh
  # still cannot be removed without sudo, and saying so beats a bare "Permission denied".
  run "{ chmod -R u+w '$BUILD_TMP' 2>/dev/null; rm -rf '$BUILD_TMP'; } || die \"cannot remove $BUILD_TMP (left root-owned by an older install.sh?) -- run: sudo rm -rf '$BUILD_TMP'   then re-run\""
  # A shallow clone of an annotated tag prints "warning: ... is not a commit!" and a
  # detached-HEAD lecture even with --quiet; both are harmless and read like a failure.
  # Keep git's output in a log and show it only if the clone actually fails.
  # Source goes in .build/src, with the Go caches and the binary beside it, not inside it:
  # Go counts untracked files in the checkout as modifications and the binary would then
  # report revision "<sha>.dirty", which check-drift.sh reads as a wrong build.
  run "git -c advice.detachedHead=false clone --quiet --branch '$FORK_BRANCH' --depth 1 '$FORK_URL' '$BUILD_TMP/src' 2>'$GO2RTC_DIR/.clone.log' || { cat '$GO2RTC_DIR/.clone.log' >&2; die \"git clone of $FORK_URL ($FORK_BRANCH) failed\"; }"
  warn "the Go build below wants ~1-1.5 GB free RAM. On a low-memory host — e.g. a 2 GB Raspberry Pi already running Homebridge/HA — it can OOM and take services down. If that's your box, build the image on a beefier machine (this same repo, any arch you'll run) and move it over: 'docker save $IMAGE | ssh pi docker load', then re-run this script with --image $IMAGE (it detects the existing image and skips the build)."
  say "  compiling (arm64/amd64 native, a few minutes)…"
  # --user: as root the build would leave .build/ (and its Go caches) root-owned on the
  # host, and the next --rebuild's `rm -rf` as you would fail with Permission denied.
  # -modcacherw: the module cache is otherwise written read-only (see the rm above).
  # golang:1.24, not -alpine: the alpine image has no git, so Go cannot stamp the commit
  # into the binary, go2rtc's /api then reports an empty revision, and check-drift.sh
  # cannot tell which tag is running. safe.directory: git refuses (exit 128, which fails
  # the whole build) to read a tree owned by another uid, as on a shared or sudo-made clone.
  run "$DOCKER run --rm --user $(id -u):$(id -g) -v '$BUILD_TMP':/work -w /work/src -e HOME=/work -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/work/src -e GOFLAGS=-modcacherw -e GOCACHE=/work/.gocache -e GOMODCACHE=/work/.gomod golang:1.24 sh -c 'CGO_ENABLED=0 go build -trimpath -ldflags \"-s -w\" -o /work/go2rtc_patched .'"
  # Build the image from a directory holding only the binary: the source tree plus the Go
  # module cache is hundreds of MB that `docker build` would otherwise send to the daemon.
  run "mkdir -p '$BUILD_TMP/image' && cp '$BUILD_TMP/go2rtc_patched' '$BUILD_TMP/image/go2rtc_patched'"
  run "printf 'FROM %s\nCOPY go2rtc_patched /usr/local/bin/go2rtc\n' '$BASE_IMAGE' > '$BUILD_TMP/image/Dockerfile'"
  run "$DOCKER build -t '$IMAGE' '$BUILD_TMP/image'"
  did "built $IMAGE"
fi

# ---- phase 2: tmpfs for snapshots -------------------------------------------
say "Snapshot directory ($SNAPS_DIR)"
if [ "$SNAPS_DIR" = "/run/nest-snaps" ]; then
  TMPFILE=/etc/tmpfiles.d/nest-snaps.conf
  if [ ! -f "$TMPFILE" ]; then
    run "echo 'd $SNAPS_DIR 0755 $(id -u) $(id -g) -' | sudo tee $TMPFILE >/dev/null"
    run "sudo systemd-tmpfiles --create $TMPFILE"
    did "tmpfs entry created (survives reboot, spares SD-card wear)"
  else ok "tmpfs entry already present"; fi
fi
run "mkdir -p '$SNAPS_DIR'"

# ---- phase 3: scripts + generate config + start go2rtc ----------------------
say "Install helper scripts into $SCRIPTS_DIR"
run "mkdir -p '$SCRIPTS_DIR'"
for s in nest-go2rtc-sync.py go2rtc-snapshot-warmer.sh; do
  run "install -m 0755 '$REPO_DIR/scripts/$s' '$SCRIPTS_DIR/$s'"
done
did "sync + warmer installed"

say "Generate go2rtc.yaml from your Homebridge credentials"
# --no-restart: the container is created a few lines below and reads this file on
# startup, so there is nothing to restart yet. Without the flag, the sync script's
# `docker restart` fails on a fresh machine, exits 1, and takes this whole installer
# down with it under `set -euo pipefail` -- leaving go2rtc unstarted, the warmer
# service uninstalled and the plugin unpatched, behind a message that reads like a
# go2rtc problem. (A second run appeared to work only because an unchanged config
# short-circuits before the restart.)
run "python3 '$SCRIPTS_DIR/nest-go2rtc-sync.py' --hb-config '$HB_CONFIG' --out '$GO2RTC_DIR/go2rtc.yaml' --container '$GO2RTC_CONTAINER' --no-restart"
run "chmod 600 '$GO2RTC_DIR/go2rtc.yaml' || true"   # contains the OAuth secret
did "wrote $GO2RTC_DIR/go2rtc.yaml (chmod 600)"

say "Start go2rtc container ($GO2RTC_CONTAINER)"
if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$GO2RTC_CONTAINER"; then
  warn "replacing the existing '$GO2RTC_CONTAINER' container (docker rm -f). Its config is the file $GO2RTC_DIR/go2rtc.yaml, so nothing is lost — but if '$GO2RTC_CONTAINER' is NOT the go2rtc you think it is, Ctrl-C now and re-run with --go2rtc-container NAME."
  run "$DOCKER rm -f '$GO2RTC_CONTAINER' >/dev/null 2>&1 || true"
fi
run "$DOCKER run -d --name '$GO2RTC_CONTAINER' --restart unless-stopped --network host -v '$GO2RTC_DIR/go2rtc.yaml':/config/go2rtc.yaml '$IMAGE' >/dev/null"
did "go2rtc running"

# ---- phase 4: warmer systemd service ----------------------------------------
say "Install snapshot-warmer service"
UNIT=/etc/systemd/system/go2rtc-snapshot-warmer.service
run "sudo tee $UNIT >/dev/null <<UNIT
[Unit]
Description=Keep go2rtc snapshot cache warm for Homebridge/HomeKit
After=docker.service
Wants=docker.service
[Service]
Environment=SNAPS_DIR=$SNAPS_DIR
ExecStart=$SCRIPTS_DIR/go2rtc-snapshot-warmer.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT"
run "sudo systemctl daemon-reload"
run "sudo systemctl enable --now go2rtc-snapshot-warmer.service"
did "warmer service enabled + started"

# ---- phase 5: plugin patches ------------------------------------------------
if [ -f "$PLUGIN_DIR/package.json" ]; then
  say "Patch the Homebridge plugin"
  # Homebridge in Docker runs npm as root, so on the host the plugin's files are usually
  # root-owned and a plain-user patch run cannot write them. It exited 1 here, which under
  # `set -e` ended the installer before the mount check and the closing instructions.
  SUDO_PATCH=""
  if [ ! -w "$PLUGIN_DIR" ] || [ ! -w "$PLUGIN_DIR/dist" ] || [ ! -w "$PLUGIN_DIR/dist/sdm" ]; then
    SUDO_PATCH="sudo "
    warn "plugin files are not writable by $(id -un) (normal for Homebridge in Docker) — patching with sudo"
  fi
  run "${SUDO_PATCH}env HOMEBRIDGE_DIR='$HOMEBRIDGE_DIR' HOMEBRIDGE_CONTAINER='$HB_CONTAINER' DOCKER_CMD='$DOCKER' PATCH_DIR='$REPO_DIR/patches/homebridge-plugin' bash '$REPO_DIR/scripts/apply-snapshot-patch.sh'"
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
   Add this bind mount to how you run the Homebridge container:
       -v $SNAPS_DIR:/homebridge/nest-snaps
   (docker-compose: under the homebridge service's 'volumes:', add
        - $SNAPS_DIR:/homebridge/nest-snaps )
   A running container cannot gain a mount, so 'docker restart' is not enough:
   recreate it (docker rm + docker run, or 'docker compose up -d').
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
# `ls` exits 2 when nothing matches, and under `set -euo pipefail` that propagated
# through the assignment and killed the installer right here -- before the warn below
# written for this exact case, and before the closing reload instructions. The `warm=` line above already
# guards this way; this one did not. Zero snapshots is normal on a cold start or with
# every camera switched off.
n=$(find "$SNAPS_DIR" -maxdepth 1 -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ') || n=0
[ "$n" -gt 0 ] && ok "$n snapshot file(s) on disk in $SNAPS_DIR" || warn "no snapshot files yet — check 'journalctl -u go2rtc-snapshot-warmer' and that cameras are on"
echo
# The prebuffer ships with the patches but is OFF unless hksvPrebufferSeconds is set. Say so
# rather than leaving the user with dormant code and no hint it exists. Deliberately NOT
# auto-edited: config.json holds their OAuth credentials and is theirs to own.
if ! python3 - "$HB_CONFIG" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
ps = [p for p in d.get("platforms", []) if "nest" in str(p.get("platform", "")).lower()]
sys.exit(0 if ps and (float(ps[0].get("hksvPrebufferSeconds") or 0) > 0) else 1)
PY
then
  warn "HKSV prebuffer is installed but NOT enabled."
  cat <<EOF
   Without it, recordings begin ~3.6s after Google's event timestamp — late enough
   that HomeKit's own People/Animals/Vehicles analysis often finds nobody in the
   clip and silently discards it. To enable, add to the
   homebridge-google-nest-sdm platform block in $HB_CONFIG:

       "hksvPrebufferSeconds": 6,
       "hksvPrebufferRetainSeconds": 15

   then reload Homebridge ($DOCKER exec $HB_CONTAINER pkill -x homebridge). Verify with:
       docker logs $HB_CONTAINER 2>&1 | grep "prebuffer.*serving"
EOF
else
  ok "HKSV prebuffer is enabled in $HB_CONFIG"
fi
echo
say "Done. Reload Homebridge with:  $DOCKER exec $HB_CONTAINER pkill -x homebridge   (prefer this to docker restart: every container start runs npm install, which wipes the patches if the pinned plugin version differs from the installed one). Then open Apple Home; tiles should show real images within a minute."
# The plugin patches land in dist/ on disk; the running process is still executing the code it
# loaded at startup, and nothing in this script restarts Homebridge, so tiles sit on the
# placeholder while everything reports success until it is reloaded. Saying this at the end is
# cheaper than the support question it prevents.
# `if`, not `[ ] && warn`: as the script's last command, a false test made every run whose
# mount was already in place exit 1 after succeeding.
if [ "$MOUNTED" = 0 ]; then warn "…once you add the snapshot bind mount to Homebridge (see above)."; fi
