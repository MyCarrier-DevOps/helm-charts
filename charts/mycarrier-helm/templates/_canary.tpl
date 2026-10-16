{{- /* Canary contract for Rollouts (DEVOPS-311). The settings are release-wide (global.strategy.canary) so every
       Rollout of a release runs the same steps; per-application updateStrategy.canary blocks are refused in
       rollout.yaml. */ -}}

{{- /* True for a Rollout that runs canary steps: deploymentType rollout and not mid-migration (a migrating Rollout
       renders a bare canary and takes over no Service; see helm.specs.rollout). */ -}}
{{- define "helm.canary.enabled" -}}
{{- if and (eq .application.deploymentType "rollout") (not .application.migratingToRollouts) }}true{{ else }}false{{ end }}
{{- end -}}

{{- /* global.strategy.canary merged over the defaults, as JSON. */ -}}
{{- define "helm.canary.config" -}}
{{- $defaults := dict
      "preset" "standard"
      "progressDeadlineSeconds" 600
      "dark" true
      "darkReplicas" 1
      "analysis" (dict "enabled" false "templates" (list "health") "health" (dict "count" 3 "interval" "30s" "consecutiveErrorLimit" 1))
      "coordinator" (dict
        "enabled" false
        "barrierTimeouts" (dict "start" "9m" "dark-ready" "9m" "dark-passed" "9m" "w10" "9m" "w25" "9m" "w50" "9m")) -}}
{{- $global := .Values.global | default dict -}}
{{- $cfg := deepCopy (dig "strategy" "canary" dict $global) -}}
{{- toJson (mustMergeOverwrite (deepCopy $defaults) $cfg) -}}
{{- end -}}

{{- /* The canary steps: global.strategy.canary.steps verbatim when set, otherwise the preset ladder (DEVOPS-307):
         standard  10, analysis, pause 5m, 25, analysis, pause 5m, 50, analysis, pause 5m, 100
         fast      25, analysis, 100
         manual    10, analysis, pause (until resumed), 100
       Analysis steps render only with analysis.enabled (default false); each references
       <environment>-<fullName>-<template>, and every referenced template must render for the app
       (helm.canary.analysis.available), because Argo Rollouts resolves them up front and leaves the Rollout InvalidSpec
       when one is missing.
       With coordinator.enabled (release-wide lockstep, D20: DEVOPS-325's mycarrier/canary-coordinator step plugin) a
       preset starts with a barrier named start, which arms the plugin's Abort hook and confirms the whole group has
       been applied, and gets a barrier named w<weight> after each weight's analysis and pause, so every Rollout of the
       release crosses each boundary together; the manual preset's pause stays before its barrier, so a resume of the
       group fans out and the barrier then holds it. An explicit steps list renders verbatim and carries its own
       barriers. The plugin's webhook host and token live in the controller, never in the Rollout spec.
       With the coordinator on and dark (default true, D11), the start barrier is followed by the header-gated dark
       stage: darkReplicas canary pods at weight 0, a canary-header route matched on X-MyCarrier-Canary:
       <global.correlationId>, the dark-ready barrier, the <environment>-<fullName>-tests-dark analysis on the leader
       only (with analysis.enabled), the dark-passed barrier, then the route is removed. setCanaryScale
       {matchTrafficWeight: true} closes the stage: Argo Rollouts keeps the last setCanaryScale in force for every later
       step, so without it the canary would stay at darkReplicas pods through the weights. The dark stage waits for the
       coordinator because followers rely on its barriers to wait for the leader's suite. */ -}}
{{- define "helm.canary.steps" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
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
{{- $available := list -}}
{{- if $cfg.analysis.enabled -}}
  {{- $available = include "helm.canary.analysis.available" . | fromJsonArray -}}
  {{- $templates := list -}}
  {{- range $cfg.analysis.templates -}}
    {{- if not (has . $available) -}}
      {{- if eq . "health" -}}
        {{- fail (printf "application '%s': the canary health check has no HTTP path on a port its -preview Service exposes. Set applications.%s.canaryHealthPath or global.strategy.canary.analysis.health.path (called on the app's http port), give the app an httpGet probe under applications.%s.probes (the chart's default probes are HTTP only for global.language csharp), or remove health from global.strategy.canary.analysis.templates." $.appName $.appName $.appName) -}}
      {{- end -}}
      {{- fail (printf "application '%s': global.strategy.canary.analysis.templates lists '%s', but no AnalysisTemplate of that name renders for it. The chart renders health; compare (DEVOPS-322) and alerts are not built yet. Remove it, or define it under applications.%s.analysisTemplates." $.appName . $.appName) -}}
    {{- end -}}
    {{- $templates = append $templates (dict "templateName" (printf "%s-%s-%s" $.Values.environment.name $fullName .)) -}}
  {{- end -}}
  {{- $analysisStep = dict "analysis" (dict "templates" $templates) -}}
{{- end -}}
{{- if $coordinator.enabled }}{{ $steps = append $steps (include "helm.canary.barrier" (dict "name" "start" "coordinator" $coordinator) | fromJson) }}{{ end -}}
{{- if and $coordinator.enabled $cfg.dark -}}
  {{- if not (include "helm.canary.leader" .) -}}
    {{- fail (printf "the dark stage runs its test suite on one leader, and this release has %d canary Rollouts; set global.strategy.canary.leader to one of: %s." (len (include "helm.canary.rollouts" . | fromJsonArray)) (join ", " (include "helm.canary.rollouts" . | fromJsonArray))) -}}
  {{- end -}}
  {{- $correlationId := toString (dig "correlationId" "" (.Values.global | default dict)) -}}
  {{- $steps = append $steps (dict "setCanaryScale" (dict "replicas" (int $cfg.darkReplicas))) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header" "match" (list (dict "headerName" "X-MyCarrier-Canary" "headerValue" (dict "exact" $correlationId))))) -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-ready" "coordinator" $coordinator) | fromJson) -}}
  {{- if and $cfg.analysis.enabled (eq (include "helm.canary.leader" .) .appName) -}}
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

