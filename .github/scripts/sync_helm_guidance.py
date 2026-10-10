#!/usr/bin/env python3
"""Publishing helpers for the helm guidance package (used by .github/workflows/sync-marketplace.yml).

helm-charts `main` is published only in its released state: for mycarrier-helm and mc-environment, the latest commit
touching the chart must be the one that set its Chart.yaml version. Changes Helm-Release does not release (tests/,
*test*.yaml and *test*.yml) and the generated package.json do not count.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

CHARTS = ("mycarrier-helm", "mc-environment")
SOURCES = ("charts/mycarrier-helm", "charts/mc-environment", "agent-guidance/helm")
STAMP_RE = re.compile(r"^Current for mycarrier-helm \S+ and mc-environment \S+\.$")
FALLBACK = "See the Breaking changes section of the helm package's guidance."


def git(repo, *args) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def chart_version(repo, chart, rev="HEAD") -> str:
    text = git(repo, "show", f"{rev}:charts/{chart}/Chart.yaml")
    return yaml.safe_load(text)["version"]


def released_state(repo):
    versions, pending = {}, []
    for chart in CHARTS:
        versions[chart] = str(chart_version(repo, chart))
        last = git(repo, "log", "-1", "--format=%H", "--", f"charts/{chart}",
                   f":(exclude)charts/{chart}/tests", f":(exclude)charts/{chart}/package.json",
                   f":(glob,exclude)charts/{chart}/**/*test*.yaml",
                   f":(glob,exclude)charts/{chart}/**/*test*.yml").strip()
        diff = git(repo, "show", "--format=", last, "--", f"charts/{chart}/Chart.yaml") if last else ""
        if not re.search(r"^\+version:", diff, re.M):
            pending.append(chart)
    return not pending, versions, pending


def stamp_text(text, versions) -> str:
    """Put the stamp line as its own paragraph right after the first '# ' heading; a previous stamp (and the blank
    line before it) is removed first, so restamping is stable."""
    lines = []
    for l in text.split("\n"):
        if STAMP_RE.match(l):
            if lines and lines[-1] == "":
                lines.pop()
            continue
        lines.append(l)
    stamp = f"Current for mycarrier-helm {versions['mycarrier-helm']} and mc-environment {versions['mc-environment']}."
    start = lines.index("---", 1) + 1 if lines and lines[0] == "---" else 0
    for i in range(start, len(lines)):
        if lines[i].startswith("# "):
            return "\n".join(lines[:i + 1] + ["", stamp] + lines[i + 1:])
    raise ValueError("no '# ' heading after the front matter")


def classify(messages):
    breaking = any(re.match(r"^[a-z]+(\([^)]*\))?!:", m) or re.search(r"(^|\n)BREAKING[ -]CHANGE:", m) for m in messages)
    feat = breaking or any(re.match(r"^feat(\([^)]*\))?!?:", m) for m in messages)
    return ("feat" if feat else "fix"), breaking


def breaking_entry(text) -> str:
    m = re.search(r"^## Breaking changes\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return FALLBACK
    e = re.search(r"^### (.+?)$(.*?)(?=^### |\Z)", m.group(1), re.M | re.S)
    if not e:
        return FALLBACK
    return f"{e.group(1).strip()}\n\n{e.group(2).strip()}".strip()


def keep_versions(previous: Path, package: Path) -> None:
    prev_apm = previous / "apm.yml"
    if not prev_apm.exists():
        return
    version = str(yaml.safe_load(prev_apm.read_text())["version"])
    apm = package / "apm.yml"
    apm.write_text(re.sub(r"^version:\s*\S+", f"version: {version}", apm.read_text(), count=1, flags=re.M))
    plugin = package / ".claude-plugin" / "plugin.json"
    data = json.loads(plugin.read_text())
    data["version"] = version
    plugin.write_text(json.dumps(data, indent=2) + "\n")


def upsert_text(marketplace_yaml: str, package: dict):
    mp = yaml.safe_load(marketplace_yaml)
    packages = mp.setdefault("marketplace", {}).setdefault("packages", [])
    if any(p.get("name") == package["name"] for p in packages):
        return marketplace_yaml, False
    packages.append({
        "name": package["name"],
        "description": package.get("description", "").strip() + "\n",
        "source": f"./packages/{package['name']}",
        "version": str(package["version"]),
        "metadata": {"category": "deployment", "tags": list(package.get("keywords", []))},
    })
    return yaml.dump(mp, sort_keys=False, default_flow_style=False, width=88), True


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("released-state"); a.add_argument("--repo", required=True)
    a = sub.add_parser("stamp"); a.add_argument("--file", required=True)
    a.add_argument("--mycarrier-helm", required=True); a.add_argument("--mc-environment", required=True)
    a = sub.add_parser("bump"); a.add_argument("--previous", default=""); a.add_argument("--repo", required=True)
    a = sub.add_parser("breaking-entry"); a.add_argument("--file", required=True)
    a = sub.add_parser("keep-versions"); a.add_argument("--previous", required=True); a.add_argument("--package", required=True)
    a = sub.add_parser("upsert"); a.add_argument("--marketplace", required=True); a.add_argument("--package", required=True)
    args = p.parse_args(argv)

    if args.cmd == "released-state":
        ok, versions, pending = released_state(args.repo)
        print(f"released={'true' if ok else 'false'}")
        print(f"mycarrier_helm={versions['mycarrier-helm']}")
        print(f"mc_environment={versions['mc-environment']}")
        print(f"pending={','.join(pending)}")
    elif args.cmd == "stamp":
        f = Path(args.file)
        f.write_text(stamp_text(f.read_text(), {"mycarrier-helm": args.mycarrier_helm, "mc-environment": args.mc_environment}))
    elif args.cmd == "bump":
        if not args.previous:
            kind, breaking = "feat", False
        else:
            raw = git(args.repo, "log", "-z", "--format=%B", f"{args.previous}..HEAD", "--", *SOURCES)
            kind, breaking = classify([m.strip() for m in raw.split("\0") if m.strip()])
        print(f"type={kind}")
        print(f"breaking={1 if breaking else 0}")
    elif args.cmd == "breaking-entry":
        print(breaking_entry(Path(args.file).read_text()))
    elif args.cmd == "keep-versions":
        keep_versions(Path(args.previous), Path(args.package))
    elif args.cmd == "upsert":
        mp = Path(args.marketplace)
        out, added = upsert_text(mp.read_text(), yaml.safe_load(Path(args.package).read_text()))
        if added:
            mp.write_text(out)
        print("added" if added else "unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
