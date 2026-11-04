"""testtrigger env (AQA-81): the template-path checks and the request bodies of mycarrier-helm.

values.schema.json refuses some bad env inputs first, with Helm's own message; helm-unittest always validates the
schema, so the contract messages of those rules are tested here, on the template path (helm template
--skip-schema-validation). Also pins how Helm reads YAML 1.1 scalars and keys in env, and checks the protected-name
list against the golden shared with TestEngine.

Keep in step with TestEngine.Worker/pkg/worker/protected_env.go (AQA-77 shared contract).
testdata/protected_env_names.json is a byte-identical copy of TestEngine.Worker/pkg/worker/testdata/protected_env_names.json.

Needs PyYAML and `helm dependency build charts/mycarrier-helm` first.
Run from the repository root: python3 -I .github/scripts/test_trigger_env.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CHART = os.path.join(ROOT, "charts", "mycarrier-helm")
GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testdata", "protected_env_names.json")
SENTINEL = "SENTINEL_VALUE_7f3a"
QUOTE_HINT = " (quote the value as a YAML string)"
SHOW_ONLY = "templates/triggertestengine.yaml"

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

DEFINITION = {
    "name": "apitests",
    "containerImage": "alpine/curl",
    "containerTag": "latest",
    "secretId": "vault:Secret/data/secret#SecretId",
    "filters": ["TestCategory=whatever"],
}


def values(shared=None, definition=None, definitions=None):
    """A minimal app1 with the given shared and per-definition env (None leaves the key out)."""
    d = dict(DEFINITION)
    if definition is not None:
        d["env"] = definition
    testtrigger = {"ttlSecondsAfterFinished": "300", "testdefinitions": definitions or [d]}
    if shared is not None:
        testtrigger["env"] = shared
    return {
        "fullnameOverride": "app",
        "namespace": "dev",
        "metaEnvironment": "dev",
        "applications": {
            "app1": {
                "version": "1.0.0",
                "enabled": True,
                "image": {"registry": "myregistry.example.com", "repository": "mycarrier/app1", "tag": "1.0.0"},
                "testtrigger": testtrigger,
            }
        },
    }


YAML_TEXT = """fullnameOverride: app
namespace: dev
metaEnvironment: dev
anchors:
  b: &b {{A: "1"}}
