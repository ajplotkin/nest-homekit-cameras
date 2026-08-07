#!/bin/bash
# go2rtc snapshot warmer — v3 (2026-07-26; liveness delta added)
# Writes a fresh JPEG per warm go2rtc stream to /run/nest-snaps/ (tmpfs).
# Baseline: every INTERVAL seconds, with a cache just under INTERVAL so each cycle
#   actually re-transcodes (tile content stays ~INTERVAL fresh, not stuck for 30s).
# Event-triggered: touch /run/nest-snaps/.refresh -> an immediate cycle with a tiny
#   cache, so motion/doorbell shows a FRESH frame (who's there), not a stale porch.
#
# v2 CHANGES (why): the tile was intermittently falling back to the HomeKit logo.
# Root cause found 2026-07-26: /api/frame.jpeg intermittently returns HTTP 500 for a
# camera needing a real transcode (upstairs ~1.9s; front_door is a 0.03s cache hit and
# never showed it). `curl -sf` turned that 500 into a SILENT no-write with no retry, so
# the snapshot aged past the plugin's 90s staleness gate -> "snapshot too stale, using
# logo". Observed staleness 93s/110s/120s/314s/344s. Three fixes:
#   1. RETRY each fetch (ATTEMPTS) instead of skipping the whole INTERVAL on one 500.
#   2. LOG failures (they were completely invisible, which is why this hid for weeks).
#   3. Reject near-uniform GRAY frames: ffmpeg emits a solid-gray JPEG when it decodes
#      H264 without a keyframe. One was caught on disk at 5618 bytes, YAVG=128 exactly,
#      and the old `-gt 1000` gate happily published it as a "valid" snapshot.
DIR="${SNAPS_DIR:-/run/nest-snaps}"   # install.sh --snaps-dir passes SNAPS_DIR via the unit
API="${GO2RTC_API:-http://127.0.0.1:1985}"
INTERVAL=10
BASELINE_CACHE=8s   # < INTERVAL so the baseline cycle gets a fresh frame each time
EVENT_CACHE=1s      # motion/doorbell: force a near-fresh transcode
ATTEMPTS=3          # retries per camera per cycle (v2) — a single 500 no longer costs a full cycle
FETCH_TIMEOUT=8     # per attempt; a good transcode measures ~1.9s, so this is ample headroom
MIN_BYTES=15000     # v2 gray-frame guard: real 720p frames measure 60-97KB; the gray frame was 5.6KB.
                    # A rejected frame keeps the LAST GOOD snapshot (better than publishing gray).
# Streams are PRELOADed in go2rtc (always-on), so go2rtc — not this script — keeps them
# warm; no bootstrap-polling needed here. But Nest intermittently DROPS a preloaded stream
# (5-min session cap, post-motion video droughts, transient errors), and while go2rtc
# re-establishes it the producer has bytes=0 so the baseline cycle below skips it. If we
# delete the snapshot during that gap the HomeKit tile falls back to the blank logo ("G").
# So keep the last good frame through the gap and only reap a snapshot that has gone
# genuinely stale (camera actually offline), not one that's briefly mid-reconnect.
STALE_MAX_MIN=30    # reap a snapshot only after this many minutes with no refresh (was 2)
BYTES_STATE="$DIR/.bytes"   # v3: previous cycle's per-stream receiver totals, for the liveness delta
mkdir -p "$DIR"

# Always emit to stderr as well as syslog: under docker-compose the warmer runs in a bare
# alpine with no syslog socket, so a logger-only implementation silently discarded every
# failure -- the exact blindness this logging was added to remove.
log() { logger -t go2rtc-warmer "$*" 2>/dev/null || true; echo "go2rtc-warmer: $*" >&2; }

refresh_all() {
  local cache="${1:-$BASELINE_CACHE}"
  # A stream counts as live only if its received-byte total went UP since the last cycle.
  # Receiver.Bytes is CUMULATIVE and is never reset, so "> 0" is true forever once a camera
  # has been warm even once. When a camera is switched off, go2rtc correctly closes the
  # connection and re-dials every ~60s (getting 400 while it stays off), but the dead
  # producer keeps its frozen counters -- so a "> 0" test still calls it warm, we fetch it,
  # /api/frame.jpeg attaches to the frozen receivers and blocks, and every cycle burns
  # ATTEMPTS x FETCH_TIMEOUT seconds for nothing. Measured: ~270 wasted fetches/hour on one
  # switched-off camera. A delta distinguishes "flowing" from "was flowing once".
  WARM=$(curl -s -m 10 "$API/api/streams" | BYTES_STATE="$BYTES_STATE" python3 -c '
import sys, json, os

state_path = os.environ.get("BYTES_STATE", "")
prev = {}
try:
    with open(state_path) as fh:
        for line in fh:
            k, _, v = line.strip().partition(" ")
            if k:
                prev[k] = int(v)
except Exception:
    pass

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

cur = {}
for name, s in d.items():
    total = 0
    for p in (s.get("producers") or []):
        for r in (p.get("receivers") or []):
            total += (r.get("bytes") or 0)
    cur[name] = total

for name, total in cur.items():
    if total <= 0:
        continue                      # never warmed (camera off since boot)
    if name not in prev:
        print(name)                   # first sighting: probe once to establish a baseline
    elif total > prev[name]:
        print(name)                   # bytes advanced: genuinely flowing

try:
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        for name, total in cur.items():
            fh.write("%s %d\n" % (name, total))
    os.replace(tmp, state_path)
except Exception:
    pass
' 2>/dev/null || echo "")
  for s in $WARM; do
    [[ "$s" =~ ^[a-z0-9_]+$ ]] || continue
    local ok=0 attempt=1 code="" size=0
    while [ "$attempt" -le "$ATTEMPTS" ]; do
      code=$(curl -s -m "$FETCH_TIMEOUT" -o "$DIR/.$s.tmp" -w "%{http_code}" \
             "$API/api/frame.jpeg?src=$s&cache=$cache" 2>/dev/null || echo "000")
      size=$(stat -c %s "$DIR/.$s.tmp" 2>/dev/null || echo 0)
      if [ "$code" = "200" ] && [ "$size" -ge "$MIN_BYTES" ]; then
        mv -f "$DIR/.$s.tmp" "$DIR/$s.jpg"
        ok=1
        [ "$attempt" -gt 1 ] && log "$s: recovered on attempt $attempt (${size}B)"
        break
      fi
      # distinguish the two failure modes so the log is actually diagnostic
      if [ "$code" = "200" ]; then
        log "$s: REJECTED gray/undersized frame (${size}B < ${MIN_BYTES}B) attempt $attempt/$ATTEMPTS"
      else
        log "$s: fetch failed http=$code attempt $attempt/$ATTEMPTS"
      fi
      attempt=$((attempt + 1))
      [ "$attempt" -le "$ATTEMPTS" ] && sleep 1
    done
    [ "$ok" = "0" ] && log "$s: ALL $ATTEMPTS attempts failed — keeping previous snapshot"
    rm -f "$DIR/.$s.tmp" 2>/dev/null || true
  done
  find "$DIR" -name '*.jpg' -mmin +"$STALE_MAX_MIN" -delete 2>/dev/null || true
}
while true; do
  refresh_all
  # Check for event-triggered refresh signal every second within the interval
  for i in $(seq 1 $INTERVAL); do
    if [ -f "$DIR/.refresh" ]; then
      rm -f "$DIR/.refresh"
      refresh_all "$EVENT_CACHE"
      break
    fi
    sleep 1
  done
done
