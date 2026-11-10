#!/usr/bin/env python3
"""Off-box test for scripts/nest-go2rtc-sync.py: the go2rtc stream keys it writes.

    python3 test/stream-key.test.py [path/to/nest-go2rtc-sync.py]   # exits non-zero on failure

Runs the real script, unmodified, with urllib's urlopen replaced by a fake that serves the
devices in test/fixtures/sdm-devices.json, so it needs no network and no credentials. The
same fixture drives test/stream-key.test.js, which checks the plugin side (StreamKey.js).
The two sides must derive the same key from the same devices, or a camera's tile dials an
RTSP path that go2rtc does not serve.

What it checks, per fixture case and again with the device list reversed (the rule must not
depend on the order Google lists devices in):
  * which device each stream key written to go2rtc.yaml dials (its nest: device_id), against
    the expected display name of that device, slugged as the plugin slugs it. A key on the
    wrong camera would show one camera's video on another camera's tile;
  * for the one-camera-per-room case, that the whole file is byte-identical to the golden
    copy in test/fixtures/, which was produced by the script BEFORE two-cameras-per-room
    support. An existing install's keys, and so its HomeKit tiles, must not move.
It also checks that the script can write --out into a directory that does not exist yet
(install.sh --image on a fresh machine died there with FileNotFoundError).
"""
import io, json, os, re, runpy, sys, tempfile, urllib.parse, urllib.request
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "scripts", "nest-go2rtc-sync.py")
FIXTURES = json.load(open(os.path.join(HERE, "fixtures", "sdm-devices.json"), encoding="utf-8"))

HB_CONFIG = {"platforms": [{"platform": "homebridge-google-nest-sdm", "clientId": "test-client",
                            "clientSecret": "test-secret", "refreshToken": "test-refresh",
                            "projectId": "test-project"}]}


class FakeResponse(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): self.close()


def run_sync(devices, out_path, extra_args=()):
    """Run the sync script against `devices`; return (exit_code, stdout)."""
    def fake_urlopen(req, data=None, timeout=None):
        url = req if isinstance(req, str) else req.full_url
        if url.startswith("https://oauth2.googleapis.com/token"):
            return FakeResponse(json.dumps({"access_token": "fake"}).encode())
        if "/devices" in url:
            return FakeResponse(json.dumps({"devices": devices}).encode())
        raise AssertionError("unexpected URL " + url)

    with tempfile.TemporaryDirectory() as td:
        cfg = os.path.join(td, "config.json")
        json.dump(HB_CONFIG, open(cfg, "w"))
        argv = [SCRIPT, "--hb-config", cfg, "--out", out_path, *extra_args]
        real_urlopen, real_argv = urllib.request.urlopen, sys.argv
        urllib.request.urlopen, sys.argv = fake_urlopen, argv
        buf, code = io.StringIO(), 0
        try:
            with redirect_stdout(buf):
                runpy.run_path(SCRIPT, run_name="__main__")
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        except Exception as e:  # the FileNotFoundError install.sh hit, for one
            buf.write("\nEXCEPTION: %r\n" % (e,))
            code = 99
        finally:
            urllib.request.urlopen, sys.argv = real_urlopen, real_argv
        return code, buf.getvalue()


def stream_devices(yaml_text):
    """{stream key: device_id its nest: source dials}, or None if there is no streams block."""
    m = re.search(r"^streams:\n(.*?)\n\npreload:", yaml_text, re.S | re.M)
    if not m:
        return None
    out = {}
    for key, query in re.findall(r'^  ([^\s:]+):\n    - "nest:\?([^"]*)"$', m.group(1), re.M):
        out[key] = urllib.parse.parse_qs(query)["device_id"][0]
    return out


def slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


failures = []
def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


for case in FIXTURES["cases"]:
    print(case["name"])
    for label, devs in (("as listed", case["devices"]), ("reversed", list(reversed(case["devices"])))):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "go2rtc.yaml")
            code, stdout = run_sync(devs, out, ["--no-restart"])
            written = open(out).read() if os.path.exists(out) else ""
        got = stream_devices(written)
        # Expected: each listed stream key -> the device whose expected display name slugs to it.
        # This is the plugin's side of the join: it dials rtsp://.../<slug(displayName)>.
        want = {slug(n): i for i, n in case["expect_names"].items() if slug(n) in case["expect_streams"]}
        check(code == 0 and got == want and sorted(want) == sorted(case["expect_streams"]),
              "%s: key -> device %s (exit %s)%s" % (label, got, code,
              "" if got else " -- output: " + stdout.strip().splitlines()[-1] if stdout.strip() else ""))
        if case.get("golden") and label == "as listed":
            golden = open(os.path.join(HERE, "fixtures", case["golden"])).read()
            check(written == golden, "go2rtc.yaml byte-identical to fixtures/" + case["golden"])

print("writing --out into a directory that does not exist yet")
with tempfile.TemporaryDirectory() as td:
    out = os.path.join(td, "fresh", "go2rtc", "go2rtc.yaml")
    code, stdout = run_sync(FIXTURES["cases"][0]["devices"], out, ["--no-restart"])
    check(code == 0 and os.path.exists(out), "exit %s, file written: %s%s" % (
        code, os.path.exists(out), "" if code == 0 else " -- " + stdout.strip().splitlines()[-1]))
    if os.path.exists(out):
        check(oct(os.stat(out).st_mode & 0o777) == "0o600", "written 0600 (it holds a refresh token)")

print()
if failures:
    print("FAILED: %d check(s)" % len(failures))
    sys.exit(1)
print("all checks passed")
