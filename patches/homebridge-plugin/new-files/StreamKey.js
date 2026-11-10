"use strict";
// Gives every Nest camera-type device a display name that is unique by stream key, so two
// cameras in one Google Home room no longer share a go2rtc stream, a snapshot file and a
// HomeKit name.
//
// The plugin keys everything go2rtc-related on Device.displayName, slugged (lowercase, every
// run of other characters -> "_"): the RTSP path rtsp://127.0.0.1:8554/<key> for live view,
// recording and the prebuffer, and /homebridge/nest-snaps/<key>.jpg for snapshots. Stock
// sets displayName to the SDM room name, so two cameras in "Living Room" both became
// living_room, both dialled the same stream and both showed as "Living Room Camera".
//
// The rule, which scripts/nest-go2rtc-sync.py display_names() MUST match exactly (it writes
// the go2rtc.yaml keys these paths have to hit; test/stream-key.test.js and
// test/stream-key.test.py run both against test/fixtures/sdm-devices.json):
//   * the only camera-type device in its room (rooms compared by slug) keeps the room name,
//     so an install with one camera per room keeps every key it already had;
//   * 2+ in one room -> "<room> <customName>" when its customName's slug is non-empty and
//     unique among them, else "<room> <last 6 characters of the device id>";
//   * if one of those 2+-per-room names still shares a slug with any other name, in any
//     room, it -> "<room> <device id>" (room "Hall" + customName "Cam" against a room called
//     "Hall Cam"). A camera alone in its room is never renamed by this step, so its key
//     cannot change because of cameras in OTHER rooms.
// It depends only on the set of devices, never their order.
//
// Camera-type means every SDM type this plugin turns into a camera accessory: CAMERA,
// DOORBELL and DISPLAY (Display extends Camera). Thermostats never collide with cameras. A
// Nest Hub Max in the same room as a camera therefore counts as a second camera there.
Object.defineProperty(exports, "__esModule", { value: true });
exports.applyUniqueNames = exports.uniqueDisplayNames = exports.slug = exports.CAMERA_TYPES = void 0;
const CAMERA_TYPES = ["CAMERA", "DOORBELL", "DISPLAY"];
exports.CAMERA_TYPES = CAMERA_TYPES;
const SUFFIX_LEN = 6;
function slug(s) {
    return (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}
exports.slug = slug;
const devType = d => String((d && d.type) || "").split(".").pop();
function roomOf(d) {
    const p = ((d && d.parentRelations) || []).find(r => r && r.displayName);
    return p ? p.displayName : undefined;
}
function customName(d) {
    const info = ((d && d.traits) || {})["sdm.devices.traits.Info"] || {};
    return info.customName || "";
}
const deviceId = d => String(d.name).split("/devices/").pop();
function count(list) {
    const m = new Map();
    for (const k of list)
        m.set(k, (m.get(k) || 0) + 1);
    return m;
}
/** Map of SDM device name -> display name, for every camera-type device with a room. */
function uniqueDisplayNames(rawDevices) {
    const groups = new Map();
    for (const d of rawDevices || []) {
        if (!d || !d.name || !CAMERA_TYPES.includes(devType(d)) || !roomOf(d))
            continue;
        // A room name with no ASCII letter or digit slugs to "", so compare such rooms by
        // their raw name: two different ones are not one room. (Same in display_names().)
        const k = slug(roomOf(d)) || "\u0000" + roomOf(d);
        if (!groups.has(k))
            groups.set(k, []);
        groups.get(k).push(d);
    }
    const cand = new Map();
    const byName = new Map();
    const alone = new Set();
    for (const peers of groups.values()) {
        for (const d of peers)
            byName.set(d.name, d);
        if (peers.length === 1) {
            cand.set(peers[0].name, roomOf(peers[0]));
            alone.add(peers[0].name);
            continue;
        }
        const cnCount = count(peers.map(d => slug(customName(d))));
        for (const d of peers) {
            const cn = customName(d);
            const tail = slug(cn) && cnCount.get(slug(cn)) === 1 ? cn : deviceId(d).slice(-SUFFIX_LEN);
            cand.set(d.name, roomOf(d) + " " + tail);
        }
    }
    const slugCount = count([...cand.values()].map(slug));
    const names = new Map();
    for (const [k, n] of cand) {
        const d = byName.get(k);
        names.set(k, alone.has(k) || slugCount.get(slug(n)) === 1 ? n : roomOf(d) + " " + deviceId(d));
    }
    return names;
}
exports.uniqueDisplayNames = uniqueDisplayNames;
/**
 * Sets displayName on each plugin Device whose name had to change. `devices` are the plugin's
 * Device objects; each holds its raw SDM JSON in `.device`. Devices outside the map (no room,
 * not a camera) are left exactly as the stock constructor set them.
 */
function applyUniqueNames(devices) {
    const names = uniqueDisplayNames((devices || []).map(d => d && d.device));
    for (const d of devices || []) {
        const n = d && d.device && names.get(d.device.name);
        if (n !== undefined)
            d.displayName = n;
    }
    return names;
}
exports.applyUniqueNames = applyUniqueNames;
