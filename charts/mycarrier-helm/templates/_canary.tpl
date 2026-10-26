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

{{- /* True for a Rollout that runs canary steps: a routed Rollout (helm.canary.routed) whose repository's
       deployment-strategy property is canary. chart-renderer passes the property as global.deploymentStrategy; only the
       exact string canary turns the steps on. Anything else (unset, empty, rolling, Canary), and every render path that
       does not pass it (offloads), renders the Rollout with no steps: the same Services, VirtualService and
       trafficRouting, without the steps, analysis, managedRoutes or canary annotations (helm.specs.rollout). */ -}}
{{- define "helm.canary.enabled" -}}
{{- if and (eq (include "helm.canary.routed" .) "true") (eq (toString (dig "deploymentStrategy" "" (.Values.global | default dict))) "canary") }}true{{ else }}false{{ end }}
{{- end -}}

{{- /* global.strategy.canary merged over the defaults, as JSON. It configures the steps of a canary Rollout
       (helm.canary.enabled); a routed Rollout without steps reads only progressDeadlineSeconds from it. Analysis is
       mandatory for every Rollout that runs steps (DEVOPS-312): health and alerts are on unless opted out, and templates
       lists only extra templates. analysis.enabled is deprecated and has no default; rollout.yaml refuses false. dark
       stays off until DEVOPS-326 renders tests-dark.
       bakeMinutes is rendered as the mycarrier.tech/bakeMinutes annotation (helm.canary.bakeMinutes). manualTimeout
       and budgetSeconds (no default) feed the mycarrier.tech/canaryBudgetSeconds annotation (helm.canary.budgetSeconds). */ -}}
{{- define "helm.canary.config" -}}
{{- $defaults := dict
      "preset" "standard"
      "progressDeadlineSeconds" 600
      "dark" false
      "darkReplicas" 1
      "bakeMinutes" 30
      "manualTimeout" "1h"
      "analysis" (dict "templates" (list)
        "health" (dict "enabled" true "count" 3 "interval" "30s" "consecutiveErrorLimit" 1 "successCondition" "result == \"Healthy\"")
        "alerts" (dict "enabled" true "service" "" "interval" "30s" "consecutiveErrorLimit" 4 "dryRun" true "tokenKey" "ci-alert-gate"
          "image" "python:3.13.15-alpine3.23@sha256:6438599575cca0d1df94aeee0d2ae088d4d8846eab554b2ee7784a3a6df0d516"))
      "coordinator" (dict
        "enabled" true
        "barrierTimeouts" (dict "start" "9m" "dark-ready" "9m" "dark-passed" "9m" "w10" "9m" "w25" "9m" "w50" "9m")) -}}
{{- $global := .Values.global | default dict -}}
{{- $cfg := deepCopy (dig "strategy" "canary" dict $global) -}}
{{- toJson (mustMergeOverwrite (deepCopy $defaults) $cfg) -}}
{{- end -}}

