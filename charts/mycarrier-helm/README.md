# MyCarrier Helm Chart

A Helm chart for deploying MyCarrier applications to Kubernetes.

## Overview

This Helm chart provides a standardized approach for deploying MyCarrier applications and services to Kubernetes environments. It supports various deployment types (standard deployments, statefulsets, and Argo Rollouts), secret management through Vault, metrics collection, and advanced networking with Istio.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Istio 1.9+ (for networking features)
- Vault (for secrets management)
- Argo CD (for GitOps deployments)
- OpenTelemetry Operator (for observability)

## Installing the Chart

To install the chart with the release name `mycarrier-app`:

```bash
helm install mycarrier-app . -f values.yaml
```

For environment-specific installations:

```bash
# Development environment
helm install mycarrier-app . -f values.yaml -f values-dev.yaml

# Production environment
helm install mycarrier-app . -f values.yaml -f values-prod.yaml
```

To upgrade an existing release:

```bash
helm upgrade mycarrier-app . -f values.yaml
```

To uninstall a release:

```bash
helm uninstall mycarrier-app
```

## Upgrading to 4.5.0 (Rollouts only)

4.5.0 adds the canary contract for `deploymentType: rollout`. Deployment and StatefulSet apps render unchanged. A Rollout
app that rendered on 4.4.0 can fail on 4.5.0, which blocks the whole release, until its values are edited:

| 4.4.0 values | 4.5.0 edit |
|---|---|
| `applications.<app>.updateStrategy.canary` (steps, `scaleDownDelaySeconds`, `abortScaleDownDelaySeconds`, `scaleDownDelayRevisionLimit`, `backgroundanalysis`, Services, `trafficRouting`) | Remove it. Set `global.strategy.canary` (`preset`, `steps`, `analysis`, `progressDeadlineSeconds`) instead; the chart injects the Services and Istio routing. The scale-down delays use the Argo Rollouts defaults. |
| Istio off (`networking.istio.enabled: false`, `istioDisabled`, `service.istioDisabled`) | Leave Istio on: the canary weights live in the chart's VirtualService. |
| `service.aliases` | Remove the aliases: alias Services would send traffic to canary pods regardless of the weights. |
| Feature environment with the `-offload` VirtualService | Set `networking.istio.offloadVSEnabled: false` (on the primary frontend too, in a multi-frontend release). |
| A custom route key `canary` or equal to the app's full name, or the same custom route key on two frontend apps | Rename the key: Argo Rollouts weights only the first route with a name. |
| A custom route whose `destination` is the app's own Service | Remove `destination` so the route gets the `-preview` destination. |
| `applications.<app>.analysisTemplates` | The AnalysisTemplates are now named `<environment>-<fullName>-<name>`, matching the analysis steps. |

## Upgrading to 4.6.0 (Rollouts only)

4.6.0 adds `global.strategy.canary.coordinator` (off by default) for release-wide lockstep through the
`mycarrier/canary-coordinator` step plugin. With it off, renders are unchanged. Turning it on requires
`global.correlationId` (deploy-core sets it): the plugin groups a release's Rollouts by that label. One Rollout app that
rendered on 4.5.0 fails on 4.6.0:

| 4.5.0 values | 4.6.0 edit |
|---|---|
| An application whose name contains `migration` with `deploymentType: rollout` | Render the migrator through `jobs` with `timing: pre-deploy`: it runs to completion and exits, so it cannot be a canary. |

Since 4.7.3 this refusal is lifted: a long-running migrator application (it runs the migration when it starts and keeps running) may be `deploymentType: rollout` and takes part in the canary. A migrator that exits stays a pre-deploy job. Unlike the pre-deploy job, it gives no start order: the release's other workloads start alongside it, so their readiness must wait for the schema version they need. Set `networking.istio.externalEnabled: false` on it so that it is reachable only inside the cluster.

## Upgrading to 4.7.0 (Rollouts with the coordinator on)

4.7.0 adds the Tech Spec's header-gated dark stage (`global.strategy.canary.dark`, default `true`, and `darkReplicas`).
It renders only with `global.strategy.canary.coordinator.enabled`, so other renders are unchanged. With the
coordinator on:

| 4.6.0 values | 4.7.0 edit |
|---|---|
| A frontend Rollout in a multi-frontend release | Set `global.strategy.canary.dark: false`: the header route would also go into the shared `-multifrontend` VirtualService, where it matches every path. |
| `coordinator.barrierTimeouts` at or above `progressDeadlineSeconds` (the 4.6.0 defaults were 10m, 15m and 30m) | The defaults are now 9m. Keep a custom timeout below `progressDeadlineSeconds`, or raise the deadline: Argo Rollouts counts the wait at a barrier toward it, so a longer barrier timeout never fires. |

