#!/bin/bash
set -uo pipefail
DEST=/mnt/backup/pi-eh-config-backups
SRC=/home/adamandaj
KEEP=14
STAMP=$(date +%Y%m%d-%H%M%S)
mountpoint -q /mnt/backup || mount /mnt/backup || { echo "backup drive not mounted; abort"; exit 1; }
mkdir -p "$DEST"
# capture docker run params (for the non-compose containers) + image list
{ echo "### docker ps -a"; docker ps -a; echo; echo "### images"; docker images;
  echo; for c in $(docker ps -a --format '{{.Names}}'); do echo "=== inspect $c ==="; docker inspect "$c"; done; } \
  > "$DEST/docker-state-$STAMP.txt" 2>/dev/null
# tar the configs, excluding regenerable bulk
tar czf "$DEST/pi-eh-configs-$STAMP.tar.gz" --warning=no-file-changed \
  --exclude='*/node_modules' \
  --exclude='*/matter-venv' \
  --exclude='*/channels-dvr/20*' \
  --exclude='*/channels-dvr/data/imagecache' \
  --exclude='*/channels-dvr/data/streaming' \
  --exclude='*.sock' \
  -C "$SRC" \
  homeassistant volumes/homebridge matterbridge vlc-bridge welj-radio ha-proxy OLD-thumbdrive-homebridge go2rtc2 scripts airconnect assistant-relay assistant-relay-config bbc-proxy netflix-proxy lyrionmusicserver matter-data whisper-data piper-data openwakeword-data go2rtc-build/go2rtc-1.9.14/pkg go2rtc-build/go2rtc-1.9.14/internal/mjpeg go2rtc-build/go2rtc-1.9.14/internal/mp4 go2rtc-build/go2rtc-1.9.14/internal/streams 2>/dev/null
# The patched Nest plugin lives under node_modules, excluded above as regenerable bulk --
# but dist/ is NOT regenerable: it carries this deployment's patches, and any container
# start that sees a version mismatch npm-reinstalls over them (happened 2026-08-01, wiped
# all four patches + PrebufferManager.js). package.json goes too: its version field is what
# decides whether that reinstall fires, so restoring dist without it is not a restore.
PLUGIN=/home/adamandaj/volumes/homebridge/node_modules/homebridge-google-nest-sdm
if [ -d "$PLUGIN/dist" ]; then
  tar czf "$DEST/homebridge-plugin-dist-$STAMP.tar.gz" -C "$PLUGIN" dist package.json config.schema.json 2>/dev/null \
    && echo "OK: plugin dist -> $DEST/homebridge-plugin-dist-$STAMP.tar.gz"
  ls -1t "$DEST"/homebridge-plugin-dist-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
fi

# The go2rtc image is a LOCALLY BUILT artifact -- it exists on no registry, so if the SD card
# dies it is gone unless it is here. It was captured by hand, which meant it silently fell
# behind: v4 was the newest copy on 2026-08-06 while v13 had been live since 2026-08-05, and
# on 2026-08-07 the backup still held v13 while v14 was running. Automated so the rule
# "re-capture whenever go2rtc is redeployed" stops depending on anyone remembering it.
#
# Keyed on the image TAG, not the stamp: re-running the backup daily must not write a fresh
# 83MB copy of an image that has not changed. A new tag is a new build, and only that copies.
G_IMAGE="$(docker inspect --format '{{.Config.Image}}' go2rtc 2>/dev/null)"
if [ -n "$G_IMAGE" ]; then
  G_TAG="$(echo "$G_IMAGE" | sed 's|.*:||')"
  G_OUT="$DEST/go2rtc-nestfix-${G_TAG}-$(date +%Y%m%d).image.tar.gz"
  if ls "$DEST"/go2rtc-nestfix-"${G_TAG}"-*.image.tar.gz >/dev/null 2>&1; then
    echo "OK: go2rtc image $G_TAG already captured (skipping)"
  else
    # gzip -1: this is a Pi 4 running live cameras. The size win from -6 is not worth the CPU.
    if docker save "$G_IMAGE" | gzip -1 > "$G_OUT" && gzip -t "$G_OUT"; then
      echo "OK: go2rtc image -> $G_OUT ($(du -h "$G_OUT" | cut -f1))"
    else
      echo "FAIL: could not save go2rtc image $G_IMAGE"; rm -f "$G_OUT"
    fi
  fi
  # Deliberately NOT rotated on KEEP. These are keyed by tag, so there is one per BUILD, not
  # one per run -- rotating by count would delete the rollback target for an older generation.
else
  echo "WARN: go2rtc container not found; image not backed up"
fi

# ROOT-LEVEL FILES AND /etc ARE NOT IN THE TAR ABOVE.
# The tar takes a list of DIRECTORIES under $SRC, so anything sitting at the root of
# /home/adamandaj -- compose.yaml above all -- was silently excluded. Discovered on
# 2026-08-09 while rebuilding after the SD card physically ejected: compose.yaml carried
# TZ, HOMEBRIDGE_CONFIG_UI_PORT and the /run/nest-snaps bind mount, and without that mount
# every HomeKit camera tile goes blank with nothing logged as an error.
# Same for the /etc files the deployment depends on but does not own.
# `systemctl enable` state lives as symlinks under /etc/systemd/system/*.wants/, which the
# file list below does NOT capture. On 2026-08-10 the rebuild restored every unit FILE but
# matterbridge-hass-guard came back disabled -- it is the guard that stops matterbridge
# starting before HA and halting the whole Matter bridge, so losing it is silent until the
# next reboot takes the devices offline. Record the enabled set as plain text.
systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
  > "$DEST/systemd-enabled-$STAMP.txt"
ls -1t "$DEST"/systemd-enabled-*.txt 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f

EXTRA="$DEST/host-files-$STAMP.tar.gz"
tar czf "$EXTRA" \
  -C "$SRC" $(cd "$SRC" && ls -1 *.yaml *.yml *.env 2>/dev/null | tr '\n' ' ') \
  -C / etc/tmpfiles.d/nest-snaps.conf \
      etc/logrotate.d/nest-wedge \
      etc/fstab \
      etc/systemd/system/go2rtc-snapshot-warmer.service \
      etc/systemd/system/go2rtc-wedge-detector.service \
      etc/systemd/system/matterbridge-hass-guard.service \
  2>/dev/null && echo "OK: host files -> $EXTRA"
ls -1t "$DEST"/host-files-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f

# rotate
ls -1t "$DEST"/pi-eh-configs-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -1t "$DEST"/docker-state-*.txt   2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
sync
echo "OK: $(ls -lh "$DEST/pi-eh-configs-$STAMP.tar.gz" | awk '{print $5}') -> $DEST/pi-eh-configs-$STAMP.tar.gz"
