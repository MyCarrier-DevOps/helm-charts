{{/*
VirtualService helper library housing routing-specific helper templates.
Separated from _lang.tpl to keep language helpers isolated.
*/}}

{{/*
Helper function to normalize paths for deduplication
Removes all trailing wildcards and slashes
*/}}
{{- define "helm.normalizePath" -}}
{{- . | trimSuffix "*" | trimSuffix "/" | trimSuffix "*" | trimSuffix "/" -}}
{{- end -}}

{{/*
Helper function to process prefix paths for Istio VirtualService
Converts wildcard patterns to Istio-compatible prefix paths by replacing * with /
Generic algorithm handles all patterns consistently without hardcoded special cases
*/}}
{{- define "helm.processPrefixPath" -}}
{{- $path := . -}}
{{- /* Replace all * with / for Istio prefix matching */ -}}
{{- $processed := $path | replace "*" "/" -}}
{{- /* Remove duplicate slashes that may result from replacement */ -}}
{{- $processed | replace "//" "/" -}}
{{- end -}}

{{/*
Helper function to process endpoint names - replaces special characters for Kubernetes naming
Replaces * with "wildcard", / with -, and removes leading/trailing dashes
*/}}
{{- define "helm.processEndpointName" -}}
{{- $name := . -}}
{{- $name = $name | replace "*" "wildcard" | replace "/" "-" | trimAll "-" -}}
{{- $name -}}
{{- end -}}

{{/*
Helper function to process regex endpoint names for Kubernetes naming conventions
Replaces regex special characters with dashes and removes leading/trailing dashes
*/}}
{{- define "helm.processRegexEndpointName" -}}
{{- . | regexReplaceAll "[/\\.\\?\\+\\*]" "-" | regexReplaceAll "[\\^$]" "" | trimAll "-" -}}
{{- end -}}

{{/*
Helper function to process exact endpoint names for Kubernetes naming conventions
Replaces / with - and removes leading/trailing dashes
*/}}
{{- define "helm.processExactEndpointName" -}}
{{- . | replace "/" "-" | trimAll "-" -}}
{{- end -}}

{{/*
Centralized endpoint name generation for all kinds
*/}}
{{- define "helm.renderEndpointName" -}}
{{- if eq .kind "regex" -}}
  {{- include "helm.processRegexEndpointName" .match -}}
{{- else if eq .kind "prefix" -}}
  {{- include "helm.processEndpointName" .match -}}
{{- else -}}
  {{- include "helm.processExactEndpointName" .match -}}
{{- end -}}
{{- end -}}

{{/*
Centralized match rendering for all endpoint kinds
*/}}
{{- define "helm.renderEndpointMatch" -}}
{{- $metaenv := default "" .metaenv -}}
{{- $isDevEnv := eq $metaenv "dev" -}}
{{- if eq .kind "regex" -}}
- uri:
    regex: {{ .match | quote }}
  {{- if $isDevEnv }}
  withoutHeaders:
    environment: {}
  {{- end }}
{{- else if eq .kind "prefix" -}}
- uri:
    prefix: {{ include "helm.processPrefixPath" .match | quote }}
  {{- if $isDevEnv }}
  withoutHeaders:
    environment: {}
  {{- end }}
{{- else -}}
- uri:
    exact: {{ .match | quote }}
  {{- if $isDevEnv }}
  withoutHeaders:
    environment: {}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Centralized HTTP rule name and match rendering for all endpoint kinds
*/}}
{{- define "helm.renderEndpointRule" -}}
{{- $endpointName := include "helm.renderEndpointName" . -}}
{{- $ruleType := .ruleType -}}
{{- $fullName := .fullName }}
- name: {{ $fullName }}-{{ $ruleType }}-{{ $endpointName }}
  match:
{{ include "helm.renderEndpointMatch" . | indent 2 }}
{{- end }}

{{/*
Helper template to generate VirtualService HTTP rules for language-specific and user-defined endpoints
This template generates the complete HTTP rules as strings to avoid duplication
*/}}
{{- define "helm.virtualservice.allowedEndpoints" -}}
{{- $namespace := include "helm.namespace" . }}
{{- $fullName := include "helm.fullname" . -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $serviceDefaults := $ctx.chartDefaults.service -}}
{{- $mergedEndpoints := list -}}
{{- $istioConfig := dig "networking" "istio" dict $.application -}}

{{/* Add language-specific endpoints first using centralized template */}}
{{- $contextWithFullName := dict "Values" $.Values "application" $.application "fullName" $fullName }}
{{- $langEndpointsYaml := include "helm.lang.endpoint.list" $contextWithFullName | trim -}}
{{- if ne $langEndpointsYaml "" }}
  {{- $langEndpoints := fromYamlArray $langEndpointsYaml -}}
  {{- $mergedEndpoints = concat $mergedEndpoints $langEndpoints -}}
{{- end }}

