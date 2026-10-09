#!/usr/bin/env bash
# Tests for check-helm-guidance.sh. Each case builds a throwaway repository with a bare origin, makes a change on a
# branch, and feeds the hook the PreToolUse JSON Claude Code sends for a Bash call.
set -euo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/check-helm-guidance.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
G=agent-guidance/helm/.apm/instructions/helm.instructions.md
fail=0

gitq() { git -c user.name=test -c user.email=test@example.com "$@"; }

# setup <name> [nocharts] -> prints the clone path, on branch "work", main pushed to origin
setup() {
  local o="$WORK/$1.git" c="$WORK/$1"
  git init -q --bare -b main "$o"
  git init -q -b main "$c"
  if [ "${2:-}" != nocharts ]; then
    mkdir -p "$c/charts/mycarrier-helm/templates" "$c/charts/mycarrier-helm/tests" "$c/charts/mc-environment"
    printf 'replicas: 1\n' > "$c/charts/mycarrier-helm/values.yaml"
    printf '{{/* render a config map */}}\nkind: ConfigMap\n' > "$c/charts/mycarrier-helm/templates/cm.yaml"
    printf 'suite: cm\n' > "$c/charts/mycarrier-helm/tests/cm_test.yaml"
    printf 'environments: []\n' > "$c/charts/mc-environment/values.yaml"
  fi
  mkdir -p "$c/$(dirname "$G")"
  printf -- '---\ndescription: guidance\napplyTo: "helm/**"\n---\n# Guidance\n' > "$c/$G"
  gitq -C "$c" add -A
  gitq -C "$c" commit -q -m init
  git -C "$c" remote add origin "$o"
  git -C "$c" push -q origin main
  git -C "$c" switch -q -c work
  echo "$c"
}
commit() { gitq -C "$1" add -A; gitq -C "$1" commit -q -m change; }
# decide <cwd> <command> -> "deny" or "allow"; the reason goes to $WORK/reason
decide() {
  local out
  out=$(jq -n --arg d "$1" --arg c "$2" '{cwd: $d, tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK")
  [ -n "$out" ] || out='{}'
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$out" > "$WORK/reason"
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null; then
    echo deny
  else
    echo allow
  fi
}
expect() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (want $2, got $3)"; fail=$((fail + 1)); fi
}

c=$(setup values); printf 'replicas: 2\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "values change without guidance blocks git push" deny "$(decide "$c" 'git push -u origin work')"
grep -q 'charts/mycarrier-helm/values.yaml' "$WORK/reason" && echo "  PASS  reason names the changed file" \
  || { echo "  FAIL  reason names the changed file"; fail=$((fail + 1)); }

c=$(setup withguide); printf 'replicas: 2\n' > "$c/charts/mycarrier-helm/values.yaml"
printf 'replicas default is now 2\n' >> "$c/$G"; commit "$c"
expect "values change with guidance update is allowed" allow "$(decide "$c" 'git push')"

c=$(setup comments); printf '# replicas for the api\nreplicas: 1\n' > "$c/charts/mycarrier-helm/values.yaml"
printf '{{/* render a config map */}}\n{{- /* second note */ -}}\nkind: ConfigMap\n' > "$c/charts/mycarrier-helm/templates/cm.yaml"
commit "$c"
expect "comment-only change is allowed" allow "$(decide "$c" 'git push')"

c=$(setup multiline); printf '{{/*\nlonger note\n*/}}\n{{/* render a config map */}}\nkind: ConfigMap\n' > "$c/charts/mycarrier-helm/templates/cm.yaml"
commit "$c"
expect "multi-line template comment counts as a change" deny "$(decide "$c" 'git push')"

c=$(setup inline); printf 'replicas: 1 # one\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "inline trailing comment counts as a change" deny "$(decide "$c" 'git push')"

c=$(setup separator); printf -- '---\nreplicas: 1\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "YAML document separator counts as a change" deny "$(decide "$c" 'git push')"

c=$(setup testsonly); printf 'suite: cm2\n' > "$c/charts/mycarrier-helm/tests/cm_test.yaml"; commit "$c"
expect "tests-only change is allowed" allow "$(decide "$c" 'git push')"

c=$(setup envchart); printf 'environments: [{name: dev}]\n' > "$c/charts/mc-environment/values.yaml"; commit "$c"
expect "mc-environment change blocks too" deny "$(decide "$c" 'git push')"

c=$(setup variants); printf 'replicas: 3\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "non-push command is ignored" allow "$(decide "$c" 'git status')"
expect "git stash push is not a push" allow "$(decide "$c" 'git stash push -m wip')"
expect "rtk git push is detected" deny "$(decide "$c" 'rtk git push')"
expect "chained git push is detected" deny "$(decide "$c" 'git commit -m x && git push origin work')"
expect "git -c option before push is detected" deny "$(decide "$c" 'git -c push.default=current push')"
expect "git -C <dir> push from elsewhere is detected" deny "$(decide "$WORK" "git -C $c push")"
expect "quoted git -C dir is detected" deny "$(decide "$WORK" "git -C \"$c\" push")"
expect "gh pr create is detected" deny "$(decide "$c" 'gh pr create --fill')"

c=$(setup other nocharts); printf 'x\n' > "$c/README.md"; commit "$c"
expect "repository without the charts is ignored" allow "$(decide "$c" 'git push')"

c=$(setup nothingahead); git -C "$c" switch -q main
expect "nothing ahead of origin/main is allowed" allow "$(decide "$c" 'git push')"

c=$(setup noorigin); printf 'replicas: 4\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
git -C "$c" remote remove origin
expect "unresolvable origin/main blocks" deny "$(decide "$c" 'git push')"
grep -q 'could not compare' "$WORK/reason" && echo "  PASS  reason says the check could not run" \
  || { echo "  FAIL  reason says the check could not run"; fail=$((fail + 1)); }

echo
if [ "$fail" -ne 0 ]; then echo "FAILED: $fail"; exit 1; fi
echo "All hook tests passed."
