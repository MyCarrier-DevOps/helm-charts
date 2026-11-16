"""PostSync hook on TestEngine's v2 trigger (AQA-38): the script of mycarrier-helm's <fullName>-trigger Job.

Renders the hook with helm, takes the Job's script and runs it with sh against a local stub of TestEngine
(MC.TestEngine TestEngine.Api/docs/V2_TRIGGER.md). An application whose test definitions set testEnvironmentTag reads
GET /v1/capabilities first: a 404 there, or no "v2" in trigger_versions, means v2 is switched off and nothing is posted;
with v2 listed, a 404 on POST /v2/trigger means the route is missing. Every failure logs an ERROR: line and the script
still exits 0, as the v1 hook does. There is never a fallback to /v1/trigger. helm-unittest checks only the rendered
text, so the behaviour is tested here. Each case runs with and without resultsApiKey/resultsApiUrl.

Needs helm, sh and curl (with tr, grep, sed and tail), and `helm dependency build charts/mycarrier-helm` first.
Run from the repository root: python3 -I .github/scripts/test_trigger_v2.py
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "charts", "mycarrier-helm")
KEY = "Bearer dGVzdC1rZXk="
CORRELATION_ID = "62a354da-6833-4bf7-8f6d-689970865996"
CAPS_V2 = {"run_kinds": ["canary", "rehearsal"], "run_kinds_enabled": True, "api_version": "test", "env_vars": True,
           "trigger_versions": ["v1", "v2"], "multi_run_enabled": False}
CAPS_V1 = dict(CAPS_V2, trigger_versions=["v1"])
RESULTS = {"resultsApiUrl": "vault:QA/data/autotestresults_api#url",
           "resultsApiKey": "vault:DevOps/data/autotestresults_api/api#key"}
# A value with $, $$-escapes, a ) and a $(NAME) of the container's env, which kubelet must not expand.
PRICE = "$5 (x) $(TESTENGINE_APIKEY) it's $$"
SWITCHED_OFF ="ERROR: TestEngine v2 trigger not sent: v2 is switched off in this TestEngine"
ROUTE_MISSING = "the /v2/trigger route is missing"


def definition(results, **fields):
    d = {"name": "apitests", "containerImage": "testing/mycarrier/api/tests", "containerTag": "1.0.0",
         "secretId": "vault:QA/data/app_auth#SecretId"}
    if results:
        d.update(RESULTS)
    d.update(fields)
    return d


def values(definitions):
    """A dev application with these test definitions, as JSON (which YAML reads)."""
    return json.dumps({
        "fullnameOverride": "app",
        "namespace": "dev",
        "metaEnvironment": "dev",
        "global": {"appStack": "mystack", "correlationId": CORRELATION_ID, "gitbranch": "main"},
        "applications": {"api": {
            "version": "1.0.0", "enabled": True,
            "image": {"registry": "registry.example.com", "repository": "api", "tag": "1.0.0"},
            "testtrigger": {"testdefinitions": definitions},
        }},
    })


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


def kubelet_expand(text, env):
    """Kubernetes' expansion of a container command (third_party/forked/golang/expansion Expand): $$ becomes $;
    $( up to the first ) is one variable name, replaced by its value when env defines it and written back as it is
    otherwise, so a $$ inside that span stays $$; a $( with no ) stays $(; any other $ stays."""
    out, i = [], 0
    while i < len(text):
        if text[i] != "$" or i + 1 == len(text):
            out.append(text[i])
            i += 1
        elif text[i + 1] == "$":
            out.append("$")
            i += 2
        elif text[i + 1] == "(":
            end = text.find(")", i + 2)
            if end < 0:
                out.append("$(")
                i += 2
            else:
                name = text[i + 2:end]
                out.append(env[name] if name in env else "$(" + name + ")")
                i = end + 1
        else:
            out.append(text[i:i + 2])
            i += 2
    return "".join(out)


def render(definitions):
    """The hook Job's script, as kubelet hands it to sh (kubelet_expand with the container's env)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(values(definitions))
    try:
        out = subprocess.run(["helm", "template", "t", CHART, "-f", f.name, "-s", "templates/triggertestengine.yaml"],
                             capture_output=True, text=True, encoding="utf-8", check=True).stdout
    finally:
        os.unlink(f.name)
    lines = out.splitlines()
    c = next(i for i in range(len(lines)) if lines[i].strip() == "- -c" and lines[i + 1].strip() == "- |")
    script = block_after(lines, c, "- |") + "\n"
    assert script.startswith("set -u\n") and script.rstrip().endswith("exit 0"), "script not found"
    return kubelet_expand(script, {"TESTENGINE_APIKEY": KEY, "TESTENGINEHOOK_URL": "http://unused"})


