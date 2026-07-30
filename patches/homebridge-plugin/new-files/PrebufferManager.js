"use strict";
/**
 * PrebufferManager — a rolling pre-trigger buffer for HKSV recordings.
 *
 * THE PROBLEM
 * -----------
 * A recording only starts once HomeKit asks for one, which is downstream of
 * Google's Pub/Sub delivery. Measured on a live deployment (2026-07-29):
 *
 *     Google event timestamp -> Pub/Sub delivery :  2.0-2.3s (best), median 7.5s
 *     delivery -> ffmpeg connected + keyframe    : ~1.0s
 *     ------------------------------------------------------
 *     event timestamp -> first recorded frame    : ~3.3s (best case)
 *
 * and Google's own detection lag sits BEFORE its timestamp, unmeasured. Someone
 * walking to a door is routinely gone by the first frame, so HomeKit's on-device
 * People/Animals/Vehicles analysis finds no subject and SILENTLY DISCARDS the
 * clip -- with every layer reporting success and `reason=NORMAL` on close.
 *
 * Separately, HomeKit *asks* for footage before the trigger (`prebufferLength`);
 * that requirement is additive to the lateness above. To honestly serve a 4s
 * advertised prebuffer we need 4 + ~3.3 = ~7.3s of history, hence the 12s default.
 *
 * THE APPROACH
 * ------------
 * Continuously remux each camera out of go2rtc with `-c copy` -- no encoding, so
 * the cost is a few percent of one core -- into fragmented MP4, and keep the last
 * N seconds of fragments in memory. On a trigger the recorder is fed
 * [buffered history] + [live], so it begins in the past.
 *
 * Fragmented MP4 rather than mpegts because every `moof` starts at a keyframe and
 * box headers are self-describing, so safe cut points need no codec parsing. This
 * is also exactly the format HksvStreamer already consumes. Measured here:
 * ~1.67s per fragment, init segment 1285 bytes, ~150KB/s => ~1.8MB per camera.
 *
 * ANCHORING
 * ---------
 * Callers request history relative to the *event timestamp*, not to "now".
 * Connection time varies with Pub/Sub latency, so anchoring to it would make the
 * recovered window vary by seconds run to run. The plugin knows the Google
 * timestamp, so it can ask for exactly what it needs.
 */

const { spawn } = require("child_process");
const { Readable } = require("stream");

// Boxes that together form the init segment every consumer needs first.
const INIT_BOXES = new Set(["ftyp", "moov"]);
// `mfra` is a random-access index ffmpeg writes at end-of-file; it never appears
// mid-live-stream and would be meaningless to forward. The others are padding.
const SKIP_BOXES = new Set(["mfra", "free", "skip"]);

// Sizing, derived from a measured event (2026-07-29 12:44) rather than picked:
//
//   Google Home's own clip started  12:44:42.0
//   SDM event timestamp             12:44:48.1   <- already 6.1s stale when issued
//   our first frame                ~12:44:51.7   <- +3.6s for delivery + ffmpeg
//
// To match what Google Home actually shows, history must reach ~6-8s BEFORE the
// event timestamp, while the request itself arrives ~3.6s AFTER it -- so the ring
// must span ~11.6s. 12s would sit exactly on that edge; 15s leaves margin for the
// jitter in delivery latency without costing anything meaningful: ~150KB/s per
// camera => ~2.3MB.
//
// This does NOT rescue the long tail of Pub/Sub latency (median 7.5s across a day,
// p75 47.8s): a 15s ring cannot span a 48s-late delivery, and for those events the
// served history begins long after the subject left. Retention margin is not
// latency coverage. Such events remain lost, and no prebuffer size fixes them --
// only Google delivering sooner would.
const DEFAULT_BUFFER_SECONDS = 15;
// A fragment is ~250KB. This caps a single camera near ~50MB even if the clock
// misbehaves or fragments arrive far faster than expected.
const MAX_FRAGMENTS = 200;
// No legitimate box here approaches this: fragments run ~250KB, init ~1.3KB. A
// larger declared size means the parse has desynced, and without a cap we would
// accumulate `pending` toward the 32-bit maximum (4GB) and OOM the Pi long before
// any error surfaced.
const MAX_BOX_BYTES = 16 * 1024 * 1024;
// Backstop for a consumer that stops draining (see the destroy-before-start case
// in HksvStreamer): without this the queue grows at ~150KB/s indefinitely.
const MAX_QUEUED_FRAGMENTS = 240;

