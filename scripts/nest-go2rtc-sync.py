#!/usr/bin/env python3
"""
Regenerate ~/go2rtc-nest/go2rtc.yaml from live SDM device discovery, so every Nest camera
(including ones added/powered on later) gets a warm stream + snapshot automatically.

Credentials are read from Homebridge's own config.json -- single source of truth, no
duplicated secrets.

STREAM KEY = the camera's display name, lowercased, every run of other characters -> "_".
The display name is the SDM ROOM name (parentRelations displayName) when the camera is the
only one in its room, so a one-camera-per-room install keeps the keys it always had. With
2+ cameras in one room, each becomes "<room> <customName>", or "<room> <last 6 characters
of the device id>" when its customName is empty or shared, with the whole device id as a
last resort; see display_names() below. A Nest Hub Max display counts as a camera here.
This MUST match the patched plugin, which derives the same name in StreamKey.js
(patches/homebridge-plugin/new-files/) and keys every RTSP path and snapshot file on it.
test/stream-key.test.py and test/stream-key.test.js run both sides against one fixture.
Do NOT use go2rtc's /api/nest names -- those are customName alone (e.g. "Primary Bedroom
Upstairs") and would not match.

Restarts go2rtc only when the generated config actually changes.
"""
import json, os, sys, urllib.parse, urllib.request, subprocess, argparse, re

def token(cid, cs, rt):
    d = urllib.parse.urlencode({"client_id": cid, "client_secret": cs,
                                "refresh_token": rt, "grant_type": "refresh_token"}).encode()
    with urllib.request.urlopen("https://oauth2.googleapis.com/token", data=d, timeout=30) as r:
        return json.load(r)["access_token"]

def devices(at, project):
    req = urllib.request.Request(
        f"https://smartdevicemanagement.googleapis.com/v1/enterprises/{project}/devices",
        headers={"Authorization": "Bearer " + at})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r).get("devices", [])

# Every SDM type the plugin turns into a camera accessory (Display extends Camera there).
# Two of them in one room collide, so all three count when looking for collisions, even a
# DISPLAY that gets no stream below. Thermostats do not: they have no stream key.
CAMERA_TYPES = ("CAMERA", "DOORBELL", "DISPLAY")
SUFFIX_LEN = 6

def slug(s):
    return re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_")

def dev_type(dev):
    return dev.get("type", "").split(".")[-1]

def room_of(dev):
    parents = [p.get("displayName") for p in dev.get("parentRelations", []) if p.get("displayName")]
    return parents[0] if parents else None

def custom_name(dev):
    return ((dev.get("traits") or {}).get("sdm.devices.traits.Info") or {}).get("customName") or ""

def device_id(dev):
    return dev["name"].split("/devices/")[-1]

def display_names(devs):
    """{SDM device name: display name} for every camera-type device that has a room.

    Keep this identical to uniqueDisplayNames() in StreamKey.js. The rule:
      * the only camera in its room (compared by slug; a room name with no ASCII letter or
        digit slugs to "", so such rooms are compared by their raw name instead) -> the room
        name, unchanged;
      * 2+ in one room -> "<room> <customName>" when its customName's slug is non-empty and
        unique among them, else "<room> <last SUFFIX_LEN characters of the device id>";
      * if one of those 2+-per-room names still shares a slug with any other name, in any
        room, it -> "<room> <device id>" (room "Hall" + customName "Cam" against a room
        called "Hall Cam"). A camera alone in its room is never renamed by this step, so its
        key cannot change because of cameras in OTHER rooms.
    It depends only on the set of devices, never their order.
    """
    groups = {}
    for d in devs:
        if dev_type(d) in CAMERA_TYPES and d.get("name") and room_of(d):
            groups.setdefault(slug(room_of(d)) or "\0" + room_of(d), []).append(d)
    cand, by_name, alone = {}, {}, set()
    for peers in groups.values():
        for d in peers:
            by_name[d["name"]] = d
        if len(peers) == 1:
            cand[peers[0]["name"]] = room_of(peers[0])
            alone.add(peers[0]["name"])
            continue
        cn_count = {}
        for d in peers:
            cn_count[slug(custom_name(d))] = cn_count.get(slug(custom_name(d)), 0) + 1
        for d in peers:
            cn = custom_name(d)
            tail = cn if slug(cn) and cn_count[slug(cn)] == 1 else device_id(d)[-SUFFIX_LEN:]
            cand[d["name"]] = room_of(d) + " " + tail
    slug_count = {}
    for n in cand.values():
        slug_count[slug(n)] = slug_count.get(slug(n), 0) + 1
    return {k: (n if k in alone or slug_count[slug(n)] == 1
                else room_of(by_name[k]) + " " + device_id(by_name[k]))
            for k, n in cand.items()}

def has_live_stream(dev):
    return "sdm.devices.traits.CameraLiveStream" in (dev.get("traits") or {})

ap = argparse.ArgumentParser()
# Point these at your own Homebridge config and desired go2rtc.yaml output, e.g.:
#   --hb-config /path/to/homebridge/config.json --out /path/to/go2rtc/go2rtc.yaml
ap.add_argument("--hb-config", required=True,
                help="path to Homebridge config.json (source of Nest credentials)")
ap.add_argument("--out", required=True,
                help="path to write the generated go2rtc.yaml")
ap.add_argument("--container", default="go2rtc",
                help="go2rtc docker container name to restart on config change")
ap.add_argument("--log-level", default=None,
                help="go2rtc log level to write (trace/debug/info/warn/error). "
                     "Default: keep the level already in --out, or 'info' for a new file. "
                     "Without this the regenerated config would silently reset a level you set by hand.")