From 4.7.9 to 4.7.12, `dark` defaulted to `false`, and `coordinator.enabled` defaults to `true` since 4.7.9 (see below).
Since the release after 4.7.12, `dark` defaults to `true` again, with `darkReplicas` 2 and a chart-rendered `tests-dark`
(see [The dark stage on by default](#the-dark-stage-on-by-default-in-the-release-after-4712-canary-rollouts)).

## Upgrading to 4.7.9 (Rollouts)

4.7.9 makes canary analysis mandatory for every Rollout (DEVOPS-312). Each analysis step runs the
chart's `health` check, and in prod the Rollout runs the chart's `alerts` check as background analysis, unless a stack
opts out of one of them. The coordinator is on by default, and the dark stage was off by default (on since the release
after 4.7.12). Deployment and
StatefulSet apps render unchanged, except where the values below fail the whole render.

`testtrigger.enableV1` now defaults to `true` for every application, because TestEngine's legacy API is retired. A test
trigger without it sends one v1 request with every test definition. `enableV1: false` keeps the legacy API, except on a
canary Rollout in prod (property `canary`), where it fails the render.

It also renders the contract the release's rollout-watch reads (DEVOPS-319). Every Rollout that runs canary steps
carries `mycarrier.tech/bakeMinutes` (`global.strategy.canary.bakeMinutes`, default 30, at most 100) and
`mycarrier.tech/canaryBudgetSeconds`, the worst-case length of its steps (Tech Spec D22). rollout-watch times out at the
largest budget of the release plus 15 minutes. The chart computes the budget for a preset: 3330 s for `standard`, 1170 s
for `fast` and 4770 s for `manual`, whose pause counts as `manualTimeout` (default `1h` then; 40m since the release after
4.7.12, which also changes these budgets). With the coordinator off,
each weight step above 0 counts `progressDeadlineSeconds` instead of the barriers: 3570 s, 1290 s and 4890 s. An explicit `steps` list
states it in `budgetSeconds`. A budget above 5700 s fails the render. In prod, a
canary Rollout's test trigger no longer renders the `<fullName>-trigger` PostSync hook (Tech Spec D7): with
`testtrigger.enableV1: true` the chart renders the ConfigMap `<fullName>-prod-tests` (key `request.json`, the hook's
TestEngine v1 request, labelled `mycarrier.tech/correlationId`), and rollout-watch posts it after promotion.

| 4.7.8 values | Edit |
|---|---|
| `global.strategy.canary.analysis.enabled: false` | Remove it: it fails the render in every environment. `true` is accepted and has no effect. To leave out one check, set `analysis.health.enabled: false` or `analysis.alerts.enabled: false`. |
| `analysis.templates` lists `health` or `alerts` (the 4.7.5 default was `[health, alerts]`) | Remove them: they always run, and listing either fails the render. List only extra templates. |
| `analysis.health.enabled: false` and `analysis.alerts.enabled: false` with no extra templates | Analysis is mandatory, so every Rollout fails to render. Keep one check on, or list an extra template. |
| A Rollout app whose liveness probe is not HTTP (any non-csharp app with default probes) | Set `applications.<app>.canaryHealthPath` or `analysis.health.path`, give the app an `httpGet` liveness probe, or set `analysis.health.enabled: false`. Readiness and startup probes are no longer used for the path. |
| A csharp Rollout app with default probes | Nothing to set: the health check now calls `/liveness` (the default liveness probe) instead of `/health`. |
| A prod canary Rollout (property `canary`) with no `analysis.alerts.service`, no `alerts.serviceName`, and a `global.appStack` that is empty or the default `app` | Set the label the service's Grafana alert rules carry in `analysis.alerts.service`, or set `analysis.alerts.enabled: false`. `global.appStack`, lower-cased, is now the last fallback. |
| A Rollout render without `global.correlationId` (deploy-core always sets it) | Set it, or set `coordinator.enabled: false`. |
| A cluster without the `mycarrier/canary-coordinator` plugin | Set `coordinator.enabled: false`: the controller rejects steps for a plugin it does not have. |
| Relied on the dark stage (`coordinator.enabled: true` with the old `dark` default) | Set `dark: true`; a `tests-dark` AnalysisTemplate must then render for the leader. |
| `global.strategy.canary.bakeMinutes` above 100 | Set it to 100 or less: alert-gate's run has a 7200 s deadline and spends about 750 s outside its window. Above 100 fails every render. |
| An explicit `global.strategy.canary.steps` list | Set `global.strategy.canary.budgetSeconds` to the steps' worst-case length in seconds (1 to 5700): the pause durations, each analysis step's longest template (`count` x max(`interval`, a Job's `activeDeadlineSeconds`)) and each barrier timeout, or without barriers `progressDeadlineSeconds` for each weight step above 0. Without it, every Rollout fails to render. |
| The `manual` preset | Nothing to set: its pause counts as `manualTimeout` (default `1h` on 4.7.9 to 4.7.12, `40m` since) in the budget, and the pause itself still has no time limit. Set `manualTimeout` to the time a person needs to promote or abort. With the manual preset, a zero `manualTimeout` fails the render. |
| A preset whose steps add up to more than 5700 s: the `manual` preset with `dark: true` (at least 5850 s with the defaults on 4.7.9 to 4.7.12; since the release after 4.7.12 the defaults fit, 5583 s for the manual leader with `manualTimeout` 40m), or raised `coordinator.barrierTimeouts`, `analysis.health` or extra templates | Lower `manualTimeout` (on 4.7.9 to 4.7.12, 45m left 750 s for the leader's `tests-dark`; since the release after 4.7.12, with `dark-passed` at 15m, the default 40m fits and 45m fails at 5883 s), the barrier timeouts, or the templates' `count` or `interval`. rollout-watch's release workflow has a 10800 s deadline and spends about 70 minutes before the canary and 15 minutes after the budget. |
| A prod canary Rollout app (property `canary`) with `testtrigger.enableV1: false` | Remove it (`true` is the default). The chart renders no PostSync hook for it, and rollout-watch starts only v1 requests, so `false` fails the render. |
| A stack that switches to Rollouts while its repository's `deployment-strategy` is `rolling` or unset | Nothing is required. Since the release after 4.7.10 the chart reads the property (`global.deploymentStrategy`): a Rollout renders canary steps, and drops its prod PostSync hook, only when it is `canary`. Otherwise it renders without steps and keeps its hook. |
| A prod canary Rollout app (property `canary`) with `testtrigger.enableV1: true` and an `apikey` other than `vault:DevOps/data/testengine/api#encoded_header` | Remove `apikey` or set the shared key: rollout-watch posts with it, and another key fails the render. |
| `global.testengineWebhookUrl` in prod, with a canary Rollout app (property `canary`) whose `testtrigger.enableV1` is true | Remove it: rollout-watch posts to its own TestEngine URL, and the value fails the render. |

## Upgrading to 4.7.10 (Rollouts outside prod)

4.7.10 renders the canary steps only in prod (Q52, DEVOPS-516). Outside prod (dev, uat, qa, preprod, feature
environments and any other environment name), a canary Rollout renders `steps: []`, and Argo Rollouts promotes
the new version at once. The barriers, the analysis steps, the pauses, the dark stage, the background analysis and
`mycarrier.tech/canaryBudgetSeconds` go with the steps. The Services, the Istio traffic routing,
`progressDeadlineSeconds`, `rollbackWindow`, `mycarrier.tech/rolloutGroupSize`, `mycarrier.tech/bakeMinutes` and the
chart's `health` AnalysisTemplate stay. Prod renders unchanged. Since the release after 4.7.10 a canary Rollout is one
whose repository's `deployment-strategy` property is `canary` (see below); any other Rollout renders no steps in every
environment.

`global.strategy.canary.stepsOutsideProd: true` (new, default `false`) renders the prod steps in any environment, for a
test drill; the chart's `alerts` check stays prod only. The 4.7.9 schema refuses the key ("additional properties not
allowed"), so a stack can set it only once the deploy-core pin has moved past 4.7.9 to 4.7.10 or later.

The render-time checks still run in every environment, as on 4.7.9: a missing health path, both analysis opt-outs, an
extra template that does not render, a barrier timeout at or above `progressDeadlineSeconds`, the leader rule with the
leader's `tests-dark`, `budgetSeconds` for an explicit `steps` list, a budget above 5700 s and a zero `manualTimeout`
with the manual preset fail the render outside prod too. A stack moves to canary as a whole, so the same Rollouts exist
in every environment, and it sees these failures on its first render, not at its first prod canary. Only
`global.correlationId` for the coordinator is required just where the steps render. Since the release after 4.7.12 the
canary pod floor (a minimum of 2 replicas) is checked there too, and the dark stage adds its own checks (see
[The dark stage on by default](#the-dark-stage-on-by-default-in-the-release-after-4712-canary-rollouts)).

| 4.7.9 values | Edit |
|---|---|
| A canary test drill or rehearsal outside prod, which needs the steps or `mycarrier.tech/canaryBudgetSeconds` | Set `global.strategy.canary.stepsOutsideProd: true` in that environment's values file. Without it, the Rollout promotes at once. |
| An explicit `global.strategy.canary.steps` list | Nothing to set. It renders only in prod, or with `stepsOutsideProd`, and it still needs `budgetSeconds` in every environment. |
| A replacement `alerts` entry under `applications.<app>.analysisTemplates` that ran as background analysis outside prod | Set `stepsOutsideProd: true` where it must run. Outside prod it no longer runs without it. |
| A non-prod render without `global.correlationId` | Nothing to set: it now renders outside prod. It still fails in prod and with `stepsOutsideProd`. |

## Upgrading past 4.7.10 (Rollouts): canary steps follow the deployment-strategy property

The repository's `deployment-strategy` property is the switch for canary steps. chart-renderer passes it on every render
as `global.deploymentStrategy`, on either chart: a mycarrier-helm stack gets it directly, and mc-environment forwards
its whole `global` map into each environment's Application (`templates/appset.yaml`). Stacks do not set it in their
values files.

`helm.canary.enabled` (`templates/_canary.tpl`) is true only for an application with `deploymentType: rollout`, without
`migratingToRollouts`, when `global.deploymentStrategy` is exactly `canary`. Such a Rollout renders as before: the
canary steps, the analysis steps and background analysis, the coordinator's barriers, the dark stage and its
`managedRoutes`, the `mycarrier.tech/rolloutGroupSize`, `mycarrier.tech/bakeMinutes` and
`mycarrier.tech/canaryBudgetSeconds` annotations, the chart's AnalysisTemplates, in prod the
`<environment>-<fullName>-alerts` ExternalSecret, and in prod the `<fullName>-prod-tests` ConfigMap in place of the
PostSync test hook. Its steps render where 4.7.10 renders them: in prod, or with `stepsOutsideProd`; elsewhere it
renders `steps: []` (see Upgrading to 4.7.10).

With any other value (`rolling`, empty, unset, or another spelling such as `Canary`) the same Rollout renders with no
steps (`templates/_spec_rollout.tpl`), in every environment: no `steps` key, not `steps: []`, and
`global.strategy.canary.stepsOutsideProd` does not change that (`helm.canary.stepsRendered` is false for it). It keeps the `<fullName>` and `<fullName>-preview` Services, the VirtualService,
`trafficRouting`, `progressDeadlineSeconds`, `progressDeadlineAbort` and `rollbackWindow`, so switching the property
moves no traffic. It renders no AnalysisTemplate of the chart's, no `<environment>-<fullName>-alerts` ExternalSecret
(prod), none of the three annotations, and in prod it keeps the `<fullName>-trigger` PostSync hook. Argo Rollouts then scales the new ReplicaSet to full size behind the `-preview`
Service at weight 0 and points the stable Service at it once it is available. The checks that protect the VirtualService
still apply: Istio left on, `networking.istio.offloadOperatorEnabled: false` in dev, and
`networking.istio.offloadVSEnabled: false` in a feature environment. The checks that only
the steps need do not run: `global.correlationId`, a health path and the alerts service label are not required.

Render paths other than chart-renderer, such as offloads, do not pass the property, so their Rollouts render without
steps until they do. A migrating Rollout (`migratingToRollouts`) renders the bare canary whatever the property says.

| Before | Edit |
|---|---|
| A Rollout rendered canary steps whenever `deploymentType: rollout` was set without `migratingToRollouts` | Set the repository's `deployment-strategy` property to `canary`; chart-renderer passes it. Without it the Rollout renders no steps. |

## Canary tests in the release after 4.7.11 (canary Rollouts, opt-in)

The release after 4.7.11 adds the chart's `tests` AnalysisTemplate (DEVOPS-515). It applies only to canary Rollouts:
applications with `deploymentType: rollout`, without `migratingToRollouts`, in a repository whose `deployment-strategy`
property is `canary` (`global.deploymentStrategy`, passed by chart-renderer; see the section above). It renders only
for a stack that lists `tests` in `global.strategy.canary.analysis.templates` (or references
`<environment>-<fullName>-tests` in explicit `steps`), so other renders do not change. Like `health` and `alerts`, a
Rollout whose property is not `canary` renders no `tests` template and runs none of its checks, with or without `tests`
listed. Each analysis step then runs a Job that sends the application's
`testtrigger.testdefinitions` to TestEngine's v1 API, with `ServiceAddress` the `-preview` Service, `RunKind: canary`,
`SlipStep: none` and `Tolerations: []`, polls the run, and passes only when the run passes. A run that ends `no_results`
or `infra_failed` is sent once more. A failed suite, a second `no_results`, TestEngine with `RUN_KINDS_ENABLED` off, a 5xx
or the end of `analysis.tests.timeout` (default `7m`) fails the AnalysisRun and aborts the canary. A Job image (or
Vault init image) that cannot be pulled leaves the measurement Inconclusive: the Rollout pauses at its canary weight,
serving production traffic, until the siblings' barrier times out and the coordinator aborts it (about 9 minutes), or,
with one canary Rollout, until rollout-watch times out (`canaryBudgetSeconds` + 15 minutes, about 93 minutes on
`standard`) and gitops-rollback reverts the release. Mirror the image to ACR and set `analysis.tests.image` to the
mirror.

| Values | Effect |
|---|---|
| `analysis.templates: [tests]` | Every canary Rollout application needs `testtrigger.testdefinitions` in that environment, or the render fails. The template renders in every environment where it is listed, like `health`. To roll back, remove `tests` from the list. |
| `analysis.tests.timeout` (default `7m`) | The poll budget. The Job's `activeDeadlineSeconds` is the timeout + `startupSeconds` (540 s by default), and the canary budget counts it, with the 33 s Argo Rollouts can take to see the Job end, for each analysis step: 4779 s for `standard`, 1653 s for `fast` and 4053 s for `manual` with `dark: false` (which `tests` needs since the release after 4.7.12) and the other defaults. With the coordinator on and more than one canary Rollout, one Rollout's longest run of an analysis step (its longest template; a Job adds ceil(sqrt(2 x `activeDeadlineSeconds`)) for Argo to see it end) minus another's shortest ((count - 1) x interval of its templates) must stay below the next barrier's timeout (9m), or the render fails: two Rollouts with the defaults wait 513 s. Several analysis steps between two barriers add up; each Rollout's own `analysisTemplates` replacements count; at `dark-passed` only the leader's `tests-dark` counts. A release with one canary Rollout has no barrier wait. |
| `analysis.tests.startupSeconds` (default `120`, 30 to 600) | Slack for the Job's pod to start (scheduling, an on-demand node, the image pull, Vault injection): Kubernetes counts `activeDeadlineSeconds` from the Job's creation. A pod still Pending past it ends `DeadlineExceeded`, with no `FAIL:` line, and a TestEngine run already started is left running. |
| `analysis.tests.image` | The Job's Python image; the default is the pinned image of the alerts check. |
| A prod filter whose first `TestCategory` starts with `preprod` | Fails the render: TestEngine refuses it in a prod canary. |
| A test definition's `serviceAddress` | Must point at the application's own Service (or its `-preview` Service), with no port or the `http` Service port; the canary run keeps its path on the `-preview` Service. Another host or port fails the render, and so does a `-preview` Service with no `http` port. |
| `testtrigger.apikey` | Unset (the shared `vault:DevOps/data/testengine/api#encoded_header`) or a `vault:` reference; a literal key fails the render. |
| Managed routes (`dark: true`, the default since the release after 4.7.12, with the coordinator on and a preset, or a `setHeaderRoute` or `setMirrorRoute` step in explicit `steps`), `coordinator.enabled: false` with more than one canary Rollout, or no `global.correlationId` where the steps render | Fails the render: TestEngine's DeployVerifier fails a canary run without the canary header on a Rollout with managed routes, and checks every Rollout of the correlation group; TestEngine refuses a run without a CorrelationId. With the coordinator off, `dark: true` adds no route. With the dark stage on, set `dark: false` with `tests` until Q54 (a DeployVerifier check of header-less canary runs per Rollout) is resolved; `tests-dark` runs the suite in the dark stage. |

**Breaking (canary budget).** `mycarrier.tech/canaryBudgetSeconds` now counts a `job` analysis template at its longest:
`activeDeadlineSeconds` + ceil(sqrt(2 x `activeDeadlineSeconds`)) (the time Argo Rollouts v1.10.0 can take to see a Job
end), and with `count` n of 2 or more at least n x (`activeDeadlineSeconds` + that lag) + (n - 1) x `interval`. This
changes canary Rollouts with a `job` template under `applications.<app>.analysisTemplates`, with or without `tests`; no
stack runs a canary Rollout today. A budget above 5700 s fails the render: a `standard`-preset stack with a `smoke` Job of
`count: 2`, `interval: 1m` and `activeDeadlineSeconds: 400` goes from 5460 s to 5814 s and fails. Lower that template's
`count`, `interval` or `activeDeadlineSeconds`, or the barrier timeouts or `manualTimeout`; recount `budgetSeconds` for
an explicit `steps` list.

The prod TestEngine runs with `RUN_KINDS_ENABLED=false` until the DEVOPS-321 pilot; until then, a prod canary with
`tests` fails at its first analysis step. The 4.7.11 schema refuses `analysis.tests`, and 4.7.11 fails the render of a
canary Rollout that lists `tests`.

## The dark stage on by default in the release after 4.7.12 (canary Rollouts)

The release after 4.7.12 turns the Tech Spec's header-gated dark stage on by default and renders its `tests-dark`
AnalysisTemplate (DEVOPS-326). It changes canary Rollouts only (`deploymentType: rollout`, without
`migratingToRollouts`, in a repository whose `deployment-strategy` property is `canary`). Deployments, StatefulSets,
migrating Rollouts and Rollouts whose property is not `canary` render unchanged.

With the coordinator on and a preset, each canary Rollout of the release runs the dark stage after its `start` barrier,
where its steps render (prod, or `stepsOutsideProd`): `darkReplicas` canary pods (default 2, at least 2) at weight 0, a
`canary-header` route that sends `X-MyCarrier-Canary: <global.correlationId, lower-cased>` to the canary, the
`dark-ready` barrier, the leader's `<environment>-<fullName>-tests-dark` analysis, the `dark-passed` barrier (15m), and
the removal of the route. `tests-dark` is the chart's `tests` Job sent to the leader's stable Service with that header,
`RunKind: canary` and `SlipStep: none`; a failing suite aborts the release before any customer HTTP request reaches a
canary through the routes. Queue-driven work is not gated: the canary pods of a Rollout that consumes a queue (a KEDA
or Service Bus worker) do real work through the whole dark window, and their HTTP calls to the release's other canary
Rollouts reach those Rollouts' canaries, still untested, through the source routes. The first weight W is then wrapped in `setCanaryScale {weight: W}`, `setWeight W` and
`setCanaryScale {matchTrafficWeight: true}`, so the canary is sized for W% before traffic moves and never drops to 0.

Every canary Rollout renders `minPodsPerReplicaSet: 2`: the canary has at least 2 pods at every weight and otherwise
follows the weight. Where the steps render, the coordinator is on and the steps move in lock-step (a preset, or an
explicit `steps` list with a canary-coordinator barrier between every two `setWeight` steps), canary pods are labelled
`mycarrier.tech/rollout-role: canary` (`canaryMetadata`; stable pods `stable`), and each application's VirtualService
gets a `<route>-canary-source` route before each route with the `-preview` destination and no `fault` or `redirect`.
It matches callers whose pods carry that label and the release's `mycarrier.tech/correlationId` (as the pod renders
it), on `sourceLabels` only: its matches carry no `gateways`, because Istio skips `sourceLabels` on a match that sets
`gateways` (a match of the original whose own `gateways` leave out `mesh` is left out, and a route with no match left
gets no source route). It sends them to the `-preview` destination, so a release's
canary pods call each other's canaries during the dark stage and at every weight. Calls that leave the mesh (public
host, ingress gateway, KrakenD) reach stable pods. The `canary-header` route has no gateway restriction, so a public
request with the release's correlation id in the header reaches the canary during the dark stage (an accepted risk). After
one Rollout of the release aborts, for up to about 30 s (`abortScaleDownDelaySeconds`) the others' canary pods that call
it reach its aborted canary pods or its stable pods, then stable. The source routes render only with the coordinator
and its barriers between weights, for load proportionality: the barriers move the release's Rollouts through the same
weights in lock-step, while without them a caller can be at 50% and its callee at 10%, and the caller canary's whole
share would go to a callee canary sized for 10%. A preset has a barrier after each weight; an explicit `steps` list
gets the source routes only when it has a canary-coordinator barrier between every two `setWeight` steps, as a preset
does. Even in lock-step, at weight W a callee's canary receives about W x (2 - W) of its callers' traffic (the caller
canary's share plus W of the caller stable's share) on pods sized for W, at least 2: about 1.9 times its weight's share
at 10%, 1.75 times at 25%, 1.5 times at 50%. It compounds down a call chain, an HPA averaging over all pods does not
correct it, and the 2-pod floor absorbs it at small replica counts; the DEVOPS-321 pilot watches canary pod CPU and
latency against stable on callees that take most of their traffic from a sibling.

| Before | Edit |
|---|---|
| A release with two or more canary Rollouts and no `global.strategy.canary.leader` | Set `leader` to the application that runs the dark suite, or set `dark: false`. The render fails in every environment. |
| A leader without `testtrigger.testdefinitions` in an environment | Add test definitions to it in every environment, define a `tests-dark` entry under its `analysisTemplates`, or set `dark: false` there. The render fails in every environment, also where the steps do not render. |
| `tests` in `analysis.templates` | Set `dark: false` with it until Q54 is resolved, or remove `tests`: the dark stage runs the suite once at weight 0. |
| A frontend Rollout in a multi-frontend release | Set `dark: false`: the header route would also go into the shared `-multifrontend` VirtualService. |
| `darkReplicas: 1` | Remove it, or set 2 or more. |
| `progressDeadlineSeconds` (global or per application) at or below 900 | Remove it (default 1200 with the dark stage; 600 with `dark: false`, explicit `steps`, the coordinator off and on other Rollouts) or raise it above every barrier timeout, `dark-passed`'s 15m included. |
| `coordinator.barrierTimeouts.dark-passed` (default 15m, was 9m) at or below the leader's `tests-dark` (573 s with the defaults), with two or more canary Rollouts | Raise it, or lower `analysis.tests.timeout`. |
| A canary Rollout whose minimum replicas (`autoscaling.minReplicas`, `keda.idleReplicaCount` when set, else `keda.minReplicaCount`, else `replicas`; 1 with the top-level `scaling` value and no autoscaler) is below 2 where the steps render | Set it to 2 or more, and remove `keda.idleReplicaCount`: KEDA scales the Rollout to it while its triggers are idle, and the canary then drops to 0 pods. `dev` and `feature<N>` default to 1 replica, so a drill there with `stepsOutsideProd` sets `replicas: 2`. |
| A budget near 5700 s | The budgets with the defaults are, leader / follower: `standard` 5343 s / 4770 s, `fast` 3183 s / 2610 s, `manual` 5583 s / 5010 s (`manualTimeout` now defaults to 40m, was 1h). Lower raised barrier timeouts, `tests.timeout` or `manualTimeout`, or set `dark: false`. |
| A prod canary before the DEVOPS-321 pilot | Set `dark: false`: the prod TestEngine runs with `RUN_KINDS_ENABLED=false`, so `tests-dark` fails and the release aborts. |

To roll back, set `global.strategy.canary.dark: false`. The canary pod floor and the canary source routes stay; they
go only with the chart version.

## Chart Structure

```
mycarrier/
├── Chart.yaml              # Chart metadata
├── Chart.lock              # Dependency lock file (auto-generated)
├── values.yaml             # Default values
├── values.schema.json      # JSON Schema for validation
├── README.md               # This documentation file
├── templates/              # Kubernetes resource templates
│   ├── _helpers.tpl        # Named template definitions
│   ├── _environment.tpl    # Environment-specific template functions
│   ├── _labels.tpl         # Labeling template functions
│   ├── _lifecycle.tpl      # Container lifecycle configurations
│   ├── _networking.tpl     # Networking template functions
│   ├── _otel.tpl           # OpenTelemetry integration helpers
│   ├── _probes.tpl         # Health/readiness probe configurations
│   ├── _toleration.tpl     # Node tolerations for pods
│   ├── _spec_job.tpl       # Job spec template definitions
│   ├── _spec_cronjob.tpl   # CronJob spec template definitions
│   ├── deployment.yaml     # Standard deployment template
│   ├── service.yaml        # Service template
│   ├── statefulset.yaml    # StatefulSet template
│   ├── jobs.yaml           # Job template
│   ├── cronjob.yaml        # CronJob template
│   ├── offloads.yaml       # ApplicationSet generator for offloads
│   ├── extraObjects.yaml   # Template for custom Kubernetes objects
│   └── tests/              # Helm test templates
│       └── test-*.yaml     # Test resources
└── charts/                 # Packaged dependencies (auto-generated)
```

## Naming Conventions

This chart follows these naming conventions:

### Resources

- **Kubernetes Resources**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **Deployment/StatefulSet**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **Service**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **ConfigMap**: `{{ include "helm.fullname" . }}-{{ .appName }}-config`
- **Secret**: `{{ include "helm.fullname" . }}-{{ .appName }}-secrets`
- **VirtualService**: `{{ include "helm.fullname" . }}-{{ .appName }}`

### Template Files

- Helper templates start with underscore: `_helpers.tpl`
- Resource templates are named for the resource they create: `deployment.yaml`
- Conditional resources include the condition in the filename: `istio-gateway.yaml`

### Labels and Annotations

Standard labels applied to all resources:

```yaml
labels:
  app.kubernetes.io/name: {{ include "helm.fullname" . }}
  app.kubernetes.io/instance: {{ include "helm.instance" . }}
  app.kubernetes.io/part-of: {{ .Values.global.appStack }}
  app.kubernetes.io/component: {{ .appName }}
  app: {{ include "helm.fullname" . }}
  mycarrier.tech/environment: {{ .Values.environment.name }}
  mycarrier.tech/envscaling: {{ include "helm.envScaling" . }}
  mycarrier.tech/envType: {{ include "helm.envType" . }}
  mycarrier.tech/service-namespace: {{ include "helm.namespace" . }}
  mycarrier.tech/reference: {{ .Values.global.branchlabel }}
```

## Coding Style & Best Practices

### YAML Formatting

- Indentation: 2 spaces
- Line length: ≤ 80 characters when possible
- Use `|` for multi-line strings that need newlines preserved
- Use `>` for multi-line strings that can be folded

### Templates

- Use helper functions in `_helpers.tpl` for reusable logic
- Document each helper function with comments
- Use Sprig functions consistently and appropriately
- Prefer named templates over duplicated logic
- Include comments for complex template logic
- Use consistently formatted whitespace in templates

### Conditional Logic

```yaml
{{- if .Values.feature.enabled }}
# Resource inclusion for enabled feature
{{- end }}
```

### Iteration

```yaml
{{- range $appName, $app := .Values.applications }}
# Resource for each application
{{- end }}
```

## Values Structure

This chart uses a structured approach to values, organized by application. The following sections outline the key configuration areas:

### Global Settings

```yaml
global:
  appStack: "app"           # Application stack name
  language: "nodejs"        # Programming language (csharp, nodejs, java, python, nginx)
  gitbranch: ""             # Git branch name (for feature branches)
  branchlabel: ""           # Label for branch
  forceAutoscaling: false   # Force autoscaling regardless of environment
```

### Environment Settings

```yaml
environment:
  name: "dev"               # Environment name (dev, preprod, prod, feature-*)
  dependencyenv: "dev"      # Environment name for dependencies
  domainOverride:
    enabled: false          # Whether to override default domain
    domain: "example.com"   # Domain to use when override is enabled
```

### Application Definitions

The chart supports multiple applications within a single release:

```yaml
applications:
  example-api:
    isFrontend: false                      # Whether this is a frontend application
    forceOffload: false                    # Whether to force offloading
    staticHostname: "api.example.com"      # Optional static hostname (in feature envs, requires isEnvironmentDeploy: true)
    labels: {}                             # Custom labels
    annotations: {}                        # Custom annotations
    deploymentType: "deployment"           # Type: deployment, statefulset, or rollout
    version: "1.0.0"                       # Application version
    image:
      registry: "myregistry.example.com"   # Docker registry
      repository: "mycarrier/example-api"  # Docker image repository
      tag: "1.0.0"                         # Docker image tag
      pullPolicy: "IfNotPresent"           # Image pull policy
      pullSecrets: []                      # Image pull secrets
    replicas: 1                        # Number of replicas
    ports:
      http: 8080                           # HTTP port
      metrics: 9090                        # Metrics port
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    autoscaling:
      enabled: false
      minReplicas: 1
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
      targetMemoryUtilizationPercentage: 80
    nodeSelector: {}
    tolerations: []
    affinity: {}
    service:
      type: "ClusterIP"
      ports:
        - name: http
          port: 80
          targetPort: 8080
      annotations: {}
      disableAffinity: false
      affinityTimeoutSeconds: 600
    probes:
      liveness:
        enabled: true
        path: "/healthz"
        port: "http"
        initialDelaySeconds: 30
        periodSeconds: 10
      readiness:
        enabled: true
        path: "/readyz"
        port: "http"
        initialDelaySeconds: 10
        periodSeconds: 10
    env: []                                # Environment variables (key-value pairs)
    volumes: []
    volumeMounts: []
    lifecycle:
      postStart: "echo postStartTest"
      preStop: "pkill dotnet"  # Varies based on language -- NOTE: documented but not implemented by any template (pre-existing)
      preStopSleepSeconds: 5  # Default 5 when omitted; renders a preStop `sleep {N}` hook. 0 disables the hook.
                               # terminationGracePeriodSeconds also defaults to 10s, so the default preStop sleep
                               # leaves headroom in the default grace budget -- raise terminationGracePeriodSeconds
                               # for apps that need more time to drain in-flight requests after SIGTERM.
    networking:
      ingress:
        type: "istio"
      istio:
        enabled: true
        hosts: []
        redirects: {}
        routes: {}
        responseHeaders: {}
        corsPolicy: {}
    serviceAccount:
      create: false
```

### Autoscaling Configuration

The chart provides intelligent autoscaling with multiple configuration levels. See [AUTOSCALING.md](AUTOSCALING.md) for comprehensive documentation.

#### Configuration Options

**Global Level:**
```yaml
global:
  forceAutoscaling: true | false | not set
```

- **`not set`** (default): Allows automatic production autoscaling for non-migration apps
- **`false`**: Disables all automatic autoscaling (override mechanism)
- **`true`**: Forces HPA creation for all non-migration apps in any environment

**Application Level:**
```yaml
applications:
  <app-name>:
    autoscaling:
      enabled: true | false
      forceAutoscaling: true | false
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
```

- **`enabled: true`**: Always creates HPA (highest precedence)
- **`forceAutoscaling: true`**: Creates HPA even for migration apps, overrides global settings

#### HPA Creation Logic

A HorizontalPodAutoscaler (HPA) is created when:

1. `autoscaling.enabled: true` (highest precedence), OR
2. `autoscaling.forceAutoscaling: true` (app-level force), OR
3. UNLESS `global.forceAutoscaling: false` (override blocks auto-scaling), THEN:
   - `global.forceAutoscaling: true` AND app is NOT a migration app, OR
   - Environment is production (envScaling=1) AND app is NOT a migration app

**Migration App Protection:** Apps with "migration" in their name are excluded from global force and automatic production autoscaling. Use app-level `autoscaling.enabled` or `autoscaling.forceAutoscaling` to enable HPA for migrations.

When autoscaling is **enabled**:
- A HorizontalPodAutoscaler (HPA) resource is created
- The `replicas` field is removed from the Deployment to allow HPA control
- The HPA manages scaling based on CPU/memory utilization
- **Default HPA values** (if not explicitly set):
  - `minReplicas`: **2**
  - `maxReplicas`: **10**
  - `targetCPUUtilizationPercentage`: **80**

When autoscaling is **disabled**:
- No HPA resource is created
- The `replicas` field is set on the Deployment with environment-specific defaults:
  - Feature environments (`feature-*`): Default 1 replica
  - Other environments (dev, preprod): Default 2 replicas
  - Production with migration apps: Default 2 replicas

#### Example Configuration

**Example 1: Default Production (Auto-scaling)**

```yaml
environment:
  name: "prod"              # Production environment (envScaling=1)

applications:
  api:
    # HPA automatically created in production
    # No autoscaling config needed
    autoscaling:
      minReplicas: 2        # Optional: customize min/max
      maxReplicas: 10

  db-migration:
    # Migration apps excluded from auto-scaling
    replicas: 1             # Uses static replicas
```

**Example 2: Disable Production Auto-scaling (Override)**

```yaml
global:
  forceAutoscaling: false   # Override: disable auto-scaling

environment:
  name: "prod"

applications:
  api:
    replicas: 3             # Uses static replicas (no HPA)
```

**Example 3: Force Autoscaling in Dev**

```yaml
global:
  forceAutoscaling: true    # Force HPA in any environment

environment:
  name: "dev"

applications:
  api:
    autoscaling:
      minReplicas: 1
      maxReplicas: 5

  db-migration:
    # Global force does NOT apply to migrations
    replicas: 1
```

**Example 4: App-level Override**

```yaml
global:
  forceAutoscaling: false   # Override global

environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: true         # Explicit enable overrides global
      minReplicas: 3
      maxReplicas: 15

  worker:
    replicas: 2             # Static replicas
```

For more examples and use cases, see [AUTOSCALING.md](AUTOSCALING.md).

### Networking Configuration

```yaml
networking:
  ingress:
    type: "istio"                          # Type: istio, nginx, or none
  istio:
    enabled: true
    hosts:
      - host: "api.example.com"
        paths:
          - path: "/"
            pathType: "Prefix"
    gateway: "istio-system/default"        # Ingress gateway (namespace/name); e.g. istio-system/authenticated for the authenticated gateway
    redirects: {}
    routes: {}
    responseHeaders: {}
    corsPolicy:
      allowOrigins:
        - exact: "https://example.com"
      allowMethods:
        - "GET"
        - "POST"
      allowHeaders:
        - "Authorization"
        - "Content-Type"
      maxAge: "24h"
```

The `mesh` gateway is always included in rendered VirtualServices; `gateway` only replaces the ingress-gateway entry and defaults to `istio-system/default` when unset. Workload resources (Deployment/StatefulSet/Rollout) and their pods carry the resolved designation in a `mycarrier.io/gateway` annotation for troubleshooting, unless istio is disabled for the application.

#### Whitelabel hosts

Use the `helm.whitelabelHost` helper to publish a label on the environment's domain without
hardcoding it. It renders `<label>.<domain>` in `prod`/`preprod`/`dev` and `<label>.<env>.<domain>`
in every other environment (`qa`, `uat`, `feature*`). The domain follows
`environment.domainOverride`.

```yaml
networking:
  istio:
    hosts:
      - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
```

| environment | rendered host |
|---|---|
| `prod` | `estes.mycarriertms.com` |
| `dev` / `preprod` | `estes.mycarrier.dev` |
| `feature20` | `estes.feature20.mycarrier.dev` |
| `feature20` + `domainOverride: integratedtm.dev` | `estes.feature20.integratedtm.dev` |

> Note: `{{ $domain }}` does **not** resolve inside a host value (it is a template-internal
> variable). Use `{{ include "helm.domain" $ }}` or the `helm.whitelabelHost` helper instead.

#### Legacy host aliases

`networking.istio.legacyHostAliases` is a list of **plain alias strings** — no template syntax.
The chart composes each alias into a full FQDN at render time via the `helm.legacyHostFqdn`
helper, reusing the same domain resolution as `helm.domain.prefix`/`helm.domain`:

```yaml
networking:
  istio:
    legacyHostAliases:
      - integrations-orderapi
```

| environment | rendered host |
|---|---|
| `prod` | `integrations-orderapi.api.mycarriertms.com` |
| `dev` | `integrations-orderapi.dev.mycarrier.dev` |
| `preprod` | `integrations-orderapi.preprod.mycarrier.dev` |
| `feature21` | `integrations-orderapi-feature21.dev.mycarrier.dev` |

> **Warning:** unlike `legacyHostAliases`, `networking.istio.hosts` entries ARE `tpl`-evaluated
> template strings, which is fine for the standard (non-offload) render path. But when an
> appStack uses v2 offloads, its `networking.istio.hosts` values are also copied verbatim into
> the `offloads.yaml` ArgoCD `ApplicationSet` (`goTemplate: true`, matrix generator), which
> parses **every** string leaf of the generator spec through Go's `text/template` with a
> sprig-only `FuncMap` before the chart ever renders it. A `{{ include ... }}` expression in a
> `networking.istio.hosts` entry is therefore a parse-time hard error at the generator stage
> that bricks the offload generator for the whole appStack — never put template syntax in
> `networking.istio.hosts` for an appStack on the offload path. Use `legacyHostAliases` (plain
> data) instead.

### Secrets Management

The chart integrates with Vault for secrets management:

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"           # Path to secrets in Vault for bulk retrieval
  individual:                              # Individual environment variables from Vault
    - envVarName: "DB_PASSWORD"
      path: "secrets/data/dev/db"
      keyName: "password"
  mounted:                                 # File-mounted secrets from Vault
    - name: "certificate"
      mountedFileName: "cert.pem"
      vault:
        path: "secrets/data/dev/certs"
        property: "certificate"
      mount:
        path: /app/certs
        subPath: cert.pem
```

### Environment Variables Configuration

The chart supports configuring environment variables at different scopes to provide maximum flexibility. Environment variables can be set at the global level (affecting all applications), per-application level, or using combinations for fine-grained control.

#### Global Environment Variables (All Components, All Environments)

Set environment variables that apply to all applications across all environments:

```yaml
global:
  env:
    LOG_LEVEL: "info"
    APP_VERSION: "1.0.0"
    FEATURE_FLAG_SERVICE_URL: "https://features.mycarrier.com"

applications:
  api:
    # Application-specific configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
  worker:
    # Application-specific configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
```

#### Component-Specific Variables

Set environment variables for specific applications that apply across all environments:

```yaml
applications:
  api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    env:
      API_RATE_LIMIT: "1000"
      API_TIMEOUT: "30s"
      ENABLE_METRICS: "true"
  
  worker:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
    env:
      WORKER_CONCURRENCY: "10"
      QUEUE_NAME: "background-jobs"
      WORKER_TIMEOUT: "300s"
```

#### Combined Approach Example

A comprehensive example showing how global and application-specific environment variables work together:

```yaml
global:
  # Global variables for all applications
  env:
    COMPANY_NAME: "MyCarrier"
    ENVIRONMENT: "dev"
    LOG_LEVEL: "warn"

environment:
  name: "prod"

applications:
  api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    env:
      # Application-specific variables
      API_PORT: "8080"
      API_WORKERS: "10"
      # Override global variable for this specific application
      LOG_LEVEL: "info"  # Always info for API, regardless of environment
    
  worker:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
    env:
      # Application-specific variables
      WORKER_TYPE: "background"
      QUEUE_WORKERS: "20"
      # This application inherits the global LOG_LEVEL setting
```

## Minimal Configuration Examples

The following examples demonstrate the minimal configuration required for different types of objects within the chart.

### Minimal Application

```yaml
global:
  appStack: "api"
  language: "nodejs"

environment:
  name: "dev"

applications:
  example-api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
```

### Minimal Service Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    service:
      type: "ClusterIP"
      ports:
        - name: http
          port: 80
          targetPort: 8080
```

### Minimal Deployment Configuration

```yaml
applications:
  example-api:
    deploymentType: "deployment"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

### Minimal StatefulSet Configuration

```yaml
applications:
  example-database:
    deploymentType: "statefulset"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/database"
      tag: "1.0.0"
    ports:
      http: 5432
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "1Gi"
```

### Minimal Istio/Networking Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    networking:
      ingress:
        type: "istio"
      istio:
        enabled: true
        hosts:
          - "api.mycarrier.dev"
```

#### Internal mesh hostnames

When Istio ingress is enabled, the chart also advertises mesh-internal DNS entries for every application using the pattern `{{ appStack }}-{{ application }}.{{ environment }}.internal`. These names allow workloads in any namespace to target a stable service address for each environment.

Only the shared, non-feature environments (`dev`, `qa`, `uat`, `preprod`, `prod`, etc.) get a `ServiceEntry` for their `.internal` host — the `dev` release is the sole owner of `*.dev.internal`. Feature environments (`environment.name` equal to or prefixed with `feature`, e.g. `feature-my-branch`) never render a `ServiceEntry` of their own, regardless of that environment's `networking.istio.internalEnabled` setting; setting `internalEnabled: false` on a shared environment also skips rendering for it.

Routing to a feature namespace instead happens **dynamically at the mesh layer**: the dev-only `EnvoyDevFallback` WASM plugin inspects the `environment` request header on calls to `*.dev.internal` and dispatches to the matching feature namespace — note the dispatch only fires when `dev`'s own response for the request is an error (404/503/route-not-found); a request the `dev` deployment answers successfully is served by `dev` even when the header names a feature environment. When no matching feature deployment exists, traffic likewise stays on `dev`. There is no per-feature DNS entry or ServiceEntry involved — see `DevOps/EnvoyDevFallback/FEATURE_ROUTING_RCA.md` for the full routing rationale.

### Minimal Secret Configuration

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"
  individual:
    - envVarName: "DB_PASSWORD"
      path: "secrets/data/dev/db"
      keyName: "password"
```

### Minimal CronJob Configuration

```yaml
cronjobs:
  - name: backup-job
    schedule: "0 2 * * *"  # Run daily at 2 AM
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
```

### Minimal OpenTelemetry Configuration

To enable OpenTelemetry for a Node.js application:

```yaml
global:
  language: "nodejs"
  appStack: "api"

disableOtelAutoinstrumentation: false  # Opt in to operator auto-instrumentation (default true = off)
```

The standard `OTEL_*` env block is injected regardless of this key; it is governed by
`manualOtelConfig`. See [OpenTelemetry Integration](#opentelemetry-integration).

### Minimal Tolerations Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "api"
        effect: "NoSchedule"
```

## Template Usage Guide

### Helper Functions

These are the main helper functions in the templates:

#### Basic Naming and Context

```
{{- define "helm.fullname" -}}
{{- $ctx := fromJson (include "helm.default-context" .) -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}
{{- $appName := .appName | default "" -}}
# ... additional logic ...
{{- end }}
```

Used for generating consistent resource names across environments.

#### Labels

```
{{- define "helm.labels.standard" -}}
app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
app.kubernetes.io/part-of: {{ $appStack }}
app.kubernetes.io/component: {{ $appName }}
# ... additional labels ...
{{- end -}}
```

Used for applying consistent labels to resources.

#### Probes

```
{{- define "helm.defaultReadinessProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if (dig "ports" (dict) .application) }}
readinessProbe:
  tcpSocket:
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  # ... probe configuration ...
{{- end }}
{{- end }}
{{- end -}}
```

Used for configuring health, readiness, and liveness probes.

### Example: Using Helper Templates

Here's how to use these helper functions in templates:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "helm.fullname" . }}-{{ $appName }}
  annotations:
    argocd.argoproj.io/sync-wave: "10"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  labels:
    {{- include "helm.labels.standard" . | nindent 4 }}
spec:
  replicas: {{ $app.replicas }}
  selector:
    matchLabels:
      {{- include "helm.labels.selector" . | nindent 6 }}
  template:
    metadata:
      annotations:
        {{- include "helm.annotations.istio" . | nindent 8 }}
        {{- include "helm.otel.annotations" . | nindent 8 }}
      labels:
        {{- include "helm.labels.selector" . | nindent 8 }}
        {{- include "helm.otel.labels" . | nindent 8 }}
    spec:
      {{- include "helm.podDefaultToleration" . | nindent 6 }}
      containers:
        - name: {{ $appName }}
          image: "{{ .image.registry }}/{{ .image.repository }}:{{ .image.tag }}"
          {{- include "helm.defaultReadinessProbe" . | nindent 10 }}
          {{- include "helm.defaultLivenessProbe" . | nindent 10 }}
          env:
            {{- include "helm.otel.envVars" . | nindent 12 }}
            {{- include "helm.otel.language" . | nindent 12 }}
          resources:
            {{- include "helm.resources" . | nindent 12 }}
```

## Common Use Cases

### Deploying a Basic Node.js Application

```yaml
global:
  appStack: "app"
  language: "nodejs"

environment:
  name: "dev"

applications:
  api:
    deploymentType: "deployment"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
      metrics: 9090
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

### Configuring Vault Secrets

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"
  individual:
    - envVarName: DB_PASSWORD
      path: secrets/data/dev/app/db
      keyName: password
  mounted:
    - name: certificate
      mountedFileName: cert.pem
      vault:
        path: secrets/data/dev/app/certs
        property: certificate
      mount:
        path: /app/certs
        subPath: cert.pem
```

### Advanced StatefulSet Configuration

```yaml
applications:
  database:
    deploymentType: "statefulset"
    replicas: 3
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        partition: 0
    podManagementPolicy: "OrderedReady"
    persistentVolumes:
      - name: data
        mountPath: /data
        size: 10Gi
        storageClass: "standard"
        accessModes:
          - ReadWriteOnce
```

### Using Offloads

For development environments, the chart supports "offloading" certain applications to separate Argo CD ApplicationSets:

```yaml
applications:
  example-api:
    isFrontend: false
    forceOffload: true  # Force this application to be offloaded
    # ... other app configuration ...
```

### Running Scheduled Jobs with CronJobs

The chart supports Kubernetes CronJobs for running scheduled tasks such as backups, cleanup operations, or periodic data processing:

#### Basic CronJob Example

```yaml
cronjobs:
  - name: nightly-backup
    schedule: "0 2 * * *"  # Run daily at 2 AM UTC
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
    command: ["/bin/sh", "-c"]
    args: ["./backup.sh"]
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

#### Advanced CronJob with All Features

```yaml
cronjobs:
  - name: data-cleanup
    schedule: "0 3 * * 0"  # Run weekly on Sunday at 3 AM
    timeZone: "America/New_York"  # Use specific timezone
    concurrencyPolicy: "Forbid"  # Don't allow concurrent runs
    suspend: false  # Set to true to temporarily disable
    successfulJobsHistoryLimit: 5  # Keep last 5 successful jobs
    failedJobsHistoryLimit: 3  # Keep last 3 failed jobs
    startingDeadlineSeconds: 300  # Start within 5 minutes of scheduled time
    activeDeadlineSeconds: 900  # Kill job if it runs longer than 15 minutes
    backoffLimit: 2  # Retry up to 2 times on failure
    restartPolicy: "OnFailure"  # Restart container on failure

    # Custom labels and annotations
    labels:
      team: "data-engineering"
      job-type: "cleanup"
    annotations:
      app.mycarrier.tech/description: "Weekly data cleanup job"

    # Container configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/data-cleanup"
      tag: "2.0.0"
    imagePullPolicy: "Always"
    imagePullSecret: "custom-pull-secret"

    # Command and arguments
    command: ["/usr/local/bin/python"]
    args: ["-m", "myapp.jobs.cleanup", "--mode=weekly"]

    # Environment variables
    env:
      - name: CLEANUP_THRESHOLD_DAYS
        value: "90"
      - name: DRY_RUN
        value: "false"

    # Use ConfigMap and Secrets
    configMapName: "cleanup-config"
    secretName: "cleanup-secrets"

    # Resource limits
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "2000m"
        memory: "2Gi"

    # Volume mounts
    volumes:
      - name: temp-data
        mountPath: /tmp/cleanup
        kind: emptyDir
```

#### Multiple CronJobs Example

```yaml
cronjobs:
  # Daily backup job
  - name: database-backup
    schedule: "0 1 * * *"  # Daily at 1 AM
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
    env:
      - name: BACKUP_TYPE
        value: "full"

  # Hourly cache cleanup
  - name: cache-cleanup
    schedule: "0 * * * *"  # Every hour
    concurrencyPolicy: "Replace"  # Replace running job if new one starts
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/cache-cleanup"
      tag: "1.0.0"

  # Weekly report generation
  - name: weekly-report
    schedule: "0 9 * * 1"  # Monday at 9 AM
    timeZone: "America/New_York"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/reports"
      tag: "1.0.0"
    resources:
      requests:
        cpu: "1000m"
        memory: "1Gi"
      limits:
        cpu: "2000m"
        memory: "4Gi"
```

#### CronJob Configuration Options

| Field | Description | Default |
|-------|-------------|---------|
| `name` | Name of the CronJob (required) | - |
| `schedule` | Cron schedule expression (required) | - |
| `timeZone` | Timezone for the schedule | System timezone |
| `concurrencyPolicy` | How to handle concurrent executions: `Allow`, `Forbid`, or `Replace` | `Forbid` |
| `suspend` | Suspend all executions | `false` |
| `successfulJobsHistoryLimit` | Number of successful jobs to keep | `3` |
| `failedJobsHistoryLimit` | Number of failed jobs to keep | `1` |
| `startingDeadlineSeconds` | Deadline for starting if missed schedule | None |
| `activeDeadlineSeconds` | Maximum job execution time | None |
| `backoffLimit` | Number of retries before marking job as failed | `0` |
| `restartPolicy` | Pod restart policy: `Never` or `OnFailure` | `Never` |
| `image` | Container image configuration (required) | - |
| `imagePullPolicy` | Image pull policy | `IfNotPresent` |
| `imagePullSecret` | Image pull secret name | `imagepull` |
| `command` | Container command override | None |
| `args` | Container arguments | None |
| `env` | Environment variables array | `[]` |
| `configMapName` | ConfigMap to load as environment variables | None |
| `secretName` | Secret to load as environment variables | None |
| `resources` | CPU and memory resource limits | Defaults set |
| `labels` | Custom labels added to the CronJob resource | `{}` |
| `annotations` | Custom annotations, rendered onto BOTH the CronJob resource metadata and the CronJob pod template (filtered against chart-managed keys — see [Security Context and Reserved Annotations](#security-context-and-reserved-annotations)) | `{}` |
| `securityContext` | Opt-in hardened security context (`readOnlyRootFilesystem`, `fsGroup`, `seccompProfile`) — see [Security Context and Reserved Annotations](#security-context-and-reserved-annotations) | unset |
| `volumes` | Volume mounts configuration | `[]` |

#### Cron Schedule Examples

- `"*/5 * * * *"` - Every 5 minutes
- `"0 * * * *"` - Every hour
- `"0 0 * * *"` - Daily at midnight
- `"0 2 * * *"` - Daily at 2 AM
- `"0 0 * * 0"` - Weekly on Sunday
- `"0 0 1 * *"` - Monthly on the 1st
- `"0 9 * * 1-5"` - Weekdays at 9 AM

### Deploying an In-Cluster MongoDB (internal tools)

`dependencyDeployments.mongodb.enabled: true` deploys a MongoDB replica set, `<appStack>-mongodb`, in the stack's
namespace, rendered from the [mc-mongodb](../mc-mongodb) subchart's named templates. It needs the MongoDB operator
and External Secrets in the cluster. Product applications keep using MongoDB Atlas (`global.dependencies.mongodb`).

```yaml
global:
  appStack: toolbox
  language: csharp
  dependencies:
    mongodb: true
dependencyDeployments:
  mongodb:
    enabled: true
    # members: 3                  # default: 3 in production, 1 elsewhere
    # version: "8.0.34"
    # storage: { size: 10Gi, storageClassName: "" }
    # resources: {...}
    # backup: { schedule: "0 2 * * *", timeZone: Etc/UTC, retentionDays: 7 }
    # backup: { enabled: true, container: <cluster's container> }   # outside production
```

- The connection string is in Secret `<appStack>-mongodb-connection`, key `connectionString`; its database is
  `appStack`. For a csharp stack with `global.dependencies.mongodb`, `MongoConnection_<env>` reads it instead of Vault.
- Production (meta environment starting with `prod`) always backs up, to the `production` container of
  `mycarriermongobackups` unless `backup.container` names another, folder `<meta environment>/<appStack>/<namespace>`,
  and gets a suspended `<appStack>-mongodb-restore` CronJob. Any other environment backs up only with
  `backup.enabled: true` and its cluster's `backup.container`; offloaded feature environments never back up.
  Production containers are named `production*` and only production uses them; a mismatch fails the render. Each
  cluster's kubelet identity needs `Storage Blob Data Contributor` on its container.
- The subchart's own values live under `mc-mongodb` and are not for stacks to set.

## KrakenD AutoConfig

The chart can render a `gateway.krakend.io/v1alpha1` **`KrakenDAutoConfig`** CR
for any application that opts in via `networking.krakend.enabled: true`. The
KrakenD operator watches the CR and generates KrakenD endpoints from the
referenced OpenAPI spec.

### Internal-only guarantee

The rendered CR **only ever references internal addresses**:

- `spec.openapi.url` is always built from the application's `.internal` host:

  ```text
  http://<baseFullName>.<metaEnv>.internal<path>
  ```

  e.g. `http://app-routingguide-publicapi.dev.internal/swagger/v1/swagger.json`.
- The chart does **not** auto-generate `urlTransform.hostMapping` entries.
  The block is omitted entirely unless the user configures `stripPathPrefix`,
  `addPathPrefix`, or `extraHostMapping`.
- User-supplied `extraHostMapping` entries are validated at template time:
  the `to:` host **must** end in `.internal` or `.svc.cluster.local`, and
  rendering **fails** if any `to:` value contains the external domain.

### Required prerequisites

KAC rendering requires **all** of the following — the chart fails the render
otherwise. These conditions mirror the gating on the `.internal` ServiceEntry
that the CR depends on.

1. `environment.name` is **not** a feature environment.
2. `networking.istio.enabled` is `true`.
3. `istioDisabled` (top-level application flag) is not `true`.
4. `service.istioDisabled` is not `true`.
5. `networking.istio.internalEnabled` is `true`.

### Development workflow

**New public API endpoints must be developed and released directly to `dev`.**
Feature environments are intentionally excluded from `KrakenDAutoConfig`
rendering — attempting to render one there will fail the Helm template.
Each KAC registers endpoints on the shared `KrakenDGateway`, so per‑feature‑env
variants of the same application would collide with the dev‑env KAC for
that application. Iterate on new gateway endpoints against `dev` and
promote through the normal preprod/prod pipeline.

### Minimal configuration

```yaml
applications:
  routingguide-publicapi:
    # ... standard deployment configuration ...
    networking:
      istio:
        enabled: true
        internalEnabled: true
      krakend:
        enabled: true
        gatewayRef:
          name: mycarrier-public-api
          namespace: krakend
```

### Full configuration reference

See the commented example under `networking.krakend` in
[`values.yaml`](./values.yaml) and the schema in
[`values.schema.json`](./values.schema.json). Supported fields:

| Field | Description |
|-------|-------------|
| `enabled` | Render the KAC CR. Default `false`. |
| `name` | Override `metadata.name`. Default `<fullName>-autoconfig`. |
| `autoConfigNamespace` | KAC namespace. Defaults to `gatewayRef.namespace` → `global.krakendGatewayNamespace` → app namespace. |
| `labels` / `annotations` | Extra metadata merged into the KAC CR. |
| `gatewayRef.name` | **Required.** `KrakenDGateway` name. |
| `gatewayRef.namespace` | Gateway namespace. Falls back to `global.krakendGatewayNamespace` or the app namespace. |
| `trigger` | `OnChange` (default) or `Periodic`. |
| `periodic.interval` | Required when `trigger=Periodic` (e.g. `5m`). |
| `openapi.path` | Path appended to the internal host. Default `/swagger/v1/swagger.json`. |
| `openapi.format` | `json` or `yaml`. Auto-detected if omitted. |
| `openapi.allowClusterLocal` | Default `true`. |
| `openapi.auth` | Optional bearer/basic auth for the spec fetch. |
| `urlTransform.stripPathPrefix` / `addPathPrefix` | Path rewrites. |
| `urlTransform.extraHostMapping` | Additional host mappings emitted under `spec.urlTransform.hostMapping`. `to:` host **must** end in `.internal` or `.svc.cluster.local`; values containing the external domain or non-internal hosts (e.g. IP literals, public hostnames) are rejected at render time. When omitted, no `hostMapping` is emitted. |
| `defaults` | Endpoint/backend defaults (mirrors `KrakenDAutoConfigSpec.Defaults`). |
| `overrides` | Per-operation overrides. |
| `filter` | Include/exclude by path/method/tag/operationId. |
| `cue` | Optional CUE definitions / environment. |

## ArgoCD Integration

The chart includes ArgoCD sync waves and options for better GitOps workflows:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Controls the order of resource creation
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

## OpenTelemetry Integration

The chart wires OpenTelemetry through two independent keys. They have **deliberately opposite
defaults** and control different things:

| Key | Default | Controls | Opt- |
| --- | --- | --- | --- |
| `manualOtelConfig` | `false` | the whole standard `OTEL_*` env block, the `otel-log` volume, and auto-instrumentation | **out** |
| `disableOtelAutoinstrumentation` | `true` | the OTel Operator's automatic instrumentation only | **in** |

For both keys, an unset or null value means the documented default, and an explicit `false` means
`false`.

### Chart-managed configuration (default)

By default the chart injects a single contiguous `OTEL_*` env block into every container of every
workload type — deployments, rollouts, statefulsets, jobs, cronjobs, and initContainers — pointing
at the node-local collector:

```yaml
global:
  language: "nodejs"  # Supported values: nodejs, java, python, csharp
```

This includes the exporter protocol and endpoint, pod/node resource attributes, and
language-specific exporter settings.

### Overriding just the endpoint

Set `OTEL_EXPORTER_OTLP_ENDPOINT` yourself and the chart omits its own, so exactly one value
reaches the container:

```yaml
global:
  env:
    OTEL_EXPORTER_OTLP_ENDPOINT: https://telemetry.example.com
```

Resolution is **per workload and mutually exclusive**, mirroring which env sources actually render
into each container. `global.env` reaches main containers only; jobs read `jobs[].env`, cronjobs
read `cronjobs[].env`, and initContainers read their own `env`. A job's endpoint therefore deviates
from its application's rather than inheriting it — and setting only `global.env` leaves jobs,
cronjobs, and initContainers on the injected default rather than stranding them with no endpoint.

### Taking over completely

```yaml
manualOtelConfig: true
global:
  env:
    OTEL_EXPORTER_OTLP_ENDPOINT: https://telemetry.example.com
    OTEL_SERVICE_NAME: my-service
```

The chart then injects nothing OTel-related: no `OTEL_*` env vars, no
`instrumentation.opentelemetry.io` / `sidecar.opentelemetry.io` annotations, and no `otel-log`
volume or mount. Use this for browser-facing apps that publish their container env, where the
injected node-local endpoint is unreachable and the pod metadata should not be exposed. It overrides
`disableOtelAutoinstrumentation`.

The `language` pod label is chart metadata rather than OTel wiring, so it is unaffected.

### Operator auto-instrumentation

```yaml
global:
  language: "nodejs"

disableOtelAutoinstrumentation: false  # opt in; default true leaves it off
```

Adds the operator's injection annotations for `nodejs`/`java`/`python` and the nodejs
`NODE_OPTIONS --require @opentelemetry/auto-instrumentations-node/register` hook. Note the operator
may also set `NODE_OPTIONS` itself when it injects.

## Security Context and Reserved Annotations

### securityContext (applications / jobs / cronjobs)

All three workload surfaces (`applications[].securityContext`, `jobs[].securityContext`,
`cronjobs[].securityContext`) support the same keys. `fsGroup`, `seccompProfile`, and
`addCapabilities` remain opt-in — omitting `securityContext` entirely leaves them unset.
`readOnlyRootFilesystem` is the exception: it defaults to `true` even when `securityContext` is
omitted entirely.

| Key | Default | Notes |
| --- | --- | --- |
| `readOnlyRootFilesystem` | `true` | Chart-hardened default, applies to every workload kind (Deployment/StatefulSet/Job/CronJob/Rollout/TriggerTestEngine, incl. initContainers) even when `securityContext` is omitted. Set explicitly to `false` per-workload as a break-glass opt-out. An unconditional `/tmp` `emptyDir` volume is mounted on every Deployment/StatefulSet/Job/CronJob/Rollout container and initContainer for temp writes, so most images do not need the opt-out — the TriggerTestEngine job is the one exception: it has no `/tmp` mount, so its single `alpine/curl` container must not need to write to disk. |
| `addCapabilities` | `[]` | Applications only. All capabilities are dropped by default (`drop: [ALL]`); list specific capabilities here to add them back. |
| `fsGroup` | unset | Sets the pod-level `fsGroup`. Must be `>= 1` — `0` is the root group and is rejected by the values schema. **This lower bound is ORG POLICY**, enforced by `MyCarrier-DevOps/kyverno-policies` `require-non-root-groups` (rule `check-fsGroup`: "must be empty or greater than zero") — it is **not** an upstream Pod Security Standards control. The [PSS spec](https://kubernetes.io/docs/concepts/security/pod-security-standards/) contains zero occurrences of `fsGroup`/`runAsGroup`/`supplementalGroups`; those were PodSecurityPolicy fields, and PSP is retired. |
| `seccompProfile` | unset | Sets the pod-level `seccompProfile`, e.g. `{type: RuntimeDefault}`. |

> **Migration note (v4.0.0):** `readOnlyRootFilesystem` now defaults to `true` for all workload
> kinds (Deployment/StatefulSet/Job/CronJob/Rollout/TriggerTestEngine, including initContainers).
> Opt out per-workload with `securityContext: { readOnlyRootFilesystem: false }` if an image writes
> outside `/tmp` at runtime. `/tmp` is a writable `emptyDir` on every Deployment/StatefulSet/Job/
> CronJob/Rollout container and initContainer regardless of this setting — TriggerTestEngine has no
> `/tmp` mount at all, so its container needs the break-glass opt-out (or must avoid writing to disk)
> if it ever needs a writable root filesystem. Consumers who already set `readOnlyRootFilesystem`
> explicitly (`true` or `false`) are unaffected — this only changes the behavior when the key is
> omitted.

**seccompProfile and the `restrict-seccomp` kyverno policy**: the ClusterPolicy differs per cluster,
because each app cluster syncs its own branch of `MyCarrier-DevOps/kyverno-policies` (verified as of
2026-08-08):

| Cluster | `validationFailureAction` | Accepted pattern | Effect on `RuntimeDefault` |
| --- | --- | --- | --- |
| development | `Enforce` | `runtime/default \| RuntimeDefault` | Passes, IS enforced at admission. |
| data, production-csp | `Audit` (report-only) | `runtime/default` (literal only) | Records a PolicyReport entry; nothing is blocked. |

Use `RuntimeDefault`: it is the correct value for the Kubernetes `SeccompProfile.type` field
(`runtime/default` is the pre-1.25 annotation form and is not a legal field value), and the Pod
Security Standards `restricted` profile permits both `RuntimeDefault` and `Localhost`, forbidding
only `Unconfined`.

### Annotation precedence and reserved keys

`annotations` on any workload surface is filtered before rendering: chart-managed annotations
**always win**. A user-supplied key that collides with a chart-managed key is **dropped** from
`annotations` — it does not override the chart's value and does not render twice. The reserved set
is an **exact-key match** (Helm's `hasKey`), not a `vault.security.banzaicloud.io/*` prefix match —
any key outside the table below (including other `vault.security.banzaicloud.io/*` annotations the
chart doesn't set) is applied to the pod/resource as-is.

| Surface | Reserved keys |
| --- | --- |
| Application pod template (Deployment / StatefulSet / Rollout) | vault keys + otel keys (see below) + `sidecar.istio.io/inject`, `proxy.istio.io/config` + `mycarrier.io/gateway` |
| CronJob resource metadata | `argocd.argoproj.io/sync-options`, `argocd.argoproj.io/sync-wave` (`"10"`, the workloads' wave, so a CronJob updates after the pre-deploy jobs) |
| CronJob pod template | vault keys + otel keys only (no argocd/istio/gateway keys) |
| Job resource metadata | `argocd.argoproj.io/sync-options`; for a job with `.timing` (unless `runAsHook: false`) also `argocd.argoproj.io/hook`, `argocd.argoproj.io/sync-wave` and `argocd.argoproj.io/hook-delete-policy`, which the chart renders here, where Argo CD reads them (`pre-deploy`: PreSync, wave `order - 100`; `post-deploy`: PostSync, wave `order + 100`), and a user value for them fails the render |
| Job pod template | vault keys + otel keys + `argocd.argoproj.io/sync-options`, `argocd.argoproj.io/hook-delete-policy`, `argocd.argoproj.io/sync-wave`, `argocd.argoproj.io/hook` (reserved unconditionally; with `runAsHook: false` the chart renders the timing annotations here, where Argo CD ignores them, as before) |

**vault keys**: `vault-addr`, `vault-auth-method`, `vault-path`, `vault-role`,
`vault-agent-env-variables`, `mutate-probes`, `run-as-non-root`, `run-as-user`, `run-as-group`, plus
`vault-env-daemon` (only when `secrets` is set) and `vault-env-from-path` (only when
`secrets.bulk.path` is set).

**otel keys**: `sidecar.opentelemetry.io/inject`, `instrumentation.opentelemetry.io/container-names`,
and `instrumentation.opentelemetry.io/inject-<language>` for the one resolved language only —
rendered only when `manualOtelConfig` is not `true` AND `disableOtelAutoinstrumentation: false` AND
the language is `nodejs`/`java`/`python`.

**Unmanaged keys pass through as-is** — including security-relevant ones. Verified: `vault-skip-verify`
(disables TLS verification to Vault), `mutate: skip` (disables secret injection entirely),
`vault-namespace`, `vault-serviceaccount`. `psp-allow-privilege-escalation` also renders through but
is not documented in the current bank-vaults reference.

**Istio override is closed on application surfaces**: `sidecar.istio.io/inject`,
`proxy.istio.io/config`, and `mycarrier.io/gateway` set in `applications[].annotations` are dropped —
the chart's own computed values always win. Use `applications[].istioDisabled`,
`applications[].networking.istio.enabled`, or `applications[].service.istioDisabled` instead.

This does **not** apply to `cronjobs[]`/`jobs[]` — their pod templates emit no istio annotations of
their own, so `sidecar.istio.io/inject: "false"` set via `cronjobs[].annotations` /
`jobs[].annotations` still passes through and remains the documented way to stop a never-exiting
sidecar from hanging a CronJob/Job. This matters more for Jobs than CronJobs: chart Jobs are ArgoCD
PreSync/PostSync hooks, so a never-exiting sidecar on a Job pod blocks the entire application sync,
not just one Job run. `jobs[].annotations` now render onto both the Job resource metadata and the
Job pod template (filtered), mirroring `cronjobs[].annotations`.

The reserved set is also context-dependent: a key that is free today can become chart-managed when a
related feature is enabled (e.g. turning on otel autoinstrumentation), at which point the user's
value stops taking effect. This is deliberate — the alternative (failing the template render) would
turn an unrelated future "enable otel" change into a hard non-local build break.

## Troubleshooting

### Common Issues

1. **Pod Fails to Start**: Check resource constraints, image availability, and Vault connectivity
   ```bash
   kubectl describe pod -l app.kubernetes.io/instance=mycarrier-app
   ```

2. **Service Unavailable**: Verify service and endpoint configurations
   ```bash
   kubectl get svc,ep -l app.kubernetes.io/instance=mycarrier-app
   ```

3. **Istio Routing Problems**: Check VirtualService and Gateway resources
   ```bash
   kubectl get virtualservice,gateway -l app.kubernetes.io/instance=mycarrier-app
   ```

## Contributing

When contributing to this chart, please follow the coding standards defined in the chart's documentation.

### Contribution Workflow

1. Create a feature branch from `main`
2. Make changes to the chart
3. Update documentation
4. Run tests
5. Submit a pull request

## Parameters

### Global Settings

| Name                                  | Description                                                                                                     | Value         |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `global.appStack`                     | Application stack name, used for naming resources and grouping applications                                     | `app`         |
| `global.gitbranch`                    | Name of the git branch (used for feature branches)                                                              | `""`          |
| `global.branchlabel`                  | Label for the branch, used for reference label                                                                  | `""`          |
| `global.language`                     | Default programming language for applications (can be overridden at application level)                          | `csharp`      |
| `global.disableLanguageSecrets`       | Do not inject the language's default secrets and environment variables (the stack supplies its own)             | `false`       |
| `global.v2migration`                  | Flag to indicate if we are migrating to v2 (enables certain ArgoCD sync options)                                | `false`       |
| `global.commitDeployed`               | Label for the deployed commit (used for tracking deployments)                                                   | `""`          |
| `global.correlationId`                | Correlation ID for tracking deployments across systems                                                          | `""`          |
| `global.deploymentStrategy`           | The repository's deployment-strategy property, passed in by chart-renderer; only canary turns on the canary steps of Rollouts | `""`          |
| `global.argoEventsInstance`           | Argo Events namespace the render pipeline runs in (argo-events|argo-events-test); selects TestEngine deployment | `argo-events` |
| `global.env`                          | Global environment variables shared across all applications                                                     | `{}`          |
| `global.dependencies`                 | Dependency flags to control infrastructure resources                                                            |               |
| `global.dependencies.mongodb`         | Enable MongoDB dependency                                                                                       | `false`       |
| `global.dependencies.elasticsearch`   | Enable Elasticsearch dependency                                                                                 | `false`       |
| `global.dependencies.redis`           | Enable Redis dependency                                                                                         | `false`       |
| `global.dependencies.postgres`        | Enable PostgreSQL dependency                                                                                    | `false`       |
| `global.dependencies.sqlserver`       | Enable SQL Server dependency                                                                                    | `false`       |
| `global.dependencies.clickhouse`      | Enable ClickHouse dependency                                                                                    | `false`       |
| `global.dependencies.azureservicebus` | Enable Azure Service Bus dependency                                                                             | `false`       |
| `global.dependencies.redpanda`        | Enable Redpanda dependency                                                                                      | `false`       |
| `global.dependencies.loadsure`        | Enable Loadsure dependency                                                                                      | `false`       |
| `global.dependencies.chargify`        | Enable Chargify dependency                                                                                      | `false`       |

### Environment Settings

| Name                                 | Description                                                                                                     | Value         |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `environment.name`                   | Environment name / namespace (DNS-1123 label). Standard names (dev, preprod, prod, qa, uat, feature-*) have built-in behavior; any other name (e.g. demo) is allowed and treated as a generic environment — configure it explicitly via global.env / application.env / secrets (the same way qa/uat are configured). | `dev`         |
| `environment.namespaceOverride`      | Override the Kubernetes namespace (defaults to environment.name if not set)                                     | `""`          |
| `environment.dependencyenv`          | Environment name for dependencies                                                                               | `dev`         |
| `environment.domainOverride`         | Domain override configuration                                                                                   |               |
| `environment.domainOverride.enabled` | Whether to override the default domain (default domains: mycarrier.dev for non-prod, mycarriertms.com for prod) | `false`       |
| `environment.domainOverride.domain`  | Domain to use when override is enabled                                                                          | `example.com` |

### Platform Settings

| Name                             | Description                                                                            | Value        |
| -------------------------------- | -------------------------------------------------------------------------------------- | ------------ |
| `enableVaultCA`                  | Enable Vault CA certificate download during pod startup (no-op: its postStart hook was removed in DEVOPS-176; flag retained for values compatibility) | `false`      |
| `disableSecurity`                | BREAK-GLASS ONLY (discouraged). When true, every pod in the release renders without runAsNonRoot/securityContext hardening — release-wide, cannot be scoped per-application. Only flag that removes the hardening block (`enableDebugMode`'s privileged sidecar is a separate route). Kyverno `require-run-as-non-root` is Enforce only on development (Audit on production-csp/data). Not settable through mc-environment `environments[]` — direct mycarrier-helm values only, by design: this keeps the blast radius limited to whoever edits mycarrier-helm values directly, and it is intentionally not plumbed through mc-environment / the ApplicationSet path. | `false`      |
| `manualOtelConfig`               | Take over OpenTelemetry configuration from the chart (default false = chart-managed)   | `false`      |
| `disableOtelAutoinstrumentation` | Disable OpenTelemetry Operator auto-instrumentation only (set to false to enable)      | `true`       |
| `tolerations`                    | Default tolerations for all applications                                               | `[]`         |
| `deployment`                     | Deployment folder name (should match the subfolder containing the specific deployment) | `deployment` |

### Applications

| Name           | Description                                                          | Value |
| -------------- | -------------------------------------------------------------------- | ----- |
| `applications` | Map of application definitions where the key is the application name | `{}`  |

### Kubernetes Jobs

| Name   | Description                    | Value |
| ------ | ------------------------------ | ----- |
| `jobs` | List of Kubernetes Jobs to run | `[]`  |

### Kubernetes CronJobs

| Name       | Description                        | Value |
| ---------- | ---------------------------------- | ----- |
| `cronjobs` | List of Kubernetes CronJobs to run | `[]`  |

### Secrets Management

| Name                 | Description                                    | Value |
| -------------------- | ---------------------------------------------- | ----- |
| `secrets`            | Secret configuration                           |       |
| `secrets.bulk`       | Bulk secret retrieval from a single Vault path | `{}`  |
| `secrets.individual` | Individual environment variables from Vault    | `[]`  |
| `secrets.mounted`    | File-mounted secrets from Vault                | `[]`  |

### Infrastructure Resources

| Name                                              | Description                                                            | Value |
| ------------------------------------------------- | ---------------------------------------------------------------------- | ----- |
| `infrastructure`                                  | Infrastructure configuration                                           |       |
| `infrastructure.azure`                            | Azure infrastructure resources                                         |       |
| `infrastructure.azure.defaults`                   | Default values shared across all Azure resources                       |       |
| `infrastructure.azure.defaults.location`          | Default Azure region for all resources (empty = must set per-resource) | `""`  |
| `infrastructure.azure.defaults.providerConfigRef` | Default Crossplane ProviderConfig name                                 | `""`  |
| `infrastructure.azure.resourceGroup`              | Azure Resource Group configurations                                    | `[]`  |
| `infrastructure.azure.storage`                    | Azure Storage configuration                                            |       |
| `infrastructure.azure.storage.accounts`           | Azure storage account configurations                                   | `[]`  |
| `infrastructure.azure.servicebus`                 | Azure Service Bus namespace configurations                             | `[]`  |

### Alerts

| Name                              | Description                                                                                                                                                                                                                            | Value                                  |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `alerts.enabled`                  | Render the stack's alerts                                                                                                                                                                                                              | `false`                                |
| `alerts.serviceName`              | HyperDX ServiceName prefix the queries match (e.g. MC.Invoice); required when enabled                                                                                                                                                  | `""`                                   |
| `alerts.displayName`              | Display name ([A-Za-z0-9]+, e.g. Invoice): resource names, titles, rule uids; required when enabled                                                                                                                                    | `""`                                   |
| `alerts.interval`                 | Rule group evaluation interval                                                                                                                                                                                                         | `60s`                                  |
| `alerts.paused`                   | Default isPaused for standard and compact rules (raw rules keep their own isPaused)                                                                                                                                                    | `false`                                |
| `alerts.filters.excludedPaths`    | Paths left out of the alerts on the service's own HTTP responses (serverErrorRatio, clientErrorRatio, serverErrorCount, http503Returned): url.path values, or http.route values for nodejs                                             | `[]`                                   |
| `alerts.standard`                 | Overrides of the standard alerts global.language supplies (csharp, nodejs; see ALERTS.md), per alert and field: enabled, severity (sev1/sev2/sev3), threshold, for, title, paused, noDataState, execErrState and the alert's own lists | `{}`                                   |
| `alerts.additional`               | Additional rules keyed by name: compact (title, severity, sql, ...) or raw (rule: a Grafana AlertRule)                                                                                                                                 | `{}`                                   |
| `alerts.contactPoints.secretName` | Secret holding the Squadcast webhook URLs                                                                                                                                                                                              | `squadcast-webhooks`                   |
| `alerts.contactPoints.secretKey`  | Secret key of the general webhook (default: serviceName lowercased); the Sev1 contact point uses this key plus -sev1                                                                                                                   | `""`                                   |
| `alerts.routing.routes`           | Extra child routes under the stack's notification route, after the Sev1 route                                                                                                                                                          | `[]`                                   |

### Deployment Settings

| Name                  | Description                                                                            | Value   |
| --------------------- | -------------------------------------------------------------------------------------- | ------- |
| `isEnvironmentDeploy` | Whether this is an environment-level deployment (affects resource naming and behavior) | `false` |

## License

This chart is licensed under the Apache 2.0 License - see the LICENSE file for details.