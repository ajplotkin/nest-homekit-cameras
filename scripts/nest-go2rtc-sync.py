#!/usr/bin/env python3
"""
Regenerate ~/go2rtc2/go2rtc.yaml from live SDM device discovery, so every Nest camera
(including ones added/powered on later) gets a warm stream + snapshot automatically.

Credentials are read from Homebridge's own config.json -- single source of truth, no
duplicated secrets.

STREAM KEY = the SDM ROOM name (parentRelations displayName), lowercased, spaces->_.
This MUST match how homebridge-google-nest-sdm's patched Camera.js derives its key
(this.displayName = parentRelations displayName). Do NOT use go2rtc's /api/nest names --
those use customName (e.g. "Primary Bedroom Upstairs") and would not match.

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

def key_for(dev):
    parents = [p.get("displayName") for p in dev.get("parentRelations", []) if p.get("displayName")]
    if not parents:
        return None
    return re.sub(r"[^a-z0-9]+", "_", parents[0].lower()).strip("_")

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
for d in devices(at, proj):
    if d.get("type","").split(".")[-1] not in ("CAMERA", "DOORBELL"):
        continue
    k = key_for(d)
    if not k:
        continue
    dev_id = d["name"].split("/devices/")[1]
    q = urllib.parse.urlencode({
        "client_id": cid, "client_secret": cs, "device_id": dev_id,
        "project_id": proj, "protocols": "WEB_RTC", "refresh_token": rt})
    if k in seen_keys:
        print(f"  ERROR: duplicate room key '{k}' — two Nest devices share a room name in the SDM API; rename one room. Refusing."); sys.exit(1)
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
# Write 0600 from the start via a temp file: the output embeds an OAuth refresh
# token, and the previous open() created it 0644 until something chmod'd it later.
_tmp = a.out + ".tmp"
_fd = os.open(_tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(_fd, "w") as _f:
    _f.write(out)
os.replace(_tmp, a.out)
print(f"config changed -> wrote {a.out}; restarting {a.container}")
# Do NOT discard this. A user who needs `sudo docker` would otherwise see
# "restarting go2rtc" while go2rtc kept serving the OLD config -- new cameras
# never get warm streams, with no error anywhere.
_r = subprocess.run(["docker", "restart", a.container], check=False,
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
if _r.returncode != 0:
    _e = (_r.stderr or b"").decode("utf-8", "replace").strip()
    print(f"WARNING: could not restart {a.container} (exit {_r.returncode}): {_e}")
    print("         go2rtc is STILL RUNNING THE OLD CONFIG -- restart it yourself.")
    sys.exit(1)
