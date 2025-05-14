{{- define "helm.specs.servicemonitor" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
namespaceSelector:
  matchNames:
    - {{ $namespace }}
selector:
  matchExpressions:
    {{ include "helm.selectorExpressions" . | indent 4 | trim }}
endpoints:
  - port: metrics
    path: /metrics
    interval: {{ dig "serviceMonitor" "interval" "30s" .application }}
    scrapeTimeout: {{ dig "serviceMonitor" "scrapeTimeout" "10s" .application }}
    {{- with (dig "serviceMonitor" "relabelings" false .application) }}
    relabelings:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with (dig "serviceMonitor" "metricRelabelings" false .application) }}
    metricRelabelings:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    scheme: {{ dig "serviceMonitor" "scheme" "http" .application }}
    {{- with (dig "serviceMonitor" "tlsConfig" false .application) }}
    tlsConfig:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end -}}