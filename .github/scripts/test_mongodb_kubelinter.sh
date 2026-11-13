#!/usr/bin/env bash
# kube-linter on rendered stacks that deploy the in-cluster MongoDB (dependencyDeployments.mongodb), run the way
# chart-renderer's render check runs it; chart_renderer_kubelinter.sh holds its configuration.
#
# The first stack that turned the feature on failed its render on three checks:
#   - access-to-secrets, on the RoleBinding of the database pods' Role, which reads one named Secret;
#   - env-value-from and read-secret-from-env-var, on every workload whose env var reads the connection Secret: an
#     ExternalSecret creates that Secret in the cluster, so no Secret is in the render.
# With backups, the backup and restore CronJobs trip the same two env checks and no-liveness-probe, and a multi-member
# replica set's PodDisruptionBudget trips pdb-unhealthy-pod-eviction-policy. This checks that:
#   1. stacks that deploy MongoDB lint clean: with only the injected MONGODB_URI, with a reference of their own, with
#      backups, in prod, as csharp, and with a Rollout, a StatefulSet, an init container and a CronJob;
#   2. the checks stay on: a workload that reads another Secret still fails the env checks, with MongoDB on or off, and
#      a RoleBinding to another Role that reads Secrets still fails access-to-secrets.
#
# Usage: test_mongodb_kubelinter.sh   (KUBE_LINTER=<path> to choose the binary)
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=chart_renderer_kubelinter.sh
source .github/scripts/chart_renderer_kubelinter.sh

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# A copy of the charts, so the dependency build never writes into the working tree.
cp -R charts/mycarrier-helm charts/mc-mongodb "$TMP/"
helm dependency build "$TMP/mycarrier-helm" >/dev/null

cat > "$TMP/stack.yaml" <<'EOF'
global:
  appStack: example
  language: python
dependencyDeployments:
  mongodb:
    enabled: true
applications:
  api:
    deploymentType: deployment
    image: {registry: registry.example.com, repository: api, tag: "1.0.0"}
    ports: {http: 8080}
  ui:
    deploymentType: deployment
    image: {registry: registry.example.com, repository: ui, tag: "1.0.0"}
    ports: {http: 8080}
EOF

# What stacks wrote before the chart injected MONGODB_URI.
cat > "$TMP/own-reference.yaml" <<'EOF'
global:
  env:
    MONGO_URI:
      valueFrom:
        secretKeyRef: {name: example-mongodb-connection, key: connectionString}
EOF

cat > "$TMP/backup.yaml" <<'EOF'
dependencyDeployments:
  mongodb:
    backup: {enabled: true, container: development}
EOF

cat > "$TMP/csharp.yaml" <<'EOF'
global:
  language: csharp
  dependencies: {mongodb: true}
EOF

# A Rollout and a StatefulSet next to the Deployment, an init container, and a cronjobs[] entry that reads the
# connection Secret. The chart also marks the CronJob for no-liveness-probe and the init container's Deployment for
# the unset cpu and memory checks, with or without MongoDB.
cat > "$TMP/kinds.yaml" <<'EOF'
global:
  correlationId: 11111111-2222-4333-8444-555555555555
applications:
  api:
    initContainers:
      - {name: migrate, image: registry.example.com/migrate, tag: "1.0.0", command: ["migrate"], args: ["up"]}
  ui:
    deploymentType: rollout
    canaryHealthPath: /health
  store:
    deploymentType: statefulset
    image: {registry: registry.example.com, repository: store, tag: "1.0.0"}
    ports: {http: 8080}
cronjobs:
  - name: nightly
    schedule: "0 3 * * *"
    image: {registry: registry.example.com, repository: nightly, tag: "1.0.0"}
    env:
      MONGODB_URI:
        valueFrom:
          secretKeyRef: {name: example-mongodb-connection, key: connectionString}
EOF

# render NAME ENVIRONMENT [values file...]: the rendered dir on stdout.
render() {
  local out="$TMP/$1" env=$2 args=() f
  shift 2
  for f in "$@"; do args+=(-f "$TMP/$f.yaml"); done
  helm template example "$TMP/mycarrier-helm" "${args[@]}" --set "environment.name=$env" --output-dir "$out" >/dev/null
  printf '%s' "$out"
}

