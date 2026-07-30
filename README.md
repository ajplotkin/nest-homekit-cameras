# Google Nest Cameras in Apple HomeKit — With Real Tile Images

You have Google Nest cameras. You want them in Apple HomeKit. And you want to actually *see* what the camera sees on the tile — a real, refreshing image — not a blank tile or a placeholder logo.

This is harder than it should be. Google does not offer Nest cameras through HomeKit natively, and when they migrated Nest devices to the Google Home app, they removed the API that provided still images. No integration — commercial or open-source — can request a snapshot from these cameras anymore. The only way to get a real picture is to grab a frame from a live video stream.

This guide walks through the full setup from scratch: getting API access to your Nest cameras, bridging them into HomeKit, and then solving the snapshot problem by keeping a warm stream and serving frames from it. By the end you'll have:

- **Real camera images on your HomeKit tiles** — refreshed every 10 seconds, and instantly on motion or doorbell events (so the tile shows *who's there*, not a stale frame)
- **~2 second live stream startup** — down from ~8 seconds stock (on the plugin's direct dial; the optional RTSP routing in [Part 6](#part-6-route-live-view-and-recording-through-go2rtc) trades a little of that for consistency)
- **Motion and doorbell event notifications** in Apple Home
- **HomeKit Secure Video recording** — motion-triggered clips saved to iCloud also work through this setup (confirmed on a Pi 4; no hardware encoder is needed — and as of the copy change below, recording does not re-encode at all). Requires iCloud+ and a Home Hub, like any HKSV camera.
- **Automatic camera discovery** — new cameras appear without editing config files

**Everything here is open source and runs on a Raspberry Pi.**

### What's in this repo

- **This README** — the complete, from-scratch guide (start here and read top to bottom).
- **[`install.sh`](install.sh)** — one-shot installer for everything after your Google credentials. Re-running is safe but **not** a no-op: it recreates the go2rtc container (dropping every warm stream) and rewrites the warmer unit. see [Quick start](#quick-start-automated--if-parts-1--2-are-already-done).
- **[`docker-compose.yml`](docker-compose.yml)** — the go2rtc + warmer half of the stack as Compose services.
- **[`scripts/`](scripts/)** — `nest-go2rtc-sync.py` (auto-discovers cameras → writes `go2rtc.yaml`), `go2rtc-snapshot-warmer.sh` (keeps the JPEG cache warm), and `apply-snapshot-patch.sh` (applies/re-applies the Homebridge plugin patches).
- **[`patches/`](patches/)** — `go2rtc-nest.patch` (the go2rtc source changes as one diff against a clean **v1.9.14** checkout), four plugin diffs against stock 1.1.24 (`Camera.js`, `Api.js`, `StreamingDelegate.js`, `HksvStreamer.js`), and `homebridge-plugin/new-files/PrebufferManager.js` (a new file, copied in rather than patched — it gives HKSV a real pre-trigger buffer; see [The prebuffer](#the-prebuffer-why-clips-used-to-open-after-the-person-had-gone)).

The patched go2rtc **source and build** live in a separate fork so the git history and upstream attribution are preserved: **[github.com/ajplotkin/go2rtc](https://github.com/ajplotkin/go2rtc/tree/nestfix-1.9.14-3)** — build from the stable tag **`nestfix-1.9.14-3`** (development happens on the `fix/nest-ipv6-ice-failure` branch, which may carry in-progress work, so don't build from the branch.). Part 3 shows how to build it. This work also folds in several community go2rtc pull requests, credited at the end.

Two things worth calling out for anyone arriving because their recordings are unreliable:
**HKSV clips from the stock plugin are silent** (an `-an` overrides the whole audio block —
[#234](https://github.com/potmat/homebridge-google-nest-sdm/issues/234)), and they **begin
~3.6s after Google's event timestamp**, which is late enough that HomeKit's own
People/Animals/Vehicles analysis often finds nobody in the footage and **silently discards the
clip**. Both are fixed here — see [The prebuffer](#the-prebuffer-why-clips-used-to-open-after-the-person-had-gone)
and [Recording copies video](#recording-copies-video--the-transcode-was-never-necessary).

## What You'll Set Up

There are four layers. Each builds on the last:

1. **Google Device Access** — Google's [official API](https://developers.google.com/nest/device-access) for accessing Nest devices programmatically. One-time $5 registration. This gives you the credentials everything else needs.

2. **[Homebridge](https://homebridge.io/)** + **[homebridge-google-nest-sdm](https://github.com/potmat/homebridge-google-nest-sdm)** — [Homebridge](https://github.com/homebridge/homebridge) (by the [@homebridge](https://github.com/homebridge) team) is an open-source HomeKit bridge that runs on a Pi or any server. The Nest plugin (by [@potmat](https://github.com/potmat)) connects to Google's SDM API and presents your cameras as HomeKit accessories. After this step, your cameras appear in Apple Home and live streams work — but the tiles are still blank.

3. **[go2rtc](https://github.com/AlexxIT/go2rtc)** (patched) — go2rtc (by [@AlexxIT](https://github.com/AlexxIT)) keeps a stream warm per camera, which is what makes real tile images possible. Part 3 covers it, including the one-line patch many home networks need.

4. **Snapshot warmer + plugin patches** — A small script that pulls a JPEG from each warm stream every 10 seconds (and immediately on motion/doorbell events), plus a patch to the Homebridge plugin that serves those images instead of the placeholder. This is the glue that connects go2rtc's capabilities to your HomeKit tiles.

## Start here — find your row

| What you have now | Start at | Skip |
|---|---|---|
| Nothing — no Google Device Access, no Homebridge | [Part 1](#part-1-google-device-access) | — |
| Homebridge running (other accessories), no Nest plugin, no Google credentials | [Part 1](#part-1-google-device-access), then the **plugin half** of [Part 2](#part-2-homebridge-and-the-nest-plugin) | Part 2's Homebridge install |
| Google credentials in hand, plugin not installed | [Part 2](#part-2-homebridge-and-the-nest-plugin) | Part 1 |
| Homebridge **and** the plugin working, tiles blank | [Quick start](#quick-start-automated--if-parts-1--2-are-already-done) (installer) or [Part 3](#part-3-go2rtc--warm-streams-and-snapshots) to do it by hand | Parts 1–2 |

**You will need on the host:** Docker, plus `git`, `curl`, `python3`, `node` and `patch`. `node` and `patch` are used by the plugin patcher, which runs on the host even if Homebridge itself is in a container. systemd for the warmer service. Building go2rtc wants roughly 1–1.5 GB of free RAM.

**The plugin must be exactly 1.1.24.** The patches are cut against it and the patcher refuses any other version — worth checking before you build anything.

Whichever row you're on, the `vEncoder: "copy"` note in [Part 2](#part-2-homebridge-and-the-nest-plugin) is a one-line config change worth having.

## Quick start (automated) — if Parts 1 & 2 are already done

The one thing that **cannot** be scripted is Google Device Access (Part 1) — creating the Cloud project, the OAuth consent screen, the $5 registration, and getting a refresh token is manual clicking through Google's consoles. Once you have those credentials in a working **Homebridge + homebridge-google-nest-sdm 1.1.24** install, the rest is one script.

**Option A — `install.sh`** (idempotent; builds the patched go2rtc image, sets up the tmpfs, generates the config, starts go2rtc, installs the warmer service, applies the plugin patches):

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

Every path and container name is a flag with a sensible default (`./install.sh --help`). The one step it leaves to you is adding the snapshot volume to your own Homebridge container; the script detects whether that mount exists and prints the exact line if it's missing.

**Option B — Docker Compose** ([`docker-compose.yml`](docker-compose.yml)) brings up the go2rtc + warmer half of the stack. You still build the image and generate `go2rtc.yaml` first (the file's header comments walk through it), add the one volume line to your Homebridge service, and run `./scripts/apply-snapshot-patch.sh`. Compose can't patch the plugin's `node_modules` for you, so that stays a script call.


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
npm install homebridge-google-nest-sdm@1.1.24
```

**Pin the version.** The patches in this repo are cut against **1.1.24** and `apply-snapshot-patch.sh` refuses to run against anything else, so an unpinned install that picks up a newer release will stop you at the patch step.

Configure it with your Device Access credentials in Homebridge's `config.json`. The block goes in the top-level `platforms` array:

```json
{
    "platforms": [
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
    ]
}
```

(If you already have other platforms, add this object to the existing array. `install.sh` and the sync script both look for it there.)

Two things to note:

**Set `vEncoder` to `"copy"`.** Your Nest cameras send H264 video. HomeKit wants H264 video. The default setting re-encodes it with x264, which wastes CPU and adds seconds of latency. `"copy"` passes the video through untouched. The plugin's README already mentions this option but understates how much it helps.

**Faster live stream startup is now in the plugin.** As of **plugin v1.1.24**, [@littlepope81](https://github.com/littlepope81)'s [PR #212](https://github.com/potmat/homebridge-google-nest-sdm/pull/212) is **merged** — no separate install needed. It cuts time-to-first-frame from ~8s to ~2s (first keyframe at **+2127ms** on a Pi 4) and exposes `-analyzeduration` / `-probesize` as config fields. It tunes the plugin's own direct WebRTC dial, so it applies unless you enable [Part 6](#part-6-route-live-view-and-recording-through-go2rtc). (The further ~4s before the tile actually appears is Apple's own HomeKit setup, not addressable from Homebridge.)

After restarting Homebridge, your cameras should appear in Apple Home. Live streams will work. But the tiles show a Google logo or a blank image — that's the problem this guide exists to solve.

### Known limitation: Google filters rapid successive events (this is NOT a bug in this setup)

If you have several motion/person events close together — e.g. someone leaves and comes back a couple of minutes later — you will often see **only the first one** reach HomeKit, so only the first gets a notification and an HKSV recording. This is **Google's own, documented behavior**: the SDM API does not publish rapid successive camera events (within a short debounce window) to your Pub/Sub topic, even when they are genuinely distinct events. See Google's [events documentation](https://developers.google.com/nest/device-access/api/events).

Key points:
- **It is upstream and intentional**, not something this plugin, this repo, or go2rtc can fix — the filtered events are simply never delivered to any third-party integration.
- **Google Home / Nest Aware still record them** on Google's own side (a separate pipeline), so you can confirm the "missing" events exist in the Google Home app even though HomeKit never saw them.
- Nothing here is broken when this happens; the event was filtered before it ever reached Homebridge.

If this matters to you, the only levers are on Google's side — you can file feedback via Device Access asking for a configurable/shorter filter window; the more reports, the better the odds it gets revisited.

## Part 3: go2rtc — Warm Streams and Snapshots

[go2rtc](https://github.com/AlexxIT/go2rtc) by [@AlexxIT](https://github.com/AlexxIT) is a streaming tool that supports dozens of camera protocols, including Google Nest via the SDM API. It can:

- Connect to your Nest cameras over WebRTC
- Automatically extend the stream before Google's 5-minute expiry
- Keep streams permanently warm via its `preload:` feature
- Serve JPEG snapshots from a warm stream via `/api/frame.jpeg`
- Re-serve the stream over RTSP for other consumers

This is the piece that makes real snapshots possible: keep one stream warm per camera, and grab a frame whenever HomeKit asks.

### The IPv6 bug

> The fork also adds Google's public STUN server (`stun:stun.l.google.com:19302`) to the PeerConnection > config, where stock go2rtc passes none. That changes ICE candidate gathering and means the host will > contact a Google STUN endpoint when negotiating a Nest stream. Noted because it is a functional change > beyond the udp4 filter.

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
git checkout nestfix-1.9.14-3   # stable tag — not the dev branch
```

> **Prefer to patch stock go2rtc yourself?** Instead of cloning the fork, check out upstream go2rtc at the `v1.9.14` tag and apply [`patches/go2rtc-nest.patch`](patches/go2rtc-nest.patch) from this repo (`git clone https://github.com/AlexxIT/go2rtc && cd go2rtc && git checkout v1.9.14 && git apply /path/to/go2rtc-nest.patch`), then run the same build command below. The diff is the exact set of source changes described in this guide, plus the credited community PRs.

```bash
# Build natively on a Pi (arm64, ~3 min). On a 2 GB Pi this can exhaust RAM and take
# running services down with it — stop other containers first, or cross-compile elsewhere:
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

- Reads your Nest credentials straight from Homebridge's `config.json`.
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

This is also why **one camera per room** is required: two cameras in the same room derive the same key and would collide, so the sync script refuses to write that config.

</details>

Run it:

```bash
python3 ~/scripts/nest-go2rtc-sync.py \
  --hb-config /path/to/homebridge/config.json \
  --out ~/go2rtc-nest/go2rtc.yaml

# the generated file embeds your OAuth refresh token — lock it down:
chmod 600 ~/go2rtc-nest/go2rtc.yaml
```

On this first run the script will print `restarting go2rtc` and fail to find the container — that's expected; you start it two steps from now.

### Re-running it later (adding or removing a camera)

When you add, remove, or rename a camera in the Google Home app, re-run the same command to pick it up:

```bash
python3 scripts/nest-go2rtc-sync.py \
  --hb-config /path/to/homebridge/config.json \
  --out /path/to/go2rtc/go2rtc.yaml \
  --container go2rtc --dry-run     # drop --dry-run to apply
```

It is **idempotent and change-detecting**: it regenerates the config, compares it to the file on disk, and if they match it prints `config unchanged` and exits without touching go2rtc. It refuses to write an empty config if discovery returns nothing.

It preserves the `log.level` already in your config, so a rebuild to pick up a new camera won't silently undo a level you set by hand. Pass `--log-level debug` (or `info`, `warn`, …) to set it explicitly.

Note that a **newly added camera still appears in HomeKit before you do any of this** — the plugin discovers cameras from the SDM API directly. It just won't have a warm stream, so its tile shows the placeholder until you re-run the sync.

The generated config is static, and the OAuth *refresh* token it embeds is long-lived (go2rtc mints short-lived access tokens itself at runtime), so a once-written config keeps working indefinitely. You only need to re-run this when your set of cameras or rooms changes.

> **A go2rtc restart drops every warm stream.** When the config *has* changed, the script rewrites `go2rtc.yaml` and restarts the container to load it, and any restart tears down all active WebRTC sessions — tiles briefly fall back to the placeholder and live views drop until the streams re-warm (~30s) and re-extend. Running the script costs nothing when nothing changed, so a periodic timer is fine; it is the restart that is disruptive, and that only fires on a real change.

### Start go2rtc

```bash
docker run -d --name go2rtc \
  --restart unless-stopped \
  --network host \
  -v ~/go2rtc-nest/go2rtc.yaml:/config/go2rtc.yaml \
  go2rtc-nestfix:1.9.14
```

> **This uses host networking.** The generated config binds the API to `127.0.0.1` (localhost only), but the RTSP (`:8554`) and WebRTC (`:8555`) listeners are on **all interfaces** and unauthenticated. That is fine on a trusted home LAN — but do not forward those ports, and don't run this on a machine with a public interface.

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

- HomeKit polls tiles roughly every 10 seconds (measured: median 10s while the Home app is open, with long gaps when nobody is looking). A poll that misses go2rtc's JPEG cache spins up ffmpeg and takes ~1.5–2 seconds — triggering Homebridge's "snapshot handler is slow to respond" warning.
- Worse: **`/api/frame.jpeg` intermittently returns HTTP 500** — measured at roughly 4–20% of transcodes on a live system, in bursts. It is *not* limited to concurrent requests; a single request in an idle system hits it too. If the plugin called the endpoint directly, that error would land straight on your tile as the placeholder logo.

The solution is a warmer script that pre-fetches a JPEG every 10 seconds and writes it to a file, **retrying transient failures** so they never reach HomeKit. The plugin then reads a local file (~1ms — no ffmpeg, no races, no 500s on the HomeKit-facing path). On motion or doorbell events, the plugin signals the warmer to grab a fresh frame immediately — so the tile shows *who's there*, not a 10-second-old empty porch.

### SD card wear

**If your system runs on an SD card** (most Raspberry Pis), put the snapshots in tmpfs (RAM). Writing ~100KB JPEGs every 10 seconds per camera is ~1.5 GB/day of flash writes for data that's pure cache — the warmer rebuilds it in seconds after a reboot. tmpfs costs about 200KB of RAM.

```bash
echo "d /run/nest-snaps 0755 $(id -u) $(id -g) -" | sudo tee /etc/tmpfiles.d/nest-snaps.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nest-snaps.conf
```

### The warmer script

The script is [`scripts/go2rtc-snapshot-warmer.sh`](scripts/go2rtc-snapshot-warmer.sh) — **copy it from there**. It auto-discovers streams from go2rtc, so there is no hardcoded camera list. Each cycle it:

- Asks go2rtc which streams are actually flowing bytes, and only polls those (off cameras are skipped — no wasted SDM quota).
- Pulls a JPEG per warm stream and writes it atomically to `/run/nest-snaps/<key>.jpg`.
- **Retries a failed fetch** (`ATTEMPTS`, default 3, one second apart) instead of losing the whole cycle to one transient HTTP 500.
- **Rejects undersized frames** (`MIN_BYTES`, default 15000) and keeps the last good file instead. ffmpeg emits a *solid grey* JPEG when it decodes H264 without a usable keyframe — around 5–6 KB at 720p, versus 60–100 KB for a real frame. Without this guard that grey image is published as a perfectly valid snapshot.
- **Logs every failure** via `logger -t go2rtc-warmer` (`journalctl -t go2rtc-warmer`) — `curl -sf` would swallow server errors silently.
- Prunes files older than `STALE_MAX_MIN` (30 min), so a camera that is genuinely gone shows the honest placeholder, while one only briefly mid-reconnect keeps its last good frame.

Freshness: the **baseline** cycle uses a cache window *shorter* than the poll interval, so each cycle re-transcodes and the tile stays ~10s fresh. On a motion/doorbell event the plugin touches `/run/nest-snaps/.refresh` and the warmer immediately grabs a frame with a **1-second** cache — so the tile shows who's actually there, not a stale porch. (An earlier version used a 30s cache on both paths, which made "instant on motion" a lie; the shipped script fixes that.)

Grab it:

```bash
curl -fsSL https://raw.githubusercontent.com/ajplotkin/nest-homekit-snapshots/main/scripts/go2rtc-snapshot-warmer.sh -o ~/scripts/go2rtc-snapshot-warmer.sh
```

Install as a systemd service — write this to `/etc/systemd/system/go2rtc-snapshot-warmer.service` (e.g. `sudo nano`), replacing `YOUR_USER`:

```ini
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

Confirm it's actually working before moving on — within ~20 seconds you should see a JPEG per warm camera, and they should keep changing:

```bash
ls -la /run/nest-snaps/           # one <key>.jpg per warm camera, 60-100 KB
journalctl -t go2rtc-warmer -n 20 # quiet is good; failures are logged here
```

### Patch the Homebridge plugin

Mount the snapshot directory into the Homebridge container. **Without this mount, the plugin can't see the files and tiles will show the placeholder:**

```bash
-v /run/nest-snaps:/homebridge/nest-snaps
```

> **A running container cannot gain a bind mount.** `docker restart` will not do it — you have to recreate the container with the extra `-v`, or add the volume to your Compose file and `docker compose up -d`. If you already run Homebridge, note the flags it was created with (`docker inspect homebridge`) before you remove it. If you enable [Part 6](#part-6-route-live-view-and-recording-through-go2rtc), Homebridge also needs `--network host`, so add both in the same recreation.

A from-scratch container looks like this:

```bash
docker run -d --name homebridge \
  --restart unless-stopped \
  --network host \
  -v /path/to/homebridge:/homebridge \
  -v /run/nest-snaps:/homebridge/nest-snaps \
  homebridge/homebridge:latest
```

The plugin needs a few small changes. They're shipped as unified diffs in **[`patches/homebridge-plugin/`](patches/homebridge-plugin/)** and applied for you by **[`scripts/apply-snapshot-patch.sh`](scripts/apply-snapshot-patch.sh)** — you don't hand-edit anything.

What the patches do:

- **`Camera.js`** — `getSnapshot()` returns the warm JPEG from `/homebridge/nest-snaps/<key>.jpg` instead of the Google logo, falling back to the logo if the file is missing or older than 90 seconds (so an off camera shows the honest placeholder). On a motion/person event it creates `/homebridge/nest-snaps/.refresh` (via the plugin's `fs`, no subshell) to trigger an immediate warm-frame grab. The `<key>` is derived exactly as the sync script derives it, which is how the plugin finds the file the warmer wrote.
- **`Api.js`** — **auto-reconnects the Pub/Sub subscription**. Upstream sets it up once and, on error, just stops — so a silently dropped streaming-pull connection permanently kills all camera events (no motion alerts, no HKSV recording) until you restart Homebridge. This re-subscribes on `error`/`close` with exponential backoff, plus a 12-hour proactive recycle to catch half-open stalls. Still open upstream as [PR #216](https://github.com/potmat/homebridge-google-nest-sdm/pull/216).
- **`StreamingDelegate.js`** — optional; see [Part 6](#part-6-route-live-view-and-recording-through-go2rtc).

Earlier versions of this repo carried several more patches; those fixes were merged upstream and ship in plugin 1.1.24. The [Related Issues and PRs](#related-issues-and-prs) index records which.

Clone this repo (you'll want it for the scripts too) and run the patcher:

```bash
git clone https://github.com/ajplotkin/nest-homekit-snapshots.git
cd nest-homekit-snapshots
HOMEBRIDGE_DIR=/path/to/homebridge ./scripts/apply-snapshot-patch.sh
```

The script pins the plugin version it was cut against (**1.1.24**) and **refuses to run on a different one** — the compiled `dist/` layout moves between releases, so a stale patch could silently break things. It's idempotent (safe to re-run) and **exits non-zero** if any patch is missing or won't apply, so a re-apply can never leave you half-patched. Want to see exactly what changes? Read the diffs in `patches/homebridge-plugin/`.

**If you're on a different plugin version**, you have three options, in order of preference:

1. **Install 1.1.24** (`npm install homebridge-google-nest-sdm@1.1.24`) and patch that. Simplest, and what this guide is tested against.
2. **Open an issue** on this repo asking for the patches to be re-cut against your version.
3. **Re-cut them yourself.** Take a pristine copy of your plugin's `dist/`, apply each hunk from `patches/homebridge-plugin/*.patch` by hand (they are small and commented), then `diff -u` pristine against patched to produce new `.patch` files, and bump `EXPECT_VER` in `apply-snapshot-patch.sh`. Check the [Related Issues and PRs](#related-issues-and-prs) list first — if a patch has since been merged upstream, you may not need it at all.

> **These patches live in `node_modules` and are wiped by any `npm install` of the plugin.** Re-run `apply-snapshot-patch.sh` after any plugin install or upgrade — always in that order: `npm install` first, patch script second. (That is also how you *uninstall* them: reinstall the plugin and don't re-run the patcher.)
>
> **This applies all four patches plus one new file, including the Part 6 live-view routing** — the script has no per-patch switch. If you don't want Part 6, read it first and be aware Homebridge needs `--network host`.

## Part 5: Verify

Restart Homebridge to load the patched plugin. (If you added the snapshot mount in the previous step, you already recreated the container — that counts.)

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

**A tile intermittently drops back to the placeholder, even though the camera is on and streaming.** The snapshot endpoint returns intermittent HTTP 500s (see [Part 4](#part-4-the-snapshot-warmer)), and the plugin discards any snapshot older than 90 seconds — so a run of silently-failed warmer cycles is enough to blank the tile. The shipped warmer retries and logs, which makes this a non-event; if you have modified it, keep the retry. Diagnose with:

```bash
journalctl -t go2rtc-warmer --since -30min   # fetch failures / grey-frame rejections
ls -la --time-style=+%H:%M:%S /run/nest-snaps/   # ages must stay well under 90s
```

A snapshot around 5–6 KB (versus a normal 60–100 KB) is a **grey frame** — ffmpeg decoding H264 without a usable keyframe. The warmer rejects those and keeps the previous good image.

**Everything shows "No Response" after a power failure.** Homebridge came up before the network had settled and advertised itself into an mDNS environment that wasn't ready. Restarting *avahi* does not help — Homebridge runs its **own** mDNS responder, so avahi never sees it and restarting avahi changes nothing. Restart **Homebridge** instead.

To make that automatic, run a one-shot unit on a `systemd` **timer** (`OnBootSec=120`) that restarts the container, rather than ordering it `After=network-online.target` — that target is unreliable on Raspberry Pi OS and has been observed reached while DHCP was still settling, and silently skipped entirely. If your accessories depend on another service (Home Assistant, for example), poll it for a 200 before restarting so the bridge re-advertises with its accessories already loaded.

**Motion notifications not arriving on your phone?** HomeKit defaults motion notifications to **off** for new camera accessories. In the Apple Home app: tap the camera → scroll down → **Status and Notifications** → turn on **Motion Notifications** (and **Activity Notifications** if available). You also need an Apple Home Hub (Apple TV, HomePod, or iPad) for notifications to push when you're away.

## Part 6: route live view and recording through go2rtc

> **Not actually optional once you patch.** `apply-snapshot-patch.sh` has no per-patch switch, and the > routing is unconditional — `useGo2rtc` is true for every camera that has a name, which is all of them. > So after patching, a Homebridge whose go2rtc is missing, stopped, or serving different stream names > **loses live view and all HKSV recording**, because ffmpeg dials `rtsp://127.0.0.1:8554/<key>` and fails. > If you only want snapshot tiles, stop after Part 4 and do not run the patch script.

By default `homebridge-google-nest-sdm` opens its **own** WebRTC connection to Google every time you tap a camera tile — separate from the warm stream go2rtc is already holding. That means 2–3 concurrent Google streams per camera (go2rtc's preload + each HomeKit view + the Google Home app). Nest enforces a concurrent-stream limit, and hitting it is what causes tiles that hang for many seconds or "never load."

You can make HomeKit live view reuse go2rtc's already-open stream instead, over local RTSP. **Be honest with yourself about what this does:** it does **not** make a single warm camera open faster (RTSP handshake + waiting for a keyframe to start clean stream-copy is ~2–4s, similar to or slightly slower than a direct WebRTC dial). What it buys is **consistency** — one shared Google stream instead of several, so the multi-viewer contention that causes the long hangs goes away. If your only pain was the occasional minute-long hang, this fixes it. If a single camera already opens fine for you, you can skip this.

Two go2rtc patches in this fork make the RTSP path viable for Nest:

- **Keyframe requests** (`pkg/webrtc/conn.go`): go2rtc sends an RTCP keyframe request (PLI) every 2s to the Nest source, so keyframes stay ~2s fresh. Without this, an idle Nest camera stretches its keyframe interval and RTSP consumers wait a long time to start. (This is media-plane RTCP — no SDM API quota cost.)
- **`sprop-parameter-sets` in the RTSP SDP** (`pkg/webrtc/conn.go`): go2rtc captures the H264 SPS/PPS from the stream and advertises them in the RTSP `DESCRIBE`, so ffmpeg knows the video dimensions immediately and a small `-probesize` is safe.

Both are already in the `go2rtc-nestfix` image you built in Part 3.

Then patch the plugin's `dist/StreamingDelegate.js` `startStream()` — before it calls the SDM streamer, use the local RTSP stream for any camera go2rtc manages:

```javascript
// near the top of startStream(), replacing:  const nestStreamer = await getStreamer(...)
let ffmpegArgs;
let nestStreamer;
let nestStream;
const go2rtcKey = (this.camera.displayName || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
// A go2rtc-managed camera ALWAYS uses RTSP. Do not gate this on snapshot freshness:
// if the stream is briefly cold, ffmpeg fails fast, which is the correct signal. Falling
// back to a Google dial instead opens a SECOND concurrent Nest session that collides with
// go2rtc's own — the result is a blank tile AND no live video. Only an unnamed camera
// (go2rtcKey === '') takes the direct dial.
const useGo2rtc = !!go2rtcKey;
if (useGo2rtc) {
    ffmpegArgs = '-rtsp_transport tcp -analyzeduration 3000000 -probesize 5000000 -i rtsp://127.0.0.1:8554/' + go2rtcKey;
} else {
    try {
        nestStreamer = await (0, NestStreamer_1.getStreamer)(this.log, this.camera, this.config);
        nestStream = await nestStreamer.initialize();
        ffmpegArgs = nestStream.args;
    } catch (error) {
        this.logThenCallback(callback, error);
        return;
    }
}
```

**Don't hand-apply this if you can avoid it** — [`patches/homebridge-plugin/StreamingDelegate.js.patch`](patches/homebridge-plugin/StreamingDelegate.js.patch) is the authoritative version and carries details omitted here for readability. The snippet above is to explain *what* changes and *why*.

Then guard the two places that assumed a streamer object always exists:
- the FfmpegProcess construction: pass `nestStream ? nestStream.stdin : undefined` (the RTSP path has no stdin pipe; FfmpegProcess already guards `if (stdin)`)
- `stopStream()`'s teardown: `if (session.streamer) await session.streamer.teardown()`

**One required safety addition.** The go2rtc RTSP input never ends (preload keeps it warm forever), unlike a Google WebRTC stream which self-expires after 5 min. So if HomeKit abandons a session without sending any RTCP, the ffmpeg transcode would run forever. Arm an inactivity watchdog right after the socket binds in `startStream()`:

```javascript
activeSession.timeout = setTimeout(() => {
    this.controller.forceStopStreamingSession(request.sessionID);
    this.stopStream(request.sessionID);
}, useGo2rtc ? 15000 : 45000);   // 15s grace on the warm RTSP path; 45s on a direct Google dial,
                                 // which legitimately takes longer to open. The socket 'message'
                                 // handler replaces this with rtcp_interval*2 on the first RTCP.
```

This `StreamingDelegate.js` change ships as [`patches/homebridge-plugin/StreamingDelegate.js.patch`](patches/homebridge-plugin/StreamingDelegate.js.patch) and is applied by the same `apply-snapshot-patch.sh`.

> **Requires Homebridge on the host network.** The live-view patch dials `rtsp://127.0.0.1:8554` from *inside* the Homebridge container, so `127.0.0.1` has to be the same host go2rtc listens on. Run the Homebridge container with `--network host` (as go2rtc does). If Homebridge is on Docker's default bridge network instead, `127.0.0.1` points at the container itself and the live-view dial fails — use the host's LAN IP, or move Homebridge to `--network host`. The **snapshot** path doesn't care (it's a file bind-mount), so this only affects Part 6.

### HKSV recording rides the warm stream too — and this matters more than live view

The same `StreamingDelegate.js` patch routes **HomeKit Secure Video recording** through the warm RTSP stream as well, using the identical freshness check.

By default, when motion fires, the plugin's recording handler (`handleRecordingStreamRequest`) opens **yet another** fresh Google WebRTC session — a *second* concurrent stream for that camera (a *third* if you're also viewing live). That tips Nest over its per-device concurrent-stream limit, and every recording triggers an ugly cascade: the second dial contends with go2rtc's warm stream → go2rtc's stream gets throttled/dropped → it reconnects (a burst of `retry=` in the go2rtc log) → and the recording itself decodes garbage (`concealing 3721 DC/AC/MV errors in I frame`, corrupt frames) because it started against a contended, half-broken stream. The system "self-heals" a minute later, but the clip is ruined.

Routing recording through the warm RTSP stream instead (`rtsp://127.0.0.1:8554/<key>` for any go2rtc-managed camera) eliminates all of it: no second session, no contention, no reconnect burst, and the recorder runs against a clean, already-established stream. (As of the prebuffer work below, that recorder no longer transcodes video at all — see *Recording copies video*.) Measured before/after on a Pi 4: decode errors dropped from **thousands per recording to ~zero**, and recording-induced reconnect spikes went to **none**. This ships in `StreamingDelegate.js.patch`. It is no longer the only change in that function — the same patch also carries the audio fix, the video-copy change, and the prebuffer feed described below — and `HksvStreamer.js` now has its own patch too (it must accept a `Readable` on stdin for the prebuffer, and end ffmpeg's stdin on source close).

The patch also carries two teardown fixes the RTSP path needs.

The first is **not optional**. On the RTSP path there is no streamer object, but the base plugin's `closeRecordingStream` calls `recordingSessionInfo.nestStreamer.teardown()` unguarded. That throws a **synchronous** `TypeError` — which `Promise.resolve` does *not* absorb — out of `closeRecordingStream`, so `recordingSessionInfo` never clears and **recording is permanently wedged after the first clip on every go2rtc camera**. The patch hands that branch a no-op streamer (`{ teardown: async () => {} }`) so the unguarded call is harmless.

The second: the recording session must be reset in a `finally`, so a generator that throws cannot leave `handlingRecordingStreamingRequest` stuck true and block every later recording. (The related destroy-prior-session fix for issue #150 is **not** ours to claim here — it merged upstream as PR #217 and is already in stock 1.1.24; the patch carries it only as context.)

### The prebuffer: why clips used to open *after* the person had gone

Recording only starts once HomeKit asks for it, which is downstream of Google's Pub/Sub
delivery. Measured on this deployment:

```
Google event timestamp -> Pub/Sub delivery :  ~2.0s typical (median 7.5s across a day)
delivery -> ffmpeg connected + keyframe    :  ~1.0s
                                              ------
event timestamp -> first recorded frame    :  ~3.6s
```

Worse, Google's timestamp is itself late. For one doorbell event Google's *own* clip began
**6.1s before** the timestamp it published to us, so we were ~9.7s behind what Google
captured. A person walking to a door is gone by the first frame.

That mattered far more than it sounds, because of what HomeKit does next. If a camera's
**Recording Options** are set to People/Animals/Vehicles (rather than Any Motion), the hub
runs its *own* analysis on the footage and **silently discards the clip if it finds no
qualifying subject**. Every layer reports success — `closeRecordingStream` returns
`reason=NORMAL`, no error anywhere — and the clip simply never appears. That is the real
cause of "the doorbell missed someone", and it is not fixable by anything on the camera side.

`PrebufferManager.js` (new file) fixes it. Per camera it continuously remuxes the warm go2rtc
stream with `-c copy` into a rolling in-memory ring of fragmented-MP4 fragments, each
beginning on a keyframe. **No encoding**, so it costs roughly 150 KB/s and a few percent of
one core per camera, and about 2 MB of RAM. When a recording starts, the recorder is fed
`[buffered history][live]` through stdin, so the clip opens *before* the trigger.

Two design points worth keeping if you modify it:

- **Anchor to the event timestamp, not to "now".** Connection time varies with Pub/Sub
  latency (median 7.5s, p75 47.8s here), so anchoring to the moment ffmpeg connects makes the
  recovered window vary by seconds run to run. `Camera.js` latches the Google timestamp when
  a STARTED motion/person event fires; the recorder anchors to that.
- **Size the window from the hub's *selected* `prebufferLength`, not from what you
  advertise.** The advertised value is only a maximum — the hub picks its own (Apple hubs
  select ~4000 ms) and anything beyond the selection is delivered and then discarded. Serving
  15 s when the hub keeps 4 s is pure waste.

Verified: a real doorbell event now opens on an empty porch **5 seconds before** the subject
appears, where it previously opened on their back as they left.

Config keys (both optional; the feature is **off** unless the first is set):

| Key | Default | Meaning |
|---|---|---|
| `hksvPrebufferSeconds` | unset (off) | Upper bound on pre-trigger footage to serve, in seconds. `6` is ample given hubs select 4 s. |
| `hksvPrebufferRetainSeconds` | `15` | How much history to hold in RAM per camera. Must comfortably exceed `hksvPrebufferSeconds` plus Pub/Sub delivery latency. |

```json
{
  "platform": "homebridge-google-nest-sdm",
  "hksvPrebufferSeconds": 6,
  "hksvPrebufferRetainSeconds": 15
}
```

Confirm it is working:

```bash
docker logs homebridge 2>&1 | grep "prebuffer.*serving"
# [prebuffer:front_door] serving 5 buffered fragments (~8.7s of history)
```

### Recording copies video — the transcode was never necessary

The stock recording path re-encodes with libx264. It does not need to, and the reason it did
is a chain of two unrelated-looking lines: the plugin advertises
`video.parameters.profiles: [HIGH]` for recording, and `handleRecordingStreamRequest` then
derives `-profile:v` from whatever the controller selected. Since Nest emits **Main**, that
combination forces a re-encode on every clip.

Nothing on the HomeKit side compares delivered bytes against the negotiation — hap-nodejs
treats each fragment as an opaque buffer and never parses `moof`/`mdat`/SPS. The proof is in
this very plugin: its **live** path already advertises Main and streams with `-codec:v copy`.
Upstream precedent too — homebridge-unifi-protect advertises Main *only* and records with
copy; scrypted copies whatever the camera emits and treats transcoding as a debug option.

So on any go2rtc-sourced camera the recorder now uses `-codec:v copy`. Only audio is
transcoded (Opus → AAC-ELD, which HomeKit genuinely requires). Measured on a Pi 4 with a
1600×1200 doorbell:

| | transcode | copy |
|---|---|---|
| CPU | ~1.8 of 4 cores | remux only |
| Encoder throughput | ~1.37× realtime | n/a |
| Frame rate | had to be capped to 15 to keep up | the source's native rate |
| Video | a re-encode of Google's encode | Google's original bytes |

That throughput figure was the margin against the hub's fragment timeout; under concurrent
load the transcode could fall below realtime, which is when clips truncate. With no encoder
there is nothing to fall behind.

Two things to know:

- **Fragment length becomes the source's IDR cadence** (~1.67 s here) rather than the
  negotiated 4000 ms. That is within contract: hap-nodejs documents `fragmentLength` as a
  maximum ("must not be longer than"), and `-movflags frag_keyframe` guarantees every
  fragment starts on a keyframe. Don't try to group fragments to reach 4000 ms — it is
  unnecessary and multi-`moof`-per-yield isn't something the spec describes.
- **The advertisement is deliberately left as `[HIGH]`.** Changing it would alter the
  supported-configuration hash, which makes hap-nodejs discard every hub's persisted selected
  configuration and forces a renegotiation. Copy needs no such change. `[LEVEL4_0]` must stay
  regardless — 1600×1200 is 7,500 macroblocks per frame, which exceeds Level 3.1/3.2's
  maximum frame size at *any* frame rate.

The libx264 block is retained for the non-go2rtc fallback path only.

### Confirm it's routing through RTSP

Enable Homebridge debug logging, tap a camera tile, and look for the patch's own line:

```bash
docker logs homebridge 2>&1 | grep "Using local go2rtc RTSP"
```

If it appears, live view is coming from the warm stream. If instead you see the plugin opening a Google dial, `go2rtcKey` didn't match a stream name — compare the accessory name against the stream names in `curl -s http://127.0.0.1:1985/api/streams`.

To undo Part 6: reinstall the plugin (`npm install homebridge-google-nest-sdm@1.1.24`) and don't re-run the patch script. That reverts all four patches and removes `PrebufferManager.js`, so re-apply them if you still want the snapshot fix — there is no per-patch switch.

### When go2rtc receives but forwards nothing — check this FIRST

On 2026-07-30 a doorbell stream spent a morning in a state where go2rtc kept pulling from
Google at ~150 KB/s while delivering **nothing** to its consumers. Measured over 60s:

| | producer `bytes_recv` | video receiver `bytes` (consumers attached) |
|---|---|---|
| broken stream | 45.9 → 50.5 → 54.6 MB, climbing | frozen, unchanged |
| healthy stream | climbing | climbing |

go2rtc logged **no error at all**. Everything downstream looked like a different bug: the
prebuffer ring reader was starved and stall-killed every 60s, the fallback direct dial was
starved too, and every clip was lost with `closeRecordingStream reason=6`. Hours were spent
on the plugin before the real fault was found one layer down.

**This is the opposite of a "drought."** A drought is *inbound* drying up, which the fork's
watchdog in `pkg/webrtc/conn.go` already handles by re-dialling. This is *outbound* dying
while inbound stays healthy — so the drought watchdog cannot see it, by construction. Same
symptom, inverted mechanism.

Root cause is upstream, in stock go2rtc's producer reconnect (`internal/streams/producer.go`):
a receiver that fails to match a media/codec on re-dial is skipped by a bare `continue`, and
the following `conn.Stop()` closes it, severing every consumer attached to it — permanently
and silently. It is directly visible in the API: a consumer whose sender reports a `parent`
receiver id that no longer exists in the producer.

Diagnose (**note the API is on 1985 here, not go2rtc's default 1984**), sampling twice at
least 30s apart, since these are cumulative counters and one sample proves nothing:

```bash
curl -s http://127.0.0.1:1985/api/streams
```

Compare each producer's `bytes_recv` against the `bytes` on its **video** receivers that have
a non-empty `childs` list. Producer climbing + receiver frozen = wedged. Two counters that
look useful and are **not**: an RTSP consumer's `bytes_send` increments only in the error
branch (it counts *failed* writes), and the `preload` consumer's counter freezes permanently
once that consumer has been severed, even while everything else is healthy.

Recovery is `docker restart go2rtc`. There is no per-stream restart in the API — `PATCH` only
calls `SetSource` and never touches the wedged connection, and `DELETE`+`PUT` rewrites the
config while leaking the running stream. Expect ~10 minutes of reader churn afterwards as
streams settle; that is normal, not a second fault.

`scripts/go2rtc-wedge-detector.py` automates the detection. It is **dry-run by default** —
run it unarmed first:

```bash
python3 scripts/go2rtc-wedge-detector.py --api http://127.0.0.1:1985/api/streams
```

Add `--arm` only after a quiet period confirms no false positives on your cameras. Its
defaults (500 KB per 30s interval before a frozen receiver counts as evidence) assume a Nest
source whose audio is ~4–8 KB/s; a source with high-bitrate audio needs re-tuning, because
`bytes_recv` counts audio RTP too while the signal is video-only.

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
| CPU per HKSV recording (transcode, before) | ~1.8 of 4 cores, ~1.37x realtime |
| CPU per HKSV recording (copy, now) | remux + audio only |
| Prebuffer ring, per camera | ~150 KB/s, ~2 MB RAM, a few % of one core |
| Pre-trigger footage recovered | ~10.7s (clip opens ~5s before the subject appears) |

### Related Issues and PRs

- [go2rtc #2311](https://github.com/AlexxIT/go2rtc/issues/2311) — `nest: wrong status: 400` / IPv6 ICE failure diagnosis
- [homebridge-google-nest-sdm #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214) — Api.js crash on `relationUpdate` events
- [homebridge-google-nest-sdm #215](https://github.com/potmat/homebridge-google-nest-sdm/issues/215) — README corrections (project ID confusion, self-hosted Pub/Sub, Node regression)
- [homebridge-google-nest-sdm PR #212](https://github.com/potmat/homebridge-google-nest-sdm/pull/212) by [@littlepope81](https://github.com/littlepope81) — stream startup latency + configurable `analyzeduration`/`probesize` — **merged in 1.1.24**
- [homebridge-google-nest-sdm PR #216](https://github.com/potmat/homebridge-google-nest-sdm/pull/216) — the Pub/Sub auto-reconnect fix from this repo — **open** (events silently stopping after a connection drop); still carried here as `Api.js.patch`
- [homebridge-google-nest-sdm PR #217](https://github.com/potmat/homebridge-google-nest-sdm/pull/217) — the HKSV recording session-leak fix from this repo (orphaned ffmpeg / memory growth; relates to #150) — **merged in 1.1.24**
- [homebridge-google-nest-sdm PR #223](https://github.com/potmat/homebridge-google-nest-sdm/pull/223) — HKSV recording-lifecycle hardening from this repo (hang-on-dead-input, stale-close, teardown-rejection) — **merged in 1.1.24**
- [homebridge-google-nest-sdm PR #224](https://github.com/potmat/homebridge-google-nest-sdm/pull/224) — reset the recording session in a `finally` (follow-up to #223) — **open**; still carried here in `StreamingDelegate.js.patch`
- [homebridge-google-nest-sdm PR #218](https://github.com/potmat/homebridge-google-nest-sdm/pull/218) by [@littlepope81](https://github.com/littlepope81) — hardens the Pub/Sub handler against `relationUpdate`/malformed events ([issue #214](https://github.com/potmat/homebridge-google-nest-sdm/issues/214)) — **merged in 1.1.24** (this repo's `Api.js.patch` now reuses the base guard and only adds reconnect)
- [homebridge-google-nest-sdm PR #219](https://github.com/potmat/homebridge-google-nest-sdm/pull/219) by [@littlepope81](https://github.com/littlepope81) — drops replayed/stale events so a reconnect/restart backlog can't fire phantom motion/recordings — **merged in 1.1.24** (this repo relies on the base plugin's version; the standalone Camera.js/Doorbell.js stale-event patches were dropped once it merged)

- [homebridge-google-nest-sdm #231](https://github.com/potmat/homebridge-google-nest-sdm/issues/231) — `MAX_EVENT_AGE_SECONDS = 30` discards real events, because Pub/Sub first deliveries are routinely 46-57s late — **open**; this repo raises the gate to 120s in `Camera.js.patch`
- [homebridge-google-nest-sdm #232](https://github.com/potmat/homebridge-google-nest-sdm/issues/232) — HKSV clips truncated by x264 lookahead/B-frames, which a live source can never recover from — **open**; now moot on the go2rtc path, which no longer encodes at all
- [homebridge-google-nest-sdm #233](https://github.com/potmat/homebridge-google-nest-sdm/issues/233) — `prebufferLength: 4000` advertised to HomeKit with no prebuffer implemented behind it — **open**; answered by `PrebufferManager.js` here
- [homebridge-google-nest-sdm #234](https://github.com/potmat/homebridge-google-nest-sdm/issues/234) — every HKSV clip recorded **silent**: an unconditional `-an` at the head of `videoArgs` overrode the whole AAC-ELD block, because `HksvStreamer` appends videoArgs *after* audioArgs — **open**; fixed here in `StreamingDelegate.js.patch`

- [homebridge-google-nest-sdm #235](https://github.com/potmat/homebridge-google-nest-sdm/issues/235) — HKSV recording re-encodes video unnecessarily; `-codec:v copy` works and the `-profile:v` requirement is self-imposed — **open**
- [homebridge-google-nest-sdm PR #237](https://github.com/potmat/homebridge-google-nest-sdm/pull/237) — the silent-recordings fix from this repo (issue #234) — **open**
- [homebridge-google-nest-sdm PR #238](https://github.com/potmat/homebridge-google-nest-sdm/pull/238) — copy the camera H.264 for HKSV recording on the WebRTC path, dropping the libx264 transcode (issue #235); RTSP cameras keep transcoding — **open**

**Upstream go2rtc work this fork builds on (credit to the authors):**

- [go2rtc PR #2368](https://github.com/AlexxIT/go2rtc/pull/2368) — the Nest keyframe-request + `sprop-parameter-sets`-in-SDP patches from this fork, submitted upstream
- [go2rtc PR #2378](https://github.com/AlexxIT/go2rtc/pull/2378) — `rtcConn` never closed the PeerConnection on a failed dial, leaking it plus its ICE agent's mDNS `:5353` sockets on every retry. A powered-off camera accumulated 142 leaked sockets on one host, which starved mDNS and left HomeKit accessories at "No Response". From this fork, submitted upstream
- [go2rtc PR #2380](https://github.com/AlexxIT/go2rtc/pull/2380) — `RTPDepay` began depayloading at whatever packet arrived first, so attaching mid-fragmented-NAL produced a synthesized, head-truncated "keyframe" that passes `IsKeyframe` but cannot decode. `/api/frame.jpeg` builds a fresh depayloader per request and hit it constantly. From this fork, submitted upstream
- [go2rtc PR #2351](https://github.com/AlexxIT/go2rtc/pull/2351) by [@tillo](https://github.com/tillo) — loops the Nest stream-extension timer and stops sharing session state between cameras (adopted here; the fork adds transient-error retry on top)
- [go2rtc PR #2194](https://github.com/AlexxIT/go2rtc/pull/2194) by [@MechanicalCoderX](https://github.com/MechanicalCoderX) — Nest expiry/token/timeout/leak fixes (the ~83-minute HTTP timeout fix is adopted here)
- [go2rtc PR #2327](https://github.com/AlexxIT/go2rtc/pull/2327) by [@zephleggett](https://github.com/zephleggett) — reap the keyframe consumer on client disconnect (defense-in-depth for the snapshot warmer)
- [go2rtc PR #2193](https://github.com/AlexxIT/go2rtc/pull/2193) by [@MechanicalCoderX](https://github.com/MechanicalCoderX) — H264/homekit bounds guards against malformed device data

## License

go2rtc is [MIT licensed](https://github.com/AlexxIT/go2rtc/blob/master/LICENSE). This fork carries a small set of Nest-focused patches: IPv4-only ICE in `pkg/nest/client.go`; keyframe-request, `sprop-parameter-sets`, and a stall watchdog in `pkg/webrtc/conn.go`; and stream-extension resilience in `pkg/nest/api.go`. It also incorporates the community PRs credited above. Only the `pkg/webrtc/conn.go` additions are gated to the Nest source (`FormatName == "nest/webrtc"`). The rest are **not** Nest-specific and affect any source that exercises them: `pkg/h264/rtp.go` (partition-head sync — every H264 RTP source), `internal/streams/preload.go` (preload retry), `internal/mjpeg/mjpeg.go` and `internal/mp4/mp4.go` (consumer reaping), `internal/ffmpeg/jpeg.go` (stderr surfacing), `pkg/core/writebuffer.go`, and `pkg/homekit/helpers.go`. They are bug fixes rather than Nest behaviour changes — three are upstream PRs (#2368/#2378/#2380) — but if you run other sources through this fork, know that they are in the path.
