# Google Nest Cameras in Apple HomeKit — With Real Tile Images

You have Google Nest cameras. You want them in Apple HomeKit. And you want to actually *see* what the camera sees on the tile — a real, refreshing image — not a blank tile or a placeholder logo.

This is harder than it should be. Google does not offer Nest cameras through HomeKit natively, and when they migrated Nest devices to the Google Home app, they removed the API that provided still images. No integration — commercial or open-source — can request a snapshot from these cameras anymore. The only way to get a real picture is to grab a frame from a live video stream.

This guide walks through the full setup from scratch: getting API access to your Nest cameras, bridging them into HomeKit, and then solving the snapshot problem by keeping a warm stream and serving frames from it. By the end you'll have:

- **Real camera images on your HomeKit tiles** — refreshed every 10 seconds, and instantly on motion or doorbell events (so the tile shows *who's there*, not a stale frame)
- **~2 second live stream startup** — down from ~8 seconds stock
- **Motion and doorbell event notifications** in Apple Home
- **HomeKit Secure Video recording** — motion-triggered clips saved to iCloud also work through this setup (confirmed on a Pi 4; the software H.264 encode keeps up, so no hardware encoder is needed). Requires iCloud+ and a Home Hub, like any HKSV camera.
- **Automatic camera discovery** — new cameras appear without editing config files

**Everything here is open source and runs on a Raspberry Pi.**

### What's in this repo

- **This README** — the complete, from-scratch guide (start here and read top to bottom).
- **[`install.sh`](install.sh)** — one idempotent installer that does everything after you have Google credentials (build image, tmpfs, config, go2rtc, warmer service, plugin patches, verify). See [Quick start](#quick-start-automated--if-parts-1--2-are-already-done).
- **[`docker-compose.yml`](docker-compose.yml)** — the go2rtc + warmer half of the stack as Compose services.
- **[`scripts/`](scripts/)** — the three helper scripts: `nest-go2rtc-sync.py` (auto-discovers cameras → writes `go2rtc.yaml`), `go2rtc-snapshot-warmer.sh` (keeps the JPEG cache warm), and `apply-snapshot-patch.sh` (applies/re-applies the Homebridge plugin patches). They take all paths/credentials as arguments or env vars — nothing is hardcoded.
- **[`patches/`](patches/)** — `go2rtc-nest.patch` (the go2rtc source changes as one diff against a clean **v1.9.14** checkout) and `homebridge-plugin/*.patch` (the three plugin changes as diffs against stock plugin 1.1.23).

The patched go2rtc **source and build** live in a separate fork so the git history and upstream attribution are preserved: **[github.com/ajplotkin/go2rtc](https://github.com/ajplotkin/go2rtc/tree/fix/nest-ipv6-ice-failure)** (branch `fix/nest-ipv6-ice-failure`). Part 3 shows how to build it. This work also folds in several community go2rtc pull requests, credited at the end.

## What You'll Set Up

There are four layers. Each builds on the last:

1. **Google Device Access** — Google's [official API](https://developers.google.com/nest/device-access) for accessing Nest devices programmatically. One-time $5 registration. This gives you the credentials everything else needs.

2. **[Homebridge](https://homebridge.io/)** + **[homebridge-google-nest-sdm](https://github.com/potmat/homebridge-google-nest-sdm)** — [Homebridge](https://github.com/homebridge/homebridge) (by the [@homebridge](https://github.com/homebridge) team) is an open-source HomeKit bridge that runs on a Pi or any server. The Nest plugin (by [@potmat](https://github.com/potmat)) connects to Google's SDM API and presents your cameras as HomeKit accessories. After this step, your cameras appear in Apple Home and live streams work — but tiles show a placeholder logo because there's no snapshot API.

3. **[go2rtc](https://github.com/AlexxIT/go2rtc)** (patched) — go2rtc (by [@AlexxIT](https://github.com/AlexxIT)) is a streaming tool that can connect to Nest cameras via WebRTC, keep the connection alive, re-serve the stream over RTSP, and produce JPEG snapshots on demand. This is the engine that makes real tile images possible. (A one-line patch is needed on many home networks — explained below.)

4. **Snapshot warmer + plugin patches** — A small script that pulls a JPEG from each warm stream every 10 seconds (and immediately on motion/doorbell events), plus a patch to the Homebridge plugin that serves those images instead of the placeholder. This is the glue that connects go2rtc's capabilities to your HomeKit tiles.

## Already have Homebridge + homebridge-google-nest-sdm working?

If your Nest cameras are already in Apple HomeKit via Homebridge and you just want to fix the snapshot/tile-image problem, skip to [Part 3: go2rtc](#part-3-go2rtc--warm-streams-and-snapshots). You already have the credentials and the plugin — you just need the warm-stream layer and the patches.

If you also want faster live stream startup (~2s instead of ~8s), check the `vEncoder: "copy"` and PR #212 notes in [Part 2](#part-2-homebridge-and-the-nest-plugin) first.

## Quick start (automated) — if Parts 1 & 2 are already done

The one thing that **cannot** be scripted is Google Device Access (Part 1) — creating the Cloud project, the OAuth consent screen, the $5 registration, and getting a refresh token is manual clicking through Google's consoles. Once you have those credentials in a working **Homebridge + homebridge-google-nest-sdm 1.1.23** install, the rest is one script.

**Option A — `install.sh`** (does everything post-credentials: builds the patched go2rtc image, sets up the tmpfs, generates the config, starts go2rtc, installs the warmer service, and applies the plugin patches — all idempotent):

```bash
git clone https://github.com/ajplotkin/nest-homekit-snapshots.git
cd nest-homekit-snapshots

# see exactly what it will do first (changes nothing):
./install.sh --dry-run --hb-config /path/to/homebridge/config.json \
             --homebridge-dir /path/to/homebridge

# then run it for real:
./install.sh --hb-config /path/to/homebridge/config.json \
             --homebridge-dir /path/to/homebridge \
             --homebridge-container my-homebridge
```

Every path and container name is a flag with a sensible default (`./install.sh --help`). The **one** step it deliberately leaves to you — because how you run Homebridge is yours to own — is adding `-v /run/nest-snaps:/homebridge/nest-snaps` to your Homebridge container and restarting it. The script detects whether that mount exists and tells you the exact line if it's missing.

**Option B — Docker Compose** ([`docker-compose.yml`](docker-compose.yml)) brings up the go2rtc + warmer half of the stack. You still build the image and generate `go2rtc.yaml` first (the file's header comments walk through it), add the one volume line to your Homebridge service, and run `./scripts/apply-snapshot-patch.sh`. Compose can't patch the plugin's `node_modules` for you, so that stays a script call.

Either way, the detailed reference for **what** each piece does and **why** is the walkthrough below.

---

## Part 1: Google Device Access

Google provides the [Smart Device Management (SDM) API](https://developers.google.com/nest/device-access) for programmatic access to Nest devices. You need to register for it before any integration can talk to your cameras.

Follow Google's own [Get Started guide](https://developers.google.com/nest/device-access/get-started). The key steps are:

1. Create a Google Cloud Platform (GCP) project and enable the SDM API
2. Create OAuth 2.0 credentials (a client ID and client secret)
3. Register for Device Access at [console.nest.google.com/device-access](https://console.nest.google.com/device-access) — this costs a one-time $5 fee
4. Authorize your Google account and obtain a refresh token

Google's docs cover this well. Here are the gotchas they don't emphasize:

**The Device Access project ID is NOT the GCP project ID.** You'll end up with two IDs that look similar. The Device Access project ID is a UUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`. The GCP project ID is a name like `my-project-123456`. Mixing them up produces a `404: Requested project not found` that's hard to diagnose because the plugin only logs "Plugin initialization failed" without the underlying error. (See [issue #215](https://github.com/potmat/homebridge-google-nest-sdm/issues/215) for details.)

**You must use a personal Google account (@gmail.com).** Google Workspace accounts (@yourdomain.com) cannot register for Device Access. The console will show "Your account doesn't meet the requirements" and offer to switch accounts. Once a project is linked to an account, it cannot be moved.

**Projects created after January 2025 must self-host their Pub/Sub topic.** Google stopped offering hosted topics for new projects ([release notes, 2025-01-23](https://developers.google.com/nest/device-access/release-notes)). You'll need to create a topic in your GCP project, grant `group:sdm-publisher@googlegroups.com` the `roles/pubsub.publisher` role, create a pull subscription, and register the topic in the Device Access Console. This is only needed for motion/doorbell events — camera streaming works without it.

**Include the `pubsub` scope in your refresh token** if you want motion and doorbell notifications. The authorization URL should include both `https://www.googleapis.com/auth/sdm.service` and `https://www.googleapis.com/auth/pubsub`.

## Part 2: Homebridge and the Nest Plugin

[Homebridge](https://homebridge.io/) bridges non-HomeKit devices into Apple Home. Install it following the [official guide](https://github.com/homebridge/homebridge/wiki) — Docker is the easiest path on a Pi.

Then install the Nest plugin by [@potmat](https://github.com/potmat):

```bash
# From the Homebridge UI (Settings > Plugins > Search), or:
npm install homebridge-google-nest-sdm
```

Configure it with your Device Access credentials in `config.json`:

```json
{
    "platform": "homebridge-google-nest-sdm",
    "clientId": "YOUR_GCP_CLIENT_ID",
    "clientSecret": "YOUR_GCP_CLIENT_SECRET",
    "projectId": "YOUR_DEVICE_ACCESS_PROJECT_UUID",
    "refreshToken": "YOUR_REFRESH_TOKEN",
    "subscriptionId": "projects/YOUR_GCP_PROJECT/subscriptions/YOUR_SUB_NAME",
    "gcpProjectId": "YOUR_GCP_PROJECT_ID",
    "vEncoder": "copy"
}
```

Two things to note:

**Set `vEncoder` to `"copy"`.** Your Nest cameras send H264 video. HomeKit wants H264 video. The default setting re-encodes it with x264, which wastes CPU and adds seconds of latency. `"copy"` passes the video through untouched. The plugin's README already mentions this option but understates how much it helps.

**For faster live stream startup**, install [PR #212](https://github.com/potmat/homebridge-google-nest-sdm/pull/212) by [@littlepope81](https://github.com/littlepope81). This unmerged PR adds three optimizations — FIR keyframe requests instead of PLI, frame-rate probe skipping (`-fpsprobesize 0`), and REMB bandwidth signaling — that reduce the time to first video frame from ~8 seconds to ~2 seconds. Measured on a Pi 4: first keyframe fully received at **+2127ms**. (The remaining ~4s to see the tile is Apple's own HomeKit setup, not addressable from Homebridge.)

```bash
# Install PR #212 from the author's branch:
npm install https://github.com/littlepope81/homebridge-google-nest-sdm/tarball/feature/configurable-analyzeduration
```

After restarting Homebridge, your cameras should appear in Apple Home. Live streams will work. But the tiles show a Google logo or a blank image — that's the problem this guide exists to solve.

### Pub/Sub event handler bug

If you've set up Pub/Sub events, be aware of a bug in the plugin: the event handler crashes on `relationUpdate` events (which Google sends when device/room relationships change, including right after you enable events). The fix is a 3-line guard in `dist/sdm/Api.js` — add this before `if (event.resourceUpdate.events) {`:

```javascript
if (!event || !event.resourceUpdate) {
    this.log.debug('Event without resourceUpdate (e.g. relationUpdate), ignoring');
    return;
}
```

See [issue #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214) for the full stack trace.

## Part 3: go2rtc — Warm Streams and Snapshots

[go2rtc](https://github.com/AlexxIT/go2rtc) by [@AlexxIT](https://github.com/AlexxIT) is a streaming tool that supports dozens of camera protocols, including Google Nest via the SDM API. It can:

- Connect to your Nest cameras over WebRTC
- Automatically extend the stream before Google's 5-minute expiry
- Keep streams permanently warm via its `preload:` feature
- Serve JPEG snapshots from a warm stream via `/api/frame.jpeg`
- Re-serve the stream over RTSP for other consumers

This is the piece that makes real snapshots possible: keep one stream warm per camera, and grab a frame whenever HomeKit asks.

### The IPv6 bug

**Stock go2rtc (v1.9.14 as of this writing) cannot stream Nest cameras on many home networks.** Its `nest:` source uses [pion/webrtc](https://github.com/pion/webrtc) for WebRTC negotiation, and pion gathers ICE candidates on all network types including IPv6. On hosts where IPv6 addresses exist but have no working route — which is extremely common — the ICE agent fails silently and no media flows. You'll see `nest: wrong status: 400 Bad Request` in the logs or streams that start but never produce video.

The `webrtc: filters:` YAML config exists for restricting network types, but `pkg/nest/client.go` bypasses it by calling `webrtc.NewAPI()` with nil filters. There is no config-only workaround. See [go2rtc #2311](https://github.com/AlexxIT/go2rtc/issues/2311) for discussion and diagnostic data.

**Try stock go2rtc first.** If it works, you don't need the patch. If you see the symptoms above, use this fork which fixes it with one line — forcing IPv4-only ICE:

```go
// was: rtcAPI, err := webrtc.NewAPI()
rtcAPI, err := webrtc.NewServerAPI("", "", &webrtc.Filters{Networks: []string{"udp4"}})
```

Note the tradeoff: `udp4` restricts ICE to IPv4/UDP, so it also drops TCP ICE candidates. On a normal home LAN — where the Pi reaches Google's relays over UDP/IPv4 — that is exactly what you want, and it's what fixes the silent failure. The only setups this could hurt are ones whose *only* working path to the relay is IPv6 or TCP (rare); the proper general fix is to plumb the real `webrtc: filters:` config through to `pkg/nest`, which this fork notes in a code comment but hardcodes `udp4` as a working reference.

The fork also removes an inner retry loop in `rtcConn` that burned ~130 SDM API calls/hour per offline camera (over Google's documented 100/hour quota).

### Build from this fork

```bash
git clone https://github.com/ajplotkin/go2rtc.git
cd go2rtc
git checkout fix/nest-ipv6-ice-failure
```

> **Prefer to patch stock go2rtc yourself?** Instead of cloning the fork, check out upstream go2rtc at the `v1.9.14` tag and apply [`patches/go2rtc-nest.patch`](patches/go2rtc-nest.patch) from this repo (`git clone https://github.com/AlexxIT/go2rtc && cd go2rtc && git checkout v1.9.14 && git apply /path/to/go2rtc-nest.patch`), then run the same build command below. The diff is the exact set of source changes described in this guide, plus the credited community PRs.

```bash
# Build natively on a Pi (arm64, ~3 min):
docker run --rm -v "$PWD":/src -w /src \
  -e GOCACHE=/tmp/gocache -e GOMODCACHE=/tmp/gomod \
  golang:1.24-alpine sh -c \
  "CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o go2rtc_patched ."
```

Create a Docker image using [@AlexxIT](https://github.com/AlexxIT)'s base (which provides the ffmpeg needed for JPEG transcoding):

```bash
mkdir -p ~/go2rtc-nest
cp go2rtc_patched ~/go2rtc-nest/

cat > ~/go2rtc-nest/Dockerfile <<'EOF'
FROM alexxit/go2rtc:1.9.14
COPY go2rtc_patched /usr/local/bin/go2rtc
EOF

docker build -t go2rtc-nestfix:1.9.14 ~/go2rtc-nest/
```

### Discover cameras and generate the config

The script below reads your Nest credentials from Homebridge's own `config.json` (single source of truth — no duplicated secrets), discovers cameras via the SDM API, and writes a go2rtc config with a warm stream per camera.

**Important:** The `nest:` source URL must be properly URL-encoded. The refresh token contains `//` which must be encoded as `%2F%2F`, and `protocols=WEB_RTC` must be present. Hand-written URLs will fail with a 400. This script handles encoding automatically. If you skip it, use go2rtc's own `GET /api/nest` endpoint to generate correctly-encoded URLs.

The script is [`scripts/nest-go2rtc-sync.py`](scripts/nest-go2rtc-sync.py) in this repo — **copy it from there** rather than transcribing from this page. What it does:

- Reads your Nest credentials straight from Homebridge's `config.json` (no second copy of secrets).
- Lists your cameras/doorbells via the SDM API.
- Derives a **stream key** from each device's SDM **room name** — lowercased, non-alphanumeric → `_` — which is the single join key the warmer and the patched plugin also use. It refuses (loudly, non-zero) if two devices share a room, since the key would collide (see the one-camera-per-room note below).
- Writes a URL-encoded `go2rtc.yaml` (with a `preload:` per camera) and restarts the go2rtc container.

Grab it and make it executable:

```bash
mkdir -p ~/scripts
curl -fsSL https://raw.githubusercontent.com/ajplotkin/nest-homekit-snapshots/main/scripts/nest-go2rtc-sync.py -o ~/scripts/nest-go2rtc-sync.py
chmod +x ~/scripts/nest-go2rtc-sync.py
```

<details>
<summary>Key-derivation detail (why the room name is the join key)</summary>

Every layer must agree on the stream key or the plugin reads the wrong file. All three derive it identically from the SDM room `displayName`:

```python
# in the sync script, the plugin, and the warmer alike:
key = re.sub(r"[^a-z0-9]+", "_", room_display_name.lower()).strip("_")
```

The generated `go2rtc.yaml` binds `api` to `127.0.0.1` (localhost only), but the RTSP (`:8554`) and WebRTC (`:8555`) listeners are on **all interfaces** and unauthenticated — fine on a trusted home LAN, but don't expose those ports to the internet.

</details>

Run it (paths are required arguments — nothing is hardcoded):

```bash
python3 ~/scripts/nest-go2rtc-sync.py \
  --hb-config /path/to/homebridge/config.json \
  --out ~/go2rtc-nest/go2rtc.yaml
```

You only need to re-run this when your set of cameras or rooms changes (add/remove a camera, rename a room) — not on a schedule. The generated config is static; the credentials it embeds come from Homebridge's `config.json`, and the OAuth *refresh* token is long-lived (go2rtc mints short-lived access tokens itself at runtime), so a once-written config keeps working. If you do automate it (e.g. a weekly systemd timer to pick up new cameras), be aware of the next point.

> **A go2rtc restart drops every warm stream.** The sync script rewrites `go2rtc.yaml` and restarts the container to load it, and any restart tears down all active WebRTC sessions — tiles briefly fall back to the placeholder and live views drop until the streams re-warm (~30s) and re-extend. So restart go2rtc deliberately (config change, upgrade), not on a frequent timer. This is also why the config is kept static rather than regenerated every cycle.

### Start go2rtc

```bash
docker run -d --name go2rtc \
  --restart unless-stopped \
  --network host \
  -v ~/go2rtc-nest/go2rtc.yaml:/config/go2rtc.yaml \
  go2rtc-nestfix:1.9.14
```

Wait ~30 seconds for the streams to warm up, then verify:

```bash
# Check warm streams
curl -s http://127.0.0.1:1985/api/streams | python3 -c "
import sys, json
for name, s in json.load(sys.stdin).items():
    warm = any(any((r.get('bytes') or 0) > 0
        for r in (p.get('receivers') or []))
        for p in (s.get('producers') or []))
    print(f'  {name}: {\"WARM\" if warm else \"cold\"}')"

# Grab a test snapshot
curl -o /tmp/test.jpg "http://127.0.0.1:1985/api/frame.jpeg?src=front_door&cache=30s"
file /tmp/test.jpg   # should say "JPEG image data"
```

If streams show "cold", check the go2rtc logs (`docker logs go2rtc`). Common causes: camera switched off in the Google Home app (`FAILED_PRECONDITION`), IPv6 issue (see above), or URL encoding problems.

## Part 4: The Snapshot Warmer

You now have go2rtc serving JPEG snapshots via HTTP. The obvious approach is to have the Homebridge plugin call that endpoint directly whenever HomeKit asks for a snapshot. **Don't do this.** It fails under real-world conditions:

- HomeKit polls tiles roughly every 10 seconds. go2rtc's JPEG cache lasts 30 seconds. Every third poll is a **cache miss**, which spins up ffmpeg and takes ~1.5 seconds — triggering Homebridge's "snapshot handler is slow to respond" warning.
- Worse: **two concurrent cache misses return HTTP 500**, and the plugin's error path falls back to the placeholder logo. The logo flashes back intermittently.

The solution is a warmer script that pre-fetches a JPEG every 10 seconds and writes it to a file. The plugin reads the file (~1ms, never races, never 500s). On motion or doorbell events, the plugin signals the warmer to grab a fresh frame immediately — so the tile shows *who's there*, not a 10-second-old empty porch.

### SD card wear

**If your system runs on an SD card** (most Raspberry Pis), put the snapshots in tmpfs (RAM). Writing ~100KB JPEGs every 10 seconds per camera is ~1.5 GB/day of flash writes for data that's pure cache — the warmer rebuilds it in seconds after a reboot. tmpfs costs about 200KB of RAM.

```bash
echo 'd /run/nest-snaps 0755 1000 1000 -' | sudo tee /etc/tmpfiles.d/nest-snaps.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nest-snaps.conf
```

### The warmer script

The warmer auto-discovers streams from go2rtc (no hardcoded camera list) and only polls streams that have active media — cameras that are off are skipped, avoiding wasted SDM quota. Stale files are pruned after 2 minutes so an off camera shows the honest placeholder rather than a frozen frame.

It also watches for an **event trigger**: when the plugin receives a motion or doorbell event, it touches a signal file, and the warmer grabs a fresh frame within 1 second instead of waiting for the next cycle.

The script is [`scripts/go2rtc-snapshot-warmer.sh`](scripts/go2rtc-snapshot-warmer.sh) — **copy it from there**. What it does each cycle:

- Asks go2rtc which streams are actually flowing bytes, and only polls those (off cameras are skipped — no wasted SDM quota).
- Pulls a JPEG per warm stream and writes it atomically to `/run/nest-snaps/<key>.jpg`, keeping the last good file if a fetch returns something too small to be a real frame.
- Prunes files older than 2 minutes, so a camera that went offline shows the honest placeholder instead of a frozen frame.

Freshness: the **baseline** cycle uses a cache window *shorter* than the poll interval, so each cycle re-transcodes and the tile stays ~10s fresh. On a motion/doorbell event the plugin touches `/run/nest-snaps/.refresh` and the warmer immediately grabs a frame with a **1-second** cache — so the tile shows who's actually there, not a stale porch. (An earlier version used a 30s cache on both paths, which made "instant on motion" a lie; the shipped script fixes that.)

Grab it:

```bash
curl -fsSL https://raw.githubusercontent.com/ajplotkin/nest-homekit-snapshots/main/scripts/go2rtc-snapshot-warmer.sh -o ~/scripts/go2rtc-snapshot-warmer.sh
```

Install as a systemd service:

```ini
# /etc/systemd/system/go2rtc-snapshot-warmer.service
[Unit]
Description=Keep go2rtc snapshot cache warm for Homebridge
After=docker.service
[Service]
ExecStart=/home/YOUR_USER/scripts/go2rtc-snapshot-warmer.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
```

```bash
chmod +x ~/scripts/go2rtc-snapshot-warmer.sh
sudo systemctl daemon-reload
sudo systemctl enable --now go2rtc-snapshot-warmer.service
```

### Patch the Homebridge plugin

Mount the snapshot directory into the Homebridge container. **Without this mount, the plugin can't see the files and tiles will show the placeholder:**

```bash
docker run -d --name homebridge \
  ... \
  -v /path/to/homebridge:/homebridge \
  -v /run/nest-snaps:/homebridge/nest-snaps \
  homebridge/homebridge:latest
```

The plugin needs a few small changes. They're shipped as unified diffs in **[`patches/homebridge-plugin/`](patches/homebridge-plugin/)** and applied for you by **[`scripts/apply-snapshot-patch.sh`](scripts/apply-snapshot-patch.sh)** — you don't hand-edit anything.

What the patches do:

- **`Camera.js`** — `getSnapshot()` returns the warm JPEG from `/homebridge/nest-snaps/<key>.jpg` instead of the Google logo, falling back to the logo if the file is missing or older than 90 seconds (so an off camera shows the honest placeholder). And on a motion/person event it creates `/homebridge/nest-snaps/.refresh` (via the plugin's `fs`, no subshell) to trigger an immediate warm-frame grab. The `<key>` is the slugified SDM room name — **identical** to the sync script's derivation, which is how the plugin finds the file the warmer wrote. It also **drops replayed/stale events** (older than 30s) at the top of `event()`, so a backlog of events redelivered by Pub/Sub after a reconnect or restart can't fire phantom motion and phantom HKSV recordings — the freshness gate from [@littlepope81](https://github.com/littlepope81)'s [PR #219](https://github.com/potmat/homebridge-google-nest-sdm/pull/219). This pairs with the `Api.js` auto-reconnect below: reconnecting is what *causes* the backlog redelivery, so the gate is its safety rail.
- **`Doorbell.js`** — the same replay/stale-event gate as `Camera.js` (it inherits `isEventStale`), so a redelivered backlog can't fire a phantom doorbell ring.
- **`Api.js`** — two robustness fixes to the Pub/Sub event subscription: (a) guards the handler against `relationUpdate` events with no `resourceUpdate` (an upstream crash; [issue #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214)); and (b) **auto-reconnects the subscription**. Upstream sets it up once and, on error, just stops — so a silently dropped streaming-pull connection permanently kills all camera events (no motion alerts, no HKSV recording) until you restart Homebridge. This re-subscribes on `error`/`close` with backoff, plus a 12-hour proactive recycle to catch half-open stalls. (Submitted upstream — see the PRs section.)
- **`StreamingDelegate.js`** — *(optional, Part 6)* routes HomeKit live view **and HKSV recording** through go2rtc's warm RTSP stream, so neither opens a second Google session (fixes recording-time stream contention and corrupt clips). Also carries recording-lifecycle hardening from an adversarial review: `closeRecordingStream` now checks session identity (a late close of an orphaned session can't kill the current recording), the async SDM teardown is `.catch()`-guarded (a rejection there would otherwise restart the bridge), and the start-of-session inactivity watchdog gives the cold Google-dial fallback a longer grace than the warm-RTSP path.
- **`HksvStreamer.js`** — hardening so an HKSV recording can't hang forever if the RTSP input dies before ffmpeg connects: `destroy()` and `handleDisconnect()` now settle the connection promise (so the fragment generator fails fast instead of awaiting a connection that never comes) and close the listening server (so the socket isn't leaked). Found by the same review.

Clone this repo (you'll want it for the scripts too) and run the patcher:

```bash
git clone https://github.com/ajplotkin/nest-homekit-snapshots.git
cd nest-homekit-snapshots
HOMEBRIDGE_DIR=/path/to/homebridge ./scripts/apply-snapshot-patch.sh
```

The script pins the plugin version it was cut against (**1.1.23**) and **refuses to run on a different one** — the compiled `dist/` layout moves between releases, so a stale patch could silently break things. It's idempotent (safe to re-run) and **exits non-zero** if any patch is missing or won't apply, so a re-apply can never leave you half-patched. Want to see exactly what changes? Read the diffs in `patches/homebridge-plugin/`.

> **These patches live in `node_modules` and are wiped by any `npm install` of the plugin.** Re-run `apply-snapshot-patch.sh` after any plugin install/upgrade. Install order: (1) `npm install homebridge-google-nest-sdm`, (2) install [PR #212](https://github.com/potmat/homebridge-google-nest-sdm/pull/212) on top, (3) *then* run the patch script.

## Part 5: Verify

```bash
docker restart homebridge
```

After about 30 seconds:

1. **Check warm streams:** `curl -s http://127.0.0.1:1985/api/streams` — each camera should show receiver bytes increasing
2. **Check snapshot files:** `ls -la /run/nest-snaps/` — a `.jpg` per camera, refreshing every ~10 seconds (and immediately on motion events)
3. **Open Apple Home** — tiles should show real camera images instead of the placeholder

### Troubleshooting

**Tiles show the placeholder for some cameras:** Check if those cameras are switched off in the Google Home app. Google returns `FAILED_PRECONDITION: "The camera is not available for streaming"` for off cameras. The system handles this gracefully (warmer skips them, stale files are pruned, plugin shows the placeholder), but the camera needs to actually be on.

**Google Home's "Home/Away Assist"** may automatically turn cameras off when you're home. This is the most common reason for cameras that work sometimes and not others. Check: Google Home app > Settings > Home & Away Routines.

**`nest: wrong status: 400 Bad Request`** in go2rtc logs: Most likely the IPv6 issue described above. Use the patched fork. Can also be a URL encoding problem — always generate URLs via the sync script or go2rtc's `GET /api/nest` endpoint.

**Node v24.17.0 breaks the plugin entirely** with `ERR_STREAM_PREMATURE_CLOSE` on every OAuth call. This is a Node.js regression ([nodejs/node#63989](https://github.com/nodejs/node/issues/63989)), not a plugin bug. Fixed in Node 24.18.0. If you're on the official Homebridge Docker image, pull the latest.

**Motion notifications not arriving on your phone?** HomeKit defaults motion notifications to **off** for new camera accessories. In the Apple Home app: tap the camera → scroll down → **Status and Notifications** → turn on **Motion Notifications** (and **Activity Notifications** if available). You also need an Apple Home Hub (Apple TV, HomePod, or iPad) for notifications to push when you're away.

## Part 6 (optional): route live view through go2rtc too

By default `homebridge-google-nest-sdm` opens its **own** WebRTC connection to Google every time you tap a camera tile — separate from the warm stream go2rtc is already holding. That means 2–3 concurrent Google streams per camera (go2rtc's preload + each HomeKit view + the Google Home app). Nest enforces a concurrent-stream limit, and hitting it is what causes tiles that hang for many seconds or "never load."

You can make HomeKit live view reuse go2rtc's already-open stream instead, over local RTSP. **Be honest with yourself about what this does:** it does **not** make a single warm camera open faster (RTSP handshake + waiting for a keyframe to start clean stream-copy is ~2–4s, similar to or slightly slower than a direct WebRTC dial). What it buys is **consistency** — one shared Google stream instead of several, so the multi-viewer contention that causes the long hangs goes away. If your only pain was the occasional minute-long hang, this fixes it. If a single camera already opens fine for you, you can skip this.

Two go2rtc patches in this fork make the RTSP path viable for Nest:

- **Keyframe requests** (`pkg/webrtc/conn.go`): go2rtc sends an RTCP keyframe request (PLI) every 2s to the Nest source, so keyframes stay ~2s fresh. Without this, an idle Nest camera stretches its keyframe interval and RTSP consumers wait a long time to start. (This is media-plane RTCP — no SDM API quota cost.)
- **`sprop-parameter-sets` in the RTSP SDP** (`pkg/webrtc/conn.go`): go2rtc captures the H264 SPS/PPS from the stream and advertises them in the RTSP `DESCRIBE`, so ffmpeg knows the video dimensions immediately and a small `-probesize` is safe.

Both are already in the `go2rtc-nestfix` image you built in Part 3.

Then patch the plugin's `dist/StreamingDelegate.js` `startStream()` — before it calls the SDM streamer, prefer the local RTSP stream when the camera is warm (a fresh snapshot exists), else fall back to the normal Google dial:

```javascript
// near the top of startStream(), replacing:  const nestStreamer = await getStreamer(...)
let ffmpegArgs;
let nestStreamer;
let nestStream;
const go2rtcKey = (this.camera.displayName || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
let useGo2rtc = false;
if (go2rtcKey) {
    try {
        const st = require('fs').statSync('/homebridge/nest-snaps/' + go2rtcKey + '.jpg');
        if (Date.now() - st.mtimeMs < 90000) useGo2rtc = true;   // fresh snapshot == stream is warm
    } catch (e) {}
}
if (useGo2rtc) {
    ffmpegArgs = '-rtsp_transport tcp -analyzeduration 3000000 -probesize 5000000 -i rtsp://127.0.0.1:8554/' + go2rtcKey;
} else {
    nestStreamer = await (0, NestStreamer_1.getStreamer)(this.log, this.camera, this.config);
    nestStream = await nestStreamer.initialize();
    ffmpegArgs = nestStream.args;
}
```

Then guard the two places that assumed a streamer object always exists:
- the FfmpegProcess construction: pass `nestStream ? nestStream.stdin : undefined` (the RTSP path has no stdin pipe; FfmpegProcess already guards `if (stdin)`)
- `stopStream()`'s teardown: `if (session.streamer) await session.streamer.teardown()`

**One required safety addition.** The go2rtc RTSP input never ends (preload keeps it warm forever), unlike a Google WebRTC stream which self-expires after 5 min. So if HomeKit abandons a session without sending any RTCP, the ffmpeg transcode would run forever. Arm an inactivity watchdog right after the socket binds in `startStream()`:

```javascript
activeSession.timeout = setTimeout(() => {
    this.controller.forceStopStreamingSession(request.sessionID);
    this.stopStream(request.sessionID);
}, 15000);   // 15s grace for a slow open; the socket 'message' handler replaces it with rtcp_interval*2 on the first RTCP
```

This `StreamingDelegate.js` change ships as [`patches/homebridge-plugin/StreamingDelegate.js.patch`](patches/homebridge-plugin/StreamingDelegate.js.patch) and is applied by the same `apply-snapshot-patch.sh` — like the others, it's wiped by any `npm install` and must be re-applied.

> **Requires Homebridge on the host network.** The live-view patch dials `rtsp://127.0.0.1:8554` from *inside* the Homebridge container, so `127.0.0.1` has to be the same host go2rtc listens on. Run the Homebridge container with `--network host` (as go2rtc does). If Homebridge is on Docker's default bridge network instead, `127.0.0.1` points at the container itself and the live-view dial fails — use the host's LAN IP, or move Homebridge to `--network host`. The **snapshot** path doesn't care (it's a file bind-mount), so this only affects Part 6.

### HKSV recording rides the warm stream too — and this matters more than live view

The same `StreamingDelegate.js` patch routes **HomeKit Secure Video recording** through the warm RTSP stream as well, using the identical freshness check. This is the bigger win.

By default, when motion fires, the plugin's recording handler (`handleRecordingStreamRequest`) opens **yet another** fresh Google WebRTC session — a *second* concurrent stream for that camera (a *third* if you're also viewing live). That tips Nest over its per-device concurrent-stream limit, and every recording triggers an ugly cascade: the second dial contends with go2rtc's warm stream → go2rtc's stream gets throttled/dropped → it reconnects (a burst of `retry=` in the go2rtc log) → and the recording itself decodes garbage (`concealing 3721 DC/AC/MV errors in I frame`, corrupt frames) because it started against a contended, half-broken stream. The system "self-heals" a minute later, but the clip is ruined.

Routing recording through the warm RTSP stream instead (same check → `rtsp://127.0.0.1:8554/<key>`, else fall back to a Google dial) eliminates all of it: no second session, no contention, no reconnect burst, and the transcode runs against a clean, already-established stream. Measured before/after on a Pi 4: decode errors dropped from **thousands per recording to ~zero**, and recording-induced reconnect spikes went to **none**. `HksvStreamer.js` already accepts an RTSP input (no stdin pipe needed), so the only change is at the streamer-creation point in `handleRecordingStreamRequest`. It ships in the same `StreamingDelegate.js.patch`.

The patch also carries two teardown guards the RTSP path needs (found in adversarial review): `closeRecordingStream` must **guard `nestStreamer.teardown()`** (on the RTSP path there's no streamer object — the unguarded call throws on every recording close, harmless only because hap-nodejs catches it), and `handleRecordingStreamRequest` must **destroy any prior session before overwriting `recordingSessionInfo`**. That second one matters *more* on the go2rtc path than on stock: a Google WebRTC input self-expires after 5 minutes, but the warm RTSP input never EOFs, so a clobbered session's transcode would otherwise run **forever** (the exact shape of plugin issue #150). Both are in the patch.

## Reference

### SDM API Quotas

Source: [developers.google.com/nest/device-access/project/limits](https://developers.google.com/nest/device-access/project/limits)

| Limit | Value |
|---|---|
| `devices.executeCommand` per project/user | 10 QPM |
| Per trait command per device | 5 QPM |
| CAMERA/DOORBELL device instance | 30 QPM or 100 QPH |

Preload costs ~12 `ExtendWebRtcStream` calls/hour/camera — well within the 100 QPH device limit. The warmer makes zero SDM calls (it reads from go2rtc's local cache).

Note that the two limits that matter are scoped differently. The **100 QPH is per camera** (per device instance), so it does *not* get tighter as you add cameras — a warm stream is ~12 extends/hour whether you run 1 camera or 20, and each stays far under its own 100/hour. The one that *is* shared is **`devices.executeCommand` at 10 QPM per project/user**: each stream setup or extend is one command, so bursts matter. In steady state 20 cameras extend ~4 times/minute combined (well under 10 QPM), but if a go2rtc restart re-establishes many streams at once you can momentarily approach the per-minute cap and see a few `429`/`RESOURCE_EXHAUSTED` retries as they stagger out — harmless, and the reason the fork removed the tight inner retry loop (see Part 3) that used to amplify this.

A camera that's **switched off** costs a little more than an active one: the fork retries its cold preload every ~2 minutes (one `GenerateWebRtcStream` each) until it comes back — roughly 30 calls/hour per off camera, still well under the per-camera 100 QPH. If you keep many cameras off for long stretches and want to trim that, lengthen the retry interval in `retryPreload` (`internal/streams/preload.go`).

### Performance (measured on Raspberry Pi 4, arm64)

| Metric | Value |
|---|---|
| Cached snapshot served | ~26 ms |
| CPU (idle, with 3 warm streams) | ~0% (brief spikes during 10s transcode cycle) |
| Bandwidth per camera | ~1.5 Mbps continuous |
| RAM for snapshot files | ~200 KB |
| Stream startup (with PR #212 + `vEncoder: "copy"`) | First keyframe at +2127ms |

### Related Issues and PRs

- [go2rtc #2311](https://github.com/AlexxIT/go2rtc/issues/2311) — `nest: wrong status: 400` / IPv6 ICE failure diagnosis
- [homebridge-google-nest-sdm #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214) — Api.js crash on `relationUpdate` events
- [homebridge-google-nest-sdm #215](https://github.com/potmat/homebridge-google-nest-sdm/issues/215) — README corrections (project ID confusion, self-hosted Pub/Sub, Node regression)
- [homebridge-google-nest-sdm PR #212](https://github.com/potmat/homebridge-google-nest-sdm/pull/212) — stream startup latency fix by [@littlepope81](https://github.com/littlepope81)
- [homebridge-google-nest-sdm PR #216](https://github.com/potmat/homebridge-google-nest-sdm/pull/216) — the Pub/Sub auto-reconnect fix from this repo, submitted upstream (events silently stopping after a connection drop)
- [homebridge-google-nest-sdm PR #217](https://github.com/potmat/homebridge-google-nest-sdm/pull/217) — the HKSV recording session-leak fix from this repo, submitted upstream (orphaned ffmpeg / memory growth; relates to #150)
- [homebridge-google-nest-sdm PR #218](https://github.com/potmat/homebridge-google-nest-sdm/pull/218) by [@littlepope81](https://github.com/littlepope81) — a dedicated upstream hardening of the Pub/Sub handler against `relationUpdate`/malformed events (the crash this repo's `Api.js.patch` guards independently; [issue #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214))
- [homebridge-google-nest-sdm PR #219](https://github.com/potmat/homebridge-google-nest-sdm/pull/219) by [@littlepope81](https://github.com/littlepope81) — drops replayed/stale events so a reconnect/restart backlog can't fire phantom motion/recordings (adopted here in `Camera.js.patch` and `Doorbell.js.patch`)

**Upstream go2rtc work this fork builds on (credit to the authors):**

- [go2rtc PR #2368](https://github.com/AlexxIT/go2rtc/pull/2368) — the Nest keyframe-request + `sprop-parameter-sets`-in-SDP patches from this fork, submitted upstream
- [go2rtc PR #2351](https://github.com/AlexxIT/go2rtc/pull/2351) by [@tillo](https://github.com/tillo) — loops the Nest stream-extension timer and stops sharing session state between cameras (adopted here; the fork adds transient-error retry on top)
- [go2rtc PR #2194](https://github.com/AlexxIT/go2rtc/pull/2194) by [@MechanicalCoderX](https://github.com/MechanicalCoderX) — Nest expiry/token/timeout/leak fixes (the ~83-minute HTTP timeout fix is adopted here)
- [go2rtc PR #2327](https://github.com/AlexxIT/go2rtc/pull/2327) by [@zephleggett](https://github.com/zephleggett) — reap the keyframe consumer on client disconnect (defense-in-depth for the snapshot warmer)
- [go2rtc PR #2193](https://github.com/AlexxIT/go2rtc/pull/2193) by [@MechanicalCoderX](https://github.com/MechanicalCoderX) — H264/homekit bounds guards against malformed device data

## License

go2rtc is [MIT licensed](https://github.com/AlexxIT/go2rtc/blob/master/LICENSE). This fork carries a small set of Nest-focused patches: IPv4-only ICE in `pkg/nest/client.go`; keyframe-request, `sprop-parameter-sets`, and a stall watchdog in `pkg/webrtc/conn.go`; and stream-extension resilience in `pkg/nest/api.go`. It also incorporates the community PRs credited above. All changes are gated to the Nest source (`FormatName == "nest/webrtc"`) so nothing else in go2rtc is affected.
