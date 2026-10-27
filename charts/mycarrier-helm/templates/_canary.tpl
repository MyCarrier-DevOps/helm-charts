{{- /* Canary contract for Rollouts (DEVOPS-311). The settings are release-wide (global.strategy.canary) so every
       Rollout of a release runs the same steps; per-application updateStrategy.canary blocks are refused in
       rollout.yaml. */ -}}

{{- /* True for a Rollout that takes over the app's Services and VirtualService (stableService, canaryService and
       trafficRouting): deploymentType rollout and not mid-migration (a migrating Rollout renders a bare canary and takes
       over no Service; see helm.specs.rollout). It holds whether or not the Rollout runs canary steps, so turning the
       steps on or off (global.deploymentStrategy) moves no traffic. */ -}}
{{- define "helm.canary.routed" -}}
{{- if and (eq .application.deploymentType "rollout") (not .application.migratingToRollouts) }}true{{ else }}false{{ end }}
{{- end -}}

{{- /* True for a canary Rollout: a routed Rollout (helm.canary.routed) whose repository's deployment-strategy property
       is canary. chart-renderer passes the property as global.deploymentStrategy; only the exact string canary turns the
       canary on. Anything else (unset, empty, rolling, Canary), and every render path that does not pass it (offloads),
       renders the Rollout with no steps: the same Services, VirtualService and trafficRouting, without the steps,
       analysis, managedRoutes or canary annotations (helm.specs.rollout), in every environment. A canary Rollout renders
       its steps only where helm.canary.stepsRendered is true. */ -}}
{{- define "helm.canary.enabled" -}}
{{- if and (eq (include "helm.canary.routed" .) "true") (eq (toString (dig "deploymentStrategy" "" (.Values.global | default dict))) "canary") }}true{{ else }}false{{ end }}
{{- end -}}

{{- /* True where a canary Rollout (helm.canary.enabled) renders its steps (Q52, DEVOPS-516): environment.name prod, or
       any environment with global.strategy.canary.stepsOutsideProd true (default false), which is for test drills. The
       opt-in is compared as the string "true", so "false" given past the schema (--skip-schema-validation) does not
       count. It is false for every Rollout that is not a canary Rollout, so the opt-in cannot give a rolling Rollout
       steps. Elsewhere a canary Rollout renders steps: [] and Argo Rollouts promotes the new version at once: no
       barriers, analysis steps, pauses, dark stage, background analysis or mycarrier.tech/canaryBudgetSeconds. The
       render-time checks of helm.canary.configuredSteps and helm.canary.budgetSeconds still run in every environment
       for a canary Rollout (the health path, both analysis opt-outs, extra templates, barrier timeouts, the tests
       template's barrier window, the leader rule with the leader's tests-dark, budgetSeconds for explicit steps and the
       budget limit): a stack moves to canary as a whole, so the same Rollouts exist in every environment, and a stack
       sees these failures on its first render, not at its first prod canary. Only the coordinator's global.correlationId requirement applies just where the steps
       render. */ -}}
{{- define "helm.canary.stepsRendered" -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") (or (eq (toString .Values.environment.name) "prod") (eq (toString (include "helm.canary.config" . | fromJson).stepsOutsideProd) "true")) }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* global.strategy.canary merged over the defaults, as JSON. It configures the steps of a canary Rollout
       (helm.canary.enabled); a routed Rollout without steps reads only progressDeadlineSeconds from it. Analysis is
       mandatory for every canary Rollout (DEVOPS-312): health and alerts are on unless opted out, and templates lists
       only extra templates. analysis.enabled is deprecated and has no default; rollout.yaml refuses false.
       bakeMinutes is rendered as the mycarrier.tech/bakeMinutes annotation (helm.canary.bakeMinutes). manualTimeout
       and budgetSeconds (no default) feed the mycarrier.tech/canaryBudgetSeconds annotation (helm.canary.budgetSeconds).
       stepsOutsideProd renders the steps outside prod (helm.canary.stepsRendered). analysis.tests (timeout, the poll
       budget; startupSeconds, the pod's start slack; and image) configures the chart's tests template, which renders
       only for a Rollout that runs it (helm.canary.tests.wanted).
       The dark-stage timing (DEVOPS-326, decision 7) lives here: dark-passed's 15m timeout fits the leader's tests-dark
       Job (573 s with the defaults) in the followers' wait, and progressDeadlineSeconds 1200 keeps every barrier
       timeout below the deadline. The 1200 default applies where the dark stage renders: a canary Rollout
       (helm.canary.enabled) with coordinator.enabled, dark true and a preset (no explicit steps), in every environment
       (also where its steps do not render). Otherwise it stays 600: on a routed Rollout whose property is not canary
       (its render does not change); on a canary Rollout with dark false, whose default barrier timeouts (9m) sit
       below 600, or with an explicit steps list, whose own barrier timeouts are checked against 600; and on a canary
       Rollout with the coordinator off, which has no barriers and whose budget counts the deadline for each
       setWeight step (4 x 1200 would put the standard preset at 5970 s, above the 5700 s limit). With the coordinator
       on the budget does not count the deadline, so it does not change the budget. manualTimeout 40m is the largest
       whole 5 minutes that keeps the manual preset's leader budget at or below 5700 s (helm.canary.budgetSeconds:
       5583 s). */ -}}
{{- define "helm.canary.config" -}}
{{- $python := "python:3.13.15-alpine3.23@sha256:6438599575cca0d1df94aeee0d2ae088d4d8846eab554b2ee7784a3a6df0d516" -}}
{{- $canary := and (kindIs "map" .application) (eq (include "helm.canary.enabled" .) "true") -}}
{{- $defaults := dict
      "preset" "standard"
      "stepsOutsideProd" false
      "progressDeadlineSeconds" 600
      "dark" true
      "darkReplicas" 2
      "bakeMinutes" 30
      "manualTimeout" "40m"
      "analysis" (dict "templates" (list)
        "health" (dict "enabled" true "count" 3 "interval" "30s" "consecutiveErrorLimit" 1 "successCondition" "result == \"Healthy\"")
        "alerts" (dict "enabled" true "service" "" "interval" "30s" "consecutiveErrorLimit" 4 "dryRun" true "tokenKey" "ci-alert-gate"
          "image" $python)
        "tests" (dict "timeout" "7m" "startupSeconds" 120 "image" $python))
      "coordinator" (dict
        "enabled" true
        "barrierTimeouts" (dict "start" "9m" "dark-ready" "9m" "dark-passed" "15m" "w10" "9m" "w25" "9m" "w50" "9m")) -}}
{{- $global := .Values.global | default dict -}}
{{- $cfg := deepCopy (dig "strategy" "canary" dict $global) -}}
{{- $merged := mustMergeOverwrite (deepCopy $defaults) $cfg -}}
{{- if and $canary $merged.coordinator.enabled $merged.dark (not $merged.steps) (not (hasKey $cfg "progressDeadlineSeconds")) }}{{ $_ := set $merged "progressDeadlineSeconds" 1200 }}{{ end -}}
{{- toJson $merged -}}
{{- end -}}

