#!/usr/bin/env bash
# kube-linter on a rendered Rollout app, run the way chart-renderer's render check runs it (DEVOPS-534).
#
# chart-renderer lints every mycarrier-helm package with `kube-linter lint <dir> --exclude ... --ignore-paths ...
# --add-all-built-in` (MyCarrier-DevOps/chart-renderer ci/render/internal/infrastructure/checks/kubelinter.go). Its
# dangling-service check models only built-in workloads, so before DEVOPS-534 it refused every Rollout app's stable and
# -preview Services. This renders a Rollout app next to a Deployment app and checks that:
#   1. the render lints clean (the Rollout Services carry the per-object ignore annotation);
#   2. a Service whose selector matches no workload still fails dangling-service (the check stays on).
#
# Usage: test_rollout_services_kubelinter.sh   (KUBE_LINTER=<path> to choose the binary; chart-renderer runs 0.8.3)
set -euo pipefail
cd "$(dirname "$0")/../.."

KUBE_LINTER=${KUBE_LINTER:-kube-linter}
for t in helm "$KUBE_LINTER"; do command -v "$t" >/dev/null || { echo "FAIL: $t is required"; exit 1; }; done
echo "kube-linter $("$KUBE_LINTER" version)"

# chart-renderer's excluded checks and ignored files; keep them equal to kubelinter.go's kubeLinterExcludes and
# kubeLinterIgnored.
excludes=(env-var-secret no-anti-affinity latest-tag sorted-keys required-annotation-email default-service-account
  restart-policy minimum-three-replicas no-readiness-probe dnsconfig-options required-label-owner no-node-affinity
  non-isolated-pod no-rolling-update-strategy no-read-only-root-fs hpa-minimum-three-replicas)
ignored=(triggertestengine.yaml jobs.yaml)
lint() {
  local args=(lint "$1")
  for c in "${excludes[@]}"; do args+=(--exclude "$c"); done
  for f in "${ignored[@]}"; do args+=(--ignore-paths "$f"); done
  args+=(--add-all-built-in)
  "$KUBE_LINTER" "${args[@]}" 2>&1 || true
}

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# A copy of the chart, so the dependency build never writes into the working tree.
cp -R charts/mycarrier-helm charts/mc-mongodb "$TMP/"
helm dependency build "$TMP/mycarrier-helm" >/dev/null

cat > "$TMP/values.yaml" <<'EOF'
global:
  appStack: example
  correlationId: 11111111-2222-4333-8444-555555555555
  language: nodejs
environment:
  name: preprod
applications:
  api:
    deploymentType: rollout
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
  worker:
    deploymentType: deployment
    image: {registry: registry.example.com, repository: worker, tag: "1.0.0"}
    ports: {http: 8080}
EOF
out="$TMP/rendered"
helm template example "$TMP/mycarrier-helm" -f "$TMP/values.yaml" --output-dir "$out" >/dev/null
svc="$out/mycarrier-helm/templates/service.yaml"
[ -f "$svc" ] || { echo "FAIL: no service.yaml rendered"; exit 1; }

fail=0
check() { if [ "$2" = 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi; }

rc=0; for n in example-api example-api-preview example-worker; do grep -qx "  name: $n" "$svc" || rc=1; done
check "the render has the Rollout's stable and -preview Services and the Deployment app's Service" "$rc"

res=$(lint "$out")
rc=0; grep -q 'No lint errors found' <<<"$res" || rc=1
check "a Rollout app next to a Deployment app passes chart-renderer's kube-linter" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

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
grep -q 'found 1 lint errors' <<<"$res" || rc=1
grep -q 'example-orphan' <<<"$res" || rc=1
grep -q 'no pods found matching service labels' <<<"$res" || rc=1
check "a Service that selects no workload still fails dangling-service (the check stays on)" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

if [ "$fail" -ne 0 ]; then echo "$fail check(s) failed"; exit 1; fi
echo "all kube-linter checks passed"