applications:
  app1:
    version: 1.0.0
    enabled: true
    image: {{registry: myregistry.example.com, repository: mycarrier/app1, tag: "1.0.0"}}
    testtrigger:
      ttlSecondsAfterFinished: "300"
      testdefinitions:
        - name: apitests
          containerImage: alpine/curl
          containerTag: latest
          secretId: "vault:Secret/data/secret#SecretId"
          filters: ["TestCategory=whatever"]
          env:
{env}
"""


def env_text(*lines):
    """YAML text of an env block (the lines are the rows of one mapping), as the YAML_TEXT template needs it."""
    return YAML_TEXT.format(env="\n".join("            " + line for line in lines))


def render(vals, show_only=SHOW_ONLY, skip_schema=False):
    """helm template of the chart. vals is a dict, or a str written verbatim as YAML."""
    text = vals if isinstance(vals, str) else json.dumps(vals)
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8", newline="\n") as f:
        f.write(text)
        path = f.name
    try:
        cmd = ["helm", "template", "t", CHART, "-f", path, "-s", show_only]
        if skip_schema:
            cmd.append("--skip-schema-validation")
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", cwd=ROOT)
    finally:
        os.unlink(path)


def docs(result):
    return [d for d in yaml.safe_load_all(result.stdout) if d]


def error_text(result):
    """The error helm prints, without the "Use --debug flag" hint it adds after a failed render."""
    lines = [ln for ln in result.stderr.strip().splitlines() if ln.strip() and not ln.startswith("Use --debug")]
    return chr(10).join(lines)


def v1_request(result):
    """The v1 request JSON that the hook Job sends (the -d '...' body of its script)."""
    job = next(d for d in docs(result) if d["kind"] == "Job")
    script = job["spec"]["template"]["spec"]["containers"][0]["command"][2]
    m = re.search(r"-d '(\{.*?\})' \"\$TESTENGINEHOOK_URL\"", script, re.S)
    return json.loads(m.group(1))


def env_vars(result, index=0):
    return v1_request(result)["Tests"][index]["TestEnvironmentVariables"].get("EnvVars")


def setUpModule():
    pkgs = os.path.join(CHART, "charts")
    if not os.path.isdir(pkgs) or not any(n.startswith("mc-mongodb") for n in os.listdir(pkgs)):
        raise RuntimeError("run helm dependency build charts/mycarrier-helm first")


class TemplatePathRefusals(unittest.TestCase):
    def refuse(self, vals, message, secret=SENTINEL, skip_schema=True):
        r = render(vals, skip_schema=skip_schema)
        self.assertNotEqual(r.returncode, 0, "expected a failure, got:\n" + r.stdout[:400])
        self.assertRegex(error_text(r), re.escape(message) + "$")
        if secret is not None:
            self.assertNotIn(secret, r.stderr)

    def test_invalid_name_fails_on_the_template_path(self):
        self.refuse(values(shared={"1BAD": SENTINEL}), 'EnvVars: test definition "apitests": variable "1BAD": invalid_name')

    def test_names_true_and_false_are_invalid_name(self):
        for name in ("true", "false"):
            with self.subTest(name=name):
                self.refuse(values(shared={name: SENTINEL}), f'EnvVars: test definition "apitests": variable "{name}": invalid_name')

    def test_unquoted_number_is_invalid_value_with_quote_hint(self):
        self.refuse(values(shared={"PORT": 1234567}),
                    'EnvVars: test definition "apitests": variable "PORT": invalid_value' + QUOTE_HINT, secret="1234567")

    def test_boolean_is_invalid_value(self):
        self.refuse(values(definition={"BOOL_ON": True}),
                    'EnvVars: test definition "apitests": variable "BOOL_ON": invalid_value' + QUOTE_HINT, secret=None)

    def test_map_and_list_values_are_invalid_value(self):
        for bad in ({"a": "b"}, ["a"]):
            with self.subTest(value=bad):
                self.refuse(values(definition={"FOO": bad}),
                            'EnvVars: test definition "apitests": variable "FOO": invalid_value' + QUOTE_HINT, secret=None)

    def test_null_value_is_invalid_value(self):
        # Sprig merge would refill the null from the shared map; the chart refuses it and never prints the shared value.
        self.refuse(values(shared={"FOO": SENTINEL}, definition={"FOO": None}),
                    'EnvVars: test definition "apitests": variable "FOO": invalid_value' + QUOTE_HINT)

    def test_env_not_a_map_is_invalid_value(self):
        self.refuse(values(shared=SENTINEL), 'EnvVars: test definition "apitests": invalid_value')

    def test_51_at_one_level_is_too_many_on_the_template_path(self):
        self.refuse(values(definition={f"V{i}": "x" for i in range(51)}), 'EnvVars: test definition "apitests": too_many', secret=None)

    def test_check_order_control_character_before_value_too_large(self):
        self.refuse(values(shared={"BIG": "é" * 2049 + "\t"}),
                    'EnvVars: test definition "apitests": variable "BIG": control_character', secret=None)

    # DEL (0x7F) cannot go through helm-unittest (its YAML parser refuses control characters, even as an escape
    # in a fixture), so this row lives here.
    def test_del_is_control_character(self):
        self.refuse(values(shared={"FOO": "a" + chr(0x7F) + "b"}),
                    'EnvVars: test definition "apitests": variable "FOO": control_character', secret=None)


class ProtectedNames(unittest.TestCase):
    def test_every_protected_name_and_prefix_is_refused(self):
        with open(GOLDEN, encoding="utf-8") as f:
            golden = json.load(f)
        self.assertEqual(len(golden["names"]), 15)
        self.assertEqual(len(golden["prefixes"]), 2)
        samples = []
        for name in golden["names"]:
            samples += [name, name.lower()]
        samples += [p + "X" for p in golden["prefixes"]]
        for sample in samples:
            with self.subTest(name=sample):
                r = render(values(shared={sample: "x"}))
                self.assertNotEqual(r.returncode, 0, sample + " was accepted")
                self.assertRegex(error_text(r),
                                 re.escape(f'EnvVars: test definition "apitests": variable "{sample}": protected_name') + "$")

    def test_similar_names_are_accepted(self):
        names = {"PATHX": "1", "XOTEL_A": "2", "TEST_FILTER_COUNT": "3", "TRACESTATE": "4"}
        r = render(values(shared=names))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(env_vars(r), names)

    def test_default_names_are_accepted(self):
        names = ["ENVIRONMENT", "SECRETID", "SERVICE_ADDRESS", "BRANCH_NAME", "RELEASE_ID", "HOME", "K8S_NAMESPACE",
                 "OTEL_EXPORTER_OTLP_ENDPOINT"]
        for name in names:
            with self.subTest(name=name):
                r = render(values(shared={name: "v-" + name}))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(env_vars(r), {name: "v-" + name})


class Yaml11AsHelmReads(unittest.TestCase):
    """How Helm reads plain scalars and keys in env. Helm's verdict is the truth (plan 02, Review Focus 2); autotriggertests
    must agree. Expectations are from goyaml.v2 resolve.go; a row that differs on the Helm version in use fails here."""

    INVALID = "invalid_value" + QUOTE_HINT

    def test_yaml_1_1_scalars_as_helm_reads_them(self):
        for line, expected in (("D: 2026-10-30", {"D": "2026-10-30"}), ("ID: _5", {"ID": "_5"})):
            with self.subTest(row=line):
                r = render(env_text(line))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(env_vars(r), expected)
        for key, scalar in (("OCT", "0o17"), ("LEAD", "017"), ("YES_VAL", "yes"), ("TILDE", "~"), ("PLUS", "+5"),
                            ("BIN", "-0b11"), ("UND", "1_000.5")):
            with self.subTest(row=f"{key}: {scalar}"):
                r = render(env_text(f"{key}: {scalar}"), skip_schema=True)
                self.assertNotEqual(r.returncode, 0, f"{key}: {scalar} was accepted as a string")
                self.assertRegex(error_text(r), re.escape(f'variable "{key}": ' + self.INVALID) + "$")

    def test_dot_5_0_row_records_helms_verdict(self):
        # plan 02 asks to record Helm's verdict for `DOT: .5_0` and report it; this row prints it and pins it.
        r = render(env_text("DOT: .5_0"), skip_schema=True)
        verdict = "string" if r.returncode == 0 else "not a string"
        print(f"\n[yaml1.1] DOT: .5_0 -> {verdict} ({'EnvVars=' + json.dumps(env_vars(r)) if r.returncode == 0 else error_text(r)[-90:]})")
        self.assertEqual(verdict, DOT_VERDICT)

    def test_plain_on_and_y_keys_become_true(self):
        r = render(env_text(f"ON: {SENTINEL}"), skip_schema=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertRegex(error_text(r), re.escape('EnvVars: test definition "apitests": variable "true": invalid_name') + "$")
        r = render(env_text('ON: "a"', 'Y: "b"'), skip_schema=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertRegex(error_text(r), re.escape('EnvVars: test definition "apitests": variable "true": invalid_name') + "$")

    def test_tilde_key_records_helms_verdict(self):
        # A plain `~` key: would the name `null` pass the pattern? Print and pin Helm's verdict; report it to the index owner.
        r = render(env_text("~: x"), skip_schema=True)
        verdict = "refused" if r.returncode else "accepted"
        detail = error_text(r)[-110:] if r.returncode else json.dumps(env_vars(r))
        print(f"\n[yaml1.1] key ~ -> {verdict}: {detail}")
        self.assertEqual(verdict, TILDE_KEY_VERDICT)

    def test_duplicate_key_last_one_wins(self):
        r = render(env_text(f"FOO: first_{SENTINEL}", "FOO: b"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(env_vars(r), {"FOO": "b"})

    def test_merge_key_before_explicit_key(self):
        r = render(env_text("<<: *b", 'A: "x"'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(env_vars(r), {"A": "x"})

    def test_merge_key_after_explicit_key(self):
        # Helm 4.2.3: the merge overrides an explicit key written before it. 3.18.6 is pinned by MERGE_AFTER below.
        r = render(env_text('A: "x"', "<<: *b"))
        self.assertEqual(r.returncode, 0, r.stderr)
        print(f"\n[yaml1.1] explicit A before <<: *b -> {env_vars(r)}")
        self.assertEqual(env_vars(r), MERGE_AFTER)


# One value with every character that needs care: a single quote (ends the shell quote in -d '...'), a dollar sign and
# $(NAME) (kubelet expands both in command and env[].value), {{...}} (Argo Rollouts resolves it over the whole metric),
# a backslash, and non-ASCII text.
WEIRD = "it's \"q\" $HOME \\d $(TESTENGINE_APIKEY) {{args.x}} café ✓"
APIKEY = "vault:DevOps/data/testengine/api#encoded_header"
CANARY_VALUES = """
global:
  appStack: mycarrier
  language: csharp
  correlationId: 62a354da-6833-4bf7-8f6d-689970865996
  gitbranch: main
  deploymentStrategy: canary
  strategy:
    canary:
      dark: false
      analysis:
        templates: [tests]
