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
import json, sys, urllib.parse, urllib.request, subprocess, argparse, re

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

out = ("api:\n  listen: \"127.0.0.1:1985\"\nrtsp:\n  listen: \":8554\"\n"
       "webrtc:\n  listen: \":8555\"\nlog:\n  level: info\n\nstreams:\n"
       + "\n".join(streams) + "\n\npreload:\n" + "\n".join(preload) + "\n")

try:
    cur = open(a.out).read()
except FileNotFoundError:
    cur = ""
if cur == out:
    print("config unchanged"); sys.exit(0)
if a.dry_run:
    print("--- would write ---"); sys.exit(0)
open(a.out, "w").write(out)
print(f"config changed -> wrote {a.out}; restarting {a.container}")
subprocess.run(["docker", "restart", a.container], check=False,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
