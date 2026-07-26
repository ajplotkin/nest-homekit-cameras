#!/bin/bash
# go2rtc snapshot warmer — v2 (2026-07-26)
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
DIR=/run/nest-snaps
API=http://127.0.0.1:1985
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
mkdir -p "$DIR"

log() { logger -t go2rtc-warmer "$*" 2>/dev/null || true; }

refresh_all() {
  local cache="${1:-$BASELINE_CACHE}"
  WARM=$(curl -s -m 10 "$API/api/streams" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for name, s in d.items():
    for p in (s.get("producers") or []):
        if any((r.get("bytes") or 0) > 0 for r in (p.get("receivers") or [])):
            print(name); break
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
