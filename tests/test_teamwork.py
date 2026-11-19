"""Tests for bin/teamwork against a local mock Teamwork server.

Run from the plugin directory:  python3 -m unittest discover -s tests

The helper runs as a subprocess with HOME, XDG dirs, the key file and the
cache dir all pointed at a temporary directory, so the real keyring and the
real ~/.local/state / ~/.cache are never touched.
"""

import base64
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "bin", "teamwork")
KEY = "twp_TestKey1234567890abcdef"
ME = {"person": {"id": 123, "firstName": "Alex", "lastName": "Example"}}


class Drip:
    """A response body sent a few bytes at a time, `delay` seconds apart."""

    def __init__(self, data, chunk=1, delay=0.2):
        self.data, self.chunk, self.delay = data, chunk, delay


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _handle(self):
        u = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        query = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        rec = {"method": self.command, "path": u.path, "query": query, "body": body,
               "auth": self.headers.get("Authorization")}
        self.server.requests.append(rec)
        route = self.server.routes.get((self.command, u.path))
        if route is None:
            status, payload, headers = 404, {"errors": [{"title": "not found"}]}, {}
        else:
            res = route(rec) if callable(route) else route
            status, payload = res[0], res[1]
            headers = res[2] if len(res) > 2 else {}
        drip = payload if isinstance(payload, Drip) else None
        if drip:
            data = drip.data
        elif isinstance(payload, (dict, list)):
            data = json.dumps(payload).encode()
        elif isinstance(payload, str):
            data = payload.encode()
        else:
            data = payload or b""
        try:
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD" and drip:
                self.wfile.flush()
                for i in range(0, len(data), drip.chunk):
                    self.wfile.write(data[i:i + drip.chunk])
                    self.wfile.flush()
                    time.sleep(drip.delay)
            elif self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle


class MockServer:
    def __init__(self):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        self.httpd.daemon_threads = True
        self.httpd.block_on_close = False
        self.httpd.routes = {}
        self.httpd.requests = []
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.httpd.server_address[1]

    @property
    def routes(self):
        return self.httpd.routes

    @property
    def requests(self):
        return self.httpd.requests

    def calls(self, method=None, path=None):
        return [r for r in self.requests
                if (method is None or r["method"] == method) and (path is None or r["path"] == path)]

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def v3(p):
    return "/projects/api/v3/" + p


def page(list_key, items, has_more=False, included=None):
    return {list_key: items, "included": included or {}, "meta": {"page": {"hasMore": has_more}}}


class Base(unittest.TestCase):
    tz = "Pacific/Auckland"
    now = "2026-11-19T10:00:00Z"   # Thursday 23:00 local (NZDT, UTC+13)

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tw-test-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.keyfile = os.path.join(self.tmp, "state", "tomhayes.teamwork", "api-key")
        self.server = MockServer()
        self.server.routes[("GET", v3("me.json"))] = (200, ME)

    def tearDown(self):
        self.server.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        e = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
            "XDG_STATE_HOME": os.path.join(self.tmp, "xdg-state"),
            "XDG_CACHE_HOME": os.path.join(self.tmp, "xdg-cache"),
            "TEAMWORK_KEY_FILE": self.keyfile,
            "TEAMWORK_CACHE_DIR": os.path.join(self.tmp, "cache"),
            "TEAMWORK_TEST_ALLOW_HTTP": "1",
            "TEAMWORK_TEST_NOW": self.now,
            "TEAMWORK_TEST_TIMEOUT": "2",
            "TZ": self.tz,
            "LANG": "C.UTF-8",
        }
        for k, v in extra.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def run_tw(self, *args, stdin=b"", env=None, site=True):
        argv = [sys.executable, SCRIPT] + list(args)
        if site:
            argv += ["--site", self.server.url]
        p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env or self.env(), timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, b"", "helper wrote to stderr: %r" % p.stderr[:500])
        out = p.stdout.decode()
        self.assertNotIn(KEY, out)
        self.assertEqual(out.count("\n"), 1, "exactly one JSON line expected")
        data = json.loads(out)
        self.assertIsInstance(data, dict)
        self.assertIn("ok", data)
        if not data["ok"]:
            self.assertIn(data.get("code"), {"auth", "network", "config", "api", "usage"})
            self.assertIsInstance(data.get("error"), str)
        return data

    def store_key(self):
        os.makedirs(os.path.dirname(self.keyfile), mode=0o700, exist_ok=True)
        with open(self.keyfile, "w") as f:
            f.write(KEY + "\n")
        os.chmod(self.keyfile, 0o600)

    def assert_error(self, data, code):
        self.assertFalse(data["ok"], data)
        self.assertEqual(data["code"], code, data)


# ------------------------------------------------------------------ key handling