{{- /* The canary steps: global.strategy.canary.steps verbatim when set, otherwise the preset ladder (DEVOPS-307):
         standard  10, analysis, pause 5m, 25, analysis, pause 5m, 50, analysis, pause 5m, 100
         fast      25, analysis, 100
         manual    10, analysis, pause (until resumed), 100
       Each analysis step runs health (unless analysis.health.enabled is false) and the extra analysis.templates; each
       references <environment>-<fullName>-<template>, and every referenced template must render for the app
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
       With the coordinator on and dark (default false until DEVOPS-326, D11), the start barrier is followed by the
       header-gated dark stage: darkReplicas canary pods at weight 0, a canary-header route matched on
       X-MyCarrier-Canary: <global.correlationId>, the dark-ready barrier, the <environment>-<fullName>-tests-dark
       analysis on the leader only, the dark-passed barrier, then the route is removed. setCanaryScale
       {matchTrafficWeight: true} closes the stage: Argo Rollouts keeps the last setCanaryScale in force for every later
       step, so without it the canary would stay at darkReplicas pods through the weights. The dark stage waits for the
       coordinator because followers rely on its barriers to wait for the leader's suite. */ -}}
{{- define "helm.canary.steps" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- if not (or $cfg.analysis.health.enabled $cfg.analysis.alerts.enabled $cfg.analysis.templates) -}}
  {{- fail (printf "analysis is mandatory for every Rollout, and application '%s' would run none: global.strategy.canary.analysis.health.enabled and analysis.alerts.enabled are both false and analysis.templates lists no extra template. Remove one of the opt-outs, or list an AnalysisTemplate defined under applications.%s.analysisTemplates in analysis.templates." .appName .appName) -}}
{{- end -}}
{{- $coordinator := $cfg.coordinator -}}
{{- if and $coordinator.enabled (not (dig "correlationId" "" (.Values.global | default dict))) -}}
  {{- fail "global.correlationId is required when the coordinator is enabled: the canary-coordinator groups a release's Rollouts by their mycarrier.tech/correlationId label." -}}
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
    {{- fail (printf "application '%s': global.strategy.canary.analysis.templates lists '%s', but no AnalysisTemplate of that name renders for it. The chart renders health and alerts; compare (DEVOPS-322) is not built yet. Remove it, or define it under applications.%s.analysisTemplates." $.appName . $.appName) -}}
  {{- end -}}
  {{- $templates = append $templates (dict "templateName" (printf "%s-%s-%s" $.Values.environment.name $fullName .)) -}}
{{- end -}}
{{- if $templates }}{{ $analysisStep = dict "analysis" (dict "templates" $templates) }}{{ end -}}
{{- if $coordinator.enabled }}{{ $steps = append $steps (include "helm.canary.barrier" (dict "name" "start" "coordinator" $coordinator) | fromJson) }}{{ end -}}
{{- if and $coordinator.enabled $cfg.dark -}}
  {{- if not (include "helm.canary.leader" .) -}}
    {{- fail (printf "the dark stage runs its test suite on one leader, and this release has %d canary Rollouts; set global.strategy.canary.leader to one of: %s." (len (include "helm.canary.rollouts" . | fromJsonArray)) (join ", " (include "helm.canary.rollouts" . | fromJsonArray))) -}}
  {{- end -}}
  {{- $correlationId := toString (dig "correlationId" "" (.Values.global | default dict)) -}}
  {{- $steps = append $steps (dict "setCanaryScale" (dict "replicas" (int $cfg.darkReplicas))) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header" "match" (list (dict "headerName" "X-MyCarrier-Canary" "headerValue" (dict "exact" $correlationId))))) -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-ready" "coordinator" $coordinator) | fromJson) -}}
  {{- if eq (include "helm.canary.leader" .) .appName -}}
    {{- if not (has "tests-dark" $available) -}}
      {{- fail (printf "application '%s': the dark stage runs the tests-dark AnalysisTemplate on the leader, and the chart does not render it yet (DEVOPS-312, DEVOPS-326). Set global.strategy.canary.dark: false, or define tests-dark under applications.%s.analysisTemplates." .appName .appName) -}}
    {{- end -}}
    {{- $steps = append $steps (dict "analysis" (dict "templates" (list (dict "templateName" (printf "%s-%s-tests-dark" .Values.environment.name $fullName))))) -}}
  {{- end -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-passed" "coordinator" $coordinator) | fromJson) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header")) -}}
  {{- $steps = append $steps (dict "setCanaryScale" (dict "matchTrafficWeight" true)) -}}
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
{{- range $weight := $ladder -}}
  {{- $steps = append $steps (dict "setWeight" $weight) -}}
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
{{- toYaml $steps }}
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