class CameraBuffer {
    constructor(log, name, url, ffmpegPath, bufferSeconds) {
        this.log = log;
        this.name = name;
        this.url = url;
        this.ffmpegPath = ffmpegPath;
        this.bufferSeconds = bufferSeconds;

        this.initSegment = Buffer.alloc(0);
        this.fragments = [];        // [{ t: epoch_ms, data: Buffer }]
        this.subscribers = new Set();
        // Streams currently being served. A restarted ffmpeg emits a fresh moov and
        // restarts mfhd/tfdt at ~0, so its fragments CANNOT be appended to a
        // recording initialised from the previous timeline -- the recorder would see
        // DTS jump backwards by hours. Consumers are destroyed on restart instead;
        // the caller falls back to dialling go2rtc directly next time.
        this.activeStreams = new Set();
        this.stopped = false;
        this.child = undefined;
        this.restarts = 0;
        this.totalFragments = 0;
        this.backoffMs = 1000;
        this.restartTimer = undefined;
        // A camera that has NEVER produced an init segment almost certainly has no
        // go2rtc stream at all (404) or is switched off. Retrying such a camera on
        // the normal cadence pokes go2rtc -> Nest forever for nothing, so its
        // backoff is allowed to grow much further than a camera that was working
        // and then dropped.
        this.everProduced = false;
        // Timestamp of the last published fragment. A camera that worked earlier but has
        // been dark for a while (AJ switches two off overnight) should not keep poking
        // go2rtc -> SDM once a minute all night for nothing.
        this.lastProducedAt = 0;
    }

