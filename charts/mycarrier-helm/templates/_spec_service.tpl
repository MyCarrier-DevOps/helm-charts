{{- define "helm.specs.service" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $serviceDefaults := $ctx.chartDefaults.service -}}
type: {{ dig "service" "type" "ClusterIP" .application }}
{{- if (dig "service" "headless" false .application) }}
clusterIP: None
{{ end }}
ports:
{{- if not (dig "service" "ports" false .application) }}
{{- range $key, $value := .application.ports }}
  - name: {{ $key | lower }}
    port: {{ $value }}
    protocol: TCP
{{- end }}
{{- end }}
{{- range dig "service" "ports" list .application }}
  - name: {{ .name }}
    port: {{ .port }}
    protocol: {{ default "TCP" .protocol }}
    targetPort: {{ default .port .targetPort  }}
{{- end }}
selector:
  {{ include "helm.labels.selector" . | indent 2 | trim }}
{{- if or (not (dig "service" "disableAffinity" false .application)) (dig "service" "headless" false .application) }}
sessionAffinity: ClientIP
sessionAffinityConfig:
  clientIP:
    timeoutSeconds: {{ dig "service" "affinityTimeoutSeconds" $serviceDefaults.sessionAffinityTimeoutSeconds .application }}
{{ end }}
{{- end -}}