environment:
  name: prod
alerts:
  serviceName: MyCarrier
applications:
  api:
    deploymentType: rollout
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
    testtrigger:
      apikey: "%(apikey)s"
      enableV1: true
      env: {WEIRD: %(weird)s}
      testdefinitions:
        - name: apitests
          containerImage: testing/mycarrier/api/tests
          containerTag: 1.0.0
          secretId: vault:QA/data/app_auth#SecretId
          filters: [TestCategory=CoreAPI]
"""


def kubelet_expand(text, env):
    """The Kubernetes rule for command and env[].value: $$ -> $, $(NAME) -> env[NAME] when defined, else left as is."""
    def sub(m):
        if m.group(0) == "$$":
            return "$"
        return env.get(m.group(1), m.group(0))
    return re.sub(r"\$\$|\$\(([^)]*)\)", sub, text)


def container_env(container):
    """A container's env as kubelet resolves it: each entry may reference the ones before it."""
    resolved = {}
    for entry in container.get("env", []):
        resolved[entry["name"]] = kubelet_expand(entry["value"], resolved)
    return resolved


STUB_CURL = """#!/bin/sh
i=0
while [ -e "$CAPDIR/$i" ]; do i=$((i+1)); done
while [ $# -gt 0 ]; do
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$CAPDIR/$i"; fi
  shift
done
exit 0
"""


