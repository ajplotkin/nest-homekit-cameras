/*
 * End-to-end test for the HKSV prebuffer ring (dist/PrebufferManager.js).
 *
 * Usage:
 *   node scripts/test-prebuffer-e2e.js <plugin-dist-dir> <out.mp4> [rtsp-base] [stream-name]
 *
 * e.g.  node scripts/test-prebuffer-e2e.js \
 *         /path/to/homebridge-google-nest-sdm/dist /tmp/clip.mp4 \
 *         rtsp://127.0.0.1:8554 front_door
 *
 * With an rtsp-base it tests against a real restreamer (go2rtc/MediaMTX). Without
 * one it spawns a synthetic source, which needs an ffmpeg whose RTSP muxer supports
 * `-rtsp_flags listen` -- ffmpeg 8.x does NOT, so prefer the real-restreamer form.
 *
 * THE POINT OF THE MEASUREMENT: it fills the ring, then asks for history anchored in
 * the past and records a SHORT live window. The resulting clip must be materially
 * LONGER than that window -- the difference IS the recovered pre-roll. A ring that
 * silently does nothing produces a clip the same length as the window and fails,
 * which is why the assertion is written that way rather than "a file was produced".
 *
 * Also asserts the consumer is released on destroy, since a leaked subscription
 * keeps the ring queueing at ~150KB/s for a recording that has already ended.
 */
const {spawn} = require('child_process');
const fs = require('fs');
const path = require('path');

const DIST = process.argv[2];
const OUT = process.argv[3];
const RTSP_BASE = process.argv[4];           // e.g. rtsp://your-pi.local:8554
const KEY = process.argv[5] || 'test';
const PORT = 8554;

const BUFFER_FOR_MS = 22000;   // let the ring fill
const LIVE_WINDOW_MS = 5000;   // how long we actually record for
const ANCHOR_BACK_MS = 10000;  // how far back we ask history to reach

const {getPrebufferManager} = require(path.join(DIST, 'PrebufferManager.js'));