{{- /* A barrier timeout such as 90s, 9m or 1h, in seconds; any other form yields 0 and is not checked. */ -}}
{{- define "helm.canary.durationSeconds" -}}
{{- $v := toString . -}}
{{- if regexMatch "^[0-9]+(s|m|h)$" $v -}}
  {{- $n := trimSuffix "h" (trimSuffix "m" (trimSuffix "s" $v)) | int -}}
  {{- if hasSuffix "h" $v }}{{ mul $n 3600 }}{{ else if hasSuffix "m" $v }}{{ mul $n 60 }}{{ else }}{{ $n }}{{ end -}}
{{- else -}}0{{- end -}}
{{- end -}}

{{- /* Names of the AnalysisTemplates that render for an app, as JSON: its applications.<app>.analysisTemplates, plus the
       chart's own health template when the app has none of that name and its health URL is known. */ -}}
{{- define "helm.canary.analysis.available" -}}
{{- $names := list -}}
{{- range (.application.analysisTemplates | default list) }}{{ $names = append $names (toString .name) }}{{ end -}}
{{- if and (not (has "health" $names)) (has "health" (include "helm.canary.config" . | fromJson).analysis.templates) (include "helm.canary.analysis.healthUrl" .) }}{{ $names = append $names "health" }}{{ end -}}
{{- toJson $names -}}
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
       Otherwise the check reuses the probes the pod renders with (_spec_workload.tpl): readiness, then startup, then
       liveness, each from applications.<app>.probes or else the chart's default for global.language (HTTP only for
       csharp), skipping a probe turned off by probes.enable*; the first httpGet path wins. The port is the Service
       port that targets that container port. */ -}}
{{- define "helm.canary.analysis.healthUrl" -}}
{{- $probes := .application.probes | default dict -}}
{{- $ports := .application.ports | default dict -}}
{{- $get := dict -}}
{{- $from := "" -}}
{{- with dig "canaryHealthPath" (include "helm.canary.config" . | fromJson).analysis.health.path .application -}}
  {{- $get = dict "path" . "port" (or (index $ports "http") (index $ports "healthcheck")) -}}
{{- end -}}
{{- range (list (list "readinessProbe" "enableReadiness" "helm.defaultReadinessProbe") (list "startupProbe" "enableStartup" "helm.defaultStartupProbe") (list "livenessProbe" "enableLiveness" "helm.defaultLivenessProbe")) -}}
  {{- if and (not $get.path) (dig (index . 1) true $probes) -}}
    {{- $probe := index $probes (index . 0) | default (get (include (index . 2) $ | fromYaml) (index . 0)) | default dict -}}
    {{- $get = $probe.httpGet | default dict -}}
    {{- if $get.path }}{{ $from = index . 0 }}{{ end -}}
  {{- end -}}
{{- end -}}
{{- /* The check calls plain http with no host or headers; a probe that needs them would make every measurement an
       Error, so it fails the render instead of aborting the canary. */ -}}
{{- if and $from (or (and $get.scheme (ne (upper (toString $get.scheme)) "HTTP")) $get.host $get.httpHeaders) -}}
  {{- fail (printf "application '%s': the canary health check would reuse the path of its %s, which sets scheme HTTPS, host or httpHeaders; the check calls plain http with none of these. Set applications.%s.canaryHealthPath to a path served over plain http, or define a health template under applications.%s.analysisTemplates." .appName $from .appName .appName) -}}
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
    {{- if include "helm.canary.managedRoutes" . | fromJsonArray -}}
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

{{- /* The Rollouts that run canary steps (the helm.canary.groupSize set), in name order, as JSON. */ -}}
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

{{- /* Number of Rollouts in the release that run canary steps (mycarrier.tech/rolloutGroupSize). */ -}}
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
