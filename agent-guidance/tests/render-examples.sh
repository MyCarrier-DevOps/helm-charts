#!/usr/bin/env bash
# Renders every complete stack example in the guidance with this repository's charts, so the examples stay valid
# as the charts change. A complete example is a ```yaml block whose first line is a "# helm/<file>" header and that
# includes a helm/deployment/ file; each header starts a new file. mc-environment when a deployment file declares
# environments:, mycarrier-helm otherwise; the environment is the one in the example's values.<env>.yaml names.
# Usage: render-examples.sh [guidance file]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUIDE="${1:-$ROOT/agent-guidance/helm/.apm/instructions/helm.instructions.md}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$GUIDE" "$WORK" <<'PY'
import os, re, sys
text, out = open(sys.argv[1]).read(), sys.argv[2]
n = 0
for block in re.findall(r"```yaml\n(.*?)```", text, re.S):
    lines = block.splitlines()
    if not lines or not re.match(r"^# helm/\S+", lines[0]):
        continue
    if not any(re.match(r"^# helm/deployment/\S+", l) for l in lines):
        continue
    n += 1
    files, current = {}, None
    for line in lines:
        m = re.match(r"^# (helm/\S+)", line)
        if m:
            current = m.group(1)
            files.setdefault(current, [])
            continue
        files[current].append(line)
    for name, body in files.items():
        path = os.path.join(out, f"ex{n}", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("\n".join(body) + "\n")
PY

fail=0
n=0
for ex in "$WORK"/ex*; do
  [ -d "$ex" ] || continue
  n=$((n + 1))
  chart=mycarrier-helm
  grep -rqs '^environments:' "$ex/helm/deployment" && chart=mc-environment
  env=$(find "$ex/helm" -name 'values.*.yaml' | head -n 1 | sed -E 's#.*/values\.([^.]+)\.yaml$#\1#')
  args=()
  for f in helm/values.yaml "helm/values.$env.yaml" helm/deployment/values.yaml "helm/deployment/values.$env.yaml"; do
    [ -f "$ex/$f" ] && args+=(-f "$ex/$f")
  done
  if out=$(helm template example "$ROOT/charts/$chart" "${args[@]}" 2>&1 >/dev/null); then
    echo "  PASS  example $n ($chart, $env)"
  else
    echo "  FAIL  example $n ($chart, $env)"
    sed 's/^/        /' <<<"$out"
    fail=$((fail + 1))
  fi
done
if [ "$n" -eq 0 ]; then
  echo "No complete examples found in $GUIDE"
  exit 1
fi
[ "$fail" -eq 0 ] || { echo "FAILED: $fail"; exit 1; }
echo "All $n examples render."
