#!/bin/bash
# Writes a fresh JPEG per warm go2rtc stream to /run/nest-snaps/ (tmpfs).
# Baseline: every 10s (HomeKit polls ~10s, go2rtc cache 30s -> always a hit).
# Event-triggered: touch /run/nest-snaps/.refresh to force an immediate cycle
# (the plugin's patched event handler can signal this on motion/doorbell).
DIR=/run/nest-snaps
API=http://127.0.0.1:1985
INTERVAL=10
mkdir -p "$DIR"
refresh_all() {
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
    if curl -sf -m 15 -o "$DIR/.$s.tmp" "$API/api/frame.jpeg?src=$s&cache=30s"; then
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
      refresh_all
      break
    fi
    sleep 1
  done
done
