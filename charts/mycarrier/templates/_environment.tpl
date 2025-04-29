{{- define "helm.envType" -}}
{{- if has .Values.environment.name (list "dev" "preprod" "prod") }}
{{- printf "standard" }}
{{- else }}
{{- printf "standard" }}
{{- /* printf "ephemeral" */}}
{{- end }}
{{- end -}}

{{- define "helm.envDependency" -}}
{{- $envType := (include "helm.envType" . ) }}
{{- if eq $envType "ephemeral" }}
{{- if .Values.globalEnv.dependencyenv }}
{{- .Values.globalEnv.dependencyenv }}
{{- else }}
{{- printf "dev" }}
{{- end }}
{{- else }}
{{- .Values.environment.name }}
{{- end }}
{{- end -}}

{{- define "helm.metaEnvironment" -}}
{{- if hasPrefix "feature" .Values.environment.name}}
{{- printf "dev" -}}
{{- else }}
{{- .Values.environment.name }}
{{- end }}
{{- end -}}