class KeyTests(Base):
    def test_has_key_false_then_true(self):
        self.assertEqual(self.run_tw("has-key", site=False), {"ok": True, "hasKey": False})
        self.store_key()
        self.assertEqual(self.run_tw("has-key", site=False), {"ok": True, "hasKey": True})

    def test_set_key_validates_and_stores_private_file(self):
        d = self.run_tw("set-key", stdin=(KEY + "\n").encode())
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["user"], {"id": 123, "name": "Alex Example"})
        self.assertEqual(d["storage"], "file")
        req = self.server.calls("GET", v3("me.json"))[0]
        self.assertEqual(req["auth"], "Basic " + base64.b64encode((KEY + ":X").encode()).decode())
        with open(self.keyfile) as f:
            self.assertEqual(f.read().strip(), KEY)
        self.assertEqual(stat.S_IMODE(os.stat(self.keyfile).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.keyfile)).st_mode), 0o700)
        # The cache holds the user but never the key.
        for root, _, files in os.walk(os.path.join(self.tmp, "cache")):
            for n in files:
                with open(os.path.join(root, n)) as f:
                    self.assertNotIn(KEY, f.read())

    def test_set_key_rejected_is_not_stored(self):
        self.server.routes[("GET", v3("me.json"))] = (401, {"errors": [{"title": "Unauthorized"}]})
        d = self.run_tw("set-key", stdin=KEY.encode())
        self.assert_error(d, "auth")
        self.assertFalse(os.path.exists(self.keyfile))

    def test_set_key_bad_input(self):
        self.assert_error(self.run_tw("set-key", stdin=b""), "usage")
        self.assert_error(self.run_tw("set-key", stdin=b"has space inside"), "usage")
        self.assert_error(self.run_tw("set-key", stdin=b"x" * 5000), "usage")
        self.assert_error(self.run_tw("set-key", stdin=b"\xff\xfe"), "usage")
        self.assertEqual(self.server.requests, [])

    def test_loose_key_file_is_tightened(self):
        self.store_key()
        os.chmod(self.keyfile, 0o644)
        self.assertTrue(self.run_tw("has-key", site=False)["hasKey"])
        self.assertEqual(stat.S_IMODE(os.stat(self.keyfile).st_mode), 0o600)

    def test_key_file_symlink_is_not_followed(self):
        real = os.path.join(self.tmp, "elsewhere")
        with open(real, "w") as f:
            f.write(KEY + "\n")
        os.makedirs(os.path.dirname(self.keyfile), mode=0o700)
        os.symlink(real, self.keyfile)
        self.assertFalse(self.run_tw("has-key", site=False)["hasKey"])

    def test_key_pasted_as_argument_is_not_echoed(self):
        for argv in (("set-key", KEY), ("start", KEY), ("complete", "1", "--billable", KEY), (KEY,),
                     ("start", "x'" + KEY)):
            d = self.run_tw(*argv)
            self.assert_error(d, "usage")
            self.assertNotIn(KEY, d["error"])
            self.assertNotIn(KEY[4:], json.dumps(d))
        self.assertEqual(self.server.requests, [])

    def test_clear_key(self):
        self.store_key()
        self.assertEqual(self.run_tw("clear-key", site=False), {"ok": True})
        self.assertFalse(os.path.exists(self.keyfile))
        self.assertEqual(self.run_tw("has-key", site=False)["hasKey"], False)

    def test_no_key_status_is_config_error(self):
        d = self.run_tw("status")
        self.assert_error(d, "config")
        self.assertEqual(self.server.requests, [])

    def _fake_secret_tool(self, store_ok=True):
        bindir = os.path.join(self.tmp, "fakebin")
        os.makedirs(bindir, exist_ok=True)
        log = os.path.join(self.tmp, "secret-tool.log")
        vault = os.path.join(self.tmp, "vault")
        script = """#!%s
import json, sys, os
log, vault = %r, %r
data = sys.stdin.buffer.read() if sys.argv[1] == "store" else b""
with open(log, "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "stdin": data.decode()}) + "\\n")
if sys.argv[1] == "store":
    if not %r:
        sys.exit(1)
    open(vault, "wb").write(data)
elif sys.argv[1] == "lookup":
    if not os.path.exists(vault):
        sys.exit(1)
    sys.stdout.buffer.write(open(vault, "rb").read())
elif sys.argv[1] == "clear":
    if os.path.exists(vault):
        os.unlink(vault)
""" % (sys.executable, log, vault, store_ok)
        path = os.path.join(bindir, "secret-tool")
        with open(path, "w") as f:
            f.write(script)
        os.chmod(path, 0o755)
        env = self.env(TEAMWORK_KEY_FILE=None, PATH=bindir + os.pathsep + os.environ.get("PATH", ""))
        return env, log, vault

    def _log(self, log):
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return [json.loads(line) for line in f]

    def test_keyring_store_passes_key_on_stdin_only(self):
        env, log, vault = self._fake_secret_tool()
        d = self.run_tw("set-key", stdin=KEY.encode(), env=env)
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["storage"], "keyring")
        calls = self._log(log)
        store = [c for c in calls if c["argv"][0] == "store"]
        self.assertEqual(len(store), 1)
        self.assertEqual(store[0]["argv"], ["store", "--label=Teamwork API key",
                                            "service", "tomhayes.teamwork", "account", "api-key"])
        self.assertEqual(store[0]["stdin"], KEY)
        for c in calls:
            self.assertNotIn(KEY, " ".join(c["argv"]))
        fallback = os.path.join(self.tmp, "xdg-state", "tomhayes.teamwork", "api-key")
        self.assertFalse(os.path.exists(fallback))
        self.assertTrue(self.run_tw("has-key", site=False, env=env)["hasKey"])
        self.assertEqual(self.run_tw("clear-key", site=False, env=env), {"ok": True})
        self.assertFalse(os.path.exists(vault))
        self.assertFalse(self.run_tw("has-key", site=False, env=env)["hasKey"])

    def test_keyring_failure_falls_back_to_file(self):
        env, log, vault = self._fake_secret_tool(store_ok=False)
        d = self.run_tw("set-key", stdin=KEY.encode(), env=env)
        self.assertEqual(d["storage"], "file")
        fallback = os.path.join(self.tmp, "xdg-state", "tomhayes.teamwork", "api-key")
        self.assertEqual(stat.S_IMODE(os.stat(fallback).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(fallback)).st_mode), 0o700)
        self.assertTrue(self.run_tw("has-key", site=False, env=env)["hasKey"])

    def test_key_file_override_never_calls_secret_tool(self):
        env, log, _ = self._fake_secret_tool()
        env["TEAMWORK_KEY_FILE"] = self.keyfile
        self.run_tw("has-key", site=False, env=env)
        self.run_tw("set-key", stdin=KEY.encode(), env=env)
        self.run_tw("clear-key", site=False, env=env)
        self.assertEqual(self._log(log), [])


# ------------------------------------------------------------------ status

TIMER_RUNNING = {"id": 10, "taskId": 2, "projectId": 900, "running": True, "duration": 600,
                 "lastStartedAt": "2026-11-19T09:50:00Z", "serverTime": "2026-11-19T10:00:00Z",
                 "description": "working", "billable": True, "userId": 123}
TIMER_PAUSED = {"id": 11, "taskId": 5, "projectId": 901, "running": False, "duration": 300,
                "lastStartedAt": "2026-11-18T08:00:00Z", "description": "", "userId": 123}
TIMER_INCLUDED = {
    "tasks": {"2": {"id": 2, "name": "Task Two", "tasklistId": 50},
              "5": {"id": 5, "name": "Task Five", "tasklistId": 51}},
    "tasklists": {"50": {"id": 50, "name": "List A", "projectId": 900},
                  "51": {"id": 51, "name": "List B", "projectId": 901}},
    "projects": {"900": {"id": 900, "name": "Project X"}, "901": {"id": 901, "name": "Project Y"}},
}
TASK_INCLUDED = {
    "tasklists": {"50": {"id": 50, "name": "List A", "projectId": 900},
                  "52": {"id": 52, "name": "List C", "projectId": 902}},
    "projects": {"900": {"id": 900, "name": "Project X"}, "902": {"id": 902, "name": "Project Z"}},
    "timeTotals": {"2": {"loggedMinutes": 120}},
}
MARKUP = '<b>Bold</b> & <img src=x onerror=alert(1)> {{x}} "q" ‮ $(rm -rf ~) `id`'


def entry(i, when, minutes, task=None, user=123, **kw):
    e = {"id": i, "timeLogged": when, "minutes": minutes, "userId": user, "projectId": 900}
    if task:
        e["taskId"] = task
    e.update(kw)
    return e


class StatusTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()
        r = self.server.routes
        r[("GET", v3("me/timers.json"))] = (200, page("timers", [TIMER_RUNNING, TIMER_PAUSED], included=TIMER_INCLUDED))

        def tasks(rec):
            q = rec["query"]
            if "ids" in q:
                ids = set(q["ids"].split(","))
                extra = [{"id": 4, "name": "Beta", "tasklistId": 52, "dueDate": None},
                         {"id": 5, "name": "Task Five", "tasklistId": 52}]
                return 200, page("tasks", [t for t in extra if str(t["id"]) in ids], included=TASK_INCLUDED)
            if q.get("page") == "1":
                return 200, page("tasks", [
                    {"id": 2, "name": "Task Two", "tasklistId": 50, "dueDate": "2026-12-01T00:00:00Z", "estimateMinutes": 90},
                    {"id": 3, "name": "Task Three", "tasklistId": 50, "dueDate": "2026-11-25"},
                    {"id": 6, "name": "Task Six", "tasklistId": 52, "dueDate": "2026-11-20"},
                ], has_more=True, included=TASK_INCLUDED)
            return 200, page("tasks", [
                {"id": 3, "name": "Task Three", "tasklistId": 50, "dueDate": "2026-11-25"},  # duplicate
                {"id": 7, "name": "alpha", "tasklistId": 52, "dueDate": None},
            ], included=TASK_INCLUDED)
        r[("GET", v3("tasks.json"))] = tasks
        r[("GET", v3("time.json"))] = (200, page("timelogs", [
            entry(1, "2026-11-19T09:30:00Z", 60, task=2),           # Thu 22:30 local: today
            entry(2, "2026-11-18T12:00:00Z", 30, task=3),           # Thu 01:00 local: today (UTC date is the 18th)
            entry(3, "2026-11-15T10:30:00Z", 45, task=3),           # Sun 23:30 local: last week
            entry(4, "2026-11-15T11:30:00Z", 15, task=4),           # Mon 00:30 local: this week
            entry(5, "2026-11-19T01:00:00Z", 50, task=2, user=999), # someone else
            entry(6, "2026-11-19T02:00:00Z", 40, task=2, deleted=True),
            entry(7, "2026-11-23T10:00:00Z", 20, task=2),           # Mon 23:00 next week
        ]))

    def test_status_snapshot(self):
        d = self.run_tw("status")
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["user"], {"id": 123, "name": "Alex Example"})
        self.assertEqual(d["today"], {"date": "2026-11-19", "loggedSeconds": 5400})
        self.assertEqual(d["week"]["start"], "2026-11-16")
        self.assertEqual(d["week"]["loggedSeconds"], 6300)
        self.assertEqual([x["date"] for x in d["week"]["days"]],
                         ["2026-11-%d" % i for i in range(16, 23)])
        self.assertEqual([x["loggedSeconds"] for x in d["week"]["days"]], [900, 0, 0, 5400, 0, 0, 0])
        self.assertEqual(d["fetchedAt"], "2026-11-19T10:00:00Z")

        t0, t1 = d["timers"]
        self.assertEqual(t0, {"id": 10, "taskId": 2, "taskName": "Task Two", "projectId": 900,
                              "projectName": "Project X", "running": True, "elapsedSeconds": 1200,
                              "lastStartedAt": "2026-11-19T09:50:00Z", "description": "working",
                              "billable": True})
        self.assertEqual((t1["id"], t1["running"], t1["elapsedSeconds"]), (11, False, 300))

        ids = [t["id"] for t in d["tasks"]]
        self.assertEqual(ids, [2, 5, 6, 3, 7, 4])
        by = {t["id"]: t for t in d["tasks"]}
        self.assertEqual(by[2]["trackedTodaySeconds"], 3600)
        self.assertEqual(by[2]["trackedWeekSeconds"], 3600)
        self.assertEqual(by[2]["trackedTotalSeconds"], 7200)
        self.assertEqual(by[2]["dueDate"], "2026-12-01")
        self.assertEqual(by[2]["estimateMinutes"], 90)
        self.assertEqual(by[2]["projectName"], "Project X")
        self.assertEqual(by[2]["tasklistName"], "List A")
        self.assertEqual(by[2]["url"], self.server.url + "/app/tasks/2")
        self.assertEqual((by[2]["timerId"], by[2]["timerRunning"]), (10, True))
        self.assertEqual((by[5]["timerId"], by[5]["timerRunning"]), (11, False))
        self.assertEqual(by[3]["trackedTodaySeconds"], 1800)
        self.assertEqual(by[4]["trackedWeekSeconds"], 900)
        self.assertEqual(by[4]["projectName"], "Project Z")
        self.assertIsNone(by[7]["dueDate"])
        self.assertEqual({i: by[i]["recent"] for i in ids},
                         {2: True, 5: True, 6: False, 3: True, 7: False, 4: True})
        for t in d["tasks"]:
            self.assertEqual(set(t) >= {"id", "name", "projectName", "tasklistName", "dueDate",
                                        "estimateMinutes", "trackedTodaySeconds", "trackedWeekSeconds",
                                        "trackedTotalSeconds", "url", "recent"}, True)

    def test_due_date_is_the_calendar_date_in_any_timezone(self):
        # v3 sends a date-only due date as midnight UTC. It is the task's
        # calendar date: converting it to local time would make it the 30th
        # west of UTC, so the helper keeps the date part as it is.
        for tz in ("America/Los_Angeles", "Pacific/Auckland", "Europe/London"):
            self.tz = tz
            d = self.run_tw("status")
            by = {t["id"]: t for t in d["tasks"]}
            self.assertEqual(by[2]["dueDate"], "2026-12-01", tz)
            self.assertEqual(by[3]["dueDate"], "2026-11-25", tz)

    def test_status_requests(self):
        self.run_tw("status")
        q = self.server.calls("GET", v3("time.json"))[0]["query"]
        self.assertEqual((q["startDate"], q["endDate"], q["assignedToUserIds"]), ("2026-11-15", "2026-11-23", "123"))
        tq = [c["query"] for c in self.server.calls("GET", v3("tasks.json"))]
        self.assertEqual(tq[0]["responsiblePartyIds"], "123")
        self.assertIn("tasklists", tq[0]["include"])
        self.assertEqual([x.get("page") for x in tq[:2]], ["1", "2"])
        self.assertEqual(sorted(tq[-1]["ids"].split(",")), ["4", "5"])

    def test_me_is_cached(self):
        self.run_tw("status")
        self.run_tw("status")
        self.assertEqual(len(self.server.calls("GET", v3("me.json"))), 1)

    def test_markup_names_pass_through_unchanged(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", [TIMER_RUNNING], included={
            "tasks": {"2": {"id": 2, "name": MARKUP, "tasklistId": 50}},
            "projects": {"900": {"id": 900, "name": "<script>alert(1)</script>"}}}))
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", [
            {"id": 2, "name": MARKUP, "tasklistId": 50}, {"id": 9, "name": "n" * 1000, "tasklistId": 50}],
            included={"tasklists": {"50": {"id": 50, "name": "<i>list</i>", "projectId": 900}},
                      "projects": {"900": {"id": 900, "name": "<script>alert(1)</script>"}}}))
        d = self.run_tw("status")
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["timers"][0]["taskName"], MARKUP)
        self.assertEqual(d["timers"][0]["projectName"], "<script>alert(1)</script>")
        by = {t["id"]: t for t in d["tasks"]}
        self.assertEqual(by[2]["name"], MARKUP)
        self.assertEqual(by[2]["tasklistName"], "<i>list</i>")
        self.assertEqual(len(by[9]["name"]), 300)

    def test_task_count_bounded(self):
        many = [{"id": i, "name": "T%d" % i} for i in range(1, 101)]
        self.server.routes[("GET", v3("tasks.json"))] = lambda rec: (200, page("tasks", [
            dict(t, id=t["id"] + 100 * (int(rec["query"]["page"]) - 1)) for t in many], has_more=True))
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", []))
        self.server.routes[("GET", v3("time.json"))] = (200, page("timelogs", []))
        d = self.run_tw("status")
        self.assertEqual(len(d["tasks"]), 500)
        self.assertLessEqual(len(self.server.calls("GET", v3("tasks.json"))), 20)

    def test_garbage_fields_are_tolerated(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", [
            {"id": "x"}, "junk", {"id": 12, "taskId": True, "running": "yes", "duration": -5}]))
        self.server.routes[("GET", v3("tasks.json"))] = (200, {"tasks": [{"id": 1, "name": 5, "dueDate": "soon"}],
                                                               "included": [], "meta": "x"})
        self.server.routes[("GET", v3("time.json"))] = (200, page("timelogs", [
            {"id": 1, "timeLogged": "not a date", "minutes": 30},
            {"id": 2, "timeLogged": "2026-11-19T09:00:00Z", "minutes": 10 ** 12}]))
        d = self.run_tw("status")
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["timers"][0]["elapsedSeconds"], 0)
        self.assertFalse(d["timers"][0]["running"])
        self.assertEqual(d["tasks"][0]["name"], "")
        self.assertIsNone(d["tasks"][0]["dueDate"])
        self.assertEqual(d["today"]["loggedSeconds"], 24 * 3600)


