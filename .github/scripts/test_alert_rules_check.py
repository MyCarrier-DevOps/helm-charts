"""Exit-code contract of the alert-rules script in mycarrier-helm's alerts AnalysisTemplate (DEVOPS-312, Q39, Q40).

Renders the chart's prod alerts template with helm, takes the script from the alert-rules Job's command, and runs it
against a local stub of Grafana's rules API. Exit 1 refuses the deploy (no rule that can fire, or a configuration
error); exit 0 with SKIPPED lets the canary go on after a Grafana outage; exit 0 otherwise means a rule can fire.

Run from the repository root: python3 .github/scripts/test_alert_rules_check.py
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "charts", "mycarrier-helm")
VALUES = """
global:
  appStack: mycarrier
  language: csharp
  strategy:
    canary:
      analysis:
        enabled: true
environment:
  name: prod
alerts:
  serviceName: MyCarrier
applications:
  api:
    deploymentType: rollout
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
"""

RULES = {
    "status": "success",
    "data": {"groups": [{"file": "Service Alerts", "rules": [
        {"name": "[Sev1] MyCarrier errors", "health": "ok", "labels": {"service": "mycarrier", "severity": "sev1"},
         "alerts": [{"labels": {"service": "mycarrier"}, "state": "Normal"}]},
    ]}]},
}


def render_script():
    """The alert-rules script: the literal block after '- -c' in the rendered AnalysisTemplate."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(VALUES)
    out = subprocess.run(["helm", "template", "t", CHART, "-f", f.name, "-s", "templates/analysistemplate.yaml"],
                         capture_output=True, text=True, check=True).stdout
    os.unlink(f.name)
    lines = out.splitlines()
    start = next(i for i, line in enumerate(lines)
                 if line.strip() == "- -c" and i + 1 < len(lines) and lines[i + 1].strip() == "- |")
    body = []
    indent = None
    for line in lines[start + 2:]:
        if line.strip() and indent is None:
            indent = len(line) - len(line.lstrip())
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:] if line.strip() else "")
    script = "\n".join(body).rstrip() + "\n"
    assert "def why_not_evaluable" in script and script.rstrip().endswith("sys.exit(main())"), "script not found"
    return script


class Stub(http.server.BaseHTTPRequestHandler):
    routes = {}
    hits = {}

    def log_message(self, *args):
        pass

    def do_GET(self):
        base = "/" + self.path.split("/")[1]
        Stub.hits[base] = Stub.hits.get(base, 0) + 1
        if self.headers.get("Authorization") != "Bearer tok":
            code, headers, body = 401, {}, b'{"message":"Invalid API key"}'
        else:
            code, headers, body = Stub.routes[base]
        self.send_response(code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


class AlertRulesScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = render_script()
        json_type = {"Content-Type": "application/json"}
        Stub.routes = {
            "/ok": (200, json_type, json.dumps(RULES).encode()),
            "/html": (200, {"Content-Type": "text/html"}, b"<html>login</html>"),
            "/empty": (200, json_type, b""),
            "/statuserr": (200, json_type, b'{"status":"error","data":{"groups":[]}}'),
            "/list": (200, json_type, b"[]"),
            "/401": (401, json_type, b"{}"),
            "/403": (403, json_type, b"{}"),
            "/404": (404, json_type, b"{}"),
            "/302": (302, {"Location": "https://login.example/"}, b""),
            "/429": (429, {"Retry-After": "1"}, b"{}"),
            "/500": (500, json_type, b"{}"),
        }
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.port = cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_script(self, base, service="mycarrier", token="tok", url=None):
        env = dict(os.environ, ALERTS_SERVICE=service, ALERTS_ENVIRONMENT="prod",
                   GRAFANA_URL=url or "http://127.0.0.1:%d%s" % (self.port, base))
        env.pop("GRAFANA_API_KEY", None)
        if token is not None:
            env["GRAFANA_API_KEY"] = token
        Stub.hits.pop(base, None)
        p = subprocess.run([sys.executable, "-I", "-B", "-c", self.script], env=env, capture_output=True, text=True,
                           timeout=120)
        return p.returncode, p.stdout, Stub.hits.get(base, 0)

    def assert_fail(self, base, **kwargs):
        rc, out, hits = self.run_script(base, **kwargs)
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL:", out)
        return hits

    def assert_skipped(self, base, **kwargs):
        rc, out, hits = self.run_script(base, **kwargs)
        self.assertEqual(rc, 0, out)
        self.assertIn("SKIPPED:", out)
        self.assertIn("NOT enforced", out)
        return hits

    def test_a_matching_rule_passes(self):
        rc, out, _ = self.run_script("/ok")
        self.assertEqual(rc, 0, out)
        self.assertIn("evaluable=1", out)
        self.assertNotIn("SKIPPED", out)

    def test_no_evaluable_rule_refuses(self):
        self.assert_fail("/ok", service="nosuch")

    def test_configuration_errors_refuse_without_retries(self):
        for base in ("/401", "/403", "/404", "/302"):
            with self.subTest(base=base):
                self.assertEqual(self.assert_fail(base), 1)

    def test_empty_token_refuses(self):
        self.assert_fail("/ok", token="")

    def test_wrong_json_shape_refuses(self):
        for base in ("/statuserr", "/list"):
            with self.subTest(base=base):
                self.assert_fail(base)

    def test_outages_pass_skipped_after_three_tries(self):
        for base in ("/500", "/429", "/html", "/empty"):
            with self.subTest(base=base):
                self.assertEqual(self.assert_skipped(base), 3)

    def test_unreachable_grafana_passes_skipped(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            closed_port = s.getsockname()[1]
        self.assert_skipped("/none", url="http://127.0.0.1:%d/" % closed_port)


if __name__ == "__main__":
    unittest.main(verbosity=2)