const log = {
    info: (...a) => console.log('  [info]', ...a),
    warn: (...a) => console.log('  [WARN]', ...a),
    error: (...a) => console.log('  [ERR ]', ...a),
    debug: () => {},
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

// When an external RTSP base is supplied we test against that (a real restreamer).
// Otherwise fall back to spawning a local synthetic source.
const server = RTSP_BASE ? null : spawn('ffmpeg', [
    '-hide_banner', '-loglevel', 'error',
    '-re',
    '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=15',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
    '-profile:v', 'main', '-pix_fmt', 'yuv420p', '-g', '30',
    '-c:a', 'aac', '-b:a', '64k',
    '-f', 'rtsp', '-rtsp_flags', 'listen',
    `rtsp://127.0.0.1:${PORT}/${KEY}`,
], {stdio: ['ignore', 'ignore', 'pipe']});
if (server) server.stderr.on('data', d => {
    const s = d.toString().trim();
    if (s) console.log('  [rtsp-server]', s.split('\n')[0]);
});

let failures = 0;
const check = (name, ok, detail) => {
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -- ' + detail : ''}`);
    if (!ok) failures++;
};

(async () => {
    await sleep(1500); // let the listener bind

    const mgr = getPrebufferManager(log, 'ffmpeg', RTSP_BASE || `rtsp://127.0.0.1:${PORT}`, 20);
    mgr.ensure(KEY);

    console.log(`\n  filling the ring for ${BUFFER_FOR_MS / 1000}s ...`);
    await sleep(BUFFER_FOR_MS);

    const stats = mgr.stats()[KEY];
    console.log('  ring stats:', JSON.stringify(stats));
    check('ring produced an init segment', !!stats && stats.haveInit);
    check('ring holds fragments', !!stats && stats.fragments > 0, `${stats && stats.fragments} fragments`);
    check('ring spans real time', !!stats && stats.seconds > 5, `${stats && stats.seconds}s`);
    check('reader did not thrash', !!stats && stats.restarts === 0, `${stats && stats.restarts} restarts`);

    if (!stats || !stats.fragments) {
        console.log('\n  ring never filled; aborting');
        mgr.stopAll();
        if (server) server.kill('SIGKILL');
        process.exit(1);
    }

    // Ask for history reaching ANCHOR_BACK_MS into the past, exactly as
    // StreamingDelegate does with Google's event timestamp.
    const anchor = Date.now();
    const stream = mgr.createStream(KEY, anchor - ANCHOR_BACK_MS);
    check('createStream returned a stream', !!stream);
    if (!stream) {
        mgr.stopAll();
        if (server) server.kill('SIGKILL');
        process.exit(1);
    }

    // Consume it the way HksvStreamer does: pipe into ffmpeg on stdin.
    const rec = spawn('ffmpeg', [
        '-hide_banner', '-loglevel', 'error',
        '-f', 'mp4', '-i', 'pipe:0',
        '-c', 'copy',
        '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
        '-y', OUT,
    ], {stdio: ['pipe', 'ignore', 'pipe']});

    let recErr = '';
    rec.stderr.on('data', d => { recErr += d.toString(); });
    rec.stdin.on('error', () => { try { stream.destroy(); } catch (e) {} });
    stream.once('close', () => {
        try { if (rec.stdin && !rec.stdin.destroyed) rec.stdin.end(); } catch (e) {}
    });
    stream.pipe(rec.stdin);

    const recordStart = Date.now();
    console.log(`\n  recording a ${LIVE_WINDOW_MS / 1000}s live window ...`);
    await sleep(LIVE_WINDOW_MS);

    const liveElapsed = Date.now() - recordStart;
    stream.destroy();
    await new Promise(r => rec.on('exit', r));

    if (recErr.trim()) console.log('  [recorder stderr]', recErr.trim().split('\n')[0]);

    // The decisive measurement.
    const probe = spawn('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-show_entries', 'stream=codec_name,codec_type',
        '-of', 'json', OUT,
    ], {stdio: ['ignore', 'pipe', 'pipe']});
    let pout = '';
    probe.stdout.on('data', d => { pout += d.toString(); });
    await new Promise(r => probe.on('exit', r));

    let info;
    try { info = JSON.parse(pout); } catch (e) { info = null; }
    const duration = info && info.format ? parseFloat(info.format.duration) : 0;
    const codecs = info && info.streams ? info.streams.map(s => `${s.codec_type}:${s.codec_name}`) : [];
    const size = fs.existsSync(OUT) ? fs.statSync(OUT).size : 0;

    console.log(`\n  clip: ${OUT}  ${size} bytes  duration ${duration}s  streams [${codecs.join(', ')}]`);
    console.log(`  live window was ${(liveElapsed / 1000).toFixed(1)}s`);

    check('clip is non-empty', size > 10000, `${size} bytes`);
    check('clip has video and audio', codecs.length === 2, codecs.join(', '));
    check('clip is LONGER than the live window (pre-roll recovered)',
        duration > (liveElapsed / 1000) + 2,
        `${duration}s vs ${(liveElapsed / 1000).toFixed(1)}s live -> ~${(duration - liveElapsed / 1000).toFixed(1)}s recovered`);

    // Upper bound, and it is not redundant. The lower bound alone is satisfied by a ring
    // that IGNORES the anchor and dumps its entire retention -- which would look like a
    // pass while silently serving minutes-old footage as if it were the trigger moment.
    // We asked for ANCHOR_BACK_MS of history over a LIVE_WINDOW_MS recording, so anything
    // beyond that plus a fragment of slack means `history(sinceEpochMs)` did not filter.
    const expectedMax = (ANCHOR_BACK_MS + LIVE_WINDOW_MS) / 1000 + 4;
    check('clip is not LONGER than requested (anchor was honoured)',
        duration <= expectedMax,
        `${duration}s vs ${expectedMax}s max (ring retains ${20}s, so an unanchored dump would exceed this)`);

    // Consumers must be released, or a dead recording pins the ring open.
    const after = mgr.stats()[KEY];
    check('consumer released on destroy', after.subscribers === 0, `${after.subscribers} subscriber(s) still attached`);

    mgr.stopAll();
    if (server) server.kill('SIGKILL');

    await sleep(500);
    console.log(`\n  ${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
    process.exit(failures === 0 ? 0 : 1);
})();
