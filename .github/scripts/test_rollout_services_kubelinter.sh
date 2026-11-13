#!/usr/bin/env bash
# kube-linter on rendered Rollout apps, run the way chart-renderer's render check runs it (DEVOPS-534).
#
# chart-renderer lints every rendered mycarrier-helm package with kube-linter; chart_renderer_kubelinter.sh holds its
# configuration.
# kube-linter models only built-in workloads, not the Argo Rollouts Rollout CRD. Before DEVOPS-534 its dangling-service
# check refused every Rollout app's stable and -preview Services, and in prod its dangling-horizontalpodautoscaler check
# refused the HPA that targets the Rollout. This checks that:
#   1. a Rollout app next to a Deployment app lints clean in preprod, in prod (rolling) and in prod as a canary;
#   2. a Service that selects no workload still fails dangling-service (the check stays on).
#
# Usage: test_rollout_services_kubelinter.sh   (KUBE_LINTER=<path> to choose the binary)
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=chart_renderer_kubelinter.sh
source .github/scripts/chart_renderer_kubelinter.sh

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# A copy of the chart, so the dependency build never writes into the working tree.
cp -R charts/mycarrier-helm charts/mc-mongodb "$TMP/"
helm dependency build "$TMP/mycarrier-helm" >/dev/null

# A Rollout app (api) next to a Deployment app (worker). The canary render needs api's test definitions: the dark
# stage, on by default, runs them; they also render triggertestengine.yaml, which the renderer does not lint.
cat > "$TMP/values.yaml" <<'EOF'
global:
  appStack: example
  correlationId: 11111111-2222-4333-8444-555555555555
  language: nodejs
applications:
  api:
    deploymentType: rollout
    canaryHealthPath: /health
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
    testtrigger:
      testdefinitions:
        - name: apitests
          containerImage: testing/example/api/tests
          containerTag: 1.0.0
          secretId: vault:QA/data/app_auth#SecretId
  worker:
    deploymentType: deployment
    image: {registry: registry.example.com, repository: worker, tag: "1.0.0"}
    ports: {http: 8080}
EOF

# render NAME ENVIRONMENT STRATEGY: the rendered dir on stdout.
render() {
  local out="$TMP/$1"
  helm template example "$TMP/mycarrier-helm" -f "$TMP/values.yaml" --set "environment.name=$2" \
    --set "global.deploymentStrategy=$3" --output-dir "$out" >/dev/null
  printf '%s' "$out"
}

for c in "preprod preprod rolling" "prod-rolling prod rolling" "prod-canary prod canary"; do
  read -r name env strategy <<<"$c"
  out=$(render "$name" "$env" "$strategy")
  tdir="$out/mycarrier-helm/templates"
  rc=0
  grep -qx "  name: example-api" "$tdir/service.yaml" || rc=1
  grep -qx "  name: example-api-preview" "$tdir/service.yaml" || rc=1
  what="the Rollout's stable and -preview Services render"
  if [ "$env" = prod ]; then
    grep -q 'kind: Rollout' "$tdir/autoscaler.yaml" || rc=1
    what="$what, and its HPA targets the Rollout"
  fi
  check "$name: $what" "$rc"
  res=$(lint "$out")
  rc=0; grep -qE "$lint_error_re" <<<"$res" && rc=1
  check "$name: a Rollout app next to a Deployment app passes chart-renderer's kube-linter" "$rc"
  [ "$rc" = 0 ] || printf '%s\n' "$res"
done

out="$TMP/preprod"
cat > "$out/mycarrier-helm/templates/orphan.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: example-orphan
  namespace: preprod
spec:
  ports:
    - name: http
      port: 8080
  selector:
    app.kubernetes.io/name: nothing-runs-this
EOF
res=$(lint "$out")
rc=0
grep -qE "$lint_error_re" <<<"$res" || rc=1
grep -q 'example-orphan' <<<"$res" || rc=1
grep -q 'check: dangling-service' <<<"$res" || rc=1
# Only the orphan is reported: every finding names it.
[ "$(grep -c '(check: ' <<<"$res")" = "$(grep -c 'example-orphan' <<<"$res")" ] || rc=1
check "a Service that selects no workload still fails dangling-service, and is the only finding (the check stays on)" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

if [ "$fail" -ne 0 ]; then echo "$fail check(s) failed"; exit 1; fi
echo "all kube-linter checks passed"
