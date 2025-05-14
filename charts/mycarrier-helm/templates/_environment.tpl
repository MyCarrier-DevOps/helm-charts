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