SORT_FIELD_ID = 7001
OTHER_FIELD_ID = 7002
SORT_FIELD = {"id": SORT_FIELD_ID, "projectId": None, "entity": "task", "name": " sort   ORDER ",
              "type": "dropdown", "options": {"choices": [{"value": "1st"}, {"value": "2nd"}]}}
OTHER_FIELD = {"id": OTHER_FIELD_ID, "projectId": None, "entity": "task", "name": "Review Status", "type": "status"}
SORT_ARG = "--sort-field=Sort Order"


def cf_value(i, field, task, value):
    return {"id": i, "customfieldId": field, "customfield": {"id": field, "type": "customfields"},
            "value": value, "taskId": task, "task": {"id": task, "type": "tasks"}}


class SortFieldTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()
        r = self.server.routes
        r[("GET", v3("me/timers.json"))] = (200, page("timers", []))
        r[("GET", v3("time.json"))] = (200, page("timelogs", []))

    def tasks_route(self, tasks, values, fields=(SORT_FIELD, OTHER_FIELD)):
        inc = dict(TASK_INCLUDED)
        inc["customfields"] = {str(f["id"]): f for f in fields}
        inc["customfieldTasks"] = {str(v["id"]): v for v in values}
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", tasks, included=inc))

    def test_off_by_default_requests_no_custom_fields(self):
        self.tasks_route([{"id": 1, "name": "A", "tasklistId": 50}], [cf_value(1, SORT_FIELD_ID, 1, "1st")])
        for args in (("status",), ("status", "--sort-field="), ("status", "--sort-field", "   ")):
            self.server.requests.clear()
            d = self.run_tw(*args)
            self.assertTrue(d["ok"], d)
            self.assertEqual((d["tasks"][0]["priorityOrder"], d["tasks"][0]["priorityRank"]), (None, None), args)
            for c in self.server.calls("GET", v3("tasks.json")):
                self.assertNotIn("customfield", c["query"]["include"], args)
        self.server.requests.clear()
        d = self.run_tw("search", "a")
        self.assertIsNone(d["tasks"][0]["priorityOrder"])
        self.assertNotIn("customfield", self.server.calls("GET", v3("tasks.json"))[0]["query"]["include"])

    def test_on_matches_field_name_ignoring_case_and_spacing(self):
        self.tasks_route([{"id": 1, "name": "A", "tasklistId": 50}, {"id": 2, "name": "B", "tasklistId": 50}],
                         [cf_value(1, SORT_FIELD_ID, 1, "2nd"), cf_value(2, OTHER_FIELD_ID, 2, "1st")])
        for name in ("Sort Order", "sort order", "  SORT   order "):
            d = self.run_tw("status", "--sort-field", name)
            by = {t["id"]: (t["priorityOrder"], t["priorityRank"]) for t in d["tasks"]}
            self.assertEqual(by, {1: ("2nd", 2), 2: (None, None)}, name)
        # Another field's name picks that field instead.
        d = self.run_tw("status", "--sort-field=review status")
        by = {t["id"]: (t["priorityOrder"], t["priorityRank"]) for t in d["tasks"]}
        self.assertEqual(by, {1: (None, None), 2: ("1st", 1)})
        # A name no field has gives nothing.
        d = self.run_tw("status", "--sort-field=Nope")
        self.assertEqual([t["priorityOrder"] for t in d["tasks"]], [None, None])

    def test_sort_field_name_bounded(self):
        self.assert_error(self.run_tw("status", "--sort-field=" + "x" * 101), "usage")
        self.assertEqual(self.server.requests, [])

    def test_status_sideloads_sort_field(self):
        tasks = [{"id": i, "name": "T%d" % i, "tasklistId": 50} for i in range(1, 10)]
        self.tasks_route(tasks, [
            cf_value(1, SORT_FIELD_ID, 1, "1st"),
            cf_value(2, SORT_FIELD_ID, 2, "  12th  "),
            cf_value(3, SORT_FIELD_ID, 3, "#3"),
            cf_value(4, SORT_FIELD_ID, 4, 2),
            cf_value(5, SORT_FIELD_ID, 5, "Urgent"),
            cf_value(6, SORT_FIELD_ID, 6, "x" * 100),
            cf_value(7, OTHER_FIELD_ID, 7, "1st"),           # another field's value
            cf_value(8, SORT_FIELD_ID, 8, ""),
            cf_value(9, SORT_FIELD_ID, 9, None),
        ])
        d = self.run_tw("status", SORT_ARG)
        self.assertTrue(d["ok"], d)
        by = {t["id"]: (t["priorityOrder"], t["priorityRank"]) for t in d["tasks"]}
        self.assertEqual(by[1], ("1st", 1))
        self.assertEqual(by[2], ("12th", 12))
        self.assertEqual(by[3], ("#3", 3))
        self.assertEqual(by[4], ("2", 2))
        self.assertEqual(by[5], ("Urgent", None))
        self.assertEqual(by[6], ("x" * 40, None))
        for i in (7, 8, 9):
            self.assertEqual(by[i], (None, None))
        # Sideloaded with the tasks: no extra requests.
        calls = self.server.calls("GET", v3("tasks.json"))
        self.assertEqual(len(calls), 1)
        self.assertIn("customfieldTasks", calls[0]["query"]["include"].split(","))
        self.assertIn("customfields", calls[0]["query"]["include"].split(","))
        self.assertEqual([r["path"] for r in self.server.requests if "customfield" in r["path"]], [])

    def test_field_missing_gives_nulls(self):
        self.tasks_route([{"id": 1, "name": "A", "tasklistId": 50}],
                         [cf_value(1, OTHER_FIELD_ID, 1, "1st")], fields=(OTHER_FIELD,))
        d = self.run_tw("status", SORT_ARG)
        self.assertTrue(d["ok"], d)
        self.assertEqual((d["tasks"][0]["priorityOrder"], d["tasks"][0]["priorityRank"]), (None, None))

    def test_garbage_sideloads_are_tolerated(self):
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", [{"id": 1, "name": "A"}], included={
            "customfields": {str(SORT_FIELD_ID): {"id": SORT_FIELD_ID, "name": 5}, "x": "junk"},
            "customfieldTasks": [{"id": 1, "customfieldId": "nope", "taskId": 1, "value": {"a": 1}}, "junk"]}))
        d = self.run_tw("status", SORT_ARG)
        self.assertTrue(d["ok"], d)
        self.assertIsNone(d["tasks"][0]["priorityOrder"])

    def test_rejected_include_falls_back(self):
        def tasks(rec):
            if "customfieldTasks" in rec["query"].get("include", ""):
                return 400, {"errors": [{"title": "bad include"}]}
            return 200, page("tasks", [{"id": 1, "name": "A", "tasklistId": 50}], included=TASK_INCLUDED)
        self.server.routes[("GET", v3("tasks.json"))] = tasks
        d = self.run_tw("status", SORT_ARG)
        self.assertTrue(d["ok"], d)
        self.assertEqual([(t["id"], t["priorityOrder"], t["priorityRank"]) for t in d["tasks"]], [(1, None, None)])
        d = self.run_tw("search", SORT_ARG, "a")
        self.assertTrue(d["ok"], d)
        self.assertIsNone(d["tasks"][0]["priorityRank"])

    def test_server_error_is_not_retried(self):
        self.server.routes[("GET", v3("tasks.json"))] = (500, {})
        self.assert_error(self.run_tw("status", SORT_ARG), "api")
        self.assertEqual(len(self.server.calls("GET", v3("tasks.json"))), 1)

    def test_search_includes_sort_field(self):
        self.tasks_route([{"id": 1, "name": "A", "tasklistId": 50}, {"id": 2, "name": "B", "tasklistId": 50}],
                         [cf_value(1, SORT_FIELD_ID, 2, "2nd")])
        d = self.run_tw("search", SORT_ARG, "a")
        self.assertTrue(d["ok"], d)
        by = {t["id"]: (t["priorityOrder"], t["priorityRank"]) for t in d["tasks"]}
        self.assertEqual(by, {1: (None, None), 2: ("2nd", 2)})
        q = self.server.calls("GET", v3("tasks.json"))[0]["query"]
        self.assertIn("customfieldTasks", q["include"].split(","))


