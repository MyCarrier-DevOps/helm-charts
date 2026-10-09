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
      "analysis" (dict "enabled" false "templates" (list "health" "compare" "alerts"))
      "coordinator" (dict
        "enabled" false
        "barrierTimeouts" (dict "start" "10m" "dark-ready" "10m" "dark-passed" "30m" "w10" "15m" "w25" "15m" "w50" "15m")) -}}
{{- $global := .Values.global | default dict -}}
{{- $cfg := deepCopy (dig "strategy" "canary" dict $global) -}}
{{- toJson (mustMergeOverwrite (deepCopy $defaults) $cfg) -}}
{{- end -}}

{{- /* The canary steps: global.strategy.canary.steps verbatim when set, otherwise the preset ladder (DEVOPS-307):
         standard  10, analysis, pause 5m, 25, analysis, pause 5m, 50, analysis, pause 5m, 100
         fast      25, analysis, 100
         manual    10, analysis, pause (until resumed), 100
       Analysis steps render only with analysis.enabled (default false until DEVOPS-312's AnalysisTemplates exist);
       each references <environment>-<fullName>-<template>.
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
{{- if $cfg.analysis.enabled -}}
  {{- $templates := list -}}
  {{- range $cfg.analysis.templates -}}
    {{- $templates = append $templates (dict "templateName" (printf "%s-%s-%s" $.Values.environment.name $fullName .)) -}}
  {{- end -}}
  {{- $analysisStep = dict "analysis" (dict "templates" $templates) -}}
{{- end -}}
{{- if $coordinator.enabled }}{{ $steps = append $steps (include "helm.canary.barrier" (dict "name" "start" "coordinator" $coordinator) | fromJson) }}{{ end -}}
{{- if and $coordinator.enabled $cfg.dark -}}
  {{- $correlationId := toString (dig "correlationId" "" (.Values.global | default dict)) -}}
  {{- $steps = append $steps (dict "setCanaryScale" (dict "replicas" (int $cfg.darkReplicas))) -}}
  {{- $steps = append $steps (dict "setHeaderRoute" (dict "name" "canary-header" "match" (list (dict "headerName" "X-MyCarrier-Canary" "headerValue" (dict "exact" $correlationId))))) -}}
  {{- $steps = append $steps (include "helm.canary.barrier" (dict "name" "dark-ready" "coordinator" $coordinator) | fromJson) -}}
  {{- if and $cfg.analysis.enabled (eq (include "helm.canary.leader" .) .appName) -}}
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
{{- toYaml $steps }}
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

{{- /* The leader of the release: the first application name in sort order among the Rollouts that run canary steps
       (the helm.canary.groupSize set). It alone runs the dark-stage suite (D20). */ -}}
{{- define "helm.canary.leader" -}}
{{- $leader := "" -}}
{{- range $name, $values := .Values.applications -}}
  {{- if and (not $leader) (eq $values.deploymentType "rollout") (not $values.migratingToRollouts) }}{{ $leader = $name }}{{ end -}}
{{- end -}}
{{- $leader -}}
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