ap.add_argument("--no-restart", action="store_true",
                help="Write the config but do not restart the container, and do not fail "
                     "if it is absent. For first-run installs, where this script legitimately "
                     "runs BEFORE the container exists and the caller starts it immediately "
                     "afterwards. Without this the missing-container restart failure exits 1 "
                     "and aborts an install.sh running under `set -e`.")
ap.add_argument("--dry-run", action="store_true")
a = ap.parse_args()

cfg = json.load(open(a.hb_config))
nest = next((p for p in cfg["platforms"] if p.get("platform") == "homebridge-google-nest-sdm"), None)
if not nest:
    print("no nest platform in homebridge config; nothing to do"); sys.exit(0)

cid, cs, rt, proj = nest["clientId"], nest["clientSecret"], nest["refreshToken"], nest["projectId"]
at = token(cid, cs, rt)

streams, preload = [], []
seen_keys = set()
all_devs = devices(at, proj)
names = display_names(all_devs)
for d in all_devs:
    t = dev_type(d)
    if t not in CAMERA_TYPES:
        continue
    # A DISPLAY (Nest Hub Max) is a camera accessory in the plugin, which dials
    # rtsp://127.0.0.1:8554/<key> for live view, recording and (if enabled) the HKSV
    # prebuffer, and looks for a snapshot under the same key. Without a stream every one of
    # those fails and the tile never gets a warm snapshot. Only a display that advertises a
    # live stream, though: nothing else could be dialled. CAMERA and DOORBELL stay
    # unconditional, as they always were.
    if t == "DISPLAY" and not has_live_stream(d):
        print(f"  skipped: {names.get(d.get('name'), d.get('name'))} (DISPLAY without CameraLiveStream)")
        continue
    k = slug(names.get(d.get("name")))
    if not k:
        continue
    dev_id = d["name"].split("/devices/")[1]
    q = urllib.parse.urlencode({
        "client_id": cid, "client_secret": cs, "device_id": dev_id,
        "project_id": proj, "protocols": "WEB_RTC", "refresh_token": rt})
    if k in seen_keys:
        # display_names() leaves a duplicate only when two whole-device-id fallbacks collide as
        # well (ids that differ only in case, say). Refuse: writing it would let one camera
        # shadow another.
        print(f"  ERROR: duplicate stream key '{k}' even after adding customName/device id; give one camera a different room or name in Google Home. Refusing."); sys.exit(1)
    seen_keys.add(k)
    streams.append(f'  {k}:\n    - "nest:?{q}"\n    - "ffmpeg:{k}#video=mjpeg"')
    preload.append(f'  {k}: "video"')
    print(f"  discovered: {k}")

if not streams:
    print("  ERROR: no cameras discovered — refusing to write empty config"); sys.exit(1)

try:
    cur = open(a.out).read()
except FileNotFoundError:
    cur = ""

# Preserve a log level already in the file unless one was passed explicitly, so a
# rebuild to pick up a new camera doesn't quietly undo a level set by hand.
if a.log_level:
    level = a.log_level
else:
    m = re.search(r"^log:\s*\n\s+level:\s*(\w+)", cur, re.M)
    level = m.group(1) if m else "info"

out = ("api:\n  listen: \"127.0.0.1:1985\"\nrtsp:\n  listen: \":8554\"\n"
       "webrtc:\n  listen: \":8555\"\nlog:\n  level: " + level + "\n\nstreams:\n"
       + "\n".join(streams) + "\n\npreload:\n" + "\n".join(preload) + "\n")
if cur == out:
    print("config unchanged"); sys.exit(0)
if a.dry_run:
    print("--- would write ---")
    print(out)
    sys.exit(0)
# Create the output directory if it is missing. install.sh --image (no build) on a fresh
# machine reached this line before anything had made --go2rtc-dir, and died here with
# FileNotFoundError on go2rtc.yaml.tmp.
if os.path.dirname(a.out):
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
# Write 0600 from the start via a temp file: the output embeds an OAuth refresh
# token, and the previous open() created it 0644 until something chmod'd it later.
_tmp = a.out + ".tmp"
_fd = os.open(_tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(_fd, "w") as _f:
    _f.write(out)
os.replace(_tmp, a.out)
if a.no_restart:
    # The caller owns the container's lifecycle this run (first install: it is created
    # moments from now, and will read this file on startup). Restarting here is not
    # merely unnecessary, it is impossible -- and its failure would abort the caller.
    print(f"config changed -> wrote {a.out}; not restarting {a.container} (--no-restart)")
    sys.exit(0)

print(f"config changed -> wrote {a.out}; restarting {a.container}")
# Do NOT discard this. A user who needs `sudo docker` would otherwise see
# "restarting go2rtc" while go2rtc kept serving the OLD config -- new cameras
# never get warm streams, with no error anywhere.
try:
    _r = subprocess.run(["docker", "restart", a.container], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    _rc = _r.returncode
    _e = (_r.stderr or b"").decode("utf-8", "replace").strip()
except FileNotFoundError:
    # No docker on PATH at all. Without this the script dies on an uncaught
    # FileNotFoundError traceback, which buries the one line the user needs.
    _rc, _e = 127, "docker not found on PATH"
if _rc != 0:
    print(f"WARNING: could not restart {a.container} (exit {_rc}): {_e}")
    print("         go2rtc is STILL RUNNING THE OLD CONFIG -- restart it yourself.")
    sys.exit(1)
