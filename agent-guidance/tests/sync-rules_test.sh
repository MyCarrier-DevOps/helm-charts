#!/usr/bin/env bash
# Tests for agent-guidance/helm/scripts/sync-rules.sh (the native Claude Code plugin delivery).
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/helm/scripts/sync-rules.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi; }

plugin() {  # plugin <version dir> <applyTo line(s)> -> plugin root with one instruction
  local root="$WORK/cache/$1"
  mkdir -p "$root/.apm/instructions"
  printf -- '---\ndescription: Helm values guidance\n%b\n---\n# Helm\n\nBody line.\n' "$2" > "$root/.apm/instructions/helm.instructions.md"
  echo "$root"
}
run() { CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$2" bash "$SCRIPT"; }

P="$WORK/project"; mkdir -p "$P/.claude/rules"; printf 'own rule\n' > "$P/.claude/rules/own.md"
root=$(plugin 1.2.3 'applyTo: "helm/**"')
out=$(run "$root" "$P")
R="$P/.claude/rules/helm/helm.md"
check "first run writes the rule" '[ -f "$R" ]'
check "applyTo becomes a paths list" 'grep -qx "paths:" "$R" && grep -qx "  - \"helm/\*\*\"" "$R"'
check "no applyTo left" '! grep -q "^applyTo" "$R"'
check "description and body kept" 'grep -qx "description: Helm values guidance" "$R" && grep -qx "Body line." "$R"'
check "stamp records the plugin version" '[ "$(tail -n 1 "$P/.claude/rules/helm/.plugin-version")" = 1.2.3 ]'
check "first run reports the update" '[[ $out == *"updated .claude/rules/helm/"* ]]'
check "project rules untouched" '[ "$(cat "$P/.claude/rules/own.md")" = "own rule" ]'

before=$(stat -c %Y "$R"); sleep 1
out=$(run "$root" "$P")
check "second run is silent" '[ -z "$out" ]'
check "second run leaves the file alone" '[ "$(stat -c %Y "$R")" = "$before" ]'

mv "$WORK/cache/1.2.3" "$WORK/cache/1.2.4"
out=$(run "$WORK/cache/1.2.4" "$P")
check "new plugin version refreshes the stamp" '[ "$(tail -n 1 "$P/.claude/rules/helm/.plugin-version")" = 1.2.4 ]'
check "an update leaves nothing else next to the rules" '[ "$(ls -A "$P/.claude/rules" | tr "\n" " ")" = "helm own.md " ]'

root=$(plugin 2.0.0 'applyTo: "helm/**, charts/{a,b}/**"')
run "$root" "$P" >/dev/null
check "comma list splits at top-level commas only" \
  'grep -qx "  - \"helm/\*\*\"" "$R" && grep -qx "  - \"charts/{a,b}/\*\*\"" "$R"'

root=$(plugin 3.0.0 'applyTo:\n  - "helm/**"\n  - "deploy/**"')
run "$root" "$P" >/dev/null
check "YAML list form keeps its items" 'grep -qx "paths:" "$R" && grep -qx "  - \"deploy/\*\*\"" "$R"'

rm "$root/.apm/instructions/helm.instructions.md"
run "$root" "$P" >/dev/null
check "removed instruction prunes the rule" '[ ! -e "$R" ] && [ -f "$P/.claude/rules/own.md" ]'

F="$WORK/failing"; mkdir -p "$F/.claude/rules" "$WORK/noawk"
printf '#!/bin/sh\nexit 1\n' > "$WORK/noawk/awk"; chmod +x "$WORK/noawk/awk"
PATH="$WORK/noawk:$PATH" CLAUDE_PLUGIN_ROOT="$(plugin 4.0.0 'applyTo: "helm/**"')" CLAUDE_PROJECT_DIR="$F" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
check "a failed run leaves no staging directory in .claude/rules" '[ -z "$(ls -A "$F/.claude/rules")" ]'

Q="$WORK/none"; mkdir -p "$Q"
out=$(cd "$Q" && env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$WORK/cache/2.0.0" bash "$SCRIPT")
check "no project dir: nothing written" '[ -z "$out" ] && [ ! -e "$Q/.claude" ]'

A="$WORK/apm"; mkdir -p "$A"
out=$(env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$A" bash "$SCRIPT" 2>&1 || echo "exit $?")
check "no plugin root (an APM install runs it so): nothing written or printed" '[ -z "$out" ] && [ -z "$(ls -A "$A")" ]'

echo
if [ "$fail" -ne 0 ]; then echo "FAILED: $fail"; exit 1; fi
echo "All sync-rules tests passed."
