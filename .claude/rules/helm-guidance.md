---
paths:
  - "charts/mycarrier-helm/**"
  - "charts/mc-environment/**"
---
# Keep the stack-values guidance current

You are changing mycarrier-helm or mc-environment. Unless the change only touches comments or the chart's `tests/`,
update `agent-guidance/helm/.apm/instructions/helm.instructions.md` in the same branch so a stack author can write
values for the chart as it now is: values, defaults, schema rules, rendered output, where each value goes, and
environment behaviour. A breaking change also adds an entry at the top of its **Breaking changes** section and is
committed as breaking. Keep the guidance's complete examples renderable: `bash agent-guidance/tests/render-examples.sh`.
The push hook denies a push that misses this; when it does, update the guidance, commit, and push again.
