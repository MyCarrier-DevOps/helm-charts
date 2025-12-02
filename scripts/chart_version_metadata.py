#!/usr/bin/env python3
"""Compute chart version metadata for the manual Helm release workflow.

This script mirrors the prerelease logic from the EnvoyDevFallback workflow by
appending a prerelease suffix for any release that does not target the default
branch. Metadata is surfaced back to GitHub Actions through ``$GITHUB_OUTPUT``
so subsequent steps can reuse the calculated versions.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Tuple

VERSION_REGEX = re.compile(r"(?m)^version:\s*\"?([0-9A-Za-z.+-]+)\"?\s*$")


class VersionMetadataError(RuntimeError):
    """Raised when the chart version metadata cannot be determined."""


def read_version_from_content(content: str) -> str:
    match = VERSION_REGEX.search(content)
    if not match:
        raise VersionMetadataError("Unable to find 'version' field in Chart.yaml contents.")
    return match.group(1)


def load_chart_version(ref: str, rel_path: Path) -> str:
    if ref == "WORKTREE":
        try:
            return read_version_from_content(rel_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:  # pragma: no cover - defensive
            raise VersionMetadataError(f"Chart file {rel_path} does not exist.") from exc
    try:
        output = subprocess.check_output(
            ["git", "show", f"{ref}:{rel_path.as_posix()}"], text=True
        )
    except subprocess.CalledProcessError as exc:  # pragma: no cover - defensive
        raise VersionMetadataError(f"Failed to read {rel_path} from {ref} (git show).") from exc
    return read_version_from_content(output)


def parse_semver_core(version: str) -> Tuple[int, int, int]:
    core = version.split("-", 1)[0]
    parts = core.split(".")
    if len(parts) != 3:
        raise VersionMetadataError(
            f"Expected semantic version in MAJOR.MINOR.PATCH form, got: {version}"
        )
    try:
        return tuple(int(part) for part in parts)
    except ValueError as exc:  # pragma: no cover - defensive
        raise VersionMetadataError(f"Version components must be integers: {version}") from exc


def bump_patch(version: str) -> str:
    major, minor, patch = parse_semver_core(version)
    patch += 1
    return f"{major}.{minor}.{patch}"


def sanitize_identifier(value: str) -> str:
    clean = re.sub(r"[^0-9A-Za-z.-]+", "-", value.lower())
    clean = re.sub(r"-{2,}", "-", clean).strip("-.")
    return clean or "pre"


def write_outputs(outputs: dict[str, str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        raise VersionMetadataError("GITHUB_OUTPUT environment variable is not set.")
    with open(output_path, "a", encoding="utf-8") as fh:
        for key, value in outputs.items():
            fh.write(f"{key}={value}\n")


def main() -> int:
    try:
        chart_name = os.environ["CHART_NAME"]
        target_branch = os.environ["TARGET_BRANCH"]
        default_branch = os.environ["DEFAULT_BRANCH"]
        user_chart_version = os.environ.get("USER_CHART_VERSION", "").strip()
        run_number = os.environ.get("RUN_NUMBER", "0")
    except KeyError as exc:
        missing = exc.args[0]
        print(f"Missing required environment variable: {missing}", file=sys.stderr)
        return 1

    chart_rel = Path("charts") / chart_name / "Chart.yaml"
    try:
        current_version = load_chart_version("WORKTREE", chart_rel)
    except VersionMetadataError as exc:  # pragma: no cover - defensive
        print(str(exc), file=sys.stderr)
        return 1

    outputs: dict[str, str] = {
        "current_version": current_version,
    }

    if target_branch == default_branch:
        outputs["chart_version_for_bumper"] = user_chart_version
        outputs["is_prerelease"] = "false"
        print(f"Default branch release detected ({default_branch}).")
        if user_chart_version:
            print(f"Using provided chart version: {user_chart_version}")
        else:
            print("No explicit chart version provided; chart-version-bumper will auto-bump patch.")
        write_outputs(outputs)
        return 0

    if user_chart_version:
        base_core = user_chart_version.split("-", 1)[0]
        # Validate the provided base core to ensure it is semver compatible.
        parse_semver_core(base_core)
    else:
        try:
            default_version = load_chart_version(f"origin/{default_branch}", chart_rel)
        except VersionMetadataError:
            default_version = current_version
        base_core = bump_patch(default_version)

    slug = sanitize_identifier(target_branch)
    prerelease_identifier = f"{slug}.build{run_number}"
    target_version = f"{base_core}-{prerelease_identifier}"

    outputs.update(
        {
            "chart_version_for_bumper": target_version,
            "is_prerelease": "true",
            "base_version": base_core,
            "prerelease_identifier": prerelease_identifier,
        }
    )

    print(f"Computed prerelease chart version: {target_version}")
    write_outputs(outputs)
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entrypoint
    sys.exit(main())
