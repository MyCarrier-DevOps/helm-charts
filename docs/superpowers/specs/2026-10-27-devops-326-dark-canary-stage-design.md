# DEVOPS-326: header-gated dark canary stage — design

Story: [DEVOPS-326](https://linear.app/mycarrier/issue/DEVOPS-326). Tech Spec: Canary Production Deploys (Argo Rollouts), decisions D11 and D20. Open-questions store: Q03, Q23–Q26, Q31, Q36, Q38, Q44, Q49, Q52, Q54.

## Why

On 2026-09-01 a case-sensitive tenant-header check shipped to prod and rejected every request from the production frontend. The canary presets start at `setWeight 10`, so customers would still meet such a build before any test has run. The dark stage runs the service's test suite against the canary at weight 0, sending headers the way production clients do, and aborts the release before a customer request reaches it. The exposure target for suite-detectable defects becomes 0%.

## What already exists (do not rebuild)

- **mycarrier-helm (main, 4.7.11)** renders the dark stage when the coordinator is on and `global.strategy.canary.dark` is true (`_canary.tpl`, `helm.canary.configuredSteps`): `setCanaryScale {replicas: darkReplicas}` → `setHeaderRoute canary-header` (match `X-MyCarrier-Canary: <global.correlationId>`) → barrier `dark-ready` → `<env>-<fullName>-tests-dark` analysis (leader only) → barrier `dark-passed` → `setHeaderRoute {name: canary-header}` (removes it) → `setCanaryScale {matchTrafficWeight: true}`. It renders `trafficRouting.managedRoutes` and the leader rule (`helm.canary.leader`: `global.strategy.canary.leader`, or the only canary Rollout when there is one — chosen on purpose, not by name order; with the dark stage on, a stack with two or more canary Rollouts must set `leader` or the render fails), and refuses the dark stage for a frontend that shares the multi-frontend VirtualService. Defaults today: `dark: false`, `darkReplicas: 1`. The leader's render fails because no `tests-dark` template exists.
- **mc-environment** tells Argo CD to ignore `.spec.http[] | select(.name == "canary-header")`.
- **TestEngine** (MC.TestEngine#95): `/v1/trigger` accepts `RunKind`, `SlipStep`, `RequestHeaders` in `TestEnvironmentVariables`; `GET /v1/capabilities`; `GET /v1/runs/{id}`. The Worker passes `RequestHeaders` to the test container as `REQUEST_HEADERS` (JSON object, name → value) and `RUN_KIND`. For `RunKind=canary`, DeployVerifier checks every Rollout of the correlation group for an available canary ReplicaSet and, when a request header carries the correlation id, for the managed header route. `RUN_KINDS_ENABLED` is true on testengine-dev, false on prod until the DEVOPS-321 pilot.
- **helm-charts#158 (DEVOPS-515, open, changes requested)** adds the `<env>-<fullName>-tests` AnalysisTemplate: a Job that submits the app's `testtrigger.testdefinitions` through `helm.testtrigger.v1request` with `RunKind=canary`, `SlipStep=none`, `Tolerations: []`, `ServiceAddress` = the `-preview` Service, and implements TestEngine's caller contract (capabilities preflight, poll, one resubmit on `no_results`/`infra_failed`, exit 0 only on `passed`). It refuses a Rollout with managed routes ("until DEVOPS-326") and refuses a coordinator-off release with more than one canary Rollout. **326 builds on #158 and cannot merge before it.**

## Decisions (from the 2026-10-27 design conversation unless noted)

1. **The suite stays in the cluster** (Q44, 2026-10-21). The leader's `tests-dark` run targets the leader's **stable** Service in-cluster address with `X-MyCarrier-Canary: <lower-case correlation id>`; the TestEngine test Job's Istio sidecar applies the header route.
2. **The header value is the correlation id**, no extra control (Q25, 2026-10-13).
3. **`dark` defaults to `true`.** Nothing running changes: no repo renders a canary Rollout today (MC.Devopstest, the one `canary` repo, renders a Deployment). From the DEVOPS-321 pilot on, prod TestEngine must have `RUN_KINDS_ENABLED=true` first, or `tests-dark` fails its capabilities check and the release aborts (fail closed, accepted).
4. **`darkReplicas` defaults to `2`** (option 1 of the 2026-09-30 route-loss comment): one canary pod restart no longer drops availability to 0, so Argo Rollouts does not remove the header route mid-suite.
5. **The canary always has at least 2 pods, and otherwise follows the weight.** Argo's `minPodsPerReplicaSet: 2` (A4). "We require minimum 2 pods in production anyway." See Change A4.
6. **Canary pods of a release call canary pods of the same release, during the dark stage and through every weight step** ("It's ideal"). Done with Istio source-label routing, not header injection. See Change A3. This is what makes one dark run reach every canary of a multi-Rollout release (R6) without the suite calling each service and without app changes.
7. **The dark-stage window is widened for everyone (option B, user 2026-10-27, provisional while the user checks suite lengths with AQA):** `barrierTimeouts.dark-passed` default 15m and `progressDeadlineSeconds` default 1200, so the leader's `tests-dark` Job (up to ~573 s with #158's 7m poll budget, 120 s startup and Argo's detect lag) fits inside the followers' wait. The chart's existing rule (every barrier timeout below the progress deadline) stays. Keep both values in one place so a later change is one edit.
8. **`manualTimeout` default drops from 1h** so the manual preset fits the 5700 s budget cap with the dark stage on (user 2026-10-27 agreed to 45m; with decision 7's longer barrier the builder sets the largest whole-5-minute value that keeps the manual leader's `canaryBudgetSeconds` ≤ 5700, expected 40m, and reports it). Standard and fast must still fit with the dark stage; the builder states each preset's leader and follower budget in the PR.
9. **The test suite is the AQA team's** (MC.TestAutomation). 326 does not wait for AQA: it defines the suite contract in an AQA ticket (Change D) and builds and proves its own side against that contract with a stand-in suite.

## Change

### A. mycarrier-helm

**A1. Defaults.** `dark: true`, `darkReplicas: 2` in `helm.canary.config`, `values.yaml` comments, `values.schema.json`, README and the stack-values guidance. `darkReplicas` minimum is 2 (schema and render check).

**A2. `<env>-<fullName>-tests-dark` AnalysisTemplate**, rendered for the leader only, under the same conditions that make `helm.canary.configuredSteps` emit the step today (coordinator on, `dark` true; the existing `stepRefs` logic in `analysistemplate.yaml` already counts it). It is #158's `tests` Job with these differences, and nothing else:
- `ServiceAddress` = the leader's stable Service, `http://<fullName>.<namespace>.svc.cluster.local:<http port>`, keeping a definition's own path the way #158 keeps it for `-preview`. #158's host and port rules apply with the stable host in place of `-preview`.
- `TestEnvironmentVariables.RequestHeaders` = `{"X-MyCarrier-Canary": "<global.correlationId, lower-cased>"}`.
- `RunKind=canary`, `SlipStep=none`, `Tolerations: []` as in #158.
- A leader without `testtrigger.testdefinitions` fails the render, naming `global.strategy.canary.dark: false` as the way out.
- The request body is otherwise the same as `tests` (shared helper; the two must not drift). Reuse #158's script and Job settings; do not fork them (DRY: this is the second consumer).

**A3. Source route (canary → canary).** For every canary Rollout where the steps render (`helm.canary.stepsRendered`), the VirtualService gets a source-matched twin of each route whose destinations include the app's `-preview` host and that has no `fault` and no `redirect`, placed **immediately before its original** (so the other routes — redirects, custom routes to other hosts, `-feature-routing`, and `-forbidden`, which on a Rollout has the `-preview` destination but whose fault answers 403 whatever the destination — keep their position and answer canary callers exactly as they answer stable ones; a canary caller asking for a blocked path falls through to the same `-forbidden` 403, R8). *Amended 2026-10-27 (Task 3 builder check): the fault/redirect exclusion replaces the earlier wording, which counted `-forbidden` among routes without a `-preview` destination.*
- same name with a `-canary-source` suffix; same `match` entries (environment header + allowed path, allowed paths, …), each entry ANDed with `sourceLabels` and `gateways: [mesh]`; a twin of a route with no `match` gets a single match with just those two;
- `sourceLabels` selects **canary pods of this release only**: the Rollout renders `strategy.canary.canaryMetadata.labels` (Argo Rollouts ephemeral metadata) with a canary-role label (name is the builder's call, e.g. `mycarrier.tech/rollout-role: canary`), and the twin matches that label **and** `mycarrier.tech/correlationId` with the value the pod label carries, as the chart renders it (`helm.labels.correlationId`: the id's own case, cut to 63 characters; Istio compares `sourceLabels` exactly, so a lower-cased value would miss an upper-case id). *Builder-check call (2026-10-27):* matching the correlation id alone would also catch the release's Deployments, StatefulSets, Jobs and CronJobs, which carry the same label and sync in the same wave, and would send their customer traffic to canaries at weight 0. Argo adds the canary label to canary pods while they are canary and replaces it with `stableMetadata` on promotion, so the twins match nothing after promotion or abort. Verify the label lifecycle against Argo Rollouts v1.10.x;
- one destination: the original's (first) `-preview` destination, on its port, weight omitted; every other field of the original except `name`, `match` and `route` (headers, timeout, retries, CORS, `rewrite`, `mirror`, …) copied, so the twin's outcome equals the original's except the destination. *Amended 2026-10-27 (Task 3): replaces the earlier list of four copied fields.*

**Correlation id casing.** The header route value and the `tests-dark` header value use the same lower-cased id (TestEngine requires lower case for the header; slip ids are minted lower case, so this changes nothing in practice). The source-route `sourceLabels` value is not lower-cased: it matches the pod label as rendered (A3). *Amended 2026-10-27 (Task 3).*

Requirement, not mechanism: a request from a canary pod of this release must get exactly the allowlist outcome a request from a stable pod gets (same paths allowed, same 403s), only served by the callee's canary. The builder verifies this against the rendered VirtualService for allowlist on/off, `enforceAllowlistOnEnvironmentHeader` true/false, and extra ports.

Constraints the builder must check, with tests:
- Twins are not listed in `trafficRouting.istio.virtualService.routes` (Argo Rollouts must not manage them) and do not match mc-environment's ignore rule (single destination), so Argo CD keeps them in sync from git.
- Argo Rollouts' `setHeaderRoute` inserts `canary-header` at the top of the VirtualService; the twins sit below it and above everything else. Confirm against Argo Rollouts v1.10.x `orderRoutes`.
- Not rendered where steps do not render, on Deployments, or on rolling Rollouts (byte-identical renders there), nor on the multi-frontend VirtualService (same refusal scope as the dark stage).
- Pods carry `mycarrier.tech/correlationId` (`helm.labels.standard` in `helm.specs.podTemplate`); Istio `sourceLabels` only applies to sidecar-injected callers inside the mesh, which is the intent. Calls that leave the mesh (public host, ingress gateway, KrakenD) reach stable; document it.

**A4. Canary pod floor.** Render `strategy.canary.minPodsPerReplicaSet: 2` (today 1) on canary Rollouts. *Amended 2026-10-27 from Argo Rollouts source (`utils/replicaset/canary.go:357-386`, v1.10.0 and v1.10.1):* whenever the canary's size comes from the traffic weight (no `setCanaryScale`, `setCanaryScale {weight}` or `{matchTrafficWeight: true}`), Argo sizes it `max(ceil(weight × spec.replicas / 100), minPodsPerReplicaSet)`, capped at `spec.replicas`; a count of 0 stays 0. So the canary has at least 2 pods at every weight and otherwise follows the weight and HPA/KEDA scale-out — exactly decision 5, with no per-step scaling (this replaces the earlier `setCanaryScale {weight: N}` formula and its full-size canaries; the one `setCanaryScale {weight: W}` left wraps the first weight, below).

Two consequences the builder implements and tests:
- The dark stage's closing `setCanaryScale {matchTrafficWeight: true}` runs at weight 0, where Argo computes 0 canary pods, so today the dark-tested canary is scaled to 0 and recreated at the first weight. *Amended 2026-10-27 (fix round 1):* drop that closing step and wrap the ladder's first weight W instead: `setCanaryScale {weight: W}` → `setWeight W` → `setCanaryScale {matchTrafficWeight: true}`. The `darkReplicas` pods stay up into the first weight and the canary never drops to 0 between the dark stage and promotion.
  - Why not just move `{matchTrafficWeight: true}` after the first `setWeight` (the earlier wording): the dark `setCanaryScale {replicas: 2}` would still be in force at `setWeight W`. Argo sets the traffic weight from the step (`rollout/trafficrouting.go`, `desiredWeight = GetCurrentSetWeight`), not from the canary's size, so W% of traffic would go to the 2 dark pods until the next step resized the canary, which overloads them whenever W% of the Rollout is more than 2 pods' worth (an HPA scaled out under load: more than 8 replicas at 25%, more than 20 at 10%). A weight-based `setCanaryScale {weight: W}` sizes the canary `max(ceil(W × spec.replicas / 100), minPodsPerReplicaSet)` through `CheckMinPodsPerReplicaSet` (`utils/replicaset/canary.go:356-386`) before traffic moves, and `setWeight W` completes only once the canary is at that size (`AtDesiredReplicaCountsForCanary`). The closing `{matchTrafficWeight: true}` then hands sizing back to the weight for the rest of the ladder.
  - The wrap renders only when the coordinator and the dark stage are on; without the dark stage no explicit scale is in force at the first weight.
- `minPodsPerReplicaSet` is capped at `spec.replicas`, so a 1-replica Rollout would still run 1 canary pod: a canary Rollout whose minimum replicas (`autoscaling.minReplicas` with the HPA, `keda.minReplicaCount` with KEDA, else `replicas`; 1 under the legacy top-level `scaling` value with neither, which renders no replicas so Argo Rollouts runs 1) is below 2 fails the render where the steps render.

**A5. #158 interplay.** #158's refusal of managed routes stays for the weight-step `tests` template: with `dark` on by default, `tests` in `analysis.templates` requires `dark: false` until Q54 (DeployVerifier per-Rollout check for header-less canary runs) is resolved. The refusal message names that. `tests-dark` is exempt by construction.

**A6. Release.** One chart release, breaking (`feat(mycarrier-helm)!`): default dark stage, canary floor, source route. GitOps-dev and GitOps-prod renders of current stacks must not change (no canary Rollouts render steps today); show that with a render of both repos' main. Then pin the release in workflow-dev (`render-deploy-core.yaml` and every other pin of the chart), promote to workflow-core later.

### B. mc-environment

No change expected. Add a unit test asserting a `-canary-source` twin is **not** ignored.

### C. TestEngine and the cluster

Nothing to build. Verify and record: the prod and dev Worker do not set `ENABLE_ISTIO_SIDECAR=false`; a test Job for `RunKind=canary` gets a sidecar; DeployVerifier's group check passes during the dark stage of a two-Rollout drill.

### D. AQA ticket (Automated QA team board): the suite contract

1. When `REQUEST_HEADERS` is set, every HTTP request the suite sends to the service under test carries every header in it, name and value unchanged, including requests from manager classes that build their own HTTP client.
2. When it is unset, behaviour is unchanged.
3. A value that is not a JSON object of string to string fails the run; headers are never dropped silently.
4. The suite logs header names only, never values.
5. A tenant-header test sends the tenant headers exactly as the production frontend sends them (e.g. `Environment: PROD`) and runs in the canary dark stage (`RUN_KIND=canary`).
Link it from DEVOPS-326 and the Tech Spec; it does not block 326.

### E. Stand-in suite (326's acceptance only)

A minimal test image, registered as a test definition the way any suite is (`ContainerImage`/`ContainerTag`), that obeys contract D1–D4: it calls the service, records the responding pod name (from a response header or body the stand-in service returns) and fails when told to expect a canary and gets a stable pod. A variant sends the tenant header as the frontend does (D5). A stand-in service (two apps in one stack, A calls B) returns its pod name and, in a "regression" build, rejects the tenant header case-sensitively. Where these live is the builder's call; reuse existing test images if one fits.

### F. Spec and Linear

- Tech Spec: D11 (dark default true, darkReplicas 2, canary floor, source route), presets table, sequence diagram gains the dark stage and the source route, Goals/metrics (0% exposure for suite-detectable defects).
- DEVOPS-326 description: acceptance rules as below. Cross-story decisions go as comments: DEVOPS-515 (A5), DEVOPS-321 (prod `RUN_KINDS_ENABLED`, leader test definitions, `minReplicas ≥ 2`), Q54 note.
- Open-questions store: record the decisions above.

## Acceptance rules (revised)

Run as a drill on the Development cluster with `global.strategy.canary.stepsOutsideProd: true`, testengine-dev and the stand-in suite (no canary Rollout can run in prod before DEVOPS-321). *Builder-check call:* the drill runs on `feature20-saia` from hand-written GitOps-dev values (`global.deploymentStrategy: canary`, `stepsOutsideProd`, `leader`), the way DEVOPS-309 and DEVOPS-313 ran their canary drills there. Plain `dev` refuses Rollouts while the offload operator is on and has no allowlist (R8); offload-pipeline deploys do not pass `global.deploymentStrategy`; preprod is shared. The builder confirms the `-offload` VirtualService for the same host does not shadow the drill's routes, and cleans up with revert PRs as 309 did.

- **R1.** During the dark stage the VirtualService carries `canary-header` above everything, weights stay 100/0, and a request from a sidecar-injected pod to the leader's stable address with the header is served by a canary pod while the same request without it never is (responding pod name).
- **R2.** A canary whose dark suite fails is aborted with zero untagged requests served by canary pods (ClickStack per-pod request counts).
- **R3.** `canary-header` is removed before the first `setWeight`; none remains after promotion or abort; Argo CD shows the Application Synced throughout.
- **R4.** A synthetic case-sensitive tenant-header regression fails the dark suite when the stand-in sends the tenant header as the production frontend does, and the release aborts with zero untagged requests served by canary pods.
- **R5.** `dark: false` renders no dark stage; Deployments and rolling Rollouts render byte-identically (snapshot); GitOps-dev and GitOps-prod main renders are unchanged.
- **R6.** On a two-Rollout release exactly one TestEngine run is submitted for the dark stage; requests of that run reach A's canary through the header route and B's canary through the source route (pod names); a failing suite aborts both Rollouts.
- **R7 (new).** From the first weight step to promotion, every request from a canary pod of the release to another service of the release is served by that service's canary, and each canary has at least 2 ready pods at every step from the dark stage to promotion and never drops to 0 in between (2-replica app at weight 10).
- **R8 (new).** A request from a canary pod to a path the callee's allowlist blocks gets the same 403 a stable pod gets.

## Known residuals

- Argo's `canary-header` route has no gateway restriction, so during the dark stage a public request carrying the correlation id reaches the canary through ingress. Accepted in Q25 (2026-10-13); restate it in the spec.
- Calls that leave the mesh (public host, ingress gateway, KrakenD) reach stable, not the canary (A3).

## Non-goals

Per-host Cloudflare checks (dropped by Q44); the suite proving each response came from a canary (the header and source routes make it unnecessary); Frontend weighted-step session affinity (Q16); DeployVerifier per-Rollout scope for weight-step `tests` (Q54); header injection via EnvoyFilter.

## Rollback

`global.strategy.canary.dark: false` in the stack values, or revert the chart pin in render-deploy-core. The source route and the canary floor go with the chart pin.

## Left to the builder

Template structure and names inside the chart; how #158's Job is shared between `tests` and `tests-dark`; the stand-in images and drill stack; test layout. Every behaviour change starts with a failing helm-unittest.
