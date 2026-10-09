# helm

Guidance for writing a service's `helm/` values with MyCarrier's charts, **mycarrier-helm** (direct) and
**mc-environment** (an ApplicationSet with one Application per environment). It covers the two layouts and their
merge order, global settings, applications, secrets, networking, scaling, test triggers, alerts and environment
conventions, and lists breaking changes per chart version.

It is maintained with the charts in [MyCarrier-DevOps/helm-charts](https://github.com/MyCarrier-DevOps/helm-charts)
and published here for every released chart version; the guidance names the chart versions it is current for.

## Install

With APM (Claude Code, GitHub Copilot, Cursor and other agents):

    apm install helm@apm_marketplace

APM deploys the instruction for `helm/**`: `.claude/rules/helm.md` for Claude Code,
`.github/instructions/helm.instructions.md` for Copilot, and the equivalent for other agents.

As a Claude Code plugin: install `helm` from this marketplace. A SessionStart hook writes the guidance to
`.claude/rules/helm/helm.md` in the project; commit it with the repository's other rules.

## Source

Edit the guidance in helm-charts (`agent-guidance/helm/`), not here; this directory is overwritten on every publish.
