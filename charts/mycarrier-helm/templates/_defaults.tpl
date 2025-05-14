{{/*
Defaults helper functions to provide consistent default values across all resources.
This file centralizes default value definitions to ensure consistent behavior.
*/}}

{{/*
Default values for container resources
*/}}
{{- define "helm.defaults.resources" -}}
requests:
  cpu: {{ default "100m" .cpu }}
  memory: {{ default "128Mi" .memory }}
limits:
  cpu: {{ default "500m" .cpu }}
  memory: {{ default "512Mi" .memory }}
{{- end -}}

{{/*
Default values for probes
*/}}
{{- define "helm.defaults.probes" -}}
livenessProbe:
  httpGet:
    path: {{ default "/health" .path }}
    port: {{ default "http" .port }}
  initialDelaySeconds: {{ default 30 .initialDelaySeconds }}
  periodSeconds: {{ default 10 .periodSeconds }}
  timeoutSeconds: {{ default 5 .timeoutSeconds }}
  successThreshold: {{ default 1 .successThreshold }}
  failureThreshold: {{ default 3 .failureThreshold }}
readinessProbe:
  httpGet:
    path: {{ default "/health" .path }}
    port: {{ default "http" .port }}
  initialDelaySeconds: {{ default 5 .initialDelaySeconds }}
  periodSeconds: {{ default 10 .periodSeconds }}
  timeoutSeconds: {{ default 5 .timeoutSeconds }}
  successThreshold: {{ default 1 .successThreshold }}
  failureThreshold: {{ default 3 .failureThreshold }}
startupProbe:
  httpGet:
    path: {{ default "/health" .path }}
    port: {{ default "http" .port }}
  initialDelaySeconds: {{ default 5 .initialDelaySeconds }}
  periodSeconds: {{ default 10 .periodSeconds }}
  timeoutSeconds: {{ default 5 .timeoutSeconds }}
  successThreshold: {{ default 1 .successThreshold }}
  failureThreshold: {{ default 30 .failureThreshold }}
{{- end -}}

{{/*
Default values for update strategies
*/}}
{{- define "helm.defaults.updateStrategy" -}}
{{- if eq .kind "Deployment" }}
type: RollingUpdate
rollingUpdate:
  maxUnavailable: 0
  maxSurge: 1
{{- else if eq .kind "StatefulSet" }}
type: RollingUpdate
rollingUpdate:
  partition: 0
{{- else if eq .kind "DaemonSet" }}
type: RollingUpdate
rollingUpdate:
  maxUnavailable: 1
{{- end }}
{{- end -}}

{{/*
Default values for autoscaling
*/}}
{{- define "helm.defaults.autoscaling" -}}
enabled: {{ default false .enabled }}
minReplicas: {{ default 2 .minReplicas }}
maxReplicas: {{ default 5 .maxReplicas }}
targetCPUUtilizationPercentage: {{ default 80 .targetCPUUtilizationPercentage }}
{{- if .targetMemoryUtilizationPercentage }}
targetMemoryUtilizationPercentage: {{ .targetMemoryUtilizationPercentage }}
{{- end }}
{{- end -}}

{{/*
Default values for service
*/}}
{{- define "helm.defaults.service" -}}
type: {{ default "ClusterIP" .type }}
{{- if .ports }}
ports:
{{- range .ports }}
- name: {{ .name | default "http" }}
  port: {{ .port }}
  targetPort: {{ .targetPort | default .port }}
  protocol: {{ .protocol | default "TCP" }}
{{- end }}
{{- else }}
ports:
- name: http
  port: 80
  targetPort: 8080
  protocol: TCP
{{- end }}
{{- if .headless }}
clusterIP: None
{{- end }}
{{- if not .disableAffinity }}
sessionAffinity: ClientIP
sessionAffinityConfig:
  clientIP:
    timeoutSeconds: {{ .affinityTimeoutSeconds | default 600 }}
{{- end }}
{{- end -}}

{{/*
Default values for security contexts
*/}}
{{- define "helm.defaults.securityContext" -}}
runAsUser: {{ default 1000 .runAsUser }}
runAsGroup: {{ default 1000 .runAsGroup }}
fsGroup: {{ default 1000 .fsGroup }}
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Default values for container security context
*/}}
{{- define "helm.defaults.containerSecurityContext" -}}
runAsNonRoot: true
allowPrivilegeEscalation: false
capabilities:
  drop:
  - ALL
seccompProfile:
  type: RuntimeDefault
{{- end -}}