{{- define "helm.defaultReadinessProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if ($.Values.application.ports) }}
readinessProbe:
  tcpSocket:
    port: {{- (or (index .Values.application.ports "http") (index .Values.application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 10
  periodSeconds: 7
  timeoutSeconds: 1
  successThreshold: 1
  failureThreshold: 3
{{- end }}
{{- end }}
{{- end -}}

{{- define "helm.defaultStartupProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if ($.Values.application.ports) }}
startupProbe:
  tcpSocket:
    port: {{- (or (index .Values.application.ports "http") (index .Values.application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 30
{{- end }}
{{- else }}
{{- if ($.Values.application.ports) }}
startupProbe:
  failureThreshold: 3
  httpGet:
    path: /health
    port: {{- (or (index .Values.application.ports "http") (index .Values.application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
{{- end }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLivenessProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if ($.Values.application.ports) }}
livenessProbe:
  tcpSocket:
    port: {{- (or (index .Values.application.ports "http") (index .Values.application.ports "healthcheck")) | toString | indent 1 }}
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 10
  successThreshold: 1
  failureThreshold: 30
{{- end }}
{{- else }}
{{- if ($.Values.application.ports) }}
livenessProbe:
  failureThreshold: 3
  httpGet:
    path: /liveness
    port: {{- (or (index .Values.application.ports "http") (index .Values.application.ports "healthcheck")) | toString | indent 1 }}
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
{{- end }}
{{- end }}
{{- end -}}
