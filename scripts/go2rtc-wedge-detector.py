#!/usr/bin/env python3
"""Detect and recover a go2rtc stream that receives media but forwards none of it.

WHY THIS EXISTS
---------------
On 2026-07-30 a Nest doorbell stream spent an entire morning in a state where go2rtc kept
pulling from Google at ~150 KB/s while delivering nothing to its consumers. go2rtc logged
NOTHING. Downstream, the HKSV prebuffer's ring reader starved and was stall-killed every 60s,
the fallback direct dial starved too, and every recording was lost with
`closeRecordingStream reason=6`. Restarting go2rtc cleared it instantly.

Root cause is upstream, in go2rtc's producer-reconnect path (present in stock 1.9.14): when a
receiver fails to match a media/codec on re-dial it is skipped SILENTLY
(`internal/streams/producer.go` :210-213 and :215-218 — two bare `continue`s), and the
following `conn.Stop()` closes the old receivers, which severs every consumer attached to
them (`pkg/core/connection.go:70-75` -> `pkg/core/node.go:61-72`). `RemoveChild` never nils
the child's parent pointer (`node.go:50-59`), so a severed sender reports a destroyed
receiver id as its `parent` forever. That is directly observable and was observed here.

This runs OUTSIDE go2rtc deliberately: no patched binary, and the worst it can do is restart
a container.

CHOOSING THE SIGNAL -- three counters look plausible and two are traps
---------------------------------------------------------------------
* Consumer `bytes_send` on an RTSP consumer counts FAILED writes only -- the increment sits
  in the error branch (`pkg/rtsp/consumer.go:87-93`). It is not a delivery counter at all.
* The `preload` consumer's `bytes_send` is not liveness either. Observed here: preload frozen
  with its sender parented to receiver id 22 while the producer's live receivers were
  285/286/287 -- the preload had been severed by an earlier reconnect while RTSP delivery was
  perfectly healthy. An earlier version of this script keyed on preload and, pointed at a
  HEALTHY production box, "confirmed" a wedge on every stream within a minute. Armed, it
  would have restarted go2rtc every cooldown forever.
* What this uses instead: `bytes` on VIDEO receivers that have consumers attached (`childs`).
  That counter increments in the same call chain that increments the producer's `bytes_recv`
  (`pkg/webrtc/conn.go:231` then :288 -> `pkg/core/track.go:29-35`), so on any healthy stream
  the two move together. It reflects the fan-out tree being fed with someone attached to it.

Known blind spot (accepted): starvation BELOW the receiver -- a single consumer whose sender
buffer overflows or which was severed while another consumer keeps the same receiver fed --
is invisible here, because receiver bytes are counted before the per-sender channel
(`track.go:99-110`). Downstream self-heals that case: the plugin's own stall watchdog kills
and re-attaches such a reader within 60s.

FALSE-POSITIVE GUARDS (each exists because it would otherwise misfire)
---------------------------------------------------------------------
* Audio receivers are excluded. `bytes_recv` counts RTP on ALL tracks including audio
  (`conn.go:224-231`), so a video-idle/audio-active camera is the obvious false positive.
  The default gate of 500 KB per 30s interval (~16.7 KB/s) is well above Nest's ~4-8 KB/s
  Opus, and this fork additionally closes video-silent sessions within 8-30s. NOTE: that
  margin is specific to Nest+this fork. Re-tune before pointing this at a non-Nest source
  with high-bitrate audio.
* Receivers with no `childs` are excluded: nothing is attached, so nobody is starving.
  Reconnects routinely leave such stale receivers behind and they are frozen by design.
* Each receiver is tracked INDIVIDUALLY, never summed. Summing lets a healthy receiver mask
  a starving sibling.
* A counter that DECREASES, or a receiver id that disappears, means replacement -- baselines
  are dropped rather than read as "frozen".
* A wedge must persist for N consecutive samples, so a single sample straddling a re-dial
  cannot trigger a restart.
* Restarts are rate-limited by a cooldown and a per-day cap, so a stream that a restart
  cannot fix can never become a restart loop.

Dry run is the DEFAULT. Arming is an explicit flag.
"""
import argparse
import http.client
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

