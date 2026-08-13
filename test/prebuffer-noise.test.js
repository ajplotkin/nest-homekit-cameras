// Off-box test for prebuffer log noise from a camera switched off in the Home app.
// Fakes ffmpeg, the clock and timers, then drives real retry cycles against the real module.
//
//   node test/prebuffer-noise.test.js [hours]      # default 6; exits non-zero on failure
//
// Three rounds of review shaped this file. What it got wrong before, so it is not undone:
//   1. it counted only lines containing "ring never started", so the per-retry "starting
//      reader" / "reader exited" debug lines were invisible -- and those are the bulk of the
//      noise on a deployment that writes debug to the log;
//   2. it pushed both stderr lines as ONE chunk. Real ffmpeg writes them separately, which
//      spends a per-chunk budget twice as fast. It emits two chunks;
//   3. it had NO assertions and always exited 0, while the commit claimed mutations made it
//      fail. It asserts now -- and the assertions are EXACT counts, not ceilings. A ceiling
//      with slack in it let two real regressions through review (a loud phase widened from 3
//      to 4 spawns, and a missing clock stamp that fired the first summary an hour early):
//      both fit inside two lines of headroom. Exact counts leave nowhere to hide.
//   4. it only covered a camera that was ALREADY off at startup. The throttle used to key on
//      "has never produced", so a camera that streamed and was THEN switched off -- routine
//      with Google Home's Home/Away Assist -- never throttled at all. Scenario B pins that.
const { EventEmitter } = require("events");
const { Readable } = require("stream");

let NOW = 1_700_000_000_000;
const timers = [];
const realSetTimeout = global.setTimeout;
global.setTimeout = (fn, ms) => { const t = { fn, at: NOW + (ms || 0), cleared: false }; timers.push(t); return { unref(){}, _t: t }; };
global.clearTimeout = h => { if (h && h._t) h._t.cleared = true; };
global.setInterval = () => ({ unref(){} });
global.clearInterval = () => {};
Date.now = () => NOW;
function advance(ms) {
  const target = NOW + ms;
  for (;;) {
    const due = timers.filter(t => !t.cleared && t.at <= target).sort((a,b) => a.at - b.at)[0];
    if (!due) break;
    NOW = due.at; due.cleared = true; due.fn();
  }
  NOW = target;
}

const cp = require("child_process");
let spawnCount = 0;
cp.spawn = function fakeSpawn() {
  spawnCount++;
  const child = new EventEmitter();
  child.pid = 1000 + spawnCount;
  child.stdout = new Readable({ read(){} });
  child.stderr = new Readable({ read(){} });
  child.kill = () => {};
  realSetTimeout(() => {                      // TWO chunks, as real ffmpeg emits
    child.stderr.push(Buffer.from("[rtsp @ 0x7f81a3d020] method DESCRIBE failed: 404 Not Found\n"));
    child.stderr.push(Buffer.from("rtsp://127.0.0.1:8554/living_room: Server returned 404 Not Found\n"));
    child.emit("exit", 1, null);
  }, 0);
  return child;
};

const all = [];                                // EVERY log line, whatever the level, with its time
const rec = lvl => (...a) => all.push({ lvl, msg: a.join(" "), t: NOW });
const log = { warn: rec("warn"), debug: rec("debug"), error: rec("error"), info: rec("info") };
const MODULE = require("path").join(__dirname, "..", "patches", "homebridge-plugin", "new-files", "PrebufferManager.js");
// getPrebufferManager caches one manager per module instance, so a second run() would reuse
// the first run's already-throttled buffer and silently observe nothing. Drop it from the
// require cache to get genuinely fresh state. (Caught by the growth check reading negative --
// two runs sharing a manager is not a subtle failure once something actually asserts.)
function freshModule() {
  delete require.cache[require.resolve(MODULE)];
  return require(MODULE);
}

const LOUD = 3, CHUNKS = 2, CAM = "living_room";
const T0 = NOW;

