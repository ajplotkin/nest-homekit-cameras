// Off-box test for the plugin's stream-key names (patches/homebridge-plugin/new-files/StreamKey.js).
//
//   node test/stream-key.test.js [path/to/StreamKey.js] [--plugin DIR]   # exits non-zero on failure
//
// Uses the same fixture as test/stream-key.test.py, which runs nest-go2rtc-sync.py. Both sides
// must derive the same name from the same devices: the plugin dials rtsp://127.0.0.1:8554/<key>
// and reads nest-snaps/<key>.jpg, and only the sync script decides which keys go2rtc serves.
//
// Each fixture case is checked as listed and with the device list reversed, so a rule that
// depends on the order Google lists devices in fails.
//
// --plugin DIR: also run the PATCHED plugin's own SmartDeviceManagement.list_devices() from
// DIR (a homebridge-google-nest-sdm 1.1.25 install with this repo's patches and new files
// applied and its dependencies installed, e.g. inside the Homebridge container), against a
// fake SDM client. That checks the wiring in Api.js, not just this module: the Device objects
// it returns must carry the unique names, so getDisplayName() gives HomeKit two different
// accessory names and every go2rtc path derived from displayName differs.
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const pi = args.indexOf("--plugin");
const pluginDir = pi >= 0 ? path.resolve(args.splice(pi, 2)[1]) : null;
const modPath = path.resolve(args[0] || path.join(__dirname, "..", "patches", "homebridge-plugin", "new-files", "StreamKey.js"));
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "sdm-devices.json"), "utf8"));

let failed = 0;
function check(ok, what) {
    console.log((ok ? "  ok   " : "  FAIL ") + what);
    if (!ok) failed++;
}
const full = id => "enterprises/test-project/devices/" + id;
const expectedMap = c => Object.fromEntries(Object.entries(c.expect_names).map(([id, n]) => [full(id), n]));
const sorted = o => JSON.stringify(Object.fromEntries(Object.entries(o).sort()));

let StreamKey;
try {
    StreamKey = require(modPath);
} catch (e) {
    console.log("FAIL: cannot load " + modPath + ": " + e.message);
    process.exit(1);
}

for (const c of fixtures.cases) {
    console.log(c.name);
    for (const [label, devs] of [["as listed", c.devices], ["reversed", [...c.devices].reverse()]]) {
        const got = Object.fromEntries(StreamKey.uniqueDisplayNames(devs));
        check(sorted(got) === sorted(expectedMap(c)), label + ": names " + JSON.stringify(got));
    }
    // applyUniqueNames must leave devices outside the map (thermostats, room-less cameras)
    // exactly as the stock constructor set them.
    const objs = c.devices.map(d => ({ device: d, displayName: "STOCK:" + d.name }));
    StreamKey.applyUniqueNames(objs);
    const exp = expectedMap(c);
    check(objs.every(o => o.displayName === (exp[o.device.name] !== undefined ? exp[o.device.name] : "STOCK:" + o.device.name)),
        "applyUniqueNames sets only the mapped devices");
}

if (pluginDir) {
    console.log("patched plugin at " + pluginDir + ": Api.js list_devices()");
    const { SmartDeviceManagement } = require(path.join(pluginDir, "dist", "sdm", "Api.js"));
    const run = async () => {
        for (const c of fixtures.cases) {
            const fake = {
                subscribed: true, projectId: "test-project",
                log: { debug() {}, info() {}, warn() {}, error(m) { console.log("    plugin error: " + m); } },
                smartdevicemanagement: { enterprises: { devices: { list: async () => ({ data: { devices: c.devices } }) } } },
            };
            const devs = await SmartDeviceManagement.prototype.list_devices.call(fake);
            const exp = expectedMap(c);
            const got = {};
            for (const d of devs || [])
                if (exp[d.getName()] !== undefined) got[d.getName()] = d.displayName;
            check(sorted(got) === sorted(exp), c.name + ": Device.displayName " + JSON.stringify(got));
            const cams = (devs || []).filter(d => /Camera|Doorbell|Display/.test(d.constructor.name) && d.displayName);
            const hk = cams.map(d => d.getDisplayName());
            check(new Set(hk).size === hk.length, "  HomeKit names unique: " + JSON.stringify(hk));
        }
    };
    run().then(done, e => { console.log("FAIL: " + (e && e.stack || e)); process.exit(1); });
} else {
    done();
}

function done() {
    console.log();
    if (failed) {
        console.log("FAILED: " + failed + " check(s)");
        process.exit(1);
    }
    console.log("all checks passed");
}
