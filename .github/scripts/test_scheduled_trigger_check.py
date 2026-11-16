"""Exit codes of the scheduled trigger script in mycarrier-helm's scheduled test definitions (AQA-90, R3).

Renders a scheduled test definition's CronJob with helm, takes the script of its Job and runs it with sh and curl against
a local stub of TestEngine's /v1/trigger. The script exits 0 on 200 and on the lease 409 (the previous run of the loop
still holds its lease, told apart from other 409s by helm.testtrigger.loopLeaseDetail), and 1 on any other answer, other
409s included, and when no answer comes. It sends the loop request with the key from TESTENGINE_APIKEY.

Run from the repository root: python3 -I .github/scripts/test_scheduled_trigger_check.py
"""
import http.server
import json
import os
import re
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "charts", "mycarrier-helm")
VALUES = """
global:
  appStack: mycarrier-frontend
  language: csharp
  correlationId: corr-1
  gitbranch: integration
environment:
  name: uat
applications:
  web:
    image: {registry: registry.example.com, repository: web, tag: "26.46.1"}
    ports: {http: 8080}
    testtrigger:
      apikey: vault:DevOps/data/testengine/api#encoded_header
      testdefinitions:
        - name: looptest-prod
          schedule: "*/5 * * * *"
          targetEnvironment: prodactive
          containerImage: testing/mycarrier/frontend/constantloop
          containerTag: 26.46.41549d4
          secretId: vault:QA/data/app_auth#SecretId
          filters: [TestCategory=LoopUITest]
          env: {GREETING: "it's $HOME"}
"""
KEY = "Bearer dGVzdC1rZXk="


def lease_detail():
    """The lease detail text, from its one definition in the chart."""
    with open(os.path.join(CHART, "templates", "_spec_triggertestengine.tpl"), encoding="utf-8") as f:
        m = re.search(r'define "helm\.testtrigger\.loopLeaseDetail" -}}\s*\n(.*?)\n{{- end', f.read())
    return m.group(1)


def render_script():
    """The Job's script as the container runs it: kubelet turns $$ back into $ (no $(VAR) in it names a variable)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(VALUES)
    try:
        out = subprocess.run(["helm", "template", "t", CHART, "-f", f.name, "-s",
                              "templates/scheduledtriggertestengine.yaml"],
                             capture_output=True, text=True, check=True).stdout
    finally:
        os.unlink(f.name)
    lines = out.splitlines()
    i = next(i for i, line in enumerate(lines) if line.strip() == "- -c" and lines[i + 1].strip() == "- |") + 2
    indent = len(lines[i]) - len(lines[i].lstrip())
    body = []
    for line in lines[i:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:])
    script = "\n".join(body).rstrip("\n") + "\n"
    assert script.startswith("set -u\n") and script.endswith("exit 1\n"), "script not found"
    return script.replace("$$", "$")


class Stub(http.server.BaseHTTPRequestHandler):
    """TestEngine's /v1/trigger: answers every POST with (status, body) and records what it got."""
    protocol_version = "HTTP/1.0"
    answer = (200, {})
    posts = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        Stub.posts.append((self.path, self.headers.get("Authorization"), self.rfile.read(length).decode("utf-8")))
        status, document = Stub.answer
        data = json.dumps(document).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/problem+json" if status >= 400 else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ScheduledTriggerScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = render_script()
        cls.lease = lease_detail()
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d/v1/trigger" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_script(self, answer=(200, {}), url=None):
        Stub.answer, Stub.posts = answer, []
        env = dict(os.environ, TESTENGINE_APIKEY=KEY, TESTENGINEHOOK_URL=url or self.url)
        p = subprocess.run(["sh", "-c", self.script], env=env, capture_output=True, text=True, timeout=90)
        self.assertNotIn(KEY, p.stdout + p.stderr)
        return p

    def test_200_exits_0_and_sends_the_loop_request(self):
        p = self.run_script((200, {"slip_aggregate_id": "a" * 32, "attempt": 1}))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("TestEngine HTTP status: 200", p.stdout)
        [(path, auth, body)] = Stub.posts
        self.assertEqual((path, auth), ("/v1/trigger", KEY))
        [test] = json.loads(body)["Tests"]
        env = test["TestEnvironmentVariables"]
        self.assertEqual((env["RunKind"], env["SlipStep"], env["EnvironmentName"], env["ReleaseId"]),
                         ("loop", "none", "prodactive", "26.46.41549d4"))
        self.assertNotIn("CorrelationId", env)
        self.assertEqual(env["EnvVars"], {"GREETING": "it's $HOME"})  # the shell and kubelet escapes undone

    def test_lease_409_exits_0(self):
        detail = "The %s for this loop is held by the previous run" % self.lease.capitalize()
        p = self.run_script((409, {"title": "Conflict", "status": 409, "detail": detail}))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("still holds its lease", p.stdout)

    def test_other_409_exits_1(self):
        p = self.run_script((409, {"title": "Conflict", "status": 409, "detail": "slip step already claimed"}))
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("ERROR: TestEngine answered HTTP 409", p.stderr)

    def test_lease_text_on_another_status_exits_1(self):
        p = self.run_script((500, {"detail": self.lease}))
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)

    def test_error_statuses_exit_1(self):
        for status in (401, 422, 425, 500):
            with self.subTest(status=status):
                p = self.run_script((status, {"detail": "refused"}))
                self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
                self.assertIn("ERROR: TestEngine answered HTTP %d" % status, p.stderr)

    def test_connection_failure_exits_1(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        p = self.run_script(url="http://127.0.0.1:%d/v1/trigger" % port)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("ERROR: TestEngine trigger failed (curl exit", p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
