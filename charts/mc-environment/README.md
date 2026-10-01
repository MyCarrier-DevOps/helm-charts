# mc-environment

`mc-environment` renders a single Argo CD `ApplicationSet` that produces one `Application` per environment defined in `values.yaml`. Each generated `Application` targets the `mycarrier-helm` chart and receives an environment-specific values bundle so overrides remain isolated.

## How it works

1. The chart pins Argo CD settings (namespace `argocd`, project `default`, destination `https://kubernetes.default.svc`, and the in-repo `mycarrier-helm` chart) so you only need to supply environment-specific application data.
2. At template time a `list` generator is built out of `environments`, and each element carries the pre-rendered values payload plus any Helm overrides.
3. For every entry in `environments` it builds a final values document by layering:
   - global defaults from `values.yaml` → `.Values.global`
   - optional per-environment overrides under `environments[].global`
   - optional extra values supplied alongside the environment (for example `applications`, `jobs`, `infrastructure`).
4. The merged values are serialized into the Argo CD `Application.spec.source.helm.values` field by the ApplicationSet template, so Argo CD deploys `mycarrier-helm` with those settings.

Go templating is supported where the chart still calls `tpl` (such as `environments[].helm.releaseNameTemplate`, helm value files, and parameters). Templates render with access to `.Values`, `.Release`, and `.Environment` so you can derive names from the current environment when needed before the ApplicationSet is emitted.

## Key values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global` | Base values passed to every `mycarrier-helm` deployment | See [values.yaml](./values.yaml) |
| `environments` | Array of environment definitions that each produce an Argo CD Application | `[]` |

## Example

See [example.yaml](./example.yaml) for a full sample covering dev and prod environments.

```yaml
global:
  appStack: carriers
  gitbranch: main

environments:
  - name: dev
    destinationNamespace: platform-dev
    global:
      gitbranch: dev
    applications:
      example-api:
        image:
          repository: ghcr.io/mycarrier/example-api
          tag: "1.0.0"
  - name: prod
    releaseName: carriers-prod
    global:
      gitbranch: prod
    environment:
      dependencyenv: prod
```

Apply the chart with your preferred Helm workflow and Argo CD will manage one `mycarrier-helm` release per configured environment.

## Argo CD sync behaviour

Since 0.3.0 generated Applications use `ServerSideApply=true` **without** `Replace=true`, so fields owned by other controllers (Argo Rollouts) are not overwritten on sync. `RespectIgnoreDifferences=true` is deliberately **not** set: in Argo CD 3.1 (`controller/sync.go`, `normalizeTargetResources`) it deletes every ignored path from the target and restores only values present in the live object. On a Deployment-to-Rollout migration the live VirtualService has no `canary` route yet, so the Rollout-managed route weights are stripped and Istio rejects the VirtualService ("total destination weight = 0"). Without it, `ignoreDifferences` still keeps controller-managed fields out of the diff (no OutOfSync flapping, no selfHeal), `ServerSideApply` keeps rollouts-controller-owned Service selector keys, and `ApplyOutOfSyncOnly` re-applies the VirtualService only on a real git change. Trade-off: after such a git change the canary weights reset to 100/0 until the Rollouts controller's next reconcile. Versus 0.2.x the rendered ApplicationSet differs by the removal of `Replace=true`, the `ignoreDifferences` entries below (Service, VirtualService, HorizontalPodAutoscaler, ScaledObject) and the `argocd.argoproj.io/client-side-apply-migration-manager` annotation (see "Migration annotation"; it is left off environments that have `jobs` or `extraObjects`, which today is only the preprod `uat` backend).

`ignoreDifferences` entries:

- `Service` fields managed by `rollouts-controller` (selector injection during canary/blue-green), plus the per-deploy labels `mycarrier.tech/correlationId`, `mycarrier.tech/commitDeployed` and `mycarrier.tech/reference` (`jsonPointers`). A deploy changes only these labels on a Service; ignoring them keeps the Service Synced, so `ApplyOutOfSyncOnly` skips it and the server-side apply never takes the atomic `spec.selector` (and its `rollouts-pod-template-hash`) away from `rollouts-controller`. Service label values therefore stay at their last real apply. Residual: a real Service change (spec edit, `mycarrier-helm` bump) deployed together with a pod-template change can still reset the selector on a Rollout-backed Service.
- `HorizontalPodAutoscaler` (`autoscaling`) and `ScaledObject` (`keda.sh`): only labels (`jsonPointers`), no spec field: the same three per-deploy labels as the Service, plus `version` and `mycarrier/service-version`, which `mycarrier-helm` stamps on these kinds from the image tag (Services carry neither, so the Service entry is unchanged). `mycarrier-helm` syncs these autoscalers in sync-wave 11, after the Rollout in wave 10. Because the labels change on every deploy, the autoscaler would always be part of the sync, and wave 11 would not start until the paused Rollout is Healthy, which only happens after the last canary step. The Application would therefore show OutOfSync for the whole canary. Ignoring the labels removes the autoscaler from a normal deploy. For apps without a PostSync hook, the deploy's sync then finishes right after the Rollout is applied, so the app stays Synced while a canary is paused. Apps with a PostSync hook (for example the `testtrigger` Job or post-deploy jobs) still keep the sync running until the Rollout is Healthy, because Argo CD always runs hook tasks; those apps show OutOfSync during a paused canary until hook-based tests move to TestEngine analysis (DEVOPS-312). Trade-off: autoscaler labels stay at their last real apply value, like the Services'; a real autoscaler spec change still enters the sync and waits for the Rollout as before. Other resources in a later wave than the Rollout: `VerticalPodAutoscaler` (wave 11) carries no per-deploy labels, and hook Jobs (`PostSync`) are not part of the diff, so neither needs an entry.
- `VirtualService` (`networking.istio.io`): the weights of every HTTP route with more than one destination where at least one destination host is a `-preview` host (`.spec.http[] | select(((.route // []) | length) > 1 and any(.route[]; (.destination.host // "") | test("-preview(\\.|$)"))) | .route[].weight`), plus the `canary-header` route. A `-preview` host is matched in both forms the templates emit: the FQDN `<app>-preview.<ns>.svc.cluster.local` and the short `<app>-preview` used by the multi-frontend `canary` route (no domain, so the regex accepts end-of-string). Requiring more than one destination (Rollout routes always carry stable + preview) stops a Deployment app that is literally named `*-preview` from matching; a missing `destination.host` is treated as empty rather than erroring. A `-preview` destination marks a route whose weights Argo Rollouts manages during progressive delivery: the `canary` route and the `allowed-*` routes, so every multi-destination route with a `-preview` host is covered, whatever its name. Routes without a `-preview` destination (Deployment-backed apps) match nothing and stay fully diffed. A git change to the VirtualService resets these weights to their git values (100/0) until the Rollouts controller reconciles.

No Rollout `/spec/replicas` ignore is emitted on purpose: `mycarrier-helm` omits `spec.replicas` on a Rollout whenever an HPA or KEDA ScaledObject is rendered (`templates/_spec_rollout.tpl`), and Argo CD's legacy (client-side) diff never treats an absent field as drift.

Stale-field caveat: after moving off `Replace=true`, fields written by the legacy `argocd-application-controller` (Update) manager may linger in `managedFields`; a one-time `kubectl patch --type=json` removing that entry cleans them up. The chart does not run it.

Migration annotation: Argo CD 3.1+ already performs client-side-apply (CSA) to server-side-apply migration by default, using the manager name `kubectl-client-side-apply`. Applications here carry `argocd.argoproj.io/client-side-apply-migration-manager: argocd-application-controller`, which only changes the manager that is migrated: it names the legacy `Replace=true` manager, so the first server-side apply of an object moves that manager's fields into the SSA manager. It is rendered **only for environments without `jobs` and without `extraObjects`**: `mycarrier-helm` Jobs (and any object carrying `Replace=true`) re-create the legacy manager on every replace, and the migration's client-side apply of an immutable field would fail the sync. Those environments still run Argo's default migration step, but their legacy `argocd-application-controller` entries are not migrated (see the stale-field caveat above). The chart has no per-environment opt-out.

Kill switch: if the migration fails a sync (`Failed to perform client-side apply migration`), add the sync option `ClientSideApplyMigration=false` to the affected Application (for example `kubectl patch application <name> -n argocd --type=json -p '[{"op":"add","path":"/spec/syncPolicy/syncOptions/-","value":"ClientSideApplyMigration=false"}]'`; the ApplicationSet controller reverts manual edits, so the durable fix is to add `jobs`/`extraObjects` handling or change the chart).

Per-resource escape hatch: annotate a resource with `argocd.argoproj.io/sync-options: Replace=true,ServerSideApply=false` when it needs replace semantics (without `ServerSideApply=false` the migration annotation first runs a client-side apply against the live object, which fails on immutable objects).
