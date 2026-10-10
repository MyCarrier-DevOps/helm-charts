import contextlib
import io
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

    def test_files_helm_release_ignores_do_not_make_a_release_pending(self):
        # Helm-Release does not run for charts/**/*test*.yaml or *.yml, so they must not hold the guidance back.
        for rel in ("templates/triggertestengine.yaml", "ci-test.yml"):
            with self.subTest(rel=rel):
                d = self.repo()
                self.bump(d, "mycarrier-helm", "4.4.1")
                f = d / "charts/mycarrier-helm" / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text("kind: Job\n")
                git(d, "add", "-A"); git(d, "commit", "-q", "-m", "fix(mycarrier-helm): trigger")
                self.assertEqual(s.released_state(d)[2], [])


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

    def test_existing_entry_at_later_version_is_left_alone(self):
        mp = self.MP + "  - name: helm\n    source: ./packages/helm\n    version: 0.4.2\n"
        out, added = s.upsert_text(mp, self.PKG)
        self.assertFalse(added)
        self.assertEqual(out, mp)
        entry = [p for p in yaml.safe_load(out)["marketplace"]["packages"] if p["name"] == "helm"][0]
        self.assertEqual(entry["version"], "0.4.2")


def run_cli(*argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        s.main(list(argv))
    return dict(l.split("=", 1) for l in buf.getvalue().splitlines())


class Cli(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        git(self.d, "init", "-q", "-b", "main")
        for rel in ("charts/mycarrier-helm/values.yaml", "charts/mc-environment/values.yaml",
                    "agent-guidance/helm/a.md", "README.md"):
            f = self.d / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text("0\n")
        for chart, ver in (("mycarrier-helm", "4.4.0"), ("mc-environment", "0.3.0")):
            (self.d / "charts" / chart / "Chart.yaml").write_text(f"name: {chart}\nversion: {ver}\n")
        git(self.d, "add", "-A"); git(self.d, "commit", "-q", "-m", "init")
        self.prev = subprocess.run(["git", "-C", str(self.d), "rev-parse", "HEAD"], check=True,
                                   capture_output=True, text=True).stdout.strip()

    def commit(self, rel, message):
        f = self.d / rel
        f.write_text(f.read_text() + "x\n")
        git(self.d, "add", "-A"); git(self.d, "commit", "-q", "-m", message)

    def bump(self):
        return run_cli("bump", "--previous", self.prev, "--repo", str(self.d))

    def test_fix_only_range(self):
        self.commit("charts/mycarrier-helm/values.yaml", "fix(mycarrier-helm): a")
        self.assertEqual(self.bump(), {"type": "fix", "breaking": "0"})

    def test_feat_in_range(self):
        self.commit("charts/mycarrier-helm/values.yaml", "fix(mycarrier-helm): a")
        self.commit("charts/mc-environment/values.yaml", "feat(mc-environment): b")
        self.assertEqual(self.bump(), {"type": "feat", "breaking": "0"})

    def test_breaking_subject_or_footer(self):
        self.commit("agent-guidance/helm/a.md", "feat(agent-guidance)!: c")
        self.assertEqual(self.bump(), {"type": "feat", "breaking": "1"})
        self.commit("charts/mycarrier-helm/values.yaml", "fix: d\n\nBREAKING CHANGE: e")
        self.assertEqual(self.bump()["breaking"], "1")

    def test_commits_outside_sources_are_ignored(self):
        self.commit("charts/mycarrier-helm/values.yaml", "fix: a")
        self.commit("README.md", "feat!: unrelated")
        self.assertEqual(self.bump(), {"type": "fix", "breaking": "0"})

    def test_first_publish(self):
        self.assertEqual(run_cli("bump", "--previous", "", "--repo", str(self.d)),
                         {"type": "feat", "breaking": "0"})

    def test_released_state_prints_the_four_keys(self):
        out = run_cli("released-state", "--repo", str(self.d))
        self.assertEqual(set(out), {"released", "mycarrier_helm", "mc_environment", "pending"})
        self.assertEqual(out["mycarrier_helm"], "4.4.0")


if __name__ == "__main__":
    unittest.main()
