#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Before a push leaves this repository, the stack-values guidance must have changed
# whenever charts/mycarrier-helm or charts/mc-environment changed in anything but comments (see AGENTS.md), compared
# with origin/main: at HEAD, or in the working tree when the same command commits before it pushes. A push that skips
# it is denied with the reason, so the agent updates the guidance and pushes again. It never prompts; when the check
# itself fails, the push is blocked.
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

# A push: `git [-C dir | -c k=v]... push` anywhere in the command (rtk-prefixed, chained, quoted as in
# `bash -c "git push"`, or by path as in `/usr/bin/git push`), or `gh pr create`, which pushes the head branch when it
# is not on the remote yet.
push_re='(^|[;&|({[:space:]"'\''`/])git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:];&|)"'\''`]|$)'
pr_re='(^|[;&|({[:space:]"'\''`/])gh[[:space:]]+pr[[:space:]]+create([[:space:];&|)"'\''`]|$)'
# before: for each kind of push found, the command text ahead of its last occurrence, with the character before it.
before=()
for re in "$push_re" "$pr_re"; do
  if [[ $command =~ ^(.*)$re ]]; then
    before+=("${BASH_REMATCH[1]}${BASH_REMATCH[2]}")
  fi
done
[ "${#before[@]}" -gt 0 ] || exit 0
# From here on an unexpected failure blocks the push (exit 2) instead of letting it through unchecked. Earlier, a
# failure (no jq, say) must not block every Bash call.
trap 'echo "helm guidance check failed unexpectedly; the push is blocked until it can run" >&2; exit 2' ERR

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

# The user's diff settings (colour, path prefixes, external diff drivers) must not change what the checks below read.
gitdiff() {
  git -C "$top" -c color.ui=never -c diff.noprefix=false -c diff.mnemonicPrefix=false diff --no-ext-diff --no-color "$@"
}

paths=("${CHARTS[@]}" ':(glob,exclude)charts/*/tests/**')

# A push compares origin/main with HEAD. When something runs ahead of it in the same command (`git add -A && git commit
# -m x && git push`), that commit does not exist yet while this hook runs, so the working tree is compared instead and
# untracked files count as changed.
range=("$base" HEAD)
new_files=
new_guidance=
runs_ahead=$'(&&|[|;]|\n)'
if [[ ${before[*]} =~ $runs_ahead ]]; then
  range=("$base")
  new_files=$(git -C "$top" ls-files --others --exclude-standard -- "${paths[@]}")
  new_guidance=$(git -C "$top" ls-files --others --exclude-standard -- "$GUIDANCE")
fi

files=$(gitdiff --name-only "${range[@]}" -- "${paths[@]}")
[ -z "$new_files" ] || files=$(printf '%s\n%s\n' "$files" "$new_files" | sed '/^$/d')
[ -n "$files" ] || exit 0

# Changed lines that are not blank, a YAML comment, or a single-line Helm comment. Lines inside a multi-line
# {{/* ... */}} count as changes: when in doubt, ask for maintenance.
patch=$(gitdiff -U0 "${range[@]}" -- "${paths[@]}")
real=$(printf '%s\n' "$patch" \
  | grep -E '^[+-]' \
  | grep -vE '^(\+\+\+|---) (a/|b/|/dev/null)' \
  | cut -c2- \
  | grep -vE '^[[:space:]]*$' \
  | grep -vE '^[[:space:]]*#' \
  | grep -vE '^[[:space:]]*\{\{-?[[:space:]]*/\*.*\*/[[:space:]]*-?\}\}[[:space:]]*$' || true)
[ -n "$real$new_files" ] || exit 0

guidance=$(gitdiff --name-only "${range[@]}" -- "$GUIDANCE")
if [ -z "$guidance$new_guidance" ]; then
  list=$(head -n 20 <<<"$files" | sed 's/^/  /')
  deny "This branch changes the charts but not the stack-values guidance ($GUIDANCE). Changed chart files compared with origin/main:
$list
Update the guidance so a stack author can write values for the charts as they now are: values, defaults, schema rules, rendered output, layout and environment behaviour. For a breaking change, add an entry at the top of its Breaking changes section. Commit the update, then push again."
fi
exit 0