def run_hook(script, env):
    """Runs the hook script under sh with a stub curl (it saves each -d argument); returns the bodies it sent."""
    with tempfile.TemporaryDirectory() as tmp:
        stubdir = os.path.join(tmp, "bin")
        capdir = os.path.join(tmp, "cap")
        os.mkdir(stubdir)
        os.mkdir(capdir)
        with open(os.path.join(stubdir, "curl"), "w", newline="\n") as f:
            f.write(STUB_CURL)
        os.chmod(os.path.join(stubdir, "curl"), 0o755)
        base = {k: v for k, v in os.environ.items() if k.upper() in ("SYSTEMROOT", "TEMP", "TMP", "HOME", "LANG")}
        run_env = {**base, **env, "CAPDIR": capdir, "PATH": stubdir + os.pathsep + os.environ["PATH"]}
        # The script goes through a file, not `sh -c <script>`: on Windows the argument would be re-parsed (backslashes lost).
        script_path = os.path.join(tmp, "hook.sh")
        with open(script_path, "w", encoding="utf-8", newline=chr(10)) as f:
            f.write(script)
        done = subprocess.run(["sh", script_path], env=run_env, capture_output=True, text=True, encoding="utf-8")
        if done.returncode != 0:
            raise AssertionError("hook script failed: " + done.stderr[-300:])
        bodies = []
        for name in sorted(os.listdir(capdir), key=int):
            with open(os.path.join(capdir, name), encoding="utf-8", newline="") as f:
                bodies.append(f.read())
        return bodies


