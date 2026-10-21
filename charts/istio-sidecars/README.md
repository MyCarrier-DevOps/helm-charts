# istio-sidecars

Namespace-scoped Istio `Sidecar` resources for the dev cluster. One `default` Sidecar per feature namespace, plus one for the `dev` namespace that lists every feature namespace. ArgoCD renders this chart from `base/istio/istio-sidecars.values` in GitOps-dev. With default values the chart renders nothing.

## Values

| Key | Default | Meaning |
|---|---|---|
| `strict` | `false` | Use `--set strict=true` for local render checks (`helm template ... --set strict=true`): any bad input fails the render. ArgoCD never sets it: it renders lenient, bad input is skipped and the render never fails. |
| `sharedHosts` | five hosts | Hosts of the `dev` Sidecar. `<name>/*` is appended for every valid feature entry. |
| `featureHosts` | six hosts, with `dev/*` | Hosts of every feature Sidecar. |
| `dev.enabled` | `false` | Renders the `dev` Sidecar. Must be a boolean. |
| `featureNamespaces` | `[]` | List of `{name, sidecar, extraHosts}`. `name` matches `^feature[0-9]{2}(-[a-z0-9]+)?$`, at most 63 characters, not one of `dev preprod uat qa istio-system kube-system default monitoring`. `sidecar` is a boolean, default `true`. `extraHosts` is an optional list of extra `<namespace>/*` hosts. |

Every Sidecar has an explicit `metadata.namespace` (never the release namespace), the annotation `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true,Prune=false`, one egress entry, no `workloadSelector` and no `outboundTrafficPolicy`.

Lenient mode, on purpose: a bad NAME gives no Sidecar and no dev host. A non-boolean `sidecar` flag gives no feature Sidecar but keeps the dev host. A duplicate name keeps the first entry. Wrong shapes are skipped (a plain string entry is not promoted to a name).

## 1. Order rule: add and remove names (G3)

Add a name to `featureNamespaces` only AFTER the namespace exists. A name added early makes the sync fail on a missing namespace (retry 5 with backoff, then it stops until a new revision). Remove the name BEFORE you delete the environment.

## 2. Manual delete (G6)

All Sidecars carry `Prune=false`. Removing a name, or setting `sidecar: false`, does NOT delete the live Sidecar. When you want it gone, run `kubectl delete sidecar default -n <namespace>`. Deleting the namespace at environment teardown also removes it. `feature13-mycarrier-engineering` stays out of this chart.

## 3. Blind spot (G18)

A typo committed by a direct push is skipped silently in lenient mode, and nothing alerts. Because of `Prune=false`, a skipped typo leaves the old Sidecar live and stale (OutOfSync, pending prune). There is no automated check of the values file: no PR check, no workflow and no detection job. A bad entry is skipped silently and nothing alerts. A YAML syntax error stalls dev `bootstrap-base` until it is reverted (section 6). The only way to find a bad entry is a local render with `helm template ... --set strict=true` before you push.

## 4. Paths that must not change

The chart path `charts/istio-sidecars` and the values path `base/istio/istio-sidecars.values` are contracts with ManagementInfra and GitOps-dev. Never delete, rename or move the chart or the values file while ManagementInfra references them.

## 5. Migrated notes (DEVOPS-389, G7)

- Measured on feature21 (commit 8059d28b5f): istio-proxy memory p50 457Mi -> 264Mi (-42%), p99 518Mi -> 284Mi (-45%), zero regressions, all 162 `<svc>.dev.internal` clusters kept. The mesh holds about 1,294 clusters (about 56MB config_dump) per proxy without a Sidecar.
- `dev/*` in `featureHosts` is a deliberate wildcard, not the few dev services a namespace was measured calling. The EnvoyDevFallback path lets a feature environment reach ANY dev service through `<svc>.dev.internal` on demand; a narrower scope breaks the first time an unobserved service is requested.
- `outboundTrafficPolicy` is NOT set. The mesh default ALLOW_ANY must stay: 80-99% of the egress is raw-IP / non-HTTP TCP to off-mesh infra (OTel collectors on :4317, Azure IMDS), which REGISTRY_ONLY would blackhole.
- Rollback is a git revert of the values change. With `Prune=false` a revert does not delete a live Sidecar (section 2).
- The `dev` Sidecar is the widest scope and gains the least: it egresses to every feature namespace (offload routing), so each one is listed. Istio `egress.hosts` has no namespace wildcard (`feature*/*` is not valid). Feature namespaces are created dynamically (`CreateNamespace=true`) and have no static Namespace manifest, so the list goes stale when a new environment is created. A missing entry makes dev -> that namespace fall to `PassthroughCluster`: it still connects, but loses VirtualService routing, mTLS and telemetry attribution, silently.
- Detect with: PassthroughCluster rows from ns=dev whose authority matches `%.svc.cluster.local%` or `%.internal%` (baseline 0). Add the new namespace when it fires. Plain "PassthroughCluster appears" does not work: it is already about 1.2M per day in dev.
- feature21 POC header (migrated): scope is deliberately generous (whole `dev` namespace, not the three services feature21 was measured calling). Measured in use by feature21: product-api.dev.internal (66/24h), document-api.dev.internal (18/24h), mycarrierproxy-api.dev.svc.cluster.local (8/24h). `monitoring/*` is precautionary: the OTel collectors are reached by pod IP (passthrough) today. `default/*` is the API server, `kube-system/*` is DNS (ISTIO_META_DNS_CAPTURE is on mesh-wide), `istio-system/*` is the control plane, ingress gateway and telemetry.

## 6. YAML syntax errors stall dev (G21, accepted residual)

Helm parses the values file BEFORE any template runs, so no chart code can skip a YAML syntax error. One bad direct push stalls the whole dev `bootstrap-base` (ComparisonError, nothing pruned) until reverted. A missing values file does the same, so `ignoreMissingValueFiles` stays unset (a missing file would hide a wrong path). Never delete, rename or move the values file.

Recorded on Helm 3.18.4 (v3.18.4+gd80839c), test N-19:

- A TAB indent fails: exit 1, `yaml: line 2: found character that cannot start any token`.
- A duplicate top-level key is NOT detected: exit 0, no error, and the LAST block wins silently (two `dev:` blocks: the second one is used).

Helm v4.3.1 gives the same results. Review values edits for a repeated top-level key by eye: no tool will flag it.
