{{- define "helm.defaultReadinessProbe" -}}
{{- if (dig "ports" (dict) .application) }}
readinessProbe:
  tcpSocket:
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 15
  periodSeconds: 5
  timeoutSeconds: 1
  successThreshold: 1
  failureThreshold: 30
{{- end }}
{{- end -}}

{{- define "helm.defaultStartupProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if (dig "ports" (dict) .application) }}
startupProbe:
  tcpSocket:
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 30
{{- end }}
{{- else }}
{{- if (dig "ports" (dict) .application) }}
startupProbe:
  failureThreshold: 3
  httpGet:
    path: /health
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
{{- end }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLivenessProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if (dig "ports" (dict) .application) }}
livenessProbe:
  tcpSocket:
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 30
{{- end }}
{{- else }}
{{- if (dig "ports" (dict) .application) }}
livenessProbe:
  failureThreshold: 3
  httpGet:
    path: /liveness
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
{{- end }}
{{- end }}
{{- end -}}