{{/* Add user-defined endpoints */}}
{{- if and (hasKey $istioConfig "allowedEndpoints") $istioConfig.allowedEndpoints -}}
  {{- $mergedEndpoints = concat $mergedEndpoints $istioConfig.allowedEndpoints -}}
{{- end }}

{{/* Exit early if no endpoints to process */}}
{{- if lt (len $mergedEndpoints) 1 -}}
{{- else -}}

{{/* Deduplicate endpoints by kind+normalizedPath AND check for name conflicts */}}
{{- $seenPaths := dict -}}
{{- $seenNames := dict -}}
{{- $unique := list -}}
{{- range $mergedEndpoints -}}
  {{/* Normalize input - convert all endpoints to unified object format */}}
  {{- $endpoint := dict -}}
  {{- if typeIs "string" . -}}
    {{/* Convert string to object based on presence of wildcard */}}
    {{- if contains "*" . -}}
      {{- $endpoint = dict "kind" "prefix" "match" . -}}
    {{- else -}}
      {{- $endpoint = dict "kind" "exact" "match" . -}}
    {{- end -}}
  {{- else -}}
    {{/* Already an object, use as-is */}}
    {{- $endpoint = . -}}
  {{- end -}}
  
  {{/* Process normalized endpoint - single path for all types */}}
  {{- $kind := $endpoint.kind -}}
  {{- $match := $endpoint.match -}}
  {{- $endpointName := "" -}}
  {{- $normalizedPath := "" -}}
  
  {{- if eq $kind "prefix" -}}
    {{- $endpointName = include "helm.processEndpointName" $match -}}
    {{- $normalizedPath = include "helm.normalizePath" $match -}}
  {{- else if eq $kind "exact" -}}
    {{- $endpointName = include "helm.processExactEndpointName" $match -}}
    {{- $normalizedPath = $match -}}
  {{- else if eq $kind "regex" -}}
    {{- $endpointName = include "helm.processRegexEndpointName" $match -}}
    {{- $normalizedPath = $match -}}
  {{- end -}}
  
  {{/* Deduplication using kind:normalizedPath and name conflict detection */}}
  {{- $pathKey := printf "%s:%s" $kind $normalizedPath -}}
  {{- if not (hasKey $seenPaths $pathKey) -}}
    {{/* Also check if endpoint name already exists (name conflict detection) */}}
    {{- if not (hasKey $seenNames $endpointName) -}}
      {{- $_ := set $seenPaths $pathKey true -}}
      {{- $_ := set $seenNames $endpointName true -}}
      {{- if eq $kind "prefix" -}}
        {{- $unique = append $unique (dict "kind" "prefix" "match" $match "normalized" $normalizedPath) -}}
      {{- else -}}
        {{- $unique = append $unique (dict "kind" $kind "match" $match) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* render HTTP rules using centralized helper */}}
{{- if gt (len $unique) 0 }}
{{- range $unique }}
{{- $ruleContext := dict "kind" .kind "match" .match "ruleType" "allowed" "fullName" $fullName "metaenv" $metaenv }}
{{ include "helm.renderEndpointRule" $ruleContext }}
  route:
    {{- if and $.application.service $.application.service.ports }}
    {{- range $.application.service.ports }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
      weight: 100
    {{- if eq $.application.deploymentType "rollout" }}
    - destination:
        host: "{{ $fullName }}-preview.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
      weight: 0
    {{- end }}
    {{- end }}
    {{- else }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 100
    {{- if eq $.application.deploymentType "rollout" }}
    - destination:
        host: "{{ $fullName }}-preview.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 0
    {{- end }}
    {{- end }}
  {{- with $istioConfig.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{/* Apply response headers - use custom if defined, otherwise use defaults */}}
  {{- $responseHeadersYaml := "" -}}
  {{- if and (hasKey $istioConfig "responseHeaders") $istioConfig.responseHeaders -}}
    {{- $responseHeadersYaml = toYaml $istioConfig.responseHeaders | trim -}}
  {{- else -}}
    {{- $responseHeadersYaml = include "helm.istioIngress.responseHeaders" $ | trim -}}
  {{- end -}}
  headers:
{{ $responseHeadersYaml | indent 4 }}
  {{/* Safely access service properties with default values if not defined */}}
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $.application }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $.application }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $.application }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $.application }}
{{- end }}


- name: {{ $fullName }}-forbidden
  route:
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}      
  fault:
    delay:
      fixedDelay: 29s
      percentage:
        value: 100
    abort:
      httpStatus: 403
      percentage:
        value: 100
{{- end }}
{{- end -}}
{{- end -}}
