{{- define "helm.defaultPreStopDelay" -}}
{{- if and (dig "ports" false .application) (or (dig "ports" "http" false .application) (dig "ports" "healthcheck" false .application)) }}
{{- printf "sleep 1 && " }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLifecyclePreStop" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if $language }}
  {{- if contains "csharp" $language }}
  {{- printf "pkill dotnet" }}
  {{- else if contains "nodejs" $language }}
  {{- printf "pkill node" }}
  {{- else if contains "nginx" $language }}
  {{- printf "pkill -QUIT nginx" }}
  {{- else if contains "java" $language }}
  {{- printf "pkill java" }}
  {{- else if contains "python" $language }}
  {{- printf "pkill vault-env || true" }}
  {{- end }}
{{- else }}
{{- printf "pkill vault-env || true" }}
{{- end }}
{{- end -}}