class WeekBoundaryTests(Base):
    tz = "Europe/London"

    def _status(self, now):
        self.now = now
        self.store_key()
        r = self.server.routes
        r[("GET", v3("me/timers.json"))] = (200, page("timers", []))
        r[("GET", v3("tasks.json"))] = (200, page("tasks", []))
        r[("GET", v3("time.json"))] = (200, page("timelogs", [
            entry(1, "2026-11-16T00:10:00Z", 10, task=1),   # Monday
            entry(2, "2026-11-22T23:50:00Z", 20, task=1),   # Sunday
            entry(3, "2026-11-15T23:50:00Z", 40, task=1),   # previous Sunday
        ]))
        return self.run_tw("status")

    def test_sunday_belongs_to_week_started_monday(self):
        d = self._status("2026-11-22T22:00:00Z")
        self.assertEqual(d["week"]["start"], "2026-11-16")
        self.assertEqual(d["today"], {"date": "2026-11-22", "loggedSeconds": 1200})
        self.assertEqual(d["week"]["loggedSeconds"], 1800)

    def test_monday_starts_new_week(self):
        d = self._status("2026-11-16T08:00:00Z")
        self.assertEqual(d["week"]["start"], "2026-11-16")
        self.assertEqual(d["today"]["loggedSeconds"], 600)

    def test_local_timezone_shifts_day(self):
        # 2026-11-16T00:10Z is still Sunday 15th in New York.
        self.tz = "America/New_York"
        d = self._status("2026-11-16T12:00:00Z")
        self.assertEqual(d["week"]["start"], "2026-11-16")
        days = {x["date"]: x["loggedSeconds"] for x in d["week"]["days"]}
        self.assertEqual(days["2026-11-16"], 0)
        self.assertEqual(days["2026-11-22"], 1200)  # 23:50Z Sunday = 18:50 local Sunday


# ------------------------------------------------------------------ timer actions

def timer_resp(t):
    return 200, {"timer": t, "included": {}}


class TimerTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()

    def test_start_resumes_existing_paused_timer(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", [TIMER_RUNNING, TIMER_PAUSED],
                                                                         included=TIMER_INCLUDED))
        self.server.routes[("PUT", v3("me/timers/11/resume.json"))] = timer_resp(dict(TIMER_PAUSED, running=True,
                                                                                      lastStartedAt="2026-11-19T10:00:00Z"))
        d = self.run_tw("start", "5")
        self.assertTrue(d["ok"], d)
        self.assertTrue(d["resumed"])
        self.assertEqual(d["timer"]["id"], 11)
        self.assertTrue(d["timer"]["running"])
        self.assertEqual(d["timer"]["taskName"], "Task Five")
        self.assertEqual(self.server.calls("POST"), [])
        self.assertEqual(len(self.server.calls("PUT", v3("me/timers/11/resume.json"))), 1)

    def test_start_already_running_is_noop(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", [TIMER_RUNNING], included=TIMER_INCLUDED))
        d = self.run_tw("start", "2")
        self.assertEqual((d["ok"], d["resumed"], d["timer"]["id"]), (True, False, 10))
        self.assertEqual([c["method"] for c in self.server.requests], ["GET"])

    def test_start_new_timer_pauses_running_one(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", [TIMER_RUNNING], included=TIMER_INCLUDED))
        self.server.routes[("GET", v3("tasks/8.json"))] = (200, {"task": {"id": 8, "name": "Eight", "tasklistId": 50},
                                                                 "included": TASK_INCLUDED})
        self.server.routes[("PUT", v3("me/timers/10/pause.json"))] = timer_resp(dict(TIMER_RUNNING, running=False))
        self.server.routes[("POST", v3("me/timers.json"))] = (201, {"timer": {
            "id": 20, "taskId": 8, "projectId": 900, "running": True, "duration": 0,
            "lastStartedAt": "2026-11-19T10:00:00Z"}})
        d = self.run_tw("start", "8")
        self.assertTrue(d["ok"], d)
        self.assertFalse(d["resumed"])
        self.assertEqual(d["timer"]["id"], 20)
        self.assertEqual(d["timer"]["taskName"], "Eight")
        self.assertEqual(d["timer"]["projectName"], "Project X")
        post = self.server.calls("POST", v3("me/timers.json"))[0]
        self.assertEqual(post["body"]["timer"]["taskId"], 8)
        self.assertEqual(post["body"]["timer"]["projectId"], 900)
        self.assertTrue(post["body"]["timer"]["isRunning"])
        order = [(c["method"], c["path"]) for c in self.server.requests]
        self.assertLess(order.index(("PUT", v3("me/timers/10/pause.json"))), order.index(("POST", v3("me/timers.json"))))

    def test_pause_resume_discard(self):
        self.server.routes[("PUT", v3("me/timers/10/pause.json"))] = timer_resp(dict(TIMER_RUNNING, running=False))
        self.server.routes[("PUT", v3("me/timers/10/resume.json"))] = timer_resp(TIMER_RUNNING)
        self.server.routes[("DELETE", v3("me/timers/10.json"))] = (204, b"")
        d = self.run_tw("pause", "10")
        self.assertEqual((d["ok"], d["timer"]["running"], d["timer"]["elapsedSeconds"]), (True, False, 600))
        d = self.run_tw("resume", "10")
        self.assertEqual((d["ok"], d["timer"]["running"]), (True, True))
        self.assertEqual(self.run_tw("discard", "10"), {"ok": True})

    def test_complete_plain(self):
        self.server.routes[("PUT", v3("me/timers/10/complete.json"))] = timer_resp(dict(TIMER_RUNNING, timeLogId=77))
        d = self.run_tw("complete", "10")
        self.assertEqual(d, {"ok": True, "timelogId": 77})
        self.assertEqual([(c["method"], c["path"]) for c in self.server.requests],
                         [("PUT", v3("me/timers/10/complete.json"))])

    def test_complete_with_description_and_billable(self):
        self.server.routes[("GET", v3("timers/10.json"))] = timer_resp(TIMER_RUNNING)
        self.server.routes[("PUT", v3("me/timers/10.json"))] = timer_resp(TIMER_RUNNING)
        self.server.routes[("PUT", v3("me/timers/10/complete.json"))] = timer_resp(TIMER_RUNNING)
        d = self.run_tw("complete", "10", "--description", "Did <the> thing", "--billable", "0")
        self.assertEqual(d, {"ok": True})
        edit = self.server.calls("PUT", v3("me/timers/10.json"))[0]["body"]["timer"]
        self.assertEqual(edit["description"], "Did <the> thing")
        self.assertIs(edit["isBillable"], False)
        self.assertEqual((edit["taskId"], edit["projectId"], edit["isRunning"]), (2, 900, True))
        order = [c["path"] for c in self.server.requests]
        self.assertEqual(order[-1], v3("me/timers/10/complete.json"))

    def test_complete_404_is_api_error(self):
        d = self.run_tw("complete", "999")
        self.assert_error(d, "api")


class LogTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()
        self.server.routes[("POST", v3("tasks/5/time.json"))] = (201, {"timelog": {"id": 300}})

    def body(self):
        return self.server.calls("POST", v3("tasks/5/time.json"))[0]["body"]["timelog"]

    def test_log_with_date_and_start(self):
        d = self.run_tw("log", "5", "--minutes", "95", "--date", "2026-11-19", "--start", "09:00",
                        "--description", "Review <x>", "--billable", "1")
        self.assertEqual(d, {"ok": True, "timelogId": 300})
        b = self.body()
        # 09:00 NZDT on the 19th is 20:00 UTC on the 18th.
        self.assertEqual((b["date"], b["time"], b["isUtc"], b["hasStartTime"]), ("2026-11-18", "20:00:00", True, True))
        self.assertEqual((b["hours"], b["minutes"]), (1, 35))
        self.assertEqual(b["description"], "Review <x>")
        self.assertIs(b["isBillable"], True)
        self.assertEqual(b["taskId"], 5)

    def test_log_today_without_start_ends_now(self):
        self.run_tw("log", "5", "--minutes", "30")
        b = self.body()
        self.assertEqual((b["date"], b["time"], b["hasStartTime"]), ("2026-11-19", "09:30:00", True))
        self.assertNotIn("isBillable", b)

    def test_log_validation(self):
        for args in (["--minutes", "0"], ["--minutes", "1441"], ["--minutes", "abc"], ["--minutes", "-5"],
                     ["--minutes", "10", "--date", "2026-02-30"], ["--minutes", "10", "--date", "19/11/2026"],
                     ["--minutes", "10", "--start", "25:00"], ["--minutes", "10", "--billable", "yes"],
                     ["--minutes", "10", "--description", "x" * 2001]):
            self.assert_error(self.run_tw("log", "5", *args), "usage")
        self.assert_error(self.run_tw("log", "0", "--minutes", "10"), "usage")
        self.assert_error(self.run_tw("log", "5;rm", "--minutes", "10"), "usage")
        self.assertEqual(self.server.requests, [])


class SearchTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()

    def test_search(self):
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", [
            {"id": i, "name": "Find %d" % i, "tasklistId": 50} for i in range(1, 41)] + [{"id": 1, "name": "dup"}],
            included=TASK_INCLUDED))
        d = self.run_tw("search", "find me")
        self.assertTrue(d["ok"], d)
        self.assertEqual(len(d["tasks"]), 30)
        self.assertEqual(d["tasks"][0]["projectName"], "Project X")
        q = self.server.calls("GET", v3("tasks.json"))[0]["query"]
        self.assertEqual((q["searchTerm"], q["pageSize"]), ("find me", "30"))

    def test_search_bounds(self):
        self.assert_error(self.run_tw("search", "   "), "usage")
        self.assert_error(self.run_tw("search", "x" * 201), "usage")


# ------------------------------------------------------------------ errors / transport

