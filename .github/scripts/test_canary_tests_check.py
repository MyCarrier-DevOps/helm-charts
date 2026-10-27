"""Caller contract of the tests Job script in mycarrier-helm's tests AnalysisTemplate (DEVOPS-515).

Renders the chart's tests template with helm, takes the script and the TESTS_REQUEST body from the Job, and runs the
script against a local stub of TestEngine's v1 API (TestEngine.Api/docs/V1_TRIGGER.md, Caller contract). Exit 0 lets
the canary go on; exit 1 fails the AnalysisRun and aborts the canary. The poll interval, the 404 grace and the poll
budget come from the environment, so every case runs in about a second. No case may show the API key or the TestEngine
host in the script's output.

Run from the repository root: python3 -I .github/scripts/test_canary_tests_check.py
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "charts", "mycarrier-helm")
# preprod: the template renders where it is listed, also where the Rollout renders steps: [], and the alerts Job
# (prod only) is not in the output. deploymentStrategy canary stands in for chart-renderer, which passes the
# repository's deployment-strategy property: only a canary Rollout gets the template.
VALUES = """
global:
  appStack: mycarrier
  language: csharp
  correlationId: 62a354da-6833-4bf7-8f6d-689970865996
  gitbranch: main
  deploymentStrategy: canary
  strategy:
    canary:
      analysis:
        templates: [tests]
environment:
  name: preprod
applications:
  api:
    deploymentType: rollout
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
    testtrigger:
      testdefinitions:
        - name: apitests
          containerImage: testing/mycarrier/api/tests
          containerTag: 1.0.0
          secretId: vault:QA/data/app_auth#SecretId
          filters: [TestCategory=CoreAPI]
"""
KEY = "Bearer dGVzdC1rZXk="
RUN_A = "a" * 32
RUN_B = "b" * 32
CAPABILITIES = {"run_kinds": ["canary", "rehearsal"], "run_kinds_enabled": True, "api_version": "test"}


def block_after(lines, start, header):
    """The literal block that follows the first line at or after start whose stripped text is header."""
    i = next(i for i in range(start, len(lines)) if lines[i].strip() == header)
    body, indent = [], None
    for line in lines[i + 1:]:
        if line.strip() and indent is None:
            indent = len(line) - len(line.lstrip())
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:] if line.strip() else "")
    return "\n".join(body).rstrip("\n")


def render():
    """The tests Job's script and its TESTS_REQUEST value, from the rendered AnalysisTemplate."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(VALUES)
    try:
        out = subprocess.run(["helm", "template", "t", CHART, "-f", f.name, "-s", "templates/analysistemplate.yaml"],
                             capture_output=True, text=True, check=True).stdout
    finally:
        os.unlink(f.name)
    lines = out.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "name: preprod-mycarrier-api-tests")
    c = next(i for i in range(start, len(lines))
             if lines[i].strip() == "- -c" and lines[i + 1].strip() == "- |")
    script = block_after(lines, c, "- |") + "\n"
    r = next(i for i in range(start, len(lines)) if lines[i].strip() == "- name: TESTS_REQUEST")
    request = block_after(lines, r, "value: |-")
    assert "def poll(" in script and script.rstrip().endswith("sys.exit(main())"), "script not found"
    assert json.loads(request)["Tests"][0]["TestEnvironmentVariables"]["RunKind"] == "canary", "request not found"
    return script, request


def accepted(run_id, run_kind="canary", slip_step="none"):
    return 200, {"slip_aggregate_id": run_id, "attempt": 1, "message": "published",
                 "test_batches": [{"test_name": "apitests", "stack_name": "mycarrier", "run_kind": run_kind,
                                   "slip_step": slip_step}]}


def run_status(status):
    return 200, {"slip_aggregate_id": "", "status": status, "run_kind": "canary", "slip_step": "none",
                 "message": "", "updated_at": "2026-10-26T12:00:00Z"}


DROP = (None, None)  # close the connection without an answer
TRUNCATED = "truncated"  # (TRUNCATED, code, body): the body is shorter than its Content-Length
DRIP = "drip"  # (DRIP, None, None): 200 headers, then one byte every 0.1 s for 40 s
HEADER_DRIP = "header-drip"  # (HEADER_DRIP, None, None): the status line, then one header byte every 0.5 s for 60 s
# The timing cases bound the run loosely (budget + 8 s or more, since self.elapsed includes the interpreter's start and
# the machine may be busy), and the slow answers last far longer than those bounds, so the cases still fail when the
# bound they pin is removed.


