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
# says <name> <text> <file>: the file (the last reason or stderr) contains the text
says() {
  if grep -qF -- "$2" "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi
}

c=$(setup values); printf 'replicas: 2\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "values change without guidance blocks git push" deny "$(decide "$c" 'git push -u origin work')"
says "reason names the changed file" 'charts/mycarrier-helm/values.yaml' "$WORK/reason"

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
expect "git push inside bash -c \"...\" is detected" deny "$(decide "$c" 'bash -c "git push"')"
expect "/usr/bin/git push is detected" deny "$(decide "$c" '/usr/bin/git push')"

# A command that commits and then pushes: the hook runs before the commit exists, so the working tree counts.
SAME='git add -A && git commit -m x && git push'
c=$(setup samecmd); printf 'replicas: 8\n' > "$c/charts/mycarrier-helm/values.yaml"
expect "uncommitted chart change committed and pushed in one command is denied" deny "$(decide "$c" "$SAME")"
expect "commit and push on separate lines of one command are denied too" deny "$(decide "$c" $'git commit -am x\ngit push')"
expect "commit then gh pr create in one command is denied too" deny "$(decide "$c" 'git commit -am x && gh pr create --fill')"
printf 'replicas default is now 8\n' >> "$c/$G"
expect "uncommitted chart and guidance changes pushed in one command are allowed" allow "$(decide "$c" "$SAME")"
c=$(setup uncommittedguide); printf 'replicas: 9\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
printf 'replicas default is now 9\n' >> "$c/$G"
expect "an uncommitted guidance change does not satisfy a plain git push" deny "$(decide "$c" 'git push')"
expect "a pipe after the push keeps the HEAD comparison" deny "$(decide "$c" 'git push 2>&1 | tail -n 5')"
c=$(setup untracked); printf 'kind: Secret\n' > "$c/charts/mycarrier-helm/templates/secret.yaml"
expect "untracked new template committed and pushed in one command is denied" deny "$(decide "$c" "$SAME")"
says "reason names the untracked file" 'charts/mycarrier-helm/templates/secret.yaml' "$WORK/reason"
c=$(setup newguide); gitq -C "$c" rm -q "$G"; commit "$c"; git -C "$c" push -q origin work:main
mkdir -p "$c/$(dirname "$G")"; printf -- '---\ndescription: guidance\n---\n# Guidance\n' > "$c/$G"
printf 'replicas: 10\n' > "$c/charts/mycarrier-helm/values.yaml"
expect "a new, untracked guidance file counts when it is committed in the same command" allow "$(decide "$c" "$SAME")"

# noisy <clone>: diff settings a user may have in their git config, which must not change what the hook sees.
noisy() {
  git -C "$1" config color.ui always
  git -C "$1" config color.diff always
  git -C "$1" config diff.noprefix true
  git -C "$1" config diff.mnemonicPrefix true
  git -C "$1" config diff.external true
}
c=$(setup noisyreal); noisy "$c"; printf 'replicas: 6\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "real change is denied whatever the user's diff config" deny "$(decide "$c" 'git push')"
c=$(setup noisycomment); noisy "$c"; printf '# replicas for the api\nreplicas: 1\n' > "$c/charts/mycarrier-helm/values.yaml"
commit "$c"
expect "comment-only change is allowed whatever the user's diff config" allow "$(decide "$c" 'git push')"
c=$(setup noisysame); noisy "$c"; printf '# replicas for the api\nreplicas: 1\n' > "$c/charts/mycarrier-helm/values.yaml"
expect "uncommitted comment-only change is allowed whatever the user's diff config" allow "$(decide "$c" "$SAME")"

# status <path dir> <cwd> <command> -> the hook's exit status with <path dir> first on PATH; stderr goes to $WORK/stderr
status() {
  local rc=0
  jq -n --arg d "$2" --arg c "$3" '{cwd: $d, tool_name: "Bash", tool_input: {command: $c}}' \
    | PATH="$1:$PATH" bash "$HOOK" >/dev/null 2>"$WORK/stderr" || rc=$?
  echo "$rc"
}
# brokengit <name> <argument>: a git that works until it is given <argument>, then fails as a broken repository would.
brokengit() {
  mkdir -p "$WORK/$1"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = %q ] && { echo "fatal: simulated" >&2; exit 128; }; done\nexec %q "$@"\n' \
    "$2" "$(command -v git)" > "$WORK/$1/git"
  chmod +x "$WORK/$1/git"
}
brokengit nodiff diff; brokengit nopatch -U0; brokengit noguide "$G"
mkdir -p "$WORK/nojq"; printf '#!/bin/sh\nexit 1\n' > "$WORK/nojq/jq"; chmod +x "$WORK/nojq/jq"
c=$(setup broken); printf 'replicas: 7\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "an unexpected failure after a push is detected blocks it (exit 2)" 2 "$(status "$WORK/nodiff" "$c" 'git push')"
says "the failure is explained on stderr" 'failed unexpectedly' "$WORK/stderr"
expect "a failure while reading the changed lines blocks too (exit 2)" 2 "$(status "$WORK/nopatch" "$c" 'git push')"
expect "a failure while checking the guidance blocks too (exit 2)" 2 "$(status "$WORK/noguide" "$c" 'git push')"
expect "a failure before a push is detected never blocks (exit 1)" 1 "$(status "$WORK/nojq" "$c" 'git status')"

c=$(setup other nocharts); printf 'x\n' > "$c/README.md"; commit "$c"
expect "repository without the charts is ignored" allow "$(decide "$c" 'git push')"

c=$(setup nothingahead); git -C "$c" switch -q main
expect "nothing ahead of origin/main is allowed" allow "$(decide "$c" 'git push')"

c=$(setup noorigin); printf 'replicas: 4\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
git -C "$c" remote remove origin
expect "unresolvable origin/main blocks" deny "$(decide "$c" 'git push')"
says "reason says the check could not run" 'could not compare' "$WORK/reason"

c=$(setup orphan); git -C "$c" checkout -q --orphan lone
printf 'replicas: 11\n' > "$c/charts/mycarrier-helm/values.yaml"; commit "$c"
expect "branch with no common history with origin/main blocks" deny "$(decide "$c" 'git push')"
says "reason says the histories could not be compared" 'could not compare' "$WORK/reason"

echo
if [ "$fail" -ne 0 ]; then echo "FAILED: $fail"; exit 1; fi
echo "All hook tests passed."
