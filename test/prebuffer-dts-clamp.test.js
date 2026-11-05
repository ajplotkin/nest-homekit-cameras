// Off-box test for the reader's stderr restart rules: a burst of ffmpeg "Non-monotonic DTS"
// warnings, and an RTP "bad cseq" line, must restart the reader whatever ffmpeg version wrote them.
//
//   node test/prebuffer-dts-clamp.test.js [path/to/PrebufferManager.js]   # exits non-zero on failure
//
// Why it exists: ffmpeg reworded the DTS warning twice, and the rule matched only the older text.
//   6.0   "Non-monotonous DTS in output stream 0:0; previous: ..."
//   6.1   "Non-monotonic DTS in output stream 0:0; previous: ..."
//   7.0+  "Non-monotonic DTS; previous: ..."   (fftools/ffmpeg_mux.c, still the text in 8.0)
// The bundled ffmpeg-for-homebridge 2.1.1 is 6.0, so a deployment on it never noticed; 2.2.x
// ships 8.0. The 7+ wording in the wild: go2rtc#2404 (Frigate's ffmpeg 8.0:
// "[vost#0:0/copy] Non-monotonic DTS; previous: 4294487443, ...").
//
// ffmpeg emits each DTS warning as two av_log calls. Most cases feed them as separate chunks, so
// the match must work on the first fragment alone. Real chunking is up to the pipe and Node, which
// can merge many warnings into one 'data' event, so one case sends a whole burst as a single chunk.
// The rule must count warnings, not chunks.
//
// The negative cases matter as much as the positive ones: a pattern loosened to "DTS" passes every
// positive case, and only the "Invalid DTS" case catches it. Positive bursts are exactly the
// threshold (20) and the below-threshold case is 19, so `>=` turned into `>` fails too.
const { EventEmitter } = require("events");
const { Readable } = require("stream");
const path = require("path");

const MODULE = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(__dirname, "..", "patches", "homebridge-plugin", "new-files", "PrebufferManager.js");

let NOW = 1_700_000_000_000;
Date.now = () => NOW;

const cp = require("child_process");
let current = null;
cp.spawn = function fakeSpawn() {
  const child = new EventEmitter();
  child.pid = 4242;
  child.stdout = new Readable({ read(){} });
  child.stderr = new Readable({ read(){} });
  child.killed = 0;
  child.kill = () => { child.killed++; };      // never exits, so the manager does not respawn
  current = child;
  return child;
};

const log = { warn(){}, debug(){}, error(){}, info(){} };

function freshModule() {
  delete require.cache[require.resolve(MODULE)];
  return require(MODULE);
}

const tick = () => new Promise(r => setImmediate(r));

async function freshReader() {
  current = null;
  NOW = 1_700_000_000_000;
  const { getPrebufferManager } = freshModule();
  getPrebufferManager(log, "/bin/false", "rtsp://127.0.0.1:8554", 15).ensure("front_door");
  await tick();
  if (!current) throw new Error("ensure() did not spawn a reader");
  return current;
}

async function push(child, text) {
  child.stderr.push(Buffer.from(text));
  await tick();
}

const TAIL = "changing to {n}. This may result in incorrect timestamps in the output file.\n";
const W60 = "[mp4 @ 0x5581] Non-monotonous DTS in output stream 0:0; previous: 9000, current: {n}; ";
const W61 = "[mp4 @ 0x5581] Non-monotonic DTS in output stream 0:0; previous: 9000, current: {n}; ";
const W7 = "[vost#0:0/copy @ 0x5581] Non-monotonic DTS; previous: 9000, current: {n}; ";
const W8 = "[vost#0:0/copy] Non-monotonic DTS; previous: 4294487443, current: {n}; ";
const fill = (s, i) => s.replace(/\{n\}/g, String(1000 + i));

// `count` warnings, each as its two av_log fragments, all at the same instant.
const split = (head, count, tail = TAIL) => async c => {
  for (let i = 0; i < count; i++) {
    await push(c, fill(head, i));
    if (tail) await push(c, fill(tail, i));
  }
};

const CASES = [
  // [name, driver, expect restart]
  ["ffmpeg 6.0 burst of 20", split(W60, 20), true],
  ["ffmpeg 6.1 burst of 20", split(W61, 20), true],
  ["ffmpeg 7+ burst of 20", split(W7, 20), true],
  ["ffmpeg 8 burst of 20 (Frigate prefix)", split(W8, 20), true],
  ["ffmpeg 7+ burst of 20 in ONE chunk", async c => {
    let s = ""; for (let i = 0; i < 20; i++) s += fill(W7, i) + fill(TAIL, i);
    await push(c, s);
  }, true],
  ["ffmpeg 7+ 19 warnings (below threshold)", split(W7, 19), false],
  ["ffmpeg 7+ 19, then 1 more 11 s later (outside the window)", async c => {
    await split(W7, 19)(c); NOW += 11_000; await split(W7, 1)(c);
  }, false],
  ["unrelated Invalid DTS burst of 25", split("[vost#0:0/copy @ 0x5581] Invalid DTS: {n} PTS: {n}, replacing by guess\n", 25, ""), false],
  ["bad cseq, decimal-looking PT (PT=60)", async c => {
    await push(c, "[rtsp @ 0x5581] RTP: PT=60: bad cseq 1a2b expected=0042\n");
  }, true],
  ["bad cseq, hex PT with a letter (PT=6f)", async c => {
    await push(c, "[rtsp @ 0x5581] RTP: PT=6f: bad cseq 1a2b expected=0042\n");
  }, true],
];

(async () => {
  const fail = [];
  for (const [name, drive, want] of CASES) {
    const c = await freshReader();
    await drive(c);
    const got = c.killed > 0;
    console.log(`${got === want ? "ok  " : "FAIL"} ${name}: ${got ? "restarted" : "kept running"}`);
    if (got !== want) fail.push(name);
  }
  if (fail.length) {
    console.log(`\n${fail.length} case(s) failed against ${MODULE}`);
    process.exit(1);
  }
  console.log(`\nall ${CASES.length} cases passed against ${MODULE}`);
  process.exit(0);
})().catch(e => { console.error(e); process.exit(2); });