{{- /* The canary steps: global.strategy.canary.steps verbatim when set, otherwise the preset ladder (DEVOPS-307):
         standard  10, analysis, pause 5m, 25, analysis, pause 5m, 50, analysis, pause 5m, 100
         fast      25, analysis, 100
         manual    10, analysis, pause (until resumed), 100
       Each analysis step runs health (unless analysis.health.enabled is false) and the extra analysis.templates (the
       chart renders tests, DEVOPS-515, for an app with testtrigger.testdefinitions); each references
       <environment>-<fullName>-<template>, and every referenced template must render for the app
       (helm.canary.analysis.available), because Argo Rollouts resolves them up front and leaves the Rollout InvalidSpec
       when one is missing. alerts is not in these steps: it runs as background analysis
       (helm.canary.backgroundAnalysis), and outside prod it is left out.
       Analysis is mandatory: with health and alerts both opted out and no extra templates the render fails, for preset
       and explicit steps alike, in every environment. The check reads the configured set, not what renders here.
       With coordinator.enabled (default true; release-wide lockstep, D20: DEVOPS-325's mycarrier/canary-coordinator
       step plugin) a preset starts with a barrier named start, which arms the plugin's Abort hook and confirms the
       whole group has been applied, and gets a barrier named w<weight> after each weight's analysis and pause, so every
       Rollout of the release crosses each boundary together; the manual preset's pause stays before its barrier, so a
       resume of the group fans out and the barrier then holds it. An explicit steps list renders verbatim and carries
       its own barriers. The plugin's webhook host and token live in the controller, never in the Rollout spec.
       With the coordinator on and dark (default true since DEVOPS-326, D11), the start barrier is followed by the
       header-gated dark stage: darkReplicas (default 2, at least 2) canary pods at weight 0, a canary-header route
       matched on X-MyCarrier-Canary: <global.correlationId, lower-cased> (helm.canary.correlationId), the dark-ready
       barrier, the <environment>-<fullName>-tests-dark analysis on the leader only (the chart renders it,
       helm.canary.testsDark.wanted, unless the leader defines its own), the dark-passed barrier, then the route is
       removed. The ladder's first weight W is then wrapped: setCanaryScale {weight: W}, setWeight W, setCanaryScale
       {matchTrafficWeight: true}. Argo Rollouts keeps the last setCanaryScale in force for every later step, so the
       size must be handed back to the weights, but not at weight 0, where it would size the canary to 0 pods (a
       weight-sized canary of weight 0 has none, whatever minPodsPerReplicaSet says) and replace the dark-tested pods
       at the first weight; and not after setWeight W alone, because Argo Rollouts sets the traffic weight from the
       step while the dark {replicas: darkReplicas} is still in force, so W% would land on the darkReplicas pods until
       the canary grows (an HPA scaled out under load: more than 8 replicas at 25%, more than 20 at 10%).
       setCanaryScale {weight: W} sizes the canary for W% first, max(ceil(W x replicas / 100), minPodsPerReplicaSet),
       capped at replicas, and setWeight W completes only once it is available. From then on the canary follows the
       weight with at least minPodsPerReplicaSet (2) pods. The dark stage waits for the coordinator because followers
       rely on its barriers to wait for the leader's suite.
       These are the steps the configuration describes. They are built in every environment, with the real leader, so
       their checks (the leader rule and the leader's tests-dark included) run in every environment and the budget is
       the same in and outside prod; they render only where helm.canary.stepsRendered is true (helm.canary.steps). Only
       the coordinator's global.correlationId requirement applies just where the steps render. */ -}}
{{- define "helm.canary.configuredSteps" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $rendered := eq (include "helm.canary.stepsRendered" .) "true" -}}
{{- if not (or $cfg.analysis.health.enabled $cfg.analysis.alerts.enabled $cfg.analysis.templates) -}}
  {{- fail (printf "analysis is mandatory for every Rollout, and application '%s' would run none: global.strategy.canary.analysis.health.enabled and analysis.alerts.enabled are both false and analysis.templates lists no extra template. Remove one of the opt-outs, or list an AnalysisTemplate defined under applications.%s.analysisTemplates in analysis.templates." .appName .appName) -}}
{{- end -}}
{{- $coordinator := $cfg.coordinator -}}
{{- if and $rendered $coordinator.enabled (not (dig "correlationId" "" (.Values.global | default dict))) -}}
  {{- fail "global.correlationId is required when the coordinator is enabled: the canary-coordinator groups a release's Rollouts by their mycarrier.tech/correlationId label." -}}
{{- end -}}
{{- /* The canary floor (spec A4): minPodsPerReplicaSet 2 is capped at spec.replicas, so a Rollout that can run 1 pod
       would run a 1-pod canary. Checked where the steps render; elsewhere the Rollout promotes at once. */ -}}
{{- if $rendered -}}
  {{- $minimum := include "helm.canary.minReplicas" . | fromJson -}}
  {{- if lt (int $minimum.replicas) 2 -}}
    {{- fail (printf "application '%s': a canary Rollout needs at least 2 pods, and its minimum is %d (%s). Argo Rollouts keeps the canary at minPodsPerReplicaSet (2) pods at every weight, but never above the Rollout's replicas, so the canary would run fewer than 2 pods. %s" .appName (int $minimum.replicas) $minimum.source $minimum.fix) -}}
  {{- end -}}
{{- end -}}
{{- $fullName := include "helm.fullname" . -}}
{{- $steps := list -}}
{{- if $cfg.steps }}
{{- $steps = $cfg.steps -}}
{{- else }}
{{- $analysisStep := dict -}}
{{- $available := include "helm.canary.analysis.available" . | fromJsonArray -}}
{{- $templates := list -}}
{{- /* health, then the extra templates; alerts runs as background analysis (helm.canary.backgroundAnalysis, which also
       checks its service label), not in these steps. rollout.yaml refuses health or alerts in analysis.templates. */ -}}
{{- $names := list -}}
{{- if $cfg.analysis.health.enabled }}{{ $names = list "health" }}{{ end -}}
{{- range (concat $names $cfg.analysis.templates) -}}
  {{- if not (has . $available) -}}
    {{- if eq . "health" -}}
      {{- fail (printf "application '%s': the canary health check has no HTTP path on a port its -preview Service exposes. Set applications.%s.canaryHealthPath or global.strategy.canary.analysis.health.path (called on the app's http port), give the app an httpGet liveness probe under applications.%s.probes.livenessProbe (the chart's default liveness probe is HTTP only for global.language csharp), or opt out with global.strategy.canary.analysis.health.enabled: false." $.appName $.appName $.appName) -}}
    {{- end -}}
    {{- fail (printf "application '%s': global.strategy.canary.analysis.templates lists '%s', but no AnalysisTemplate of that name renders for it. The chart renders health, alerts and tests; compare (DEVOPS-322) is not built yet. Remove it, or define it under applications.%s.analysisTemplates." $.appName . $.appName) -}}
  {{- end -}}
  {{- $templates = append $templates (dict "templateName" (printf "%s-%s-%s" $.Values.environment.name $fullName .)) -}}
{{- end -}}
{{- if $templates }}{{ $analysisStep = dict "analysis" (dict "templates" $templates) }}{{ end -}}
{{- if $coordinator.enabled }}{{ $steps = append $steps (include "helm.canary.barrier" (dict "name" "start" "coordinator" $coordinator) | fromJson) }}{{ end -}}
{{- if and $coordinator.enabled $cfg.dark -}}
  {{- if not (include "helm.canary.leader" .) -}}
    {{- fail (printf "the dark stage runs its test suite on one leader, and this release has %d canary Rollouts; set global.strategy.canary.leader to one of: %s." (len (include "helm.canary.rollouts" . | fromJsonArray)) (join ", " (include "helm.canary.rollouts" . | fromJsonArray))) -}}
  {{- end -}}
  {{- if lt (int $cfg.darkReplicas) 2 -}}
    {{- fail (printf "global.strategy.canary.darkReplicas is %v; the minimum is 2. With one dark canary pod a single restart leaves the canary with no available pod, and Argo Rollouts removes the canary-header route in the middle of the dark suite. Set darkReplicas to 2 or more." $cfg.darkReplicas) -}}
  {{- end -}}
  {{- $steps = append $steps (dict "setCanaryScale" (dict "replicas" (int $cfg.darkReplicas))) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header" "match" (list (dict "headerName" "X-MyCarrier-Canary" "headerValue" (dict "exact" (include "helm.canary.correlationId" .)))))) -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-ready" "coordinator" $coordinator) | fromJson) -}}
  {{- /* The leader's tests-dark renders (helm.canary.analysis.available): helm.canary.testsDark.wanted renders the
         chart's, or fails the render, unless the leader defines its own. */ -}}
  {{- if eq (include "helm.canary.leader" .) .appName -}}
    {{- $steps = append $steps (dict "analysis" (dict "templates" (list (dict "templateName" (printf "%s-%s-tests-dark" .Values.environment.name $fullName))))) -}}
  {{- end -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-passed" "coordinator" $coordinator) | fromJson) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header")) -}}
{{- end -}}
{{- $ladder := list -}}
{{- $pause := dict -}}
{{- if eq $cfg.preset "standard" -}}
  {{- $ladder = list 10 25 50 -}}{{- $pause = dict "duration" "5m" -}}
{{- else if eq $cfg.preset "fast" -}}
  {{- $ladder = list 25 -}}
{{- else if eq $cfg.preset "manual" -}}
  {{- $ladder = list 10 -}}
{{- else -}}
  {{- fail (printf "global.strategy.canary.preset '%s' is not one of standard, fast, manual" $cfg.preset) -}}
{{- end -}}
{{- range $i, $weight := $ladder -}}
  {{- $reset := and (eq $i 0) $coordinator.enabled $cfg.dark -}}
  {{- if $reset }}{{ $steps = append $steps (dict "setCanaryScale" (dict "weight" $weight)) }}{{ end -}}
  {{- $steps = append $steps (dict "setWeight" $weight) -}}
  {{- if $reset }}{{ $steps = append $steps (dict "setCanaryScale" (dict "matchTrafficWeight" true)) }}{{ end -}}
  {{- if $analysisStep }}{{ $steps = append $steps $analysisStep }}{{ end -}}
  {{- if eq $cfg.preset "manual" }}{{ $steps = append $steps (dict "pause" (dict)) }}{{ else if $pause }}{{ $steps = append $steps (dict "pause" $pause) }}{{ end -}}
  {{- if $coordinator.enabled }}{{ $steps = append $steps (include "helm.canary.barrier" (dict "name" (printf "w%d" $weight) "coordinator" $coordinator) | fromJson) }}{{ end -}}
{{- end -}}
{{- $steps = append $steps (dict "setWeight" 100) -}}
{{- end }}
{{- /* Argo Rollouts counts the time a Rollout waits at a plugin step toward progressDeadlineSeconds (only analysis,
       experiment and pause steps are exempt: isIndefiniteStep in rollout/sync.go), so a barrier whose timeout is at or
       above the deadline never times out; progressDeadlineAbort aborts the Rollout first. Checked for preset and
       explicit steps alike, against the deadline that applies to this application. */ -}}
{{- $deadline := int (dig "progressDeadlineSeconds" $cfg.progressDeadlineSeconds .application) -}}
{{- range $steps -}}
  {{- $plugin := dig "plugin" dict . -}}
  {{- $timeout := toString (dig "config" "timeout" "" $plugin) -}}
  {{- if and (eq (toString (dig "name" "" $plugin)) "mycarrier/canary-coordinator") (eq (toString (dig "config" "kind" "" $plugin)) "barrier") $timeout -}}
    {{- if ge (include "helm.canary.durationSeconds" $timeout | int) $deadline -}}
      {{- fail (printf "barrier '%s' has timeout %s, which is not below progressDeadlineSeconds (%d s). Argo Rollouts aborts a Rollout that waits at a barrier once the progress deadline passes, so this timeout would never fire. Set the barrier timeout below %d s, or raise progressDeadlineSeconds." (toString (dig "config" "name" "" $plugin)) $timeout $deadline $deadline) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- /* Checks of the chart's tests template (DEVOPS-515) that read the steps; they run in every environment, like the
       other checks here.
       - Managed routes (the dark stage's canary-header with a preset, or a setHeaderRoute or setMirrorRoute step of
         explicit steps, which render no dark stage): TestEngine's DeployVerifier fails a canary run of a Rollout with
         managed routes that sends no X-MyCarrier-Canary header, and the tests run sends none (with the dark stage it
         runs at the weight steps, after the header route is removed), so every tests run would fail until Q54 (a
         DeployVerifier check of header-less canary runs per Rollout) is resolved (spec A5). The message names the
         source. The dark stage's own tests-dark sends the header, so it is not refused.
       - Lockstep: the DeployVerifier checks every Rollout of the correlation group, which must be in flight. With
         coordinator.enabled false and more than one canary Rollout, a sibling that already promoted (or has not
         started) fails the run after part of the release shipped.
       - global.correlationId, where the steps render: the request sends it as CorrelationId, and TestEngine answers 422
         without it.
       - The barrier window, while tests is listed (helm.canary.tests.listed; also when an app replaces tests) or the
         dark stage runs the leader's tests-dark (a preset with the coordinator and dark on; the chart's tests-dark or
         the leader's own, DEVOPS-326), whose followers wait at dark-passed for the leader's suite. In an
         analysis step every canary Rollout of the release runs its own templates in parallel; after the steps up to the
         next barrier, canary-coordinator holds the barrier until the whole group has reached it. Between two barriers,
         Rollout j waits for Rollout i for i's longest run of the analysis steps since the previous barrier minus j's
         shortest run of them (the steps are shared, so pauses and setWeights cancel out). Each step's lengths come
         from each Rollout's own templates (helm.canary.analysis.templateSeconds, the table the budget uses, so a
         replaced health or tests and the extra templates count): the longest is its longest template, with the time
         Argo Rollouts takes to see a Job end (a Job with count n can run n x (activeDeadlineSeconds + that lag) +
         (n - 1) x interval); the shortest is its templates' largest (count - 1) x interval (Argo Rollouts takes the
         first measurement at once, and a Job can end at once). The dark stage's analysis step (tests-dark) runs on the
         leader only, so in a preset with the coordinator and dark on, only the leader's lengths count before the first
         setWeight. The render fails when the worst ordered pair of different Rollouts reaches the barrier's timeout:
         the barrier would time out and abort the release. A release with one canary Rollout has no pair, and
         canary-coordinator passes a group of one at once, so it is never checked. The spread of pod readiness between
         Rollouts is not counted. Checked at every barrier that follows an analysis step, for preset (w10, w25, w50,
         dark-passed) and explicit steps alike; a barrier without a timeout in the 90s, 9m or 1h form is skipped, as in
         the progress-deadline check above, and the sums restart after it. Without barriers (coordinator.enabled false)
         there is nothing to check. */ -}}
{{- if eq (include "helm.canary.tests.wanted" .) "true" -}}
  {{- $managed := list -}}
  {{- range $steps -}}
    {{- $route := dig "setHeaderRoute" "name" (dig "setMirrorRoute" "name" "" .) . -}}
    {{- if and $route (not (has $route $managed)) }}{{ $managed = append $managed $route }}{{ end -}}
  {{- end -}}
  {{- if $managed -}}
    {{- $q54 := "until Q54 (a DeployVerifier check of header-less canary runs per Rollout) is resolved." -}}
    {{- if $cfg.steps -}}
      {{- fail (printf "application '%s': the canary tests template cannot run on a Rollout with managed routes (%s, from setHeaderRoute or setMirrorRoute steps in global.strategy.canary.steps): TestEngine's DeployVerifier fails a canary run of such a Rollout that sends no X-MyCarrier-Canary header, and the tests run sends none, so every tests run would fail. Remove the setHeaderRoute and setMirrorRoute steps, or stop running tests (remove it from global.strategy.canary.analysis.templates and from the steps), %s" .appName (join ", " $managed) $q54) -}}
    {{- end -}}
    {{- fail (printf "application '%s': the canary tests template cannot run on a Rollout with managed routes (%s, from the dark stage, global.strategy.canary.dark: true): TestEngine's DeployVerifier fails a canary run of such a Rollout that sends no X-MyCarrier-Canary header, and tests runs at the weight steps, after the dark stage removed its header route, so every tests run would fail. The dark stage already runs the suite against the canary (tests-dark). Set global.strategy.canary.dark: false or remove tests from global.strategy.canary.analysis.templates %s" .appName (join ", " $managed) $q54) -}}
  {{- end -}}
  {{- $rollouts := include "helm.canary.rollouts" . | fromJsonArray -}}
  {{- if and (not $coordinator.enabled) (gt (len $rollouts) 1) -}}
    {{- fail (printf "application '%s': the canary tests template needs the coordinator when the release has more than one canary Rollout (%s). TestEngine's DeployVerifier checks every Rollout of the release's correlation group, and each must be in flight; with global.strategy.canary.coordinator.enabled false each Rollout runs its own steps, so a sibling that already promoted (or has not started) fails the run after part of the release shipped. Set coordinator.enabled: true, or remove tests from global.strategy.canary.analysis.templates." .appName (join ", " $rollouts)) -}}
  {{- end -}}
  {{- if and $rendered (not (toString (dig "correlationId" "" (.Values.global | default dict)))) -}}
    {{- fail (printf "application '%s': the canary tests template sends global.correlationId as the TestEngine run's CorrelationId, and it is empty, so TestEngine would answer 422 (CorrelationId is required for /v1/trigger). Set global.correlationId (the pipeline sets it on every render)." .appName) -}}
  {{- end -}}
{{- end -}}
{{- $rollouts := include "helm.canary.rollouts" . | fromJsonArray -}}
{{- $leaderOnly := and (not $cfg.steps) $coordinator.enabled $cfg.dark -}}
{{- if and (or (eq (include "helm.canary.tests.listed" .) "true") $leaderOnly) (gt (len $rollouts) 1) -}}
  {{- $environment := toString .Values.environment.name -}}
  {{- $selfPrefix := printf "%s-%s-" $environment $fullName -}}
  {{- /* Each canary Rollout's template table and template-name prefix, and every table entry by its full name (explicit
         steps name templates literally, so every Rollout runs those). */ -}}
  {{- $tables := dict -}}
  {{- $prefixes := dict -}}
  {{- $byName := dict -}}
  {{- range $name := $rollouts -}}
    {{- $appContext := merge (dict "appName" $name "application" (index $.Values.applications $name)) (omit $ "appName" "application") -}}
    {{- $table := include "helm.canary.analysis.templateSeconds" $appContext | fromJson -}}
    {{- $_ := set $tables $name $table -}}
    {{- $_ := set $prefixes $name (printf "%s-%s-" $environment (include "helm.fullname" $appContext)) -}}
    {{- range $key, $entry := $table }}{{ $_ := set $byName $key $entry }}{{ end -}}
  {{- end -}}
  {{- /* The dark stage's analysis step (tests-dark) runs on the leader only: followers go from dark-ready straight to
         dark-passed. In a preset with the coordinator and dark on it is the only analysis step before the first
         setWeight, so there only the leader's lengths count; the leader's own render sees it (a follower's steps do
         not have it). */ -}}
  {{- $leader := "" -}}
  {{- if $leaderOnly }}{{ $leader = include "helm.canary.leader" . }}{{ end -}}
  {{- $beforeWeights := true -}}
  {{- /* Each Rollout's longest and shortest run of the analysis steps since the previous barrier, summed: the steps are
         shared by every Rollout, so the pauses and setWeights between them cancel out. */ -}}
  {{- $longSum := dict -}}
  {{- $shortSum := dict -}}
  {{- range $name := $rollouts }}{{ $_ := set $longSum $name 0 }}{{ $_ := set $shortSum $name 0 }}{{ end -}}
  {{- $pending := false -}}
  {{- range $steps -}}
    {{- $plugin := dig "plugin" dict . -}}
    {{- if hasKey . "setWeight" }}{{ $beforeWeights = false }}{{ end -}}
    {{- if hasKey . "analysis" -}}
      {{- $names := list -}}
      {{- range (dig "analysis" "templates" list .) }}{{ $names = append $names (toString .templateName) }}{{ end -}}
      {{- /* Longest and shortest run of this step for each Rollout: a preset step names this Rollout's templates, which
             map to each Rollout's own by their suffix; explicit steps name the same templates for every Rollout. */ -}}
      {{- range $name := $rollouts -}}
        {{- if not (and $leaderOnly $beforeWeights (ne $name $leader)) -}}
          {{- $long := 0 -}}
          {{- $short := 0 -}}
          {{- range $names -}}
            {{- $entry := dict -}}
            {{- if and (not $cfg.steps) (hasPrefix $selfPrefix .) -}}
              {{- $entry = index (index $tables $name) (printf "%s%s" (index $prefixes $name) (trimPrefix $selfPrefix .)) | default dict -}}
            {{- else -}}
              {{- $entry = index $byName . | default dict -}}
            {{- end -}}
            {{- $long = max $long (int (dig "longest" 0 $entry)) -}}
            {{- $short = max $short (int (dig "shortest" 0 $entry)) -}}
          {{- end -}}
          {{- $_ := set $longSum $name (add (index $longSum $name) $long) -}}
          {{- $_ := set $shortSum $name (add (index $shortSum $name) $short) -}}
        {{- end -}}
      {{- end -}}
      {{- $pending = true -}}
    {{- else if and (eq (toString (dig "name" "" $plugin)) "mycarrier/canary-coordinator") (eq (toString (dig "config" "kind" "" $plugin)) "barrier") -}}
      {{- $timeout := toString (dig "config" "timeout" "" $plugin) -}}
      {{- $timeoutSeconds := include "helm.canary.durationSeconds" $timeout | int -}}
      {{- if and $pending $timeoutSeconds -}}
        {{- $worst := dict "wait" -1 -}}
        {{- range $waiter := $rollouts -}}
          {{- range $other := $rollouts -}}
            {{- if ne $waiter $other -}}
              {{- $wait := sub (index $longSum $other) (index $shortSum $waiter) -}}
              {{- if gt (int $wait) (int $worst.wait) }}{{ $worst = dict "wait" (int $wait) "waiter" $waiter "other" $other "longest" (index $longSum $other) "shortest" (index $shortSum $waiter) }}{{ end -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- if ge (int $worst.wait) $timeoutSeconds -}}
          {{- fail (printf "application '%s': barrier '%s' has timeout %s (%d s), and Rollout '%s' can wait there %d s for Rollout '%s': in the analysis steps since the previous barrier, '%s' may run %d s (each step's longest template, with the time Argo Rollouts takes to see a Job end) and '%s' can end after %d s (each step's largest (count - 1) x interval of its templates). canary-coordinator holds the barrier until every Rollout of the release reaches it, so at or above the barrier's timeout it times out and aborts the release. Lower global.strategy.canary.analysis.tests.timeout (or the count, interval or activeDeadlineSeconds of '%s''s templates), or raise global.strategy.canary.coordinator.barrierTimeouts above %d s (each below progressDeadlineSeconds, and the canary budget at or below 5700 s)." $.appName (toString (dig "config" "name" "" $plugin)) $timeout $timeoutSeconds $worst.waiter (int $worst.wait) $worst.other $worst.other (int $worst.longest) $worst.waiter (int $worst.shortest) $worst.other (int $worst.wait)) -}}
        {{- end -}}
      {{- end -}}
      {{- range $name := $rollouts }}{{ $_ := set $longSum $name 0 }}{{ $_ := set $shortSum $name 0 }}{{ end -}}
      {{- $pending = false -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toYaml $steps }}
{{- end -}}

