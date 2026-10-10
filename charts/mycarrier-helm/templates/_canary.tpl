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
      "analysis" (dict "enabled" false "templates" (list "health" "compare" "alerts")) -}}
{{- $global := .Values.global | default dict -}}
{{- $cfg := deepCopy (dig "strategy" "canary" dict $global) -}}
{{- toJson (mustMergeOverwrite (deepCopy $defaults) $cfg) -}}
{{- end -}}

{{- /* The canary steps: global.strategy.canary.steps verbatim when set, otherwise the preset ladder (DEVOPS-307):
         standard  10, analysis, pause 5m, 25, analysis, pause 5m, 50, analysis, pause 5m, 100
         fast      25, analysis, 100
         manual    10, analysis, pause (until resumed), 100
       Analysis steps render only with analysis.enabled (default false until DEVOPS-312's AnalysisTemplates exist);
       each references <environment>-<fullName>-<template>. The coordinator steps (PR 3) and the dark stage
       (DEVOPS-326) go in front of the ladder. */ -}}
{{- define "helm.canary.steps" -}}
{{- $cfg := include "helm.canary.config" . | fromJson -}}
{{- if $cfg.steps }}
{{- toYaml $cfg.steps }}
{{- else }}
{{- $fullName := include "helm.fullname" . -}}
{{- $analysisStep := dict -}}
{{- if $cfg.analysis.enabled -}}
  {{- $templates := list -}}
  {{- range $cfg.analysis.templates -}}
    {{- $templates = append $templates (dict "templateName" (printf "%s-%s-%s" $.Values.environment.name $fullName .)) -}}
  {{- end -}}
  {{- $analysisStep = dict "analysis" (dict "templates" $templates) -}}
{{- end -}}
{{- $steps := list -}}
{{- if eq $cfg.preset "standard" -}}
  {{- range $weight := list 10 25 50 -}}
    {{- $steps = append $steps (dict "setWeight" $weight) -}}
    {{- if $analysisStep }}{{ $steps = append $steps $analysisStep }}{{ end -}}
    {{- $steps = append $steps (dict "pause" (dict "duration" "5m")) -}}
  {{- end -}}
  {{- $steps = append $steps (dict "setWeight" 100) -}}
{{- else if eq $cfg.preset "fast" -}}
  {{- $steps = append $steps (dict "setWeight" 25) -}}
  {{- if $analysisStep }}{{ $steps = append $steps $analysisStep }}{{ end -}}
  {{- $steps = append $steps (dict "setWeight" 100) -}}
{{- else if eq $cfg.preset "manual" -}}
  {{- $steps = append $steps (dict "setWeight" 10) -}}
  {{- if $analysisStep }}{{ $steps = append $steps $analysisStep }}{{ end -}}
  {{- $steps = append $steps (dict "pause" (dict)) -}}
  {{- $steps = append $steps (dict "setWeight" 100) -}}
{{- else -}}
  {{- fail (printf "global.strategy.canary.preset '%s' is not one of standard, fast, manual" $cfg.preset) -}}
{{- end -}}
{{- toYaml $steps }}
{{- end }}
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
    {{- $result = append $result (dict "name" (printf "%s-multifrontend" $primaryFullName) "routes" $mfRoutes) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $result -}}
  {{- fail (printf "application '%s': no VirtualService route reaches %s, so the canary has nothing to weight." .appName $fullName) -}}
{{- end -}}
{{- toYaml $result -}}
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
