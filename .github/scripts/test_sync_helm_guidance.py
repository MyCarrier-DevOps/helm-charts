import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

import sync_helm_guidance as s

GUIDE = """---
description: d
applyTo: "helm/**"
---
# Helm Configuration Instructions

Intro.

## Breaking changes

Newest first.

### mycarrier-helm 4.4.0

- blueGreen removed.

### mycarrier-helm 4.2.0

- allowAllEndpoints rejected.
"""


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@e.com", *args],
                   check=True, capture_output=True)


class ReleasedState(unittest.TestCase):
    def repo(self):
        d = Path(tempfile.mkdtemp())
        git(d, "init", "-q", "-b", "main")
        for chart, ver in (("mycarrier-helm", "4.4.0"), ("mc-environment", "0.3.0")):
            (d / "charts" / chart / "tests").mkdir(parents=True)
            (d / "charts" / chart / "Chart.yaml").write_text(f"name: {chart}\nversion: {ver}\n")
            (d / "charts" / chart / "values.yaml").write_text("a: 1\n")
        git(d, "add", "-A"); git(d, "commit", "-q", "-m", "init")
        return d

    def bump(self, d, chart, ver):
        (d / "charts" / chart / "Chart.yaml").write_text(f"name: {chart}\nversion: {ver}\n")
        git(d, "add", "-A"); git(d, "commit", "-q", "-m", "Automated Change")

    def test_released_when_each_chart_last_changed_by_its_version_bump(self):
        d = self.repo()
        (d / "charts/mycarrier-helm/values.yaml").write_text("a: 2\n"); git(d, "commit", "-qam", "feat: x")
        self.bump(d, "mycarrier-helm", "4.4.1")
        ok, versions, pending = s.released_state(d)
        self.assertTrue(ok)
        self.assertEqual(versions, {"mycarrier-helm": "4.4.1", "mc-environment": "0.3.0"})
        self.assertEqual(pending, [])

    def test_pending_when_a_chart_changed_after_its_bump(self):
        d = self.repo()
        (d / "charts/mc-environment/values.yaml").write_text("a: 2\n"); git(d, "commit", "-qam", "feat: y")
        ok, _, pending = s.released_state(d)
        self.assertFalse(ok)
        self.assertEqual(pending, ["mc-environment"])

    def test_tests_and_package_json_do_not_make_a_release_pending(self):
        d = self.repo()
        (d / "charts/mycarrier-helm/tests/t_test.yaml").write_text("suite: t\n")
        (d / "charts/mycarrier-helm/package.json").write_text("{}\n")
        git(d, "add", "-A"); git(d, "commit", "-q", "-m", "test: only")
        self.assertTrue(s.released_state(d)[0])


class Stamp(unittest.TestCase):
    def test_line_after_title(self):
        out = s.stamp_text(GUIDE, {"mycarrier-helm": "4.4.1", "mc-environment": "0.3.1"})
        lines = out.splitlines()
        i = lines.index("# Helm Configuration Instructions")
        self.assertEqual(lines[i + 1:i + 3], ["", "Current for mycarrier-helm 4.4.1 and mc-environment 0.3.1."])
        self.assertTrue(out.startswith("---\ndescription: d\napplyTo: \"helm/**\"\n---\n"))

    def test_restamp_replaces_the_previous_line(self):
        once = s.stamp_text(GUIDE, {"mycarrier-helm": "4.4.1", "mc-environment": "0.3.1"})
        twice = s.stamp_text(once, {"mycarrier-helm": "4.4.2", "mc-environment": "0.3.1"})
        self.assertEqual(twice.count("Current for mycarrier-helm"), 1)
        self.assertIn("Current for mycarrier-helm 4.4.2 and mc-environment 0.3.1.", twice)
        self.assertEqual(s.stamp_text(twice, {"mycarrier-helm": "4.4.2", "mc-environment": "0.3.1"}), twice)


class Classify(unittest.TestCase):
    def test_feat_wins_over_fix(self):
        self.assertEqual(s.classify(["fix(x): a", "feat(mycarrier-helm): b", "Automated Change"]), ("feat", False))

    def test_default_is_fix(self):
        self.assertEqual(s.classify(["Automated Change", "docs(agent-guidance): c"]), ("fix", False))

    def test_bang_or_footer_is_breaking(self):
        self.assertEqual(s.classify(["feat(mycarrier-helm)!: drop x"]), ("feat", True))
        self.assertEqual(s.classify(["fix: y\n\nBREAKING CHANGE: z"]), ("feat", True))


class BreakingEntry(unittest.TestCase):
    def test_newest_entry(self):
        self.assertEqual(s.breaking_entry(GUIDE), "mycarrier-helm 4.4.0\n\n- blueGreen removed.")

    def test_fallback_when_no_entry(self):
        text = GUIDE.split("### mycarrier-helm 4.4.0")[0]
        self.assertEqual(s.breaking_entry(text), "See the Breaking changes section of the helm package's guidance.")


class KeepVersions(unittest.TestCase):
    def pkg(self, version):
        d = Path(tempfile.mkdtemp())
        (d / ".claude-plugin").mkdir()
        (d / "apm.yml").write_text(f"name: helm\nversion: {version}\ndescription: x\n")
        (d / ".claude-plugin/plugin.json").write_text(json.dumps({"name": "helm", "version": version}, indent=2) + "\n")
        return d

    def test_marketplace_version_kept(self):
        prev, new = self.pkg("0.4.2"), self.pkg("0.1.0")
        s.keep_versions(prev, new)
        self.assertIn("version: 0.4.2\n", (new / "apm.yml").read_text())
        self.assertEqual(json.loads((new / ".claude-plugin/plugin.json").read_text())["version"], "0.4.2")

    def test_first_publish_keeps_source_version(self):
        prev, new = Path(tempfile.mkdtemp()), self.pkg("0.1.0")
        s.keep_versions(prev, new)
        self.assertIn("version: 0.1.0\n", (new / "apm.yml").read_text())


class Upsert(unittest.TestCase):
    MP = "name: apm_marketplace\nversion: 0.11.0\nmarketplace:\n  packages:\n  - name: pipeline\n    source: ./packages/pipeline\n    version: 0.6.1\n"
    PKG = {"name": "helm", "version": "0.1.0", "description": "Guidance.\n", "keywords": ["helm", "instructions"]}

    def test_adds_once(self):
        out, added = s.upsert_text(self.MP, self.PKG)
        self.assertTrue(added)
        entry = [p for p in yaml.safe_load(out)["marketplace"]["packages"] if p["name"] == "helm"][0]
        self.assertEqual(entry["source"], "./packages/helm")
        self.assertEqual(entry["metadata"], {"category": "deployment", "tags": ["helm", "instructions"]})
        again, added_again = s.upsert_text(out, self.PKG)
        self.assertFalse(added_again)
        self.assertEqual(again, out)


if __name__ == "__main__":
    unittest.main()