{{- /* The canary steps the Rollout renders: helm.canary.configuredSteps where helm.canary.stepsRendered is true
       (prod, or stepsOutsideProd), otherwise [] after the same checks, so the Rollout promotes at once (Q52,
       DEVOPS-516). */ -}}
{{- define "helm.canary.steps" -}}
{{- $steps := include "helm.canary.configuredSteps" . -}}
{{- if eq (include "helm.canary.stepsRendered" .) "true" }}{{ $steps }}{{ else }}[]{{ end -}}
{{- end -}}

{{- /* alert-gate's watch window after promotion, in minutes (Tech Spec D18): global.strategy.canary.bakeMinutes, default
       30, rendered on every canary Rollout as mycarrier.tech/bakeMinutes. The release's rollout-watch reads the
       smallest value across the release's Rollouts and puts it in the alert.gate event (DEVOPS-319); it takes any value
       outside 1-100 as 30. alert-gate's own run has activeDeadlineSeconds 7200 and spends about 750 s outside its
       watch window, so a window above 100 minutes would be killed before it ends: the render fails. values.schema.json
       has the same bounds; this check also covers a render without schema validation. */ -}}
{{- define "helm.canary.bakeMinutes" -}}
{{- $bake := (include "helm.canary.config" . | fromJson).bakeMinutes -}}
{{- if or (not (kindIs "float64" $bake)) (lt $bake 1.0) (ne $bake (float64 (int $bake))) -}}
  {{- fail (printf "global.strategy.canary.bakeMinutes must be a whole number of minutes from 1 to 100, not %v" $bake) -}}
{{- end -}}
{{- if gt $bake 100.0 -}}
  {{- fail (printf "global.strategy.canary.bakeMinutes is %v; the maximum is 100. alert-gate watches the service for bakeMinutes after promotion inside one run whose activeDeadlineSeconds is 7200 (2 hours), and a run spends about 750 s outside its watch window, so a window above 100 minutes would be killed before it ends. Set bakeMinutes to 100 or less." $bake) -}}
{{- end -}}
{{- int $bake -}}
{{- end -}}

