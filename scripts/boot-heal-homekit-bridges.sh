#!/bin/bash
# Post-boot self-heal for HomeKit bridges.
#
# THE PROBLEM: after a power failure, the Pi's containers can start before the network
# (and Home Assistant, if you use it) have settled. Bridges that advertise over mDNS at
# that moment never get discovered properly, and every accessory shows "No Response" in
# the Home app until something restarts them — which, on an unattended box 3,000 miles
# away, is nobody. Restarting the BRIDGES is the fix; restarting avahi is not (Homebridge
# and Matterbridge each run their own mDNS responder, so avahi never sees them).
#
# WHY A TIMER, NOT network-online.target: that target is unreliable on Raspberry Pi OS —
# it is frequently reported reached while DHCP/DNS are still settling, and has been seen
# silently skipped entirely. An OnBootSec timer does not depend on it.
#
# Install: see the systemd unit + timer at the bottom of this file, or run install.sh.
# All settings are env vars so nothing here is host-specific.

# Containers to restart. Space-separated; only containers that actually exist are touched.
BRIDGE_CONTAINERS="${BRIDGE_CONTAINERS:-homebridge matterbridge}"

# Optional: if you run Home Assistant and your bridges expose HA entities, wait for HA to
# answer before restarting, so the bridges re-advertise with their entities already loaded.
# Set HA_URL="" to skip the wait entirely (note the `-` not `:-`, so an explicitly empty
# value is honoured rather than falling back to the default).
HA_URL="${HA_URL-http://localhost:8123}"
GRACE="${GRACE:-30}"        # extra settle after HA answers, so integrations finish loading
MAX_WAIT="${MAX_WAIT:-72}"  # x5s = up to 6 min for HA to answer before giving up

log() { logger -t homekit-boot-heal "$*"; }

if [ -n "$HA_URL" ]; then
  waited=0
  for i in $(seq 1 "$MAX_WAIT"); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$HA_URL/" 2>/dev/null || echo 000)
    if [ "$code" = "200" ] || [ "$code" = "302" ]; then
      log "HA answered $code after $((i * 5))s; settling ${GRACE}s"
      sleep "$GRACE"
      waited=1
      break
    fi
    sleep 5
  done
  [ "$waited" = "0" ] && log "HA never answered after $((MAX_WAIT * 5))s; restarting bridges anyway"
fi

# Restart only the containers that exist, so a setup without matterbridge (or without
# Home Assistant at all) still works with no edits.
existing=""
for c in $BRIDGE_CONTAINERS; do
  if docker inspect "$c" >/dev/null 2>&1; then
    existing="$existing $c"
  else
    log "skip '$c' (no such container)"
  fi
done

if [ -z "${existing// /}" ]; then
  log "no bridge containers found — nothing to do"
  exit 0
fi

log "restarting:$existing"
# shellcheck disable=SC2086
if docker restart $existing >/dev/null 2>&1; then
  log "done"
else
  log "restart FAILED for:$existing"
  exit 1
fi

# ---------------------------------------------------------------------------
# /etc/systemd/system/homekit-boot-heal.service
#   [Unit]
#   Description=Post-boot self-heal: restart HomeKit bridges after network/HA settle
#   After=docker.service
#   Requires=docker.service
#   [Service]
#   Type=oneshot
#   ExecStart=/path/to/scripts/boot-heal-homekit-bridges.sh
#
# /etc/systemd/system/homekit-boot-heal.timer
#   [Unit]
#   Description=Run the HomeKit bridge boot self-heal shortly after boot
#   [Timer]
#   OnBootSec=120
#   AccuracySec=10
#   Persistent=false
#   [Install]
#   WantedBy=timers.target
#
#   sudo systemctl daemon-reload && sudo systemctl enable --now homekit-boot-heal.timer
# ---------------------------------------------------------------------------
