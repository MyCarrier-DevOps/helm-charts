#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Before a push leaves this repository, the stack-values guidance must have changed
# whenever charts/mycarrier-helm or charts/mc-environment changed in anything but comments (see AGENTS.md). A push
# that skips it is denied with the reason, so the agent updates the guidance and pushes again. It never prompts.
set -euo pipefail

GUIDANCE=agent-guidance/helm/.apm/instructions/helm.instructions.md
CHARTS=(charts/mycarrier-helm charts/mc-environment)

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

input=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
cwd=${cwd:-$PWD}

# A push: `git [-C dir | -c k=v]... push` anywhere in the command (rtk-prefixed, chained), or `gh pr create`, which
# pushes the head branch when it is not on the remote yet.
push_re='(^|[;&|({[:space:]])git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'
pr_re='(^|[;&|({[:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if ! [[ $command =~ $push_re || $command =~ $pr_re ]]; then
  exit 0
fi

dir=$cwd
if [[ $command =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  target=${BASH_REMATCH[1]}
  target=${target#[\"\']}
  target=${target%[\"\']}
  case $target in
    /*) dir=$target ;;
    *) dir=$cwd/$target ;;
  esac
fi

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
for chart in "${CHARTS[@]}"; do
  [ -d "$top/$chart" ] || exit 0
done

timeout 30 git -C "$top" fetch -q origin main 2>/dev/null || true
base=$(git -C "$top" merge-base origin/main HEAD 2>/dev/null) \
  || deny "The helm guidance check could not compare this branch with origin/main (no origin/main, or no common history). Fix the remote or the history, then push again."

paths=("${CHARTS[@]}" ':(glob,exclude)charts/*/tests/**')
files=$(git -C "$top" diff --name-only "$base" HEAD -- "${paths[@]}")
[ -n "$files" ] || exit 0

# Changed lines that are not blank, a YAML comment, or a single-line Helm comment. Lines inside a multi-line
# {{/* ... */}} count as changes: when in doubt, ask for maintenance.
real=$(git -C "$top" diff -U0 "$base" HEAD -- "${paths[@]}" \
  | grep -E '^[+-]' \
  | grep -vE '^(\+\+\+|---) (a/|b/|/dev/null)' \
  | cut -c2- \
  | grep -vE '^[[:space:]]*$' \
  | grep -vE '^[[:space:]]*#' \
  | grep -vE '^[[:space:]]*\{\{-?[[:space:]]*/\*.*\*/[[:space:]]*-?\}\}[[:space:]]*$' || true)
[ -n "$real" ] || exit 0

if git -C "$top" diff --quiet "$base" HEAD -- "$GUIDANCE"; then
  list=$(head -n 20 <<<"$files" | sed 's/^/  /')
  deny "This branch changes the charts but not the stack-values guidance ($GUIDANCE). Changed chart files compared with origin/main:
$list
Update the guidance so a stack author can write values for the charts as they now are: values, defaults, schema rules, rendered output, layout and environment behaviour. For a breaking change, add an entry at the top of its Breaking changes section. Commit the update, then push again."
fi
exit 0