class Stub(http.server.BaseHTTPRequestHandler):
    """TestEngine's v1 API under /api. Each answer list is consumed in order and its last answer repeats."""
    protocol_version = "HTTP/1.0"
    lock = threading.Lock()
    capabilities = (200, CAPABILITIES)
    posts = []
    runs = {}
    log = []

    def log_message(self, *args):
        pass

    @classmethod
    def reset(cls, capabilities=(200, CAPABILITIES), posts=(), runs=None):
        with cls.lock:
            cls.capabilities = capabilities
            cls.posts = list(posts)
            cls.runs = {k: list(v) for k, v in (runs or {}).items()}
            cls.log = []

    @staticmethod
    def take(answers):
        return answers.pop(0) if len(answers) > 1 else answers[0]

    def answer(self, code, body, kind=None):
        if code is None and kind is None:
            self.close_connection = True
            return
        if kind == HEADER_DRIP:
            try:
                self.wfile.write(b"HTTP/1.0 200 OK\r\n")
                for _ in range(120):
                    self.wfile.write(b"X")
                    self.wfile.flush()
                    time.sleep(0.5)
            except OSError:
                pass
            self.close_connection = True
            return
        if kind == DRIP:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "1000")
            self.end_headers()
            try:
                for _ in range(400):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.1)
            except OSError:
                pass
            self.close_connection = True
            return
        if kind == TRUNCATED:
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw) + 100))
            self.end_headers()
            self.wfile.write(raw)
            self.close_connection = True
            return
        raw = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain" if isinstance(body, str) else "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_one(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with Stub.lock:
            Stub.log.append({"method": method, "path": self.path, "body": body,
                             "authorization": self.headers.get("Authorization"),
                             "content_type": self.headers.get("Content-Type"),
                             "user_agent": self.headers.get("User-Agent")})
            if self.headers.get("Authorization") != KEY:
                answer = (401, {"title": "Unauthorized", "status": 401})
            elif method == "GET" and self.path == "/api/v1/capabilities":
                answer = Stub.capabilities
            elif method == "POST" and self.path == "/api/v1/trigger":
                answer = Stub.take(Stub.posts)
            elif method == "GET" and self.path.startswith("/api/v1/runs/") and self.path[13:] in Stub.runs:
                answer = Stub.take(Stub.runs[self.path[13:]])
            else:
                answer = (404, "404 page not found")
        if len(answer) == 3:
            self.answer(answer[1], answer[2], kind=answer[0])
        else:
            self.answer(*answer)

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")


class TestsJobScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script, cls.request = render()
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d/api" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def run_script(self, url=None, key=KEY, budget="5", grace="2", request=None, **extra):
        url = url or self.base + "/v1/trigger"
        env = dict(os.environ, TESTENGINE_URL=url, TESTENGINE_APIKEY=key,
                   TESTS_REQUEST=self.request if request is None else request, TESTS_BUDGET_SECONDS=budget,
                   TESTS_POLL_INTERVAL_SECONDS="0.02", TESTS_NOT_FOUND_GRACE_SECONDS=grace,
                   TESTS_RESUBMIT_FLOOR_SECONDS="0.1")
        env.update(extra)
        started = time.monotonic()
        p = subprocess.run([sys.executable, "-I", "-B", "-c", self.script], env=env, capture_output=True, text=True,
                           timeout=60)
        self.elapsed = time.monotonic() - started
        self.assertEqual(p.stderr, "", "the script wrote to stderr (a traceback?)")
        # N7: the output never shows the key (or its token) or the TestEngine host.
        for secret in {key.strip(), key.strip().split(" ")[-1]} - {""}:
            self.assertNotIn(secret, p.stdout, "the script printed the API key")
        host = urllib.parse.urlsplit(url).hostname
        if host:
            self.assertNotIn(host, p.stdout, "the script printed the TestEngine host")
        return p.returncode, p.stdout

    def posts(self):
        return [r for r in Stub.log if r["method"] == "POST"]

    def gets(self, path):
        return [r for r in Stub.log if r["method"] == "GET" and r["path"] == "/api" + path]

    # R3: a passing suite passes with exactly one POST, of the rendered request, as the hook sends it.
    def test_a_passing_run_passes_with_exactly_one_post(self):
        Stub.reset(posts=[accepted(RUN_A)],
                   runs={RUN_A: [run_status("queued"), run_status("running"), run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertIn("PASS: run %s passed" % RUN_A, out)
        self.assertEqual(len(self.gets("/v1/capabilities")), 1)
        posts = self.posts()
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["path"], "/api/v1/trigger")
        self.assertEqual(posts[0]["body"], self.request)
        self.assertEqual(posts[0]["content_type"], "application/json")
        self.assertTrue(all(r["authorization"] == KEY for r in Stub.log), "the Authorization header is the key as is")
        self.assertTrue(all(r["user_agent"] == "mycarrier-helm-canary-tests/1" for r in Stub.log), "N6: User-Agent")
        self.assertEqual(len(self.gets("/v1/runs/" + RUN_A)), 3)
        # The capabilities preflight comes before the POST.
        self.assertEqual(Stub.log[0]["path"], "/api/v1/capabilities")

    def test_a_failed_run_fails_without_a_resubmit(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("running"), run_status("failed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL: run %s failed" % RUN_A, out)
        self.assertEqual(len(self.posts()), 1)

    # R2: no_results or infra_failed is submitted once more; only a pass of that run passes.
    def test_no_results_or_infra_failed_is_submitted_once_more(self):
        for first in ("no_results", "infra_failed"):
            for second, rc_wanted in (("passed", 0), ("failed", 1), ("no_results", 1), ("infra_failed", 1)):
                with self.subTest(first=first, second=second):
                    Stub.reset(posts=[accepted(RUN_A), accepted(RUN_B)],
                               runs={RUN_A: [run_status("running"), run_status(first)],
                                     RUN_B: [run_status("queued"), run_status(second)]})
                    rc, out = self.run_script()
                    self.assertEqual(rc, rc_wanted, out)
                    posts = self.posts()
                    self.assertEqual(len(posts), 2, "exactly one resubmit")
                    self.assertEqual(posts[1]["body"], posts[0]["body"])
                    self.assertIn("goes once more as a new run", out)
                    if second in ("no_results", "infra_failed"):
                        self.assertIn("again after one resubmit", out)

    # R4: no POST without run kinds; the message names RUN_KINDS_ENABLED.
    def test_run_kinds_disabled_sends_no_post(self):
        for capabilities in ((200, dict(CAPABILITIES, run_kinds_enabled=False)), (404, "404 page not found")):
            with self.subTest(capabilities=capabilities[0]):
                Stub.reset(capabilities=capabilities, posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script()
                self.assertEqual(rc, 1, out)
                self.assertIn("RUN_KINDS_ENABLED", out)
                self.assertEqual(self.posts(), [])

    def test_a_404_within_the_grace_is_retried(self):
        not_found = (404, {"title": "Not Found", "status": 404})
        Stub.reset(posts=[accepted(RUN_A)],
                   runs={RUN_A: [not_found, not_found, not_found, run_status("running"), run_status("passed")]})
        rc, out = self.run_script(grace="5")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.gets("/v1/runs/" + RUN_A)), 5)

    def test_a_404_after_the_grace_fails(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [(404, {"title": "Not Found", "status": 404})]})
        rc, out = self.run_script(grace="0.3", budget="40")
        self.assertEqual(rc, 1, out)
        self.assertIn("still answered 404", out)
        self.assertLess(self.elapsed, 30, "the 404 grace, not the poll budget (40 s), ends the run")
        self.assertEqual(len(self.posts()), 1)

    def test_a_5xx_on_the_run_fails(self):
        for code in (500, 502, 503):
            with self.subTest(code=code):
                Stub.reset(posts=[accepted(RUN_A)],
                           runs={RUN_A: [run_status("running"), (code, {"title": "error", "status": code})]})
                rc, out = self.run_script()
                self.assertEqual(rc, 1, out)
                self.assertIn("answered HTTP %d" % code, out)
                if code == 503:
                    self.assertIn("status store is unavailable", out)
                self.assertEqual(len(self.posts()), 1)

    def test_a_5xx_on_the_post_fails_without_a_retry(self):
        for code in (500, 503):
            with self.subTest(code=code):
                Stub.reset(posts=[(code, {"title": "error", "status": code, "detail": "publish failed"}),
                                  accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script()
                self.assertEqual(rc, 1, out)
                self.assertIn("POST /v1/trigger answered HTTP %d: publish failed" % code, out)
                self.assertEqual(len(self.posts()), 1)

    def test_a_425_on_the_post_sends_the_same_request_again(self):
        too_early = (425, {"title": "Too Early", "status": 425, "detail": "nothing was dispatched; retry later"})
        Stub.reset(posts=[too_early, too_early, accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        posts = self.posts()
        self.assertEqual(len(posts), 3)
        self.assertTrue(all(p["body"] == self.request for p in posts))

    def test_a_422_run_kinds_disabled_is_not_retried(self):
        Stub.reset(posts=[(422, {"title": "Unprocessable Entity", "status": 422,
                                 "detail": "validation errors: [0] run kinds disabled"}), accepted(RUN_A)],
                   runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 1, out)
        self.assertIn("RUN_KINDS_ENABLED", out)
        self.assertIn("not retried", out)
        self.assertEqual(len(self.posts()), 1)

    def test_another_4xx_on_the_post_fails_with_its_detail(self):
        for code, detail in ((422, "validation errors: [0] StackName is required"),
                             (409, "slip . cannot be claimed; nothing was dispatched")):
            with self.subTest(code=code):
                Stub.reset(posts=[(code, {"status": code, "detail": detail}), accepted(RUN_A)],
                           runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script()
                self.assertEqual(rc, 1, out)
                self.assertIn(detail, out)
                self.assertEqual(len(self.posts()), 1)

    def test_a_poll_timeout_fails(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("running")]})
        rc, out = self.run_script(budget="2")
        self.assertEqual(rc, 1, out)
        self.assertIn("did not end in time (last status: running)", out)
        self.assertIn("poll budget of", out)

    def test_the_poll_budget_covers_the_resubmit(self):
        Stub.reset(posts=[accepted(RUN_A), accepted(RUN_B)],
                   runs={RUN_A: [run_status("no_results")], RUN_B: [run_status("running")]})
        rc, out = self.run_script(budget="3")
        self.assertEqual(rc, 1, out)
        self.assertIn("run %s did not end in time" % RUN_B, out)
        self.assertEqual(len(self.posts()), 2)

    def test_no_answer_on_a_poll_is_retried(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [DROP, run_status("running"), run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertIn("no answer (", out)

    def test_a_missing_run_kind_echo_fails_before_polling(self):
        for run_kind, slip_step in (("", ""), ("canary", ""), ("", "none")):
            with self.subTest(run_kind=run_kind, slip_step=slip_step):
                Stub.reset(posts=[accepted(RUN_A, run_kind, slip_step)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script()
                self.assertEqual(rc, 1, out)
                self.assertIn("did not echo run_kind canary and slip_step none", out)
                self.assertEqual(self.gets("/v1/runs/" + RUN_A), [])

    def test_an_answer_without_a_run_id_fails(self):
        Stub.reset(posts=[(200, {"message": "published"})], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 1, out)
        self.assertIn("without a slip_aggregate_id", out)

    def test_the_url_may_name_the_v1_trigger_the_legacy_trigger_or_the_api_root(self):
        for suffix in ("/v1/trigger", "/v1/trigger/", "/trigger", "", "/"):
            with self.subTest(suffix=suffix):
                Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script(url=self.base + suffix)
                self.assertEqual(rc, 0, out)
                self.assertEqual([r["path"] for r in Stub.log],
                                 ["/api/v1/capabilities", "/api/v1/trigger", "/api/v1/runs/" + RUN_A])

    def test_a_refused_key_fails_without_a_post(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(key="Bearer d3Jvbmc=")
        self.assertEqual(rc, 1, out)
        self.assertIn("answered 401", out)
        self.assertEqual(self.posts(), [])

    def test_an_unresolved_vault_reference_fails_without_a_request(self):
        for kwargs in ({"key": "vault:DevOps/data/testengine/api#encoded_header"},
                       {"url": "vault:DevOps/data/testengine/api/v1#url"}, {"key": ""}):
            with self.subTest(**kwargs):
                Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script(**kwargs)
                self.assertEqual(rc, 1, out)
                self.assertEqual(Stub.log, [])

    # M8 (a): the key goes into an HTTP header, so it must be printable ASCII; the FAIL line never shows it.
    def test_a_key_with_control_or_non_ascii_characters_fails_without_a_request(self):
        for key in ("Bearer dGVz\tdC1rZXk=", "Bearer dGVzdC1rZXk=\x01", "Bearer d\u00fcGVzdA=="):
            with self.subTest(key=repr(key)):
                Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
                rc, out = self.run_script(key=key)
                self.assertEqual(rc, 1, out)
                self.assertIn("TESTENGINE_APIKEY holds characters that cannot go in an HTTP header", out)
                self.assertEqual(Stub.log, [])

    # M8 (b): an error answer whose body is cut short still counts by its status, so a 404 in the grace is retried.
    def test_a_truncated_404_body_within_the_grace_is_retried(self):
        Stub.reset(posts=[accepted(RUN_A)],
                   runs={RUN_A: [(TRUNCATED, 404, {"title": "Not Found", "status": 404}), run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.gets("/v1/runs/" + RUN_A)), 2)

    def test_a_truncated_5xx_body_still_fails_by_its_status(self):
        Stub.reset(posts=[(TRUNCATED, 503, {"title": "Service Unavailable", "status": 503})],
                   runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 1, out)
        self.assertIn("POST /v1/trigger answered HTTP 503", out)

    def test_a_truncated_run_answer_counts_as_no_answer_and_is_retried(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [(TRUNCATED, 200, {"status": "passed"}), run_status("passed")]})
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertIn("no answer (IncompleteRead)", out)

    # M8 (c): any other error ends the run with its type only, never its message or a traceback.
    def test_an_unexpected_error_fails_with_its_type_only(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(TESTS_POLL_INTERVAL_SECONDS="not-a-number")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL: unexpected ValueError", out)
        self.assertNotIn("not-a-number", out)

    # N2: no answer names the error's type, so DNS, refused and TLS failures are told apart without the host.
    def test_a_refused_connection_is_named_and_fails_at_the_end_of_the_budget(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            closed_port = s.getsockname()[1]
        rc, out = self.run_script(url="http://127.0.0.1:%d/api/v1/trigger" % closed_port, budget="1")
        self.assertEqual(rc, 1, out)
        self.assertIn("GET /v1/capabilities: no answer (ConnectionRefusedError)", out)
        self.assertIn("never answered; the poll budget of", out)

    # N3: each HTTP call ends by the poll budget, also when the answer arrives one byte at a time.
    def test_a_slow_answer_cannot_run_past_the_budget(self):
        Stub.reset(capabilities=(DRIP, None, None), posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(budget="1")
        self.assertEqual(rc, 1, out)
        self.assertIn("GET /v1/capabilities: no answer (TimeoutError)", out)
        self.assertIn("FAIL: GET /v1/capabilities never answered; the poll budget of 1 s", out)
        self.assertLess(self.elapsed, 9, "the slow answer (40 s) ran past the budget (1 s)")
        self.assertEqual(self.posts(), [])

    # P1: the whole call is bounded by the budget, also when the status line and headers arrive one byte at a time.
    def test_slow_headers_cannot_run_past_the_budget(self):
        Stub.reset(capabilities=(HEADER_DRIP, None, None), posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(budget="2")
        self.assertEqual(rc, 1, out)
        self.assertIn("GET /v1/capabilities: no answer (TimeoutError)", out)
        self.assertIn("FAIL: GET /v1/capabilities never answered; the poll budget of 2 s", out)
        self.assertLess(self.elapsed, 10, "the slow headers (60 s) ran past the budget (2 s)")
        self.assertEqual(self.posts(), [])

    # P5: no resubmit when less than the floor of the budget is left: the new run could not end in time.
    def test_the_resubmit_is_skipped_without_enough_budget(self):
        Stub.reset(posts=[accepted(RUN_A), accepted(RUN_B)],
                   runs={RUN_A: [run_status("no_results")], RUN_B: [run_status("passed")]})
        rc, out = self.run_script(budget="2", TESTS_RESUBMIT_FLOOR_SECONDS="10")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL: run %s ended no_results, and the resubmit was skipped" % RUN_A, out)
        self.assertIn("less than the 10 s a new run needs at least", out)
        self.assertEqual(len(self.posts()), 1)

    # P5: a POST the budget leaves no time for is not sent, and the FAIL line says so.
    def test_a_post_after_the_budget_is_not_sent(self):
        too_early = (425, {"title": "Too Early", "status": 425, "detail": "nothing was dispatched; retry later"})
        Stub.reset(posts=[too_early, accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(budget="3", TESTS_POLL_INTERVAL_SECONDS="30")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL: POST /v1/trigger was not sent: the poll budget of 3 s", out)
        self.assertNotIn("may have started a run", out)
        self.assertEqual(len(self.posts()), 1)

    def test_a_request_without_run_kind_fails_without_a_request(self):
        Stub.reset(posts=[accepted(RUN_A)], runs={RUN_A: [run_status("passed")]})
        rc, out = self.run_script(request=json.dumps({"Tests": [{"TestEnvironmentVariables": {}}]}))
        self.assertEqual(rc, 1, out)
        self.assertIn("TESTS_REQUEST", out)
        self.assertEqual(Stub.log, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