def hook_values():
    vals = values(shared={"WEIRD": WEIRD})
    vals["applications"]["app1"]["testtrigger"]["apikey"] = APIKEY
    return vals


def hook_container(result):
    job = next(d for d in docs(result) if d["kind"] == "Job")
    return job["spec"]["template"]["spec"]["containers"][0]


class LiteralRequestBodies(unittest.TestCase):
    """The v1 hook body and the canary TESTS_REQUEST stay literal: quotes, $ and {{ in a value arrive unchanged."""

    def test_v1_hook_body_round_trips(self):
        r = render(hook_values())
        self.assertEqual(r.returncode, 0, r.stderr)
        c = hook_container(r)
        env = container_env(c)
        script = kubelet_expand(c["command"][2], env)
        bodies = run_hook(script, env)
        self.assertEqual(len(bodies), 1)
        body = json.loads(bodies[0])
        self.assertEqual(body["Tests"][0]["TestEnvironmentVariables"]["EnvVars"], {"WEIRD": WEIRD})

    def test_kubelet_does_not_expand_dollar_paren(self):
        r = render(hook_values())
        self.assertEqual(r.returncode, 0, r.stderr)
        c = hook_container(r)
        env = container_env(c)
        self.assertEqual(env["TESTENGINE_APIKEY"], APIKEY)
        script = kubelet_expand(c["command"][2], env)
        self.assertNotIn("vault:DevOps", script)
        bodies = run_hook(script, env)
        sent = json.loads(bodies[0])["Tests"][0]["TestEnvironmentVariables"]["EnvVars"]["WEIRD"]
        self.assertIn("$(TESTENGINE_APIKEY)", sent)

    def canary_values(self):
        return CANARY_VALUES % {"apikey": APIKEY, "weird": json.dumps(WEIRD)}

    def test_canary_tests_request_round_trips(self):
        r = render(self.canary_values(), show_only="templates/analysistemplate.yaml")
        self.assertEqual(r.returncode, 0, r.stderr)
        tmpl = next(d for d in docs(r) if d["metadata"]["name"].endswith("-tests"))
        c = tmpl["spec"]["metrics"][0]["provider"]["job"]["spec"]["template"]["spec"]["containers"][0]
        raw = next(e["value"] for e in c["env"] if e["name"] == "TESTS_REQUEST")
        self.assertNotIn("{{", raw)
        env = container_env(c)
        request = json.loads(kubelet_expand(raw, env))
        self.assertEqual(request["Tests"][0]["TestEnvironmentVariables"]["EnvVars"], {"WEIRD": WEIRD})

    def test_configmap_body_is_plain_json(self):
        r = render(self.canary_values(), show_only="templates/triggertestengine.yaml")
        self.assertEqual(r.returncode, 0, r.stderr)
        cm = next(d for d in docs(r) if d["kind"] == "ConfigMap")
        request = json.loads(cm["data"]["request.json"])
        self.assertEqual(request["Tests"][0]["TestEnvironmentVariables"]["EnvVars"], {"WEIRD": WEIRD})


# Helm's verdicts, pinned. Values are filled from real runs (see the report); a different Helm version fails the row.
DOT_VERDICT = "not a string"
TILDE_KEY_VERDICT = "refused"
MERGE_AFTER = {"A": "1"}

if __name__ == "__main__":
    unittest.main(verbosity=2)