{{- /* The canary's worst-case length in whole seconds (Tech Spec D22, Q51), rendered on every canary Rollout as
       mycarrier.tech/canaryBudgetSeconds. The release's rollout-watch (DEVOPS-319) times out at the largest value of
       the release group plus 15 minutes, so the budget covers the steps helm.canary.steps renders for this Rollout at
       their longest, and rollout-watch never times out a canary that is still inside its designed steps:
       - pause: its duration; the manual preset's pause, which has none, counts manualTimeout (default 1h). The pause
         itself stays indefinite; manualTimeout only feeds the budget.
       - analysis: the longest of its templates (they run in parallel), each count x max(interval, the Job's
         activeDeadlineSeconds when the template is a Job provider that sets it). The chart's health template uses
         analysis.health.count and interval; an applications.<app>.analysisTemplates entry (an extra template, or one
         that replaces health or supplies tests-dark) uses its own count (1 when unset, as analysistemplate.yaml renders
         it; Argo Rollouts runs count 0 without an interval once) and interval (0 when unset).
       - a canary-coordinator barrier: its timeout.
       - a setWeight step above 0 waits until the canary's pods are available, for up to progressDeadlineSeconds. With
         the coordinator on, the barrier timeouts cover that wait; with coordinator.enabled false, each such setWeight
         step (100 included) counts progressDeadlineSeconds.
       - every other step (setWeight 0, setCanaryScale, setHeaderRoute): 0. The background alerts analysis runs alongside
         the steps and is not counted.
       The leader runs tests-dark and its followers do not, so their budgets can differ. An explicit steps list states its
       own budget in budgetSeconds (required there); with a preset the chart computes it and budgetSeconds is ignored.
       rollout-watch's release workflow has activeDeadlineSeconds 10800, which covers about 70 minutes before the canary
       starts, the budget and 15 minutes after it, so a budget above 5700 s fails the render. helm.canary.steps runs
       first, so its own checks report before these. */ -}}
{{- define "helm.canary.budgetSeconds" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $steps := include "helm.canary.steps" . | fromYamlArray -}}
{{- $budget := 0 -}}
{{- if $cfg.steps -}}
  {{- $set := $cfg.budgetSeconds -}}
  {{- if or (not (kindIs "float64" $set)) (lt $set 1.0) (ne $set (float64 (int $set))) -}}
    {{- fail (printf "global.strategy.canary.budgetSeconds is %s; an explicit global.strategy.canary.steps list needs it, as a whole number of seconds from 1 to 5700 (Tech Spec D22). It is the canary's worst-case length: the release's rollout-watch times out at it plus 15 minutes. Add up the pause durations, each analysis step's longest template (count x max(interval, the Job's activeDeadlineSeconds)) and each barrier timeout." (ternary "not set" (toString $set) (kindIs "invalid" $set))) -}}
  {{- end -}}
  {{- $budget = int $set -}}
{{- else -}}
  {{- $manual := 0 -}}
  {{- if eq $cfg.preset "manual" -}}
    {{- $manual = include "helm.canary.durationSeconds" $cfg.manualTimeout | int -}}
    {{- if not $manual -}}
      {{- fail (printf "global.strategy.canary.manualTimeout is '%v'; the manual preset needs a duration above zero such as 90s, 30m or 1h (default 1h). It is how long the release's rollout-watch allows for the manual pause (Tech Spec D22); the pause itself has no time limit." $cfg.manualTimeout) -}}
    {{- end -}}
  {{- end -}}
  {{- /* Seconds per AnalysisTemplate an analysis step can reference, by the name the step uses. */ -}}
  {{- $prefix := printf "%s-%s-" (toString .Values.environment.name) (include "helm.fullname" .) -}}
  {{- $health := $cfg.analysis.health -}}
  {{- $templates := dict (printf "%shealth" $prefix) (mul (int $health.count) (include "helm.canary.durationSeconds" $health.interval | int)) -}}
  {{- range (.application.analysisTemplates | default list) -}}
    {{- $count := 1 -}}
    {{- if hasKey . "count" }}{{ $count = max 1 (int .count) }}{{ end -}}
    {{- $interval := include "helm.canary.durationSeconds" (.interval | default "") | int -}}
    {{- $deadline := int (dig "provider" "job" "spec" "activeDeadlineSeconds" 0 .) -}}
    {{- $_ := set $templates (printf "%s%s" $prefix (toString .name)) (mul $count (max $interval $deadline)) -}}
  {{- end -}}
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
       chart's own health template when health is on, the app has none of that name and its health URL is known, and
       the chart's alerts template when alerts is on, the app has none of that name, the environment is prod and the
       service label is known. */ -}}
{{- define "helm.canary.analysis.available" -}}
{{- $names := list -}}
{{- range (.application.analysisTemplates | default list) }}{{ $names = append $names (toString .name) }}{{ end -}}
{{- $analysis := (include "helm.canary.config" . | fromJson).analysis -}}
{{- if and (not (has "health" $names)) $analysis.health.enabled (include "helm.canary.analysis.healthUrl" .) }}{{ $names = append $names "health" }}{{ end -}}
{{- if and (not (has "alerts" $names)) $analysis.alerts.enabled (include "helm.canary.alerts.environment" .) (include "helm.canary.alerts.service" .) }}{{ $names = append $names "alerts" }}{{ end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* The Rollout's background analysis, as JSON, or "" when it has none: the alerts template (the chart's, or an
       applications.<app>.analysisTemplates entry named alerts) unless analysis.alerts.enabled is false. It starts at
       the first step that sends the canary traffic (setWeight above 0, after the dark stage) and runs until the Rollout
       is promoted or aborted, so it also checks during the pauses, where the alert rules' for windows (5m for most
       standard rules) run out; a step-by-step check would sample only the first minute of each weight. A replacement
       entry runs that long only with count 0 and an interval. The service-label check sits here, outside the steps,
       so explicit global.strategy.canary.steps reach it too. */ -}}
{{- define "helm.canary.backgroundAnalysis" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- $customAlerts := false -}}
{{- range (.application.analysisTemplates | default list) }}{{ if eq (toString .name) "alerts" }}{{ $customAlerts = true }}{{ end }}{{ end -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") $cfg.analysis.alerts.enabled (not $customAlerts) (include "helm.canary.alerts.environment" .) (not (include "helm.canary.alerts.service" .)) -}}
  {{- fail (printf "application '%s': the canary alerts check filters Grafana alerts on the service label, and the chart cannot tell it. Set global.strategy.canary.analysis.alerts.service to the label the service's alert rules carry (the lower-cased repository name, or its alias, such as mycarrier for MC.MyCarrier), set alerts.serviceName or global.appStack, or opt out with global.strategy.canary.analysis.alerts.enabled: false." .appName) -}}
{{- end -}}
{{- if and (eq (include "helm.canary.enabled" .) "true") $cfg.analysis.alerts.enabled (has "alerts" (include "helm.canary.analysis.available" . | fromJsonArray)) -}}
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
    {{- $previewName := printf "%s-preview" $.fullName -}}
    {{- if or (eq $host $previewName) (hasPrefix (printf "%s.%s.svc" $previewName $.namespace) $host) }}{{ $preview = true }}{{ end -}}
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

{{- /* The Rollouts that run canary steps (the helm.canary.groupSize set), in name order, as JSON: every application with
       deploymentType rollout and without migratingToRollouts. global.deploymentStrategy is release-wide, so it is not
       checked here; the callers (the dark stage and the rolloutGroupSize annotation) render only when it is canary. */ -}}
{{- define "helm.canary.rollouts" -}}
{{- $names := list -}}
{{- range $name, $values := .Values.applications -}}
  {{- if and (eq $values.deploymentType "rollout") (not $values.migratingToRollouts) }}{{ $names = append $names $name }}{{ end -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* The leader of the release, which alone runs the dark-stage suite (D20): global.strategy.canary.leader, which must
       name one of the canary Rollouts, or the only canary Rollout when there is one; "" otherwise (helm.canary.steps
       fails when the dark stage needs a leader and there is none). Chosen on purpose, not by name order, so adding or
       renaming a Rollout (a migrator Rollout, for example) cannot move the suite. */ -}}
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
       own routes while they exist. */ -}}
{{- define "helm.canary.managedRoutes" -}}
{{- $names := list -}}
{{- range (include "helm.canary.steps" . | fromYamlArray) -}}
  {{- $name := dig "setHeaderRoute" "name" (dig "setMirrorRoute" "name" "" .) . -}}
  {{- if and $name (not (has $name $names)) }}{{ $names = append $names $name }}{{ end -}}
{{- end -}}
{{- toJson $names -}}
{{- end -}}

{{- /* Number of Rollouts in the release that run canary steps (mycarrier.tech/rolloutGroupSize), counted as in
       helm.canary.rollouts. */ -}}
{{- define "helm.canary.groupSize" -}}
{{- $count := 0 -}}
{{- range $name, $values := .Values.applications -}}
  {{- if and (eq $values.deploymentType "rollout") (not $values.migratingToRollouts) }}{{ $count = add1 $count }}{{ end -}}
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