{{- /* The canary's worst-case length in whole seconds (Tech Spec D22, Q51), rendered as
       mycarrier.tech/canaryBudgetSeconds on every canary Rollout whose steps render (helm.canary.stepsRendered). The
       release's rollout-watch (DEVOPS-319) times out at the largest value of the release group plus 15 minutes, so
       the budget covers the steps helm.canary.configuredSteps describes for this Rollout at their longest, and
       rollout-watch never times out a canary that is still inside its designed steps:
       - pause: its duration; the manual preset's pause, which has none, counts manualTimeout (default 40m). The pause
         itself stays indefinite; manualTimeout only feeds the budget.
       - analysis: the longest of its templates (they run in parallel), each count x max(interval, the Job's
         activeDeadlineSeconds when the template is a Job provider that sets it), plus, for a Job, the time Argo
         Rollouts can take to see it end, ceil(sqrt(2 x activeDeadlineSeconds)); a Job with count n >= 2 at least
         n x (activeDeadlineSeconds + that lag) + (n - 1) x interval. The chart's health template uses
         analysis.health.count and interval; the chart's tests and tests-dark templates count their Job's
         activeDeadlineSeconds (analysis.tests.timeout + analysis.tests.startupSeconds) + lag (540 + 33 by default); an
         applications.<app>.analysisTemplates entry (an extra template, or one that replaces health or supplies
         tests-dark) uses its own count (1 when unset, as analysistemplate.yaml renders it; Argo Rollouts runs count 0
         without an interval once) and interval (0 when unset). The lengths come from
         helm.canary.analysis.templateSeconds.
       - a canary-coordinator barrier: its timeout.
       - a setWeight step above 0 waits until the canary's pods are available, for up to progressDeadlineSeconds. With
         the coordinator on, the barrier timeouts cover that wait; with coordinator.enabled false, each such setWeight
         step (100 included) counts progressDeadlineSeconds.
       - every other step (setWeight 0, setCanaryScale, setHeaderRoute): 0. The background alerts analysis runs alongside
         the steps and is not counted.
       The leader runs tests-dark and its followers do not, so their budgets can differ. An explicit steps list states its
       own budget in budgetSeconds (required there); with a preset the chart computes it and budgetSeconds is ignored.
       rollout-watch's release workflow has activeDeadlineSeconds 10800, which covers about 70 minutes before the canary
       starts, the budget and 15 minutes after it, so a budget above 5700 s fails the render.
       helm.canary.configuredSteps runs first, so its own checks report before these.
       The budget is computed, and its checks run, in every environment (budgetSeconds for an explicit steps list
       included), and it is the same in and outside prod; rollout.yaml renders it only where the steps render. */ -}}
{{- /* The length of every AnalysisTemplate an analysis step of this canary Rollout can reference, as JSON, by the name
       the step uses (<environment>-<fullName>-<name>): the chart's health (analysis.health count and interval), the
       chart's tests and tests-dark when the app runs them (helm.canary.tests.wanted, helm.canary.testsDark.wanted), and
       each applications.<app>.analysisTemplates
       entry, which replaces the chart's template of the same name. For each, in seconds:
       - budget: the template at its longest, as Tech Spec D22's budget needs. count x max(interval, the Job's
         activeDeadlineSeconds when it is a Job provider that sets it); count is 1 when unset or 0 (Argo Rollouts runs
         count 0 without an interval once). A Job provider adds lag: ceil(sqrt(2 x activeDeadlineSeconds)), the time
         Argo Rollouts v1.10.0 can take to see a Job end (helm.canary.tests.completionLagSeconds), so a count-1 Job
         counts activeDeadlineSeconds + lag. A Job with count n >= 2 counts at least n x (activeDeadlineSeconds + lag)
         + (n - 1) x interval: Argo Rollouts starts each measurement at the previous one's FinishedAt + interval, and a
         Job's FinishedAt is when the controller sees it end. helm.canary.budgetSeconds adds it up.
       - longest: the same as budget; the barrier window uses it.
       - shortest: (count - 1) x interval: Argo Rollouts takes the first measurement at once, and a Job can end at once.
       helm.canary.budgetSeconds and the barrier window of helm.canary.configuredSteps both read this table, so they
       cannot drift apart. */ -}}
{{- define "helm.canary.analysis.templateSeconds" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $prefix := printf "%s-%s-" (toString .Values.environment.name) (include "helm.fullname" .) -}}
{{- $health := $cfg.analysis.health -}}
{{- $healthInterval := include "helm.canary.durationSeconds" $health.interval | int -}}
{{- $table := dict (printf "%shealth" $prefix) (dict "budget" (mul (int $health.count) $healthInterval) "longest" (mul (int $health.count) $healthInterval) "shortest" (mul (max 0 (sub (int $health.count) 1)) $healthInterval)) -}}
{{- $chartTests := list -}}
{{- if eq (include "helm.canary.tests.wanted" .) "true" }}{{ $chartTests = append $chartTests "tests" }}{{ end -}}
{{- if eq (include "helm.canary.testsDark.wanted" .) "true" }}{{ $chartTests = append $chartTests "tests-dark" }}{{ end -}}
{{- if $chartTests -}}
  {{- $deadline := include "helm.canary.tests.activeDeadlineSeconds" . | int -}}
  {{- $length := add $deadline (include "helm.canary.tests.completionLagSeconds" $deadline | int) -}}
  {{- range $chartTests }}{{ $_ := set $table (printf "%s%s" $prefix .) (dict "budget" $length "longest" $length "shortest" 0) }}{{ end -}}
{{- end -}}
{{- range (.application.analysisTemplates | default list) -}}
  {{- $count := 1 -}}
  {{- if hasKey . "count" }}{{ $count = max 1 (int .count) }}{{ end -}}
  {{- $interval := include "helm.canary.durationSeconds" (.interval | default "") | int -}}
  {{- $deadline := int (dig "provider" "job" "spec" "activeDeadlineSeconds" 0 .) -}}
  {{- $budget := mul $count (max $interval $deadline) -}}
  {{- if and (kindIs "map" .provider) (hasKey .provider "job") -}}
    {{- $lag := include "helm.canary.tests.completionLagSeconds" $deadline | int -}}
    {{- $budget = add $budget $lag -}}
    {{- /* Each measurement starts at the previous one's FinishedAt + interval, and a Job's FinishedAt is when Argo
           Rollouts sees it end. */ -}}
    {{- if gt $count 1 }}{{ $budget = max $budget (add (mul $count (add $deadline $lag)) (mul (sub $count 1) $interval)) }}{{ end -}}
  {{- end -}}
  {{- $_ := set $table (printf "%s%s" $prefix (toString .name)) (dict "budget" $budget "longest" $budget "shortest" (mul (sub $count 1) $interval)) -}}
{{- end -}}
{{- toJson $table -}}
{{- end -}}