# clean NAME ENVIRONMENT [values file...]: the stack renders MONGODB_URI and the RoleBinding, and lints clean.
clean() {
  local name=$1 out tdir res rc=0
  out=$(render "$@")
  tdir="$out/mycarrier-helm/templates"
  grep -q 'name: MONGODB_URI' "$tdir/deployment.yaml" || rc=1
  grep -q 'kind: RoleBinding' "$tdir/mongodb.yaml" || rc=1
  check "$name: the application container gets MONGODB_URI, and the database RoleBinding renders" "$rc"
  res=$(lint "$out")
  rc=0; grep -qE "$lint_error_re" <<<"$res" && rc=1
  check "$name: passes chart-renderer's kube-linter" "$rc"
  [ "$rc" = 0 ] || printf '%s\n' "$res"
}

clean dev dev stack
clean dev-own-reference dev stack own-reference
clean dev-backup dev stack backup
clean prod prod stack
clean prod-csharp prod stack csharp
clean preprod-kinds preprod stack kinds

rc=0
tdir="$TMP/dev-backup/mycarrier-helm/templates"
grep -q 'name: example-mongodb-backup$' "$tdir/mongodb.yaml" || rc=1
grep -q 'name: example-mongodb-restore$' "$tdir/mongodb.yaml" || rc=1
check "dev-backup: the backup and restore CronJobs render" "$rc"
rc=0
grep -q 'kind: PodDisruptionBudget' "$TMP/prod/mycarrier-helm/templates/mongodb.yaml" || rc=1
check "prod: the replica set's PodDisruptionBudget renders" "$rc"
rc=0
tdir="$TMP/preprod-kinds/mycarrier-helm/templates"
for f in rollout.yaml statefulset.yaml; do grep -q 'name: MONGODB_URI' "$tdir/$f" || rc=1; done
grep -q 'name: example-mongodb-connection' "$tdir/cronjob.yaml" || rc=1
grep -q 'name: migrate' "$tdir/deployment.yaml" || rc=1
check "preprod-kinds: the Rollout and the StatefulSet get MONGODB_URI, the CronJob reads the connection Secret, and the init container renders" "$rc"

# only_checks RESULT OBJECT CHECK...: the lint fails, every finding is on OBJECT, and the findings are exactly CHECK...
only_checks() {
  local res=$1 object=$2 rc=0 want got
  shift 2
  grep -qE "$lint_error_re" <<<"$res" || rc=1
  [ "$(grep -c '(check: ' <<<"$res")" = "$(grep -c "$object" <<<"$res")" ] || rc=1
  want=$(printf '%s\n' "$@" | sort -u)
  got=$(grep -o '(check: [a-z-]*' <<<"$res" | sed 's/(check: //' | sort -u)
  [ "$want" = "$got" ] || rc=1
  printf '%s' "$rc"
}

# Without MongoDB, the same reference gets no annotation: both Deployments fail both env checks.
cat > "$TMP/off.yaml" <<'EOF'
dependencyDeployments:
  mongodb:
    enabled: false
EOF
res=$(lint "$(render off dev stack own-reference off)")
rc=$(only_checks "$res" 'Kind=Deployment' env-value-from read-secret-from-env-var)
[ "$(grep -c '(check: ' <<<"$res")" = 4 ] || rc=1
check "a reference to the connection Secret still fails the env checks when MongoDB is not deployed" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

# With MongoDB, a workload that reads another Secret, and not the connection Secret, stays linted.
cat > "$TMP/other-secret.yaml" <<'EOF'
cronjobs:
  - name: nightly
    schedule: "0 3 * * *"
    image: {registry: registry.example.com, repository: nightly, tag: "1.0.0"}
    env:
      API_KEY:
        valueFrom:
          secretKeyRef: {name: example-other-secret, key: value}
EOF
res=$(lint "$(render other-secret dev stack other-secret)")
rc=$(only_checks "$res" 'example-nightly' env-value-from read-secret-from-env-var)
check "a CronJob that reads another Secret still fails the env checks when MongoDB is deployed, and is the only finding" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

out="$TMP/dev"
cat > "$out/mycarrier-helm/templates/other-role.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: example-other
  namespace: dev
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: example-other
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: example-other
subjects:
  - kind: ServiceAccount
    name: default
    namespace: dev
EOF
res=$(lint "$out")
rc=$(only_checks "$res" 'example-other' access-to-secrets)
check "a RoleBinding to another Role that reads Secrets still fails access-to-secrets, and is the only finding" "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$res"

if [ "$fail" -ne 0 ]; then echo "$fail check(s) failed"; exit 1; fi
echo "all kube-linter checks passed"
