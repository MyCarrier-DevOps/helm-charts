# Agent instructions for helm-charts

## Stack-values guidance

This repository owns the guidance agents follow when they write a service's `helm/` values:
`agent-guidance/helm/.apm/instructions/helm.instructions.md`. It is published as the `helm` package in
MyCarrier-DevOps/apm_marketplace on every released version of the charts.

Any change under `charts/mycarrier-helm/` or `charts/mc-environment/` updates that file in the same branch, except a
change that only touches comments or the charts' `tests/`. Write the guidance for a stack author: which values exist
and what they do, defaults, schema rules and rejections, what renders, where each value belongs in the stack's files,
and environment behaviour. Keep its examples complete and renderable (`agent-guidance/tests/render-examples.sh`
renders them with these charts).

A breaking change (a value removed or renamed, a default or rendered output that existing stacks must react to, a
configuration that now fails to render) adds an entry at the top of the guidance's **Breaking changes** section: the
chart and version, what broke, and what a stack's values must change. Mark the commit as breaking (`feat!:` or a
`BREAKING CHANGE:` footer); the publishing workflow carries that entry to the marketplace.

A push hook (`.claude/hooks/check-helm-guidance.sh`) enforces this for Claude Code sessions: a push of chart changes
without a guidance change is denied with the reason. Update the guidance, commit, and push again.

Never edit `version:` in a `Chart.yaml`; the release workflow bumps it.