{{- define "helm.canary.budgetSeconds" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $steps := include "helm.canary.configuredSteps" . | fromYamlArray -}}
{{- $budget := 0 -}}
{{- if $cfg.steps -}}
  {{- $set := $cfg.budgetSeconds -}}
  {{- if or (not (kindIs "float64" $set)) (lt $set 1.0) (ne $set (float64 (int $set))) -}}
    {{- fail (printf "global.strategy.canary.budgetSeconds is %s; an explicit global.strategy.canary.steps list needs it, as a whole number of seconds from 1 to 5700 (Tech Spec D22). It is the canary's worst-case length: the release's rollout-watch times out at it plus 15 minutes. Add up the pause durations, each analysis step's longest template (count x max(interval, the Job's activeDeadlineSeconds), plus for a Job ceil(sqrt(2 x activeDeadlineSeconds)); a Job with count n >= 2 at least n x (activeDeadlineSeconds + that lag) + (n - 1) x interval) and each barrier timeout." (ternary "not set" (toString $set) (kindIs "invalid" $set))) -}}
  {{- end -}}
  {{- $budget = int $set -}}
{{- else -}}
  {{- $manual := 0 -}}
  {{- if eq $cfg.preset "manual" -}}
    {{- $manual = include "helm.canary.durationSeconds" $cfg.manualTimeout | int -}}
    {{- if not $manual -}}
      {{- fail (printf "global.strategy.canary.manualTimeout is '%v'; the manual preset needs a duration above zero such as 90s, 30m or 1h (default 40m). It is how long the release's rollout-watch allows for the manual pause (Tech Spec D22); the pause itself has no time limit." $cfg.manualTimeout) -}}
    {{- end -}}
  {{- end -}}
  {{- /* Seconds per AnalysisTemplate an analysis step can reference, by the name the step uses: the budget column of
         helm.canary.analysis.templateSeconds, which the barrier window reads too. */ -}}
  {{- $templates := dict -}}
  {{- range $name, $entry := (include "helm.canary.analysis.templateSeconds" . | fromJson) }}{{ $_ := set $templates $name (int $entry.budget) }}{{ end -}}
  {{- range $steps -}}
    {{- $plugin := dig "plugin" dict . -}}
    {{- if hasKey . "pause" -}}
      {{- $duration := dig "pause" "duration" "" . -}}
      {{- $budget = add $budget (ternary (include "helm.canary.durationSeconds" $duration | int) $manual (not (empty $duration))) -}}
    {{- else if hasKey . "analysis" -}}
      {{- $longest := 0 -}}
      {{- range (dig "analysis" "templates" list .) -}}
        {{- if not (hasKey $templates (toString .templateName)) -}}
          {{- fail (printf "helm.canary.budgetSeconds has no length for AnalysisTemplate '%s'; a chart change added a template to the preset steps without adding it here." (toString .templateName)) -}}
        {{- end -}}
        {{- $longest = max $longest (index $templates (toString .templateName)) -}}
      {{- end -}}
      {{- $budget = add $budget $longest -}}
    {{- else if and (eq (toString (dig "name" "" $plugin)) "mycarrier/canary-coordinator") (eq (toString (dig "config" "kind" "" $plugin)) "barrier") -}}
      {{- $budget = add $budget (include "helm.canary.durationSeconds" (dig "config" "timeout" "" $plugin) | int) -}}
    {{- else if and (not $cfg.coordinator.enabled) (gt (int (dig "setWeight" 0 .)) 0) -}}
      {{- $budget = add $budget (int $cfg.progressDeadlineSeconds) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if gt (int $budget) 5700 -}}
  {{- fail (printf "application '%s': the canary budget (mycarrier.tech/canaryBudgetSeconds) is %d s; the maximum is 5700 s. rollout-watch's release workflow has activeDeadlineSeconds 10800, which must cover about 70 minutes before the canary starts, the budget, and 15 minutes after it (DEVOPS-319). Lower global.strategy.canary.manualTimeout, the coordinator.barrierTimeouts, or the analysis templates' count or interval; with explicit steps, shorten their pauses and lower budgetSeconds." .appName (int $budget)) -}}
{{- end -}}
{{- int $budget -}}
{{- end -}}

{{- /* True for an application whose prod_tests the release's rollout-watch starts after promotion (Tech Spec D7,
       DEVOPS-319): a canary Rollout (helm.canary.enabled) in prod, because canaries run only in prod (Q42). For it
       triggertestengine.yaml renders no PostSync hook, which could start prod_tests at the start of a canary sync or
       after an abort, and renders the <fullName>-prod-tests ConfigMap instead. helm.canary.enabled follows the
       repository's deployment-strategy property (global.deploymentStrategy), the same property that sends the release
       down the canary path that runs rollout-watch, so the ConfigMap renders exactly when rollout-watch will read it.
       Every other application (other environments, Deployments, StatefulSets, migratingToRollouts, and Rollouts whose
       property is not canary) keeps the hook. */ -}}
{{- define "helm.canary.prodTestsByRolloutWatch" -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") (eq (toString .Values.environment.name) "prod") }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* A duration such as 90s, 9m or 1h (a barrier timeout, a pause, an analysis interval, manualTimeout), in seconds;
       any other form yields 0, so a barrier timeout in another form is not checked. */ -}}
{{- define "helm.canary.durationSeconds" -}}
{{- $v := toString . -}}
{{- if regexMatch "^[0-9]+(s|m|h)$" $v -}}
  {{- $n := trimSuffix "h" (trimSuffix "m" (trimSuffix "s" $v)) | int -}}
  {{- if hasSuffix "h" $v }}{{ mul $n 3600 }}{{ else if hasSuffix "m" $v }}{{ mul $n 60 }}{{ else }}{{ $n }}{{ end -}}
{{- else -}}0{{- end -}}
{{- end -}}