    start() {
        if (this.stopped) {
            return;
        }
        const args = [
            "-hide_banner", "-loglevel", "error",
            "-rtsp_transport", "tcp",
            "-i", this.url,
            "-c", "copy",
            "-f", "mp4",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "pipe:1",
        ];
        this.log.debug(`[prebuffer:${this.name}] starting reader ${this.url}`);

        let child;
        try {
            child = spawn(this.ffmpegPath, args, { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
        } catch (e) {
            this.log.error(`[prebuffer:${this.name}] cannot spawn ffmpeg: ${e}`);
            this.scheduleRestart();
            return;
        }
        this.child = child;
        const startedAt = Date.now();

        this.pending = Buffer.alloc(0);
        this.pendingMoof = undefined;

        child.stdout.on("data", chunk => this.consume(chunk));
        // Never discard ffmpeg's stderr. A reader that silently produces nothing
        // is indistinguishable from a healthy idle camera, and that ambiguity has
        // cost real debugging time on this deployment before.
        child.stderr.on("data", d => {
            const s = d.toString().trim();
            if (!s) {
                return;
            }
            // Before this camera has EVER produced a fragment, ffmpeg's complaint is the
            // only thing that explains why the prebuffer is silently inert (e.g. an older
            // ffmpeg refusing Opus-in-MP4 without -strict experimental). Do not bury it.
            if (!this.everProduced) {
                this.log.warn(`[prebuffer:${this.name}] ffmpeg (ring never started): ${s}`);
            }
            else {
                this.log.debug(`[prebuffer:${this.name}] ffmpeg: ${s}`);
            }
        });
        child.on("error", e => this.log.error(`[prebuffer:${this.name}] ffmpeg error: ${e}`));
        child.on("exit", (code, signal) => {
            if (this.stopped) {
                return;
            }
            this.restarts++;
            // A restarted ffmpeg emits a fresh ftyp/moov which may not describe the
            // old fragments; keeping them risks handing a consumer a mismatched init.
            this.initSegment = Buffer.alloc(0);
            this.fragments = [];
            // Drop half-parsed state HERE too, not just in killChild(): stdout buffered
            // before 'exit' can still arrive afterwards, and completing an old-timeline
            // moof+mdat into the new array is a backward-DTS splice that -codec:v copy
            // cannot mask. start() also resets these, but only after the backoff delay.
            this.pending = Buffer.alloc(0);
            this.pendingMoof = undefined;
            this.resetConsumers("prebuffer reader restarted; timeline discontinuity");
            // Reset backoff if it had been healthy: a stream that ran for minutes
            // and then dropped deserves a prompt retry, not the delay earned by one
            // that fails instantly.
            if (this.everProduced && Date.now() - startedAt > 30000) {
                this.backoffMs = 1000;
            }
            this.log.debug(`[prebuffer:${this.name}] reader exited (code=${code} signal=${signal}), retry in ${this.backoffMs}ms`);
            this.scheduleRestart();
        });
    }

    /** Destroy every in-flight consumer; their timeline is no longer valid. */
    resetConsumers(reason) {
        const streams = Array.from(this.activeStreams);
        this.activeStreams.clear();
        for (const st of streams) {
            try {
                st.destroy(new Error(reason));
            }
            catch (e) { /* already gone */ }
        }
        if (streams.length) {
            this.log.warn(`[prebuffer:${this.name}] ${reason} -- dropped ${streams.length} in-flight consumer(s)`);
        }
    }

    scheduleRestart() {
        if (this.stopped || this.restartTimer) {
            return;
        }
        const delay = this.backoffMs;
        const sustainedOutage = this.lastProducedAt > 0 && (Date.now() - this.lastProducedAt) > 300000;
        const cap = (this.everProduced && !sustainedOutage) ? 60000 : 300000;
        this.backoffMs = Math.min(this.backoffMs * 2, cap);
        this.restartTimer = setTimeout(() => {
            this.restartTimer = undefined;
            this.start();
        }, delay);
        if (this.restartTimer.unref) {
            this.restartTimer.unref();
        }
    }

    consume(chunk) {
        this.pending = this.pending.length ? Buffer.concat([this.pending, chunk]) : chunk;
        for (;;) {
            if (this.pending.length < 8) {
                return;
            }
            let size = this.pending.readUInt32BE(0);
            const type = this.pending.toString("latin1", 4, 8);
            let header = 8;
            if (size === 1) {
                if (this.pending.length < 16) {
                    return;
                }
                // 64-bit sizes are legal but never produced here; read the low word
                // and refuse anything that would not fit in a sane buffer.
                const hi = this.pending.readUInt32BE(8);
                const lo = this.pending.readUInt32BE(12);
                if (hi !== 0) {
                    this.log.error(`[prebuffer:${this.name}] absurd 64-bit box size, restarting reader`);
                    this.killChild();
                    return;
                }
                size = lo;
                header = 16;
            }
            if (size > MAX_BOX_BYTES) {
                this.log.error(`[prebuffer:${this.name}] box '${type}' declares ${size} bytes (>${MAX_BOX_BYTES}); parse desynced, restarting reader`);
                this.killChild();
                return;
            }
            if (size < header) {
                this.log.error(`[prebuffer:${this.name}] bad box size ${size} for '${type}', restarting reader`);
                this.killChild();
                return;
            }
            if (this.pending.length < size) {
                return;
            }
            const box = this.pending.subarray(0, size);
            this.pending = this.pending.subarray(size);

            if (INIT_BOXES.has(type)) {
                this.initSegment = this.initSegment.length
                    ? Buffer.concat([this.initSegment, box])
                    : Buffer.from(box);
                continue;
            }
            if (SKIP_BOXES.has(type)) {
                continue;
            }
            if (type === "moof") {
                this.pendingMoof = Buffer.from(box);
                continue;
            }
            if (type === "mdat") {
                if (!this.pendingMoof) {
                    // An mdat with no moof cannot be framed; dropping it is the only
                    // safe move (a moof without its mdat would wedge a demuxer).
                    continue;
                }
                this.publish(Buffer.concat([this.pendingMoof, Buffer.from(box)]));
                this.pendingMoof = undefined;
                continue;
            }
            // Unknown box: ignore rather than guess at its meaning.
        }
    }

    killChild() {
        // Drop half-parsed state with the child. Otherwise buffered stdout from the
        // dying process keeps hitting the corrupt-parse path, and a late chunk can
        // interleave with the next child's output through the same `pending`.
        this.pending = Buffer.alloc(0);
        this.pendingMoof = undefined;
        try {
            if (this.child) {
                this.child.kill("SIGKILL");
            }
        } catch (e) { /* exit handler schedules the restart */ }
    }

    publish(fragment) {
        this.everProduced = true;
        const now = Date.now();
        this.lastProducedAt = now;
        this.fragments.push({ t: now, data: fragment });
        this.totalFragments++;
        const cutoff = now - this.bufferSeconds * 1000;
        while (this.fragments.length && this.fragments[0].t < cutoff) {
            this.fragments.shift();
        }
        while (this.fragments.length > MAX_FRAGMENTS) {
            this.fragments.shift();
        }
        for (const sub of this.subscribers) {
            try {
                sub(fragment);
            } catch (e) {
                this.log.debug(`[prebuffer:${this.name}] subscriber threw: ${e}`);
            }
        }
    }

    /**
     * Fragments buffered at or after `sinceEpochMs`, plus the init segment.
     * Returns null when no init segment has been seen yet -- the caller must fall
     * back rather than emit a headless stream.
     */
    history(sinceEpochMs) {
        if (!this.initSegment.length) {
            return null;
        }
        return {
            init: this.initSegment,
            fragments: this.fragments.filter(f => f.t >= sinceEpochMs).map(f => f.data),
            oldestAvailable: this.fragments.length ? this.fragments[0].t : undefined,
        };
    }

    stop() {
        this.stopped = true;
        this.resetConsumers("prebuffer stopped");
        if (this.restartTimer) {
            clearTimeout(this.restartTimer);
            this.restartTimer = undefined;
        }
        this.killChild();
        this.child = undefined;
        this.subscribers.clear();
    }

    stats() {
        const span = this.fragments.length >= 2
            ? (this.fragments[this.fragments.length - 1].t - this.fragments[0].t) / 1000
            : 0;
        return {
            fragments: this.fragments.length,
            seconds: Math.round(span * 100) / 100,
            haveInit: this.initSegment.length > 0,
            subscribers: this.subscribers.size,
            totalFragments: this.totalFragments,
            restarts: this.restarts,
        };
    }
}

class PrebufferManager {
    /**
     * @param log            Homebridge logger
     * @param ffmpegPath     path to ffmpeg
     * @param rtspBase       go2rtc RTSP base, e.g. rtsp://127.0.0.1:8554
     * @param bufferSeconds  how much history to retain per camera
     */
    constructor(log, ffmpegPath, rtspBase, bufferSeconds) {
        this.log = log;
        this.ffmpegPath = ffmpegPath;
        this.rtspBase = (rtspBase || "rtsp://127.0.0.1:8554").replace(/\/+$/, "");
        this.bufferSeconds = bufferSeconds || DEFAULT_BUFFER_SECONDS;
        this.buffers = new Map();
    }

    /** Stop one camera's ring (HKSV switched off for it) without touching others. */
    release(cameraKey) {
        const buf = this.buffers.get(cameraKey);
        if (buf) {
            buf.stop();
            this.buffers.delete(cameraKey);
        }
    }

    ensure(cameraKey) {
        let buf = this.buffers.get(cameraKey);
        if (!buf) {
            buf = new CameraBuffer(this.log, cameraKey, `${this.rtspBase}/${cameraKey}`,
                this.ffmpegPath, this.bufferSeconds);
            this.buffers.set(cameraKey, buf);
            buf.start();
        }
        return buf;
    }

    /**
     * A Readable delivering [init][history since sinceEpochMs][live...].
     *
     * Subscribe happens before the history snapshot, and the two run in one
     * synchronous block while `publish()` can only run from an async stdout 'data'
     * event -- so no fragment can land between them. That yields neither a gap nor
     * a duplicate. (An earlier comment here claimed duplicates were possible but
     * harmless; that was wrong on both counts, and the ordering must stay
     * synchronous -- inserting an `await` would make the untested duplicate-safety
     * claim load-bearing.)
     *
     * Note `f.t` is stamped when a fragment COMPLETES, so the fragment containing
     * the anchor instant is filtered out: expect up to ~1.67s less history than
     * requested, plus any NTP skew between Google's clock and this host. The
     * pre-roll margin absorbs both.
     *
     * Returns null if the buffer has no init segment yet, so the caller can fall
     * back to dialling go2rtc directly.
     */
    createStream(cameraKey, sinceEpochMs) {
        // M-5a: look up, do NOT ensure(). Implicitly creating the ring here resurrected
        // rings that updateRecordingActive(false) had just released, and they then ran
        // until the next toggle. A missing ring means the caller falls back to dialling
        // go2rtc directly, which is the correct behaviour.
        const buf = this.buffers.get(cameraKey);
        if (!buf) {
            this.log.debug(`[prebuffer:${cameraKey}] no ring for this camera; caller must fall back`);
            return null;
        }
        const queue = [];
        let flowing = false;
        let stream;

        const onFragment = f => {
            // H1 backstop: if the consumer never drains (ffmpeg died before its stdin
            // was piped, or was killed while the reader was down so no write ever
            // raised EPIPE), this queue would otherwise grow at ~150KB/s forever.
            if (queue.length >= MAX_QUEUED_FRAGMENTS) {
                this.log.error(`[prebuffer:${cameraKey}] consumer not draining (${queue.length} fragments queued); destroying it`);
                try {
                    stream.destroy(new Error("prebuffer consumer stalled"));
                }
                catch (e) { /* fall through */ }
                return;
            }
            queue.push(f);
            if (flowing) {
                pump();
            }
        };
        const pump = () => {
            while (queue.length) {
                const chunk = queue.shift();
                if (!stream.push(chunk)) {
                    flowing = false;
                    return;
                }
            }
            flowing = true;
        };

        buf.subscribers.add(onFragment);
        const hist = buf.history(sinceEpochMs);
        if (!hist) {
            buf.subscribers.delete(onFragment);
            this.log.warn(`[prebuffer:${cameraKey}] no init segment yet, caller must fall back`);
            return null;
        }

        stream = new Readable({
            read() {
                flowing = true;
                pump();
            },
        });
        buf.activeStreams.add(stream);
        // 'close' fires on destroy() from any direction; belt-and-braces on 'error'
        // too, since a destroy(err) emits both and the Set must not retain either.
        const cleanup = () => {
            buf.subscribers.delete(onFragment);
            buf.activeStreams.delete(stream);
            queue.length = 0;
        };
        stream.once("close", cleanup);
        stream.once("error", cleanup);

        queue.unshift(...hist.fragments);
        queue.unshift(hist.init);

        const recovered = hist.oldestAvailable
            ? Math.round((Date.now() - Math.max(hist.oldestAvailable, sinceEpochMs)) / 100) / 10
            : 0;
        this.log.info(`[prebuffer:${cameraKey}] serving ${hist.fragments.length} buffered fragments (~${recovered}s of history)`);
        return stream;
    }

    stats() {
        const out = {};
        for (const [k, v] of this.buffers) {
            out[k] = v.stats();
        }
        return out;
    }

    stopAll() {
        for (const buf of this.buffers.values()) {
            buf.stop();
        }
        this.buffers.clear();
    }
}

// StreamingDelegate is constructed per camera, but the buffers must be shared and
// long-lived (they run whether or not a recording is in progress), so the manager
// is a module singleton rather than per-delegate state.
let _manager;

function getPrebufferManager(log, ffmpegPath, rtspBase, bufferSeconds) {
    if (!_manager) {
        _manager = new PrebufferManager(log, ffmpegPath, rtspBase, bufferSeconds);
    }
    return _manager;
}

module.exports = { PrebufferManager, getPrebufferManager };