def body_of(script):
    """The JSON request body of the script: payload='...' (v2) or -d '...' (v1)."""
    marker = "payload='{" if "payload='{" in script else "-d '{"
    return json.JSONDecoder().raw_decode(script, script.index(marker) + len(marker) - 1)[0]


class Stub(http.server.BaseHTTPRequestHandler):
    capabilities = (200, CAPS_V2)
    trigger = (200, {"batch_id": "x"})
    requests = []

    def log_message(self, *args):
        pass

    @classmethod
    def reset(cls, capabilities=(200, CAPS_V2), trigger=(200, {"batch_id": "x"})):
        cls.capabilities, cls.trigger, cls.requests = capabilities, trigger, []

    def answer(self, code, body):
        data = (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain" if isinstance(body, str) else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_one(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        Stub.requests.append((method, self.path, self.headers.get("Authorization"), body))
        if method == "GET" and self.path.endswith("/v1/capabilities"):
            self.answer(*Stub.capabilities)
        elif method == "POST" and self.path.endswith("/v2/trigger"):
            self.answer(*Stub.trigger)
        elif method == "POST" and self.path.endswith("/v1/trigger"):
            self.answer(200, {"batch_id": "v1"})
        else:
            self.answer(404, "404 page not found\n")

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")


class HookV2(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        cls.root = "http://127.0.0.1:%d/testengine" % cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.scripts = {}

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def script(self, results, **fields):
        key = (results, json.dumps(fields, sort_keys=True))
        if key not in self.scripts:
            self.scripts[key] = render([definition(results, **fields)])
        return self.scripts[key]

    def run_script(self, script, url=None):
        env = dict(os.environ, TESTENGINEHOOK_URL=url or self.root + "/v1/trigger", TESTENGINE_APIKEY=KEY)
        p = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True, encoding="utf-8", timeout=120)
        return p.returncode, p.stdout, p.stderr

    def posts(self):
        return [r for r in Stub.requests if r[0] == "POST"]

    def test_v2_listed_posts_the_v2_request_once_after_the_capabilities_read(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset()
                code, out, err = self.run_script(self.script(results, testEnvironmentTag="FeatureCore"))
                self.assertEqual(code, 0)
                self.assertNotIn("ERROR", err)
                self.assertEqual([(m, p) for m, p, _, _ in Stub.requests],
                                 [("GET", "/testengine/v1/capabilities"), ("POST", "/testengine/v2/trigger")])
                self.assertTrue(all(a == KEY for _, _, a, _ in Stub.requests))
                test = json.loads(self.posts()[0][3])["Tests"][0]
                self.assertEqual(test["TestEnvironmentTag"], "FeatureCore")
                self.assertNotIn("TestFilters", test)
                self.assertNotIn("TestTags", test)
                self.assertNotIn("MultiRun", test)
                self.assertEqual("ResultsApiKey" in test["TestEnvironmentVariables"], results)
                self.assertIn("TestEngine HTTP status: 200", out)

    def test_dollars_and_parentheses_in_the_body_reach_testengine_as_written(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset()
                code, _, err = self.run_script(self.script(results, testEnvironmentTag="FeatureCore",
                                                           env={"PRICE": PRICE}))
                self.assertEqual(code, 0)
                self.assertNotIn("ERROR", err)
                test = json.loads(self.posts()[0][3])["Tests"][0]
                self.assertEqual(test["TestEnvironmentVariables"]["EnvVars"], {"PRICE": PRICE})
                self.assertNotIn(KEY, self.posts()[0][3])

    def test_test_tags_and_multi_run_are_sent(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset()
                code, _, err = self.run_script(self.script(results, testEnvironmentTag="Invoices.Api",
                                                           testTags=["a_b", "c-d"], multiRun=True))
                self.assertEqual(code, 0)
                test = json.loads(self.posts()[0][3])["Tests"][0]
                self.assertEqual((test["TestEnvironmentTag"], test["TestTags"], test["MultiRun"]),
                                 ("Invoices.Api", ["a_b", "c-d"], True))
                self.assertIn("WARN: multiRun is set", err)
                self.assertNotIn("ERROR", err)

    def test_multi_run_warns_only_while_multi_run_is_off(self):
        Stub.reset(capabilities=(200, dict(CAPS_V2, multi_run_enabled=True)))
        _, _, err = self.run_script(self.script(True, testEnvironmentTag="FeatureCore", multiRun=True))
        self.assertNotIn("WARN", err)
        self.assertEqual(len(self.posts()), 1)

    def test_capabilities_without_v2_is_switched_off_and_posts_nothing(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset(capabilities=(200, CAPS_V1))
                code, _, err = self.run_script(self.script(results, testEnvironmentTag="FeatureCore"))
                self.assertEqual(code, 0)
                self.assertIn(SWITCHED_OFF, err)
                self.assertIn("does not list v2 in trigger_versions", err)
                self.assertEqual(self.posts(), [])

    def test_a_404_on_capabilities_is_switched_off_and_posts_nothing(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset(capabilities=(404, "404 page not found\n"))
                code, _, err = self.run_script(self.script(results, testEnvironmentTag="FeatureCore"))
                self.assertEqual(code, 0)
                self.assertIn(SWITCHED_OFF, err)
                self.assertIn("answered 404", err)
                self.assertEqual(self.posts(), [])

    def test_another_capabilities_failure_posts_nothing(self):
        for status in (401, 500):
            with self.subTest(status=status):
                Stub.reset(capabilities=(status, {"title": "nope"}))
                code, _, err = self.run_script(self.script(True, testEnvironmentTag="FeatureCore"))
                self.assertEqual(code, 0)
                self.assertIn("ERROR: TestEngine v2 trigger not sent: GET /v1/capabilities answered HTTP %d" % status,
                              err)
                self.assertEqual(self.posts(), [])

    def test_no_answer_on_capabilities_posts_nothing(self):
        Stub.reset()
        code, _, err = self.run_script(self.script(True, testEnvironmentTag="FeatureCore"),
                                       url="http://127.0.0.1:1/v1/trigger")
        self.assertEqual(code, 0)
        self.assertIn("ERROR: TestEngine v2 trigger not sent: GET /v1/capabilities failed (curl exit", err)

    def test_a_404_on_the_post_with_v2_listed_is_a_missing_route_without_a_v1_fallback(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset(trigger=(404, "404 page not found\n"))
                code, _, err = self.run_script(self.script(results, testEnvironmentTag="FeatureCore"))
                self.assertEqual(code, 0)
                self.assertIn(ROUTE_MISSING, err)
                self.assertEqual([p for _, p, _, _ in self.posts()], ["/testengine/v2/trigger"])

    def test_another_post_failure_is_an_error(self):
        Stub.reset(trigger=(422, {"detail": "Tests[0]: TestEnvironmentTag is required"}))
        code, out, err = self.run_script(self.script(True, testEnvironmentTag="FeatureCore"))
        self.assertEqual(code, 0)
        self.assertIn("ERROR: TestEngine v2 trigger failed (HTTP 422)", err)
        self.assertIn("TestEnvironmentTag is required", out)
        self.assertEqual(len(self.posts()), 1)

    def test_the_url_may_name_the_v1_trigger_the_legacy_trigger_or_the_api_root(self):
        script = self.script(True, testEnvironmentTag="FeatureCore")
        for suffix in ("/v1/trigger", "/v1/trigger/", "/trigger", ""):
            with self.subTest(suffix=suffix):
                Stub.reset()
                self.run_script(script, url=self.root + suffix)
                self.assertEqual([p for _, p, _, _ in Stub.requests],
                                 ["/testengine/v1/capabilities", "/testengine/v2/trigger"])

    def test_a_v1_definition_posts_to_the_hook_url_without_reading_capabilities(self):
        for results in (True, False):
            with self.subTest(results_api=results):
                Stub.reset()
                code, _, err = self.run_script(self.script(results, filters=["TestCategory=CoreAPI"]))
                self.assertEqual(code, 0)
                self.assertNotIn("ERROR", err)
                self.assertEqual([(m, p) for m, p, _, _ in Stub.requests], [("POST", "/testengine/v1/trigger")])
                self.assertEqual(json.loads(Stub.requests[0][3])["Tests"][0]["TestFilters"], ["TestCategory=CoreAPI"])

    def test_the_v2_body_is_the_v1_body_with_the_tag_in_place_of_the_filters(self):
        common = {"serviceAddress": "http://api.dev.svc.cluster.local:8080/x?a=1&b='2'",
                  "tolerations": [{"key": "k", "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 3600}],
                  "env": {"PRICE": PRICE}}
        for results in (True, False):
            with self.subTest(results_api=results):
                v1 = body_of(render([definition(results, filters=["TestCategory=CoreAPI"], **common)]))
                v2 = body_of(render([definition(results, testEnvironmentTag="CoreAPI", testTags=["Smoke"],
                                                multiRun=True, **common)]))
                v1_test, v2_test = v1["Tests"][0], v2["Tests"][0]
                self.assertEqual(v1_test.pop("TestFilters"), ["TestCategory=CoreAPI"])
                for key, value in (("TestEnvironmentTag", "CoreAPI"), ("TestTags", ["Smoke"]), ("MultiRun", True)):
                    self.assertEqual(v2_test.pop(key), value)
                self.assertEqual(v2, v1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