{{- /* Names of the AnalysisTemplates that render for an app, as JSON: its applications.<app>.analysisTemplates, plus the
       chart's own health template when health is on, the app has none of that name and its health URL is known, the
       chart's alerts template when alerts is on, the app has none of that name, the environment is prod and the
       service label is known, the chart's tests template when the app runs it (helm.canary.tests.wanted, which
       fails the render when the app has no testtrigger.testdefinitions), and the chart's tests-dark template for the
       dark stage's leader (helm.canary.testsDark.wanted, which fails the same way). */ -}}
{{- define "helm.canary.analysis.available" -}}
{{- $names := list -}}
{{- range (.application.analysisTemplates | default list) }}{{ $names = append $names (toString .name) }}{{ end -}}
{{- $analysis := (include "helm.canary.config" . | fromJson).analysis -}}
{{- if and (not (has "health" $names)) $analysis.health.enabled (include "helm.canary.analysis.healthUrl" .) }}{{ $names = append $names "health" }}{{ end -}}
{{- if and (not (has "alerts" $names)) $analysis.alerts.enabled (include "helm.canary.alerts.environment" .) (include "helm.canary.alerts.service" .) }}{{ $names = append $names "alerts" }}{{ end -}}
{{- if eq (include "helm.canary.tests.wanted" .) "true" }}{{ $names = append $names "tests" }}{{ end -}}
{{- if eq (include "helm.canary.testsDark.wanted" .) "true" }}{{ $names = append $names "tests-dark" }}{{ end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* The Rollout's background analysis, as JSON, or "" when it has none: the alerts template (the chart's, or an
       applications.<app>.analysisTemplates entry named alerts) unless analysis.alerts.enabled is false. It starts at
       the first step that sends the canary traffic (setWeight above 0, after the dark stage) and runs until the Rollout
       is promoted or aborted, so it also checks during the pauses, where the alert rules' for windows (5m for most
       standard rules) run out; a step-by-step check would sample only the first minute of each weight. A replacement
       entry runs that long only with count 0 and an interval. The service-label check sits here, outside the steps,
       so explicit global.strategy.canary.steps reach it too. The background analysis belongs to the steps, so it
       renders only where they do (helm.canary.stepsRendered): a replacement alerts entry outside prod runs only with
       stepsOutsideProd. */ -}}
{{- define "helm.canary.backgroundAnalysis" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $customAlerts := false -}}
{{- range (.application.analysisTemplates | default list) }}{{ if eq (toString .name) "alerts" }}{{ $customAlerts = true }}{{ end }}{{ end -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") $cfg.analysis.alerts.enabled (not $customAlerts) (include "helm.canary.alerts.environment" .) (not (include "helm.canary.alerts.service" .)) -}}
  {{- fail (printf "application '%s': the canary alerts check filters Grafana alerts on the service label, and the chart cannot tell it. Set global.strategy.canary.analysis.alerts.service to the label the service's alert rules carry (the lower-cased repository name, or its alias, such as mycarrier for MC.MyCarrier), set alerts.serviceName or global.appStack, or opt out with global.strategy.canary.analysis.alerts.enabled: false." .appName) -}}
{{- end -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") (eq (include "helm.canary.stepsRendered" .) "true") $cfg.analysis.alerts.enabled (has "alerts" (include "helm.canary.analysis.available" . | fromJsonArray)) -}}
  {{- $analysis := dict "templates" (list (dict "templateName" (printf "%s-%s-alerts" .Values.environment.name (include "helm.fullname" .)))) -}}
  {{- range $index, $step := (include "helm.canary.steps" . | fromYamlArray) -}}
    {{- if and (not (hasKey $analysis "startingStep")) (gt (int (dig "setWeight" 0 $step)) 0) }}{{ $_ := set $analysis "startingStep" $index }}{{ end -}}
  {{- end -}}
  {{- toJson $analysis -}}
{{- end -}}
{{- end -}}

{{- /* The environment whose Grafana alert rules the alerts check reads: prod only, because canaries run only in prod
       (Q42, bcarlock 2026-10-20; other environments run canaries only as test drills); "" elsewhere. alert-gate also
       supports preprod, and helm.canary.alerts.match still takes any environment. */ -}}
{{- define "helm.canary.alerts.environment" -}}
{{- if eq (toString .Values.environment.name) "prod" }}prod{{ end -}}
{{- end -}}

{{- /* The Grafana service label the alerts check filters on: global.strategy.canary.analysis.alerts.service, else
       alerts.serviceName lower-cased, the label the chart's own alert rules carry, else global.appStack lower-cased.
       "app", the values.yaml default, counts as unset: no alert rule carries it, so a stack that never set appStack
       fails the render in prod instead of being refused by alert-rules at its first canary weight. */ -}}
{{- define "helm.canary.alerts.service" -}}
{{- $appStack := lower (toString (dig "appStack" "" (.Values.global | default dict))) -}}
{{- if eq $appStack "app" }}{{ $appStack = "" }}{{ end -}}
{{- (include "helm.canary.config" . | fromJson).analysis.alerts.service | default (lower (toString (dig "serviceName" "" (.Values.alerts | default dict)))) | default $appStack -}}
{{- end -}}

{{- /* An expr condition that is true when the label map at .labels matches alert-gate's matchers (DEVOPS-329): the
       service, the environment (prod also matches no environment label, because the Service Alerts carry none and
       read only prod data), and a folder other than Platform. */ -}}
{{- define "helm.canary.alerts.match" -}}
{{- $l := .labels -}}
{{- $environment := printf `(%s?.environment ?? "") == %s` $l (toJson .environment) -}}
{{- if eq .environment "prod" }}{{ $environment = printf `(%s?.environment ?? "") in ["prod", ""]` $l }}{{ end -}}
{{- printf `(%s?.service ?? "") == %s && %s && (%s?.grafana_folder ?? "") != "Platform"` $l (toJson .service) $environment $l -}}
{{- end -}}

{{- /* The -preview Service port that reaches a container port of the app, given as a number or a port name, or "" when
       the Service does not expose it: the matching ports entry, or with service.ports the entry whose targetPort is
       that number or name. */ -}}
{{- define "helm.canary.previewPort" -}}
{{- $ports := .application.ports | default dict -}}
{{- $want := .port -}}
{{- $containerPort := "" -}}
{{- $portName := "" -}}
{{- if kindIs "string" $want -}}
  {{- range $name, $number := $ports }}{{ if eq (lower $name) $want }}{{ $containerPort = toString $number }}{{ $portName = lower $name }}{{ end }}{{ end -}}
{{- else if $want -}}
  {{- $containerPort = toString $want -}}
{{- end -}}
{{- $servicePort := "" -}}
{{- if $containerPort -}}
  {{- $custom := dig "service" "ports" list .application -}}
  {{- if $custom -}}
    {{- range $custom }}{{ $target := toString (default .port .targetPort) }}{{ if and (not $servicePort) (or (eq $target $containerPort) (and $portName (eq $target $portName))) }}{{ $servicePort = toString .port }}{{ end }}{{ end -}}
  {{- else -}}
    {{- range $name, $number := $ports }}{{ if eq (toString $number) $containerPort }}{{ $servicePort = $containerPort }}{{ end }}{{ end -}}
  {{- end -}}
{{- end -}}
{{- $servicePort -}}
{{- end -}}

{{- /* The URL the canary health check calls on the app's -preview Service, or "" when the chart finds no path.
       applications.<app>.canaryHealthPath, else global.strategy.canary.analysis.health.path, when set, is called on
       the app's http (or healthcheck) port.
       Otherwise the check reuses the liveness probe the pod renders with (_spec_workload.tpl):
       applications.<app>.probes.livenessProbe, or else the chart's default for global.language (HTTP only for csharp,
       at /liveness), unless probes.enableLiveness is false; its httpGet path is the one. Readiness and startup probes
       are not used. The port is the Service port that targets that container port. */ -}}
{{- define "helm.canary.analysis.healthUrl" -}}
{{- $probes := .application.probes | default dict -}}
{{- $ports := .application.ports | default dict -}}
{{- $get := dict -}}
{{- $from := "" -}}
{{- with dig "canaryHealthPath" (include "helm.canary.config" . | fromJson).analysis.health.path .application -}}
  {{- $get = dict "path" . "port" (or (index $ports "http") (index $ports "healthcheck")) -}}
{{- end -}}
{{- if and (not $get.path) (dig "enableLiveness" true $probes) -}}
  {{- $probe := $probes.livenessProbe | default (get (include "helm.defaultLivenessProbe" . | fromYaml) "livenessProbe") | default dict -}}
  {{- $get = $probe.httpGet | default dict -}}
  {{- if $get.path }}{{ $from = "livenessProbe" }}{{ end -}}
{{- end -}}
{{- /* The check calls plain http with no host or headers; a probe that needs them would make every measurement an
       Error, so it fails the render instead of aborting the canary. */ -}}
{{- if and $from (or (and $get.scheme (ne (upper (toString $get.scheme)) "HTTP")) $get.host $get.httpHeaders) -}}
  {{- fail (printf "application '%s': the canary health check would reuse the path of its %s, which sets scheme HTTPS, host or httpHeaders; the check calls plain http with none of these. Set applications.%s.canaryHealthPath to a path served over plain http, define a health template under applications.%s.analysisTemplates, or opt out with global.strategy.canary.analysis.health.enabled: false." .appName $from .appName .appName) -}}
{{- end -}}
{{- $servicePort := include "helm.canary.previewPort" (dict "application" .application "port" $get.port) -}}
{{- if and $get.path $servicePort -}}
http://{{ include "helm.fullname" . }}-preview.{{ include "helm.namespace" . }}.svc.cluster.local:{{ $servicePort }}{{ if not (hasPrefix "/" (toString $get.path)) }}/{{ end }}{{ $get.path }}
{{- end -}}
{{- end -}}

{{- /* One canary-coordinator barrier step, as JSON; its timeout comes from coordinator.barrierTimeouts.<name>. */ -}}
{{- define "helm.canary.barrier" -}}
{{- $timeout := index .coordinator.barrierTimeouts .name -}}
{{- if not $timeout -}}
  {{- fail (printf "global.strategy.canary.coordinator.barrierTimeouts.%s is not set" .name) -}}
{{- end -}}
{{- toJson (dict "plugin" (dict "name" "mycarrier/canary-coordinator" "config" (dict "kind" "barrier" "name" .name "timeout" $timeout))) -}}
{{- end -}}

{{- /* "true" when a VirtualService destination host is the app's -preview Service: its short name <fullName>-preview or
       <fullName>-preview.<namespace>.svc[...]; "" otherwise. Takes host, fullName and namespace. One test for the
       routes Argo Rollouts weights (helm.canary.routesFor) and the routes that get a source route
       (helm.canary.sourceRoutes). */ -}}
{{- define "helm.canary.isPreviewHost" -}}
{{- $previewName := printf "%s-preview" .fullName -}}
{{- if or (eq .host $previewName) (hasPrefix (printf "%s.%s.svc" $previewName .namespace) .host) }}true{{ end -}}
{{- end -}}

{{- /* True where a canary Rollout renders the canary source routes and the canary/stable pod labels they match
       (DEVOPS-326): where its steps render (helm.canary.stepsRendered) and coordinator.enabled is true. The coordinator
       moves every Rollout of the release through the same weights in lock-step, so a callee's canary is sized for the
       weight its canary callers are at. Without it a caller can be at 50% while its callee is at 10%, and the source
       routes would send the caller canary's whole share to a callee canary sized for 10%; so with the coordinator off
       canary callers keep reaching stable. After a Rollout aborts, Argo Rollouts v1.10.0 (dynamicStableScale false)
       points its -preview Service back at its stable ReplicaSet on every reconcile (rollout/trafficrouting.go), after
       pointing it at the aborted canary ReplicaSet while that still has available pods
       (reconcileStableAndCanaryService, rollout/service.go), so for up to abortScaleDownDelaySeconds (30 s) the
       siblings' canary callers reach its aborted canary pods or its stable pods, then stable. */ -}}
{{- define "helm.canary.sourceRoutesRendered" -}}
{{- if and (eq (include "helm.canary.stepsRendered" .) "true") (include "helm.canary.config" . | fromJson).coordinator.enabled }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* Names of the HTTP routes in a rendered VirtualService spec that send traffic to the app's Service, as JSON.
       A destination counts when its host is the Service's short name or <fullName>.<namespace>.svc[.cluster.local];
       other hosts that share the prefix, such as the <app>.dev.internal ServiceEntry, are not the Service. */ -}}
{{- define "helm.canary.routesFor" -}}
{{- $names := list -}}
{{- $serviceDomain := printf "%s.%s.svc" .fullName .namespace -}}
{{- range (.spec.http | default list) -}}
  {{- $route := . -}}
  {{- $hit := false -}}
  {{- $preview := false -}}
  {{- range ($route.route | default list) -}}
    {{- $host := toString .destination.host -}}
    {{- if or (eq $host $.fullName) (eq $host $serviceDomain) (hasPrefix (printf "%s." $serviceDomain) $host) }}{{ $hit = true }}{{ end -}}
    {{- if include "helm.canary.isPreviewHost" (dict "host" $host "fullName" $.fullName "namespace" $.namespace) }}{{ $preview = true }}{{ end -}}
  {{- end -}}
  {{- if and $hit (not $preview) -}}
    {{- fail (printf "VirtualService route '%s' sends traffic to %s without its -preview destination, so it would bypass the canary. A custom route with an explicit destination to the app's own Service gets no -preview destination; leave destination unset." $route.name $.fullName) -}}
  {{- end -}}
  {{- if $hit -}}
    {{- /* Argo Rollouts weights only the first route with a given name, so a second route of the same name would be
           silently skipped (or resolve to another app's route in a multi-frontend VirtualService). */ -}}
    {{- $sameName := 0 -}}
    {{- range $.spec.http }}{{ if eq (toString .name) (toString $route.name) }}{{ $sameName = add1 $sameName }}{{ end }}{{ end -}}
    {{- if gt $sameName 1 -}}
      {{- fail (printf "VirtualService has %d HTTP routes named '%s'; Argo Rollouts weights only the first route with a name, so every route that reaches %s needs a unique name (a custom route key must not be 'canary' or the app's full name, and custom route keys must differ across frontend apps)." $sameName $route.name $.fullName) -}}
    {{- end -}}
    {{- $names = append $names $route.name -}}
  {{- end -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* The http routes of an app's VirtualService with a canary source route before each route that has the app's
       -preview destination and no fault or redirect, as JSON (DEVOPS-326 spec A3). Takes http (the parsed routes) and
       context (the app context) and ctx (its helm.context); helm.specs.virtualservice calls it where
       helm.canary.sourceRoutesRendered is true.
       A source route, <name>-canary-source, takes every match of its original that can match in the mesh with two
       more conditions in each (a route without a match gets one match of just these). A match whose own gateways leave
       out mesh (an ingress-only custom route under networking.istio.routes) never matches an in-mesh caller, so it is
       dropped, and a route left with no match gets no source route: a canary caller falls through it as a stable
       caller does. The two conditions: the caller is in the mesh (gateways: [mesh], in place of a match's own
       gateways) and its pod is a canary pod of this release, labelled mycarrier.tech/rollout-role: canary by the
       Rollout's canaryMetadata and carrying this release's mycarrier.tech/correlationId as the pod label renders it
       (helm.labels.correlationId; Istio compares sourceLabels exactly). It sends the request to the original's first
       -preview destination and keeps every other field of the original (headers, timeout, retries, rewrite, CORS), so
       a canary caller gets the answer a stable caller gets, served by the canary. A route with a fault (-forbidden) answers the same whatever
       its destination, and a redirect has none, so they get no source route: a canary caller falls through to them as
       a stable caller does. Argo Rollouts puts its managed routes (canary-header) above all others and leaves the rest
       in this order. */ -}}
{{- define "helm.canary.sourceRoutes" -}}
{{- $fullName := include "helm.fullname" .context -}}
{{- $namespace := include "helm.namespace" .context -}}
{{- $sourceLabels := dict "mycarrier.tech/rollout-role" "canary" "mycarrier.tech/correlationId" (include "helm.labels.correlationId" .ctx) -}}
{{- $caller := dict "gateways" (list "mesh") "sourceLabels" $sourceLabels -}}
{{- $routes := list -}}
{{- range (.http | default list) -}}
  {{- $preview := dict -}}
  {{- range (.route | default list) -}}
    {{- if and (not $preview) (include "helm.canary.isPreviewHost" (dict "host" (toString .destination.host) "fullName" $fullName "namespace" $namespace)) }}{{ $preview = .destination }}{{ end -}}
  {{- end -}}
  {{- $matches := list -}}
  {{- if and $preview (not .fault) (not .redirect) -}}
    {{- range (.match | default (list dict)) -}}
      {{- if or (not (hasKey . "gateways")) (has "mesh" .gateways) }}{{ $matches = append $matches (merge (deepCopy $caller) .) }}{{ end -}}
    {{- end -}}
  {{- end -}}
  {{- if $matches -}}
    {{- $twin := omit . "name" "match" "route" -}}
    {{- $_ := set $twin "name" (printf "%s-canary-source" .name) -}}
    {{- $_ := set $twin "match" $matches -}}
    {{- $_ := set $twin "route" (list (dict "destination" $preview)) -}}
    {{- $routes = append $routes $twin -}}
  {{- end -}}
  {{- $routes = append $routes . -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}

{{- /* trafficRouting.istio.virtualServices for the app: its own VirtualService and, for a frontend in a
       multi-frontend release, the shared <primary>-multifrontend one. The routes are read from the same templates
       that render those VirtualServices, so the list always matches what Istio gets, and every listed route
       carries the stable and -preview destinations (Argo Rollouts requires both). */ -}}
{{- define "helm.canary.virtualServices" -}}
{{- $fullName := include "helm.fullname" . -}}
{{- $result := list -}}
{{- $own := include "helm.specs.virtualservice" . | fromYaml -}}
{{- $namespace := include "helm.namespace" . -}}
{{- $ownRoutes := include "helm.canary.routesFor" (dict "spec" $own "fullName" $fullName "namespace" $namespace) | fromJsonArray -}}
{{- if $ownRoutes }}
{{- $result = append $result (dict "name" $fullName "routes" $ownRoutes) -}}
{{- end -}}
{{- if .application.isFrontend -}}
  {{- $frontendApps := dict -}}
  {{- $primaryApp := "" -}}
  {{- range $name, $values := .Values.applications -}}
    {{- if $values.isFrontend -}}
      {{- $_ := set $frontendApps $name $values -}}
      {{- if $values.isPrimary }}{{ $primaryApp = $name }}{{ end -}}
    {{- end -}}
  {{- end -}}
  {{- /* Same condition as frontendVirtualService.yaml. */ -}}
  {{- if and (gt (len $frontendApps) 1) $primaryApp -}}
    {{- $primaryAppValues := index $frontendApps $primaryApp -}}
    {{- $primaryFullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) (omit . "appName" "application")) -}}
    {{- $mfContext := merge (dict "frontendApps" $frontendApps "primaryApp" $primaryApp "primaryAppValues" $primaryAppValues "primaryFullName" $primaryFullName) (omit . "appName" "application") -}}
    {{- $mf := include "helm.specs.multifrontend.virtualservice" $mfContext | fromYaml -}}
    {{- $mfRoutes := include "helm.canary.routesFor" (dict "spec" $mf "fullName" $fullName "namespace" $namespace) | fromJsonArray -}}
    {{- if $mfRoutes }}
    {{- /* Argo Rollouts adds a managed route (the dark stage's canary-header) to every VirtualService the Rollout lists,
           ahead of their other routes, and it matches only the header. In this shared VirtualService it would send
           every path to this app's canary, and two frontend Rollouts would overwrite each other's route. */ -}}
    {{- if and (eq (include "helm.canary.enabled" .) "true") (include "helm.canary.managedRoutes" . | fromJsonArray) -}}
      {{- fail (printf "application '%s': the dark stage's header route would also go into the shared %s-multifrontend VirtualService, where it matches every path. Set global.strategy.canary.dark: false for a multi-frontend release." .appName $primaryFullName) -}}
    {{- end -}}
    {{- $result = append $result (dict "name" (printf "%s-multifrontend" $primaryFullName) "routes" $mfRoutes) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $result -}}
  {{- fail (printf "application '%s': no VirtualService route reaches %s, so the canary has nothing to weight." .appName $fullName) -}}
{{- end -}}
{{- toYaml $result -}}
{{- end -}}

{{- /* The Rollouts that run canary steps (the helm.canary.groupSize set), in name order, as JSON: every routed Rollout
       (helm.canary.routed: deploymentType rollout without migratingToRollouts). global.deploymentStrategy is
       release-wide, so it is not checked here; the callers (the dark stage and the rolloutGroupSize annotation) render
       only when it is canary. */ -}}
{{- define "helm.canary.rollouts" -}}
{{- $names := list -}}
{{- range $name, $values := .Values.applications -}}
  {{- if eq (include "helm.canary.routed" (dict "application" $values)) "true" }}{{ $names = append $names $name }}{{ end -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* global.correlationId as a string, in its own case: a numeric id renders as its digits (12345, not 1.2345e+04);
       unset, empty or 0 renders "". helm.canary.tests.request sends it as the request's CorrelationId. */ -}}
{{- define "helm.canary.correlationIdString" -}}
{{- $id := dig "correlationId" "" (.Values.global | default dict) -}}
{{- if and (kindIs "float64" $id) (eq $id (float64 (int64 $id))) }}{{ $id = int64 $id }}{{ end -}}
{{- toString ($id | default "") -}}
{{- end -}}

{{- /* global.correlationId lower-cased (helm.canary.correlationIdString), the one form every value that routes on it
       uses (DEVOPS-326): the dark stage's header route and the tests-dark X-MyCarrier-Canary header. TestEngine
       requires the header lower case; slip ids are minted lower case. */ -}}
{{- define "helm.canary.correlationId" -}}
{{- lower (include "helm.canary.correlationIdString" .) -}}
{{- end -}}

{{- /* The leader of the release, which alone runs the dark-stage suite (D20): global.strategy.canary.leader, which must
       name one of the canary Rollouts, or the only canary Rollout when there is one; "" otherwise
       (helm.canary.configuredSteps fails, in every environment, when the dark stage needs a leader and there is none).
       Chosen on purpose, not by name order, so adding or renaming a Rollout (a migrator Rollout, for example) cannot
       move the suite. */ -}}
{{- define "helm.canary.leader" -}}
{{- $rollouts := include "helm.canary.rollouts" . | fromJsonArray -}}
{{- $set := toString (dig "strategy" "canary" "leader" "" (.Values.global | default dict)) -}}
{{- if $set -}}
  {{- if not (has $set $rollouts) -}}
    {{- fail (printf "global.strategy.canary.leader '%s' is not an application with deploymentType rollout that runs canary steps; %s." $set (ternary "this release has none" (printf "choose one of: %s" (join ", " $rollouts)) (empty $rollouts))) -}}
  {{- end -}}
  {{- $set -}}
{{- else if eq (len $rollouts) 1 -}}
  {{- first $rollouts -}}
{{- end -}}
{{- end -}}

{{- /* trafficRouting.managedRoutes: every route a setHeaderRoute or setMirrorRoute step names, as JSON. Argo Rollouts
       rejects those steps for a route that is not listed, and it puts the listed routes ahead of the VirtualService's
       own routes while they exist. Read from helm.canary.configuredSteps, so the multi-frontend check in
       helm.canary.virtualServices runs in every environment; helm.specs.rollout renders the list only where the
       steps render. */ -}}
{{- define "helm.canary.managedRoutes" -}}
{{- $names := list -}}
{{- range (include "helm.canary.configuredSteps" . | fromYamlArray) -}}
  {{- $name := dig "setHeaderRoute" "name" (dig "setMirrorRoute" "name" "" .) . -}}
  {{- if and $name (not (has $name $names)) }}{{ $names = append $names $name }}{{ end -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* The fewest pods a canary Rollout runs, as JSON {replicas, source, fix}: keda.minReplicaCount with KEDA,
       autoscaling.minReplicas with the HPA (helm.kedaCondition, helm.hpaCondition, as helm.specs.rollout decides), 1
       with the top-level scaling value (helm.specs.rollout then renders no replicas and Argo Rollouts runs 1), else the
       Rollout's replicas (helm.specs.replicas). fix is the remedy the canary-floor check prints. */ -}}
{{- define "helm.canary.minReplicas" -}}
{{- $set := printf "Set applications.%s.%%s to 2 or more." .appName -}}
{{- if eq "true" (include "helm.kedaCondition" . | trim) -}}
  {{- toJson (dict "replicas" (include "helm.keda.minReplicaCount" . | int) "source" "keda.minReplicaCount" "fix" (printf $set "keda.minReplicaCount")) -}}
{{- else if eq "true" (include "helm.hpaCondition" . | trim) -}}
  {{- toJson (dict "replicas" (include "helm.hpa.minReplicas" . | int) "source" "autoscaling.minReplicas" "fix" (printf $set "autoscaling.minReplicas")) -}}
{{- else if .Values.scaling -}}
  {{- toJson (dict "replicas" 1 "source" "top-level scaling: the Rollout renders no replicas, and Argo Rollouts runs 1" "fix" "Remove the top-level scaling value, or scale the application with an HPA or KEDA whose minimum is 2 or more.") -}}
{{- else -}}
  {{- toJson (dict "replicas" ((include "helm.specs.replicas" . | fromYaml).replicas | int) "source" "replicas" "fix" (printf $set "replicas")) -}}
{{- end -}}
{{- end -}}

{{- /* Number of Rollouts in the release that run canary steps (mycarrier.tech/rolloutGroupSize), counted as in
       helm.canary.rollouts. */ -}}
{{- define "helm.canary.groupSize" -}}
{{- $count := 0 -}}
{{- range $name, $values := .Values.applications -}}
  {{- if eq (include "helm.canary.routed" (dict "application" $values)) "true" }}{{ $count = add1 $count }}{{ end -}}
{{- end -}}
{{- $count -}}
{{- end -}}

{{- /* The stable and -preview destinations of one VirtualService route of a Rollout app, at 100/0, one pair per port.
       Argo Rollouts manages a route only when it has both. Takes stableHost, previewHost and ports. */ -}}
{{- define "helm.canary.destinations" -}}
{{- range .ports }}
- destination:
    host: {{ $.stableHost | quote }}
    port:
      number: {{ . }}
  weight: 100
- destination:
    host: {{ $.previewHost | quote }}
    port:
      number: {{ . }}
  weight: 0
{{- end }}
{{- end -}}