class ErrorTests(Base):
    def setUp(self):
        super().setUp()
        self.store_key()

    def test_401_maps_to_auth(self):
        self.server.routes[("GET", v3("me.json"))] = (401, "")
        self.assert_error(self.run_tw("status"), "auth")

    def test_http_status_mapping(self):
        for status, code in ((403, "api"), (404, "api"), (429, "api"), (500, "api"), (503, "api"), (422, "api")):
            self.server.routes[("PUT", v3("me/timers/1/pause.json"))] = (status, {"errors": [{"detail": "nope"}]})
            self.assert_error(self.run_tw("pause", "1"), code)

    def test_redirect_not_followed(self):
        self.server.routes[("GET", v3("me.json"))] = (302, b"", {"Location": self.server.url + "/elsewhere"})
        self.assert_error(self.run_tw("status"), "config")
        self.assertEqual(self.server.calls(path="/elsewhere"), [])

    def test_timeout_maps_to_network(self):
        def slow(rec):
            time.sleep(1.5)
            return 200, ME
        self.server.routes[("GET", v3("me.json"))] = slow
        t = time.monotonic()
        d = self.run_tw("status", env=self.env(TEAMWORK_TEST_TIMEOUT="0.3"))
        self.assert_error(d, "network")
        self.assertLess(time.monotonic() - t, 10)

    def test_connection_refused_maps_to_network(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        d = self.run_tw("status", "--site", "http://127.0.0.1:%d" % port, site=False)
        self.assert_error(d, "network")

    def test_oversized_response(self):
        big = b'{"person": {"id": 1, "x": "' + b"a" * (6 * 1024 * 1024) + b'"}}'
        self.server.routes[("GET", v3("me.json"))] = (200, big)
        d = self.run_tw("status")
        self.assert_error(d, "api")
        self.assertIn("too large", d["error"])

    def test_malformed_responses(self):
        for payload in (b"<html>oops</html>", b'{"person": ', b"[1, 2, 3]", b"\xff\xfe\x00",
                        b"[" * 100000 + b"]" * 100000):
            self.server.routes[("GET", v3("me.json"))] = (200, payload)
            self.assert_error(self.run_tw("status"), "api")

    def test_trickled_response_hits_the_overall_deadline(self):
        # Each byte arrives well within the socket timeout; the call as a whole must still end.
        self.server.routes[("GET", v3("me.json"))] = (200, Drip(json.dumps(ME).encode() + b" " * 200, delay=0.1))
        t = time.monotonic()
        d = self.run_tw("status", env=self.env(TEAMWORK_TEST_TIMEOUT="1", TEAMWORK_TEST_DEADLINE="1.5"))
        self.assert_error(d, "network")
        self.assertLess(time.monotonic() - t, 8)

    def test_trickled_error_body_is_cut_short(self):
        self.server.routes[("PUT", v3("me/timers/1/pause.json"))] = (500, Drip(b"x" * 400, delay=0.1))
        t = time.monotonic()
        d = self.run_tw("pause", "1", env=self.env(TEAMWORK_TEST_TIMEOUT="1", TEAMWORK_TEST_DEADLINE="1.5"))
        self.assert_error(d, "api")
        self.assertLess(time.monotonic() - t, 8)

    def test_non_finite_numbers_are_refused_or_ignored(self):
        for payload in (b'{"person": {"id": NaN}}', b'{"person": {"id": 1}, "x": Infinity}',
                        b'{"person": {"id": 1}, "x": -Infinity}'):
            self.server.routes[("GET", v3("me.json"))] = (200, payload)
            self.assert_error(self.run_tw("status"), "api")
        # 1e400 is valid JSON that parses to infinity: a duration like that counts as 0.
        self.server.routes[("GET", v3("me.json"))] = (200, ME)
        self.server.routes[("GET", v3("me/timers.json"))] = (200, (
            b'{"timers": [{"id": 10, "taskId": 2, "running": false, "duration": 1e400, "userId": 123}],'
            b' "meta": {"page": {"hasMore": false}}}'))
        self.server.routes[("GET", v3("tasks.json"))] = (200, (
            b'{"tasks": [{"id": 2, "name": "T", "estimateMinutes": -1e400}], "meta": {}}'))
        self.server.routes[("GET", v3("time.json"))] = (200, (
            b'{"timelogs": [{"id": 1, "minutes": 1e400, "timeLogged": "2026-11-19T09:00:00Z", "userId": 123}]}'))
        d = self.run_tw("status")
        self.assertTrue(d["ok"], d)
        self.assertEqual(d["timers"][0]["elapsedSeconds"], 0)
        self.assertEqual(d["tasks"][0]["estimateMinutes"], 0)
        self.assertEqual(d["today"]["loggedSeconds"], 0)

    def test_corrupt_cache_is_ignored(self):
        cache = os.path.join(self.tmp, "cache")
        os.makedirs(cache, mode=0o700)
        with open(os.path.join(cache, "me.json"), "w") as f:
            f.write("[" * 60000)
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", []))
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", []))
        self.server.routes[("GET", v3("time.json"))] = (200, page("timelogs", []))
        self.assertTrue(self.run_tw("status")["ok"])

    def test_me_without_id(self):
        self.server.routes[("GET", v3("me.json"))] = (200, {"person": {"firstName": "x"}})
        self.assert_error(self.run_tw("status"), "api")

    def test_unexpected_list_type(self):
        self.server.routes[("GET", v3("me/timers.json"))] = (200, {"timers": "nope"})
        self.assert_error(self.run_tw("status"), "api")


# ------------------------------------------------------------------ old id migration

class LegacyKeyTests(Base):
    """A key stored under the old tom.teamwork id moves to tomhayes.teamwork."""

    def setUp(self):
        super().setUp()
        bindir = os.path.join(self.tmp, "fakebin")
        os.makedirs(bindir)
        self.vault = os.path.join(self.tmp, "vault")
        os.makedirs(self.vault)
        self.log = os.path.join(self.tmp, "secret-tool.log")
        # A keyring keyed by the service attribute; store_ok=0 makes store fail.
        script = """#!%s
import json, os, sys
log, vault = %r, %r
argv = sys.argv[1:]
data = sys.stdin.buffer.read() if argv[0] == "store" else b""
with open(log, "a") as f:
    f.write(json.dumps({"argv": argv, "stdin": data.decode()}) + "\\n")
attrs = [a for a in argv[1:] if not a.startswith("--")]
service = dict(zip(attrs[::2], attrs[1::2])).get("service", "")
path = os.path.join(vault, service)
if argv[0] == "store":
    if os.environ.get("FAKE_STORE_OK") == "0":
        sys.exit(1)
    open(path, "wb").write(data)
elif argv[0] == "lookup":
    if not os.path.exists(path):
        sys.exit(1)
    sys.stdout.buffer.write(open(path, "rb").read())
elif argv[0] == "clear":
    if os.path.exists(path):
        os.unlink(path)
""" % (sys.executable, self.log, self.vault)
        with open(os.path.join(bindir, "secret-tool"), "w") as f:
            f.write(script)
        os.chmod(os.path.join(bindir, "secret-tool"), 0o755)
        self.kenv = self.env(TEAMWORK_KEY_FILE=None, PATH=bindir + os.pathsep + os.environ.get("PATH", ""))
        state = os.path.join(self.tmp, "xdg-state")
        self.old_file = os.path.join(state, "tom.teamwork", "api-key")
        self.new_file = os.path.join(state, "tomhayes.teamwork", "api-key")
        self.old_cache = os.path.join(self.tmp, "xdg-cache", "tom.teamwork", "me.json")

    def keyring(self, service):
        p = os.path.join(self.vault, service)
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return f.read()

    def put_old_file(self):
        os.makedirs(os.path.dirname(self.old_file), mode=0o700)
        with open(self.old_file, "w") as f:
            f.write(KEY + "\n")
        os.chmod(self.old_file, 0o600)

    def put_old_cache(self):
        os.makedirs(os.path.dirname(self.old_cache))
        with open(self.old_cache, "w") as f:
            f.write("{}")

    def calls(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def test_old_keyring_entry_moves_to_new_service(self):
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write(KEY)
        self.put_old_cache()
        self.assertEqual(self.run_tw("has-key", site=False, env=self.kenv), {"ok": True, "hasKey": True})
        self.assertEqual(self.keyring("tomhayes.teamwork"), KEY)
        self.assertIsNone(self.keyring("tom.teamwork"))
        self.assertFalse(os.path.exists(self.new_file))
        self.assertFalse(os.path.exists(os.path.dirname(self.old_cache)))
        for c in self.calls():
            self.assertNotIn(KEY, " ".join(c["argv"]))
        store = [c for c in self.calls() if c["argv"][0] == "store"]
        self.assertEqual([c["argv"][-4:] for c in store], [["service", "tomhayes.teamwork", "account", "api-key"]])
        self.assertEqual(store[0]["stdin"], KEY)
        # Once moved, the old service is not asked again.
        before = len(self.calls())
        self.assertTrue(self.run_tw("has-key", site=False, env=self.kenv)["hasKey"])
        self.assertEqual([c["argv"][:1] + c["argv"][-4:] for c in self.calls()[before:]],
                         [["lookup", "service", "tomhayes.teamwork", "account", "api-key"]])

    def test_old_file_moves_to_new_keyring(self):
        self.put_old_file()
        self.assertTrue(self.run_tw("has-key", site=False, env=self.kenv)["hasKey"])
        self.assertEqual(self.keyring("tomhayes.teamwork"), KEY)
        self.assertFalse(os.path.exists(self.old_file))
        self.assertFalse(os.path.exists(os.path.dirname(self.old_file)))

    def test_old_file_moves_to_new_file_without_keyring(self):
        self.put_old_file()
        env = dict(self.kenv, FAKE_STORE_OK="0")
        self.assertTrue(self.run_tw("has-key", site=False, env=env)["hasKey"])
        with open(self.new_file) as f:
            self.assertEqual(f.read().strip(), KEY)
        self.assertEqual(stat.S_IMODE(os.stat(self.new_file).st_mode), 0o600)
        self.assertFalse(os.path.exists(self.old_file))
        self.assertTrue(self.run_tw("has-key", site=False, env=env)["hasKey"])

    def test_migrated_key_is_used_for_requests(self):
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write(KEY)
        self.server.routes[("GET", v3("me/timers.json"))] = (200, page("timers", []))
        self.server.routes[("GET", v3("tasks.json"))] = (200, page("tasks", []))
        self.server.routes[("GET", v3("time.json"))] = (200, page("timelogs", []))
        d = self.run_tw("status", env=self.kenv)
        self.assertTrue(d["ok"], d)
        self.assertEqual(self.server.requests[0]["auth"], "Basic " + base64.b64encode((KEY + ":X").encode()).decode())

    def test_new_key_wins_and_old_is_left_alone(self):
        with open(os.path.join(self.vault, "tomhayes.teamwork"), "w") as f:
            f.write(KEY)
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write("twp_OldKey000")
        self.assertTrue(self.run_tw("has-key", site=False, env=self.kenv)["hasKey"])
        self.assertEqual(self.keyring("tomhayes.teamwork"), KEY)
        self.assertEqual([c["argv"][0] for c in self.calls()], ["lookup"])

    def test_invalid_old_key_is_ignored(self):
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write("has space")
        self.assertFalse(self.run_tw("has-key", site=False, env=self.kenv)["hasKey"])
        self.assertIsNone(self.keyring("tomhayes.teamwork"))

    def test_clear_key_removes_old_copies_too(self):
        with open(os.path.join(self.vault, "tomhayes.teamwork"), "w") as f:
            f.write(KEY)
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write(KEY)
        self.put_old_file()
        self.assertEqual(self.run_tw("clear-key", site=False, env=self.kenv), {"ok": True})
        self.assertIsNone(self.keyring("tomhayes.teamwork"))
        self.assertIsNone(self.keyring("tom.teamwork"))
        self.assertFalse(os.path.exists(self.old_file))
        self.assertFalse(self.run_tw("has-key", site=False, env=self.kenv)["hasKey"])

    def test_key_file_override_skips_migration(self):
        with open(os.path.join(self.vault, "tom.teamwork"), "w") as f:
            f.write(KEY)
        env = dict(self.kenv, TEAMWORK_KEY_FILE=self.keyfile)
        self.assertFalse(self.run_tw("has-key", site=False, env=env)["hasKey"])
        self.assertEqual(self.keyring("tom.teamwork"), KEY)
        self.assertFalse(os.path.exists(self.log))


class SiteTests(Base):
    def test_site_validation(self):
        prod = self.env(TEAMWORK_TEST_ALLOW_HTTP=None)
        bad = ["http://acme.teamwork.com", "https://acme.teamwork.com/app",
               "https://acme.teamwork.com?x=1", "https://u:p@acme.teamwork.com",
               "https://user@acme.teamwork.com", "https://acme.teamwork.com:8443",
               "https://bad_host.teamwork.com", "https://", "ftp://acme.teamwork.com",
               "acme.teamwork.com", "https://acme.teamwork.com#frag",
               "javascript:alert(1)", "https://" + "a" * 300 + ".com", "",
               "https://localhost", "https://intranet", "https://\u212aacme.teamwork.com",
               "https://acme.teamwork.com\\@evil.example", "https://acme.teamwork.com:443",
               "https://acme.teamwork.com/%2e%2e/", "https://acme.teamwork.com.",
               "https://[::1]"]
        for site in bad:
            d = self.run_tw("open-url", "1", "--site", site, site=False, env=prod)
            self.assertFalse(d["ok"], site)
            self.assertIn(d["code"], ("config", "usage"), site)

    def test_site_normalised(self):
        prod = self.env(TEAMWORK_TEST_ALLOW_HTTP=None)
        d = self.run_tw("open-url", "42", "--site", "https://Acme.Teamwork.com/", site=False, env=prod)
        self.assertEqual(d, {"ok": True, "url": "https://acme.teamwork.com/app/tasks/42"})
        d = self.run_tw("--site", "https://acme.teamwork.com", "open-url", "42", site=False, env=prod)
        self.assertEqual(d["url"], "https://acme.teamwork.com/app/tasks/42")
        # A custom domain is allowed.
        d = self.run_tw("open-url", "7", "--site", "https://projects.example.co.uk", site=False, env=prod)
        self.assertEqual(d["url"], "https://projects.example.co.uk/app/tasks/7")

    def test_missing_site(self):
        self.assert_error(self.run_tw("open-url", "1", site=False), "config")

    def test_test_now_ignored_without_test_flag(self):
        # TEAMWORK_TEST_NOW must have no effect outside test mode; http is refused first.
        d = self.run_tw("status", env=self.env(TEAMWORK_TEST_ALLOW_HTTP=None))
        self.assert_error(d, "config")

    def test_usage_errors(self):
        self.assert_error(self.run_tw(site=False), "usage")
        self.assert_error(self.run_tw("nope", site=False), "usage")
        self.assert_error(self.run_tw("--help", site=False), "usage")
        self.assert_error(self.run_tw("start", site=False), "usage")
        self.assert_error(self.run_tw("start", "1" * 30), "usage")


if __name__ == "__main__":
    unittest.main()