# go2rtc omits zero-valued counters (`json:"bytes,omitempty"`, pkg/core/track.go:179-196).
# A childs-bearing video receiver with NO `bytes` key is therefore a receiver that has never
# been fed -- which is exactly what a post-reconnect wedge looks like at birth, since
# `receiver.Replace(track)` moves consumers onto a brand-new receiver starting at zero
# (producer.go:220-222). Treating "absent" as "not present" would make that wedge invisible
# forever, so absent must mean 0.
MISSING_IS_ZERO = 0


def log(msg, stream=None):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print("%s go2rtc-wedge-detector: %s%s" % (ts, ("[%s] " % stream) if stream else "", msg),
          flush=True)


def make_opener():
    # urllib honours http_proxy/https_proxy from the environment; a proxy has no business
    # intercepting a localhost admin API.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch(opener, api_url, timeout):
    with opener.open(api_url, timeout=timeout) as r:
        return json.load(r)


def extract(streams):
    """-> {stream_name: {"recv": int|None, "video": {receiver_id: bytes}, "orphaned": int}}

    `video` holds ONE ENTRY PER childs-bearing video receiver, keyed by receiver id, so a
    starving receiver cannot be masked by a healthy sibling. Receiver ids are unique for the
    life of the process (`pkg/core/connection.go:10-20`), so an id vanishing means the
    receiver was replaced.

    `orphaned` counts consumers whose senders all point at a receiver id the producer no
    longer has. Diagnostic only -- never a trigger, because a severed preload degrades
    snapshot warming but does not stop recording. It undercounts on purpose: a consumer with
    only one of its senders severed is not counted.
    """
    out = {}
    for name, s in (streams or {}).items():
        if not isinstance(s, dict):
            continue
        recv, have_recv = 0, False
        video = {}
        live_receiver_ids = set()
        for p in (s.get("producers") or []):
            # A stopped producer marshals as {"url": ...} with no id and no counters
            # (internal/streams/producer.go:134-140). It contributes nothing either way.
            if p.get("id") is None:
                continue
            have_recv = True
            v = p.get("bytes_recv")
            recv += v if isinstance(v, int) else MISSING_IS_ZERO
            for r in (p.get("receivers") or []):
                rid = r.get("id")
                if rid is not None:
                    live_receiver_ids.add(rid)
                if (r.get("codec") or {}).get("codec_type") != "video":
                    continue
                if not (r.get("childs") or []):
                    continue
                b = r.get("bytes")
                video[rid] = b if isinstance(b, int) else MISSING_IS_ZERO
        orphaned = 0
        for c in (s.get("consumers") or []):
            senders = c.get("senders") or []
            if senders and all(sn.get("parent") not in live_receiver_ids for sn in senders):
                orphaned += 1
        out[name] = {"recv": recv if have_recv else None, "video": video, "orphaned": orphaned}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", default="http://127.0.0.1:1985/api/streams",
                    help="go2rtc streams API (default: %(default)s -- this deployment listens "
                         "on 1985, not go2rtc's default 1984)")
    ap.add_argument("--interval", type=float, default=30.0, help="seconds between samples")
    ap.add_argument("--min-recv-delta", type=int, default=500_000,
                    help="producer must advance at least this many bytes BETWEEN SAMPLES for a "
                         "frozen receiver to count as evidence. This is per-interval, so "
                         "changing --interval rescales sensitivity (default: %(default)s "
                         "= ~16.7 KB/s at the default 30s interval)")
    ap.add_argument("--strikes", type=int, default=3, help="consecutive wedged samples before acting")
    ap.add_argument("--cooldown", type=float, default=1800.0, help="minimum seconds between actions")
    ap.add_argument("--max-per-day", type=int, default=6,
                    help="hard cap on recovery actions per rolling 24h; 0 disables the cap")
    ap.add_argument("--restart-cmd", default="docker restart go2rtc", help="recovery command")
    ap.add_argument("--arm", action="store_true",
                    help="actually run the recovery command. WITHOUT THIS IT ONLY REPORTS.")
    ap.add_argument("--http-timeout", type=float, default=10.0)
    args = ap.parse_args()

    if args.strikes < 1:
        ap.error("--strikes must be >= 1")
    if args.interval <= 0:
        ap.error("--interval must be > 0")
    if args.min_recv_delta < 1:
        ap.error("--min-recv-delta must be >= 1")

    log("started: api=%s interval=%ss strikes=%d min_recv_delta=%d cooldown=%ss armed=%s"
        % (args.api, args.interval, args.strikes, args.min_recv_delta, args.cooldown, args.arm))
    if not args.arm:
        log("DRY RUN -- a wedge will be reported but no recovery command will run")

    opener = make_opener()
    prev = {}
    streak = {}                 # (stream, receiver_id) -> consecutive frozen samples
    actions = []                # monotonic timestamps of recovery actions
    samples = 0

    while True:
        acted = False
        try:
            cur = extract(fetch(opener, args.api, args.http_timeout))
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
            # go2rtc restarting or briefly unreachable is normal. Drop baselines so the next
            # comparison is against fresh numbers rather than pre-restart ones.
            log("API unreachable (%s); resetting baselines" % e)
            prev, streak = {}, {}
            time.sleep(args.interval)
            continue

        samples += 1
        for name in sorted(cur):
            c = cur[name]
            p = prev.get(name)
            if c["recv"] is None or not c["video"]:
                # No active producer, or no video receiver with consumers attached: camera
                # off, or nothing is consuming. Nothing can be starving.
                for k in [k for k in streak if k[0] == name]:
                    del streak[k]
                continue
            if p is None or p["recv"] is None:
                continue

            d_recv = c["recv"] - p["recv"]
            if d_recv < 0:
                log("producer replaced (counter reset); re-arming", name)
                for k in [k for k in streak if k[0] == name]:
                    del streak[k]
                continue

            for rid, nbytes in sorted(c["video"].items()):
                key = (name, rid)
                if rid not in p["video"]:
                    streak.pop(key, None)       # brand new receiver: no baseline yet
                    continue
                d_bytes = nbytes - p["video"][rid]
                if d_bytes < 0:
                    log("receiver %s counter reset; re-arming" % rid, name)
                    streak.pop(key, None)
                    continue
                if d_recv >= args.min_recv_delta and d_bytes == 0:
                    streak[key] = streak.get(key, 0) + 1
                    log("WEDGED? producer +%d bytes but video receiver %s delivered 0 to its "
                        "attached consumers -- strike %d/%d"
                        % (d_recv, rid, streak[key], args.strikes), name)
                else:
                    if streak.get(key) and d_bytes > 0:
                        log("receiver %s delivery resumed (+%d bytes)" % (rid, d_bytes), name)
                    streak.pop(key, None)

            # drop baselines for receivers that no longer exist
            for k in [k for k in streak if k[0] == name and k[1] not in c["video"]]:
                del streak[k]

            if c["orphaned"] and samples % 20 == 0:
                log("note: %d consumer(s) severed from the current producer (parent receiver "
                    "no longer exists) -- upstream go2rtc reconnect orphan bug; harmless for "
                    "recording, degrades snapshot warming" % c["orphaned"], name)

            hot = [k for k in streak if k[0] == name and streak[k] >= args.strikes]
            if not hot:
                continue

            now = time.monotonic()
            actions[:] = [t for t in actions if now - t < 86400]
            if actions and now - actions[-1] < args.cooldown:
                log("wedge confirmed but within cooldown (%ds left); not acting"
                    % int(args.cooldown - (now - actions[-1])), name)
            elif args.max_per_day and len(actions) >= args.max_per_day:
                log("wedge confirmed but %d recovery actions already taken in the last 24h; "
                    "REFUSING to act -- restarts are not fixing this, investigate"
                    % len(actions), name)
            elif not args.arm:
                log("WEDGE CONFIRMED -- would run: %s   (dry run, not armed)" % args.restart_cmd, name)
                for k in hot:
                    streak.pop(k, None)
            else:
                log("WEDGE CONFIRMED -- running: %s" % args.restart_cmd, name)
                try:
                    r = subprocess.run(args.restart_cmd, shell=True, capture_output=True,
                                       text=True, timeout=120)
                    if r.returncode == 0:
                        log("recovery command succeeded", name)
                    else:
                        log("recovery command FAILED rc=%d: %s"
                            % (r.returncode, (r.stderr or "").strip()), name)
                except (subprocess.SubprocessError, OSError) as e:
                    log("recovery command errored: %s" % e, name)
                actions.append(now)
                acted = True
                break

        # Everything is about to change; start from a clean slate rather than diffing the
        # next sample against pre-restart numbers. Must come AFTER the loop, or `prev = cur`
        # below silently undoes it.
        if acted:
            prev, streak = {}, {}
        else:
            prev = cur
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
