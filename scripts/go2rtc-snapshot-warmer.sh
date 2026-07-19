#!/bin/bash
# Writes a fresh JPEG per warm go2rtc stream to /run/nest-snaps/ (tmpfs).
# Baseline: every INTERVAL seconds, with a cache just under INTERVAL so each cycle
#   actually re-transcodes (tile content stays ~INTERVAL fresh, not stuck for 30s).
# Event-triggered: touch /run/nest-snaps/.refresh -> an immediate cycle with a tiny
#   cache, so motion/doorbell shows a FRESH frame (who's there), not a stale porch.
DIR=/run/nest-snaps
API=http://127.0.0.1:1985
INTERVAL=10
BASELINE_CACHE=8s   # < INTERVAL so the baseline cycle gets a fresh frame each time
EVENT_CACHE=1s      # motion/doorbell: force a near-fresh transcode
mkdir -p "$DIR"
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
    if curl -sf -m 15 -o "$DIR/.$s.tmp" "$API/api/frame.jpeg?src=$s&cache=$cache"; then
      if [ -s "$DIR/.$s.tmp" ] && [ "$(stat -c %s "$DIR/.$s.tmp")" -gt 1000 ]; then
        mv -f "$DIR/.$s.tmp" "$DIR/$s.jpg"
      fi
    fi
    rm -f "$DIR/.$s.tmp" 2>/dev/null || true
  done
  find "$DIR" -name '*.jpg' -mmin +2 -delete 2>/dev/null || true
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