// `produceAfterMin`: null = camera off from the start (scenario A).
// A number = let it stream one fragment that many minutes in, then it goes dark (scenario B).
async function run(hours, produceAfterMin) {
  all.length = 0; spawnCount = 0; timers.length = 0; NOW = T0;
  const { getPrebufferManager } = freshModule();
  const mgr = getPrebufferManager(log, "/bin/false", "rtsp://127.0.0.1:8554", 15);
  const buf = mgr.ensure(CAM);
  for (let i = 0; i < hours * 60; i++) {
    advance(60_000);
    if (produceAfterMin !== null && i === produceAfterMin) buf.publish(Buffer.alloc(8));
    await new Promise(r => realSetTimeout(r, 0));
  }
  const lines = all.filter(l => l.msg.includes(`prebuffer:${CAM}`));
  const notice = lines.filter(l => l.msg.includes("output suppressed"));
  const summary = lines.filter(l => l.msg.includes("still not started after"));
  return {
    hours, spawns: spawnCount,
    totalLines: lines.length,
    // Match the per-chunk warning specifically. "ring not started" alone also matches the
    // suppression notice, which quotes it -- that inflated this count by one.
    loudWarns: lines.filter(l => l.msg.includes("ffmpeg (ring not started)")).length,
    debug: lines.filter(l => l.lvl === "debug").length,
    notices: notice.length,
    summaries: summary.length,
    // Minutes from the suppression notice to the FIRST summary. Pins the hour gate itself:
    // drop the clock stamp taken at the notice and this collapses to ~0 while every count
    // stays within a line or two of correct.
    firstSummaryGapMin: (notice.length && summary.length)
      ? Math.round((summary[0].t - notice[0].t) / 60000) : null,
    lastAttemptCount: summary.length
      ? +(/still not started after (\d+) attempts/.exec(summary[summary.length - 1].msg) || [])[1] : null,
  };
}

// Assertions every scenario must satisfy, none of them fitted to observed output.
function check(name, r, long) {
  const fail = [];
  if (r.notices !== 1) fail.push(`notices ${r.notices} != 1`);
  if (r.totalLines !== r.loudWarns + r.debug + r.notices + r.summaries)
    fail.push(`totalLines ${r.totalLines} is not the sum of its parts (unaccounted output)`);
  // The summary is the operator's only remaining signal, so it must keep coming...
  if (r.summaries < r.hours - 2) fail.push(`summaries ${r.summaries} < ${r.hours - 2} (operator loses visibility)`);
  // ...but no more often than hourly.
  if (r.summaries > r.hours) fail.push(`summaries ${r.summaries} > ${r.hours} (more often than hourly)`);
  if (r.firstSummaryGapMin === null) fail.push(`no summary followed the notice`);
  else if (r.firstSummaryGapMin < 55) fail.push(`first summary came ${r.firstSummaryGapMin}min after the notice, expected ~60 (hour gate not honoured)`);
  if (r.lastAttemptCount !== null && Math.abs(r.lastAttemptCount - r.spawns) > r.spawns * 0.15)
    fail.push(`summary says ${r.lastAttemptCount} attempts but there were ${r.spawns} spawns`);
  // THE central property, and the one that was actually broken: once the throttle engages,
  // the ONLY thing that may grow with elapsed time is the hourly summary. Stated as a
  // difference between two run lengths, so it needs no hand-counted constant -- which is
  // what matters, because a ceiling with slack in it is what let two regressions through
  // review. Under the pre-fix code scenario B grew ~49 lines/hour and this fails loudly.
  const extraLines = long.totalLines - r.totalLines;
  const extraSummaries = long.summaries - r.summaries;
  if (extraLines !== extraSummaries)
    fail.push(`over ${long.hours - r.hours}h more, output grew by ${extraLines} lines but only ${extraSummaries} were summaries `
            + `(${extraLines - extraSummaries} lines/period of unthrottled noise)`);
  console.log(`${name}: ` + JSON.stringify(r));
  console.log(`${name}: ${long.hours}h -> ` + JSON.stringify({ totalLines: long.totalLines, summaries: long.summaries }));
  return fail.map(f => `${name}: ${f}`);
}

const HOURS = Number(process.argv[2] || 6);
(async () => {
  const fail = [];
  // A. Off before Homebridge started: never produced, so every spawn is dry from the first
  //    and the loud phase is exactly the first LOUD spawns.
  const a = await run(HOURS, null), aLong = await run(HOURS * 4, null);
  if (a.loudWarns !== LOUD * CHUNKS)
    fail.push(`A/off-at-startup: loudWarns ${a.loudWarns} != ${LOUD * CHUNKS} (loud phase is not exactly ${LOUD} spawns)`);
  if (a.debug !== LOUD * 2)
    fail.push(`A/off-at-startup: debug ${a.debug} != ${LOUD * 2} ("starting reader" + "reader exited" for each loud spawn)`);
  fail.push(...check("A/off-at-startup", a, aLong));
  // B. Streamed, then switched off -- the case the "has never produced" version of this
  //    throttle missed entirely. Its exact composition depends on where in the retry ramp
  //    the fragment lands, so it is pinned on the invariants above rather than on counts.
  fail.push(...check("B/off-after-streaming", await run(HOURS, 1), await run(HOURS * 4, 1)));
  if (fail.length) { console.error("FAIL:\n  " + fail.join("\n  ")); process.exit(1); }
  console.log("PASS");
})();
