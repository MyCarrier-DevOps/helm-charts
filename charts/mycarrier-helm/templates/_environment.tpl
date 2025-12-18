{{- define "helm.envType" -}}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}

{{- if has $envName (list "dev" "preprod" "prod") }}
{{- printf "standard" }}
{{- else }}
{{- printf "standard" }}
{{- /* printf "ephemeral" */}}
{{- end }}
{{- end -}}

{{- define "helm.envDependency" -}}
{{- $envType := (include "helm.envType" . ) }}
{{- if eq $envType "ephemeral" }}
{{- if and .Values.globalEnv .Values.globalEnv.dependencyenv }}
{{- .Values.globalEnv.dependencyenv }}
{{- else }}
{{- printf "dev" }}
{{- end }}
{{- else }}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}
{{- $envName }}
{{- end }}
{{- end -}}

{{- define "helm.metaEnvironment" -}}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}

{{- if hasPrefix "feature" $envName }}
{{- printf "dev" -}}
{{- else }}
{{- $envName }}
{{- end }}
{{- end -}}

{{/*
Helper to get the environment header value for routing.
- For preprod environment, returns a regex pattern matching "preprod", "uat", or "qa"
- For feature environments, the actual environment name is used (e.g., "feature20")
- For other environments, the meta environment is used (prod, dev)
*/}}
{{- define "helm.environmentHeaderValue" -}}
{{- $envName := .Values.environment.name -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if eq $metaenv "preprod" -}}
{{- printf "^(preprod|uat|qa)$" -}}
{{- else if hasPrefix "feature" $envName -}}
{{- $envName -}}
{{- else -}}
{{- $metaenv -}}
{{- end -}}
{{- end -}}

{{/*
Helper to determine if the environment header should use regex matching.
Returns "true" for preprod (which accepts preprod/uat/qa), "false" otherwise.
*/}}
{{- define "helm.environmentHeaderIsRegex" -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if eq $metaenv "preprod" -}}
{{- printf "true" -}}
{{- else -}}
{{- printf "false" -}}
{{- end -}}
{{- end -}}

{{/*
Helper to determine if the environment is a "simple" environment (prod or preprod).
Simple environments don't require complex header-based routing with withoutHeaders fallbacks.
They use a straightforward default route without header matching requirements.
*/}}
{{- define "helm.isSimpleEnvironment" -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if or (eq $metaenv "prod") (eq $metaenv "preprod") -}}
{{- printf "true" -}}
{{- else -}}
{{- printf "false" -}}
{{- end -}}
{{- end -}}
