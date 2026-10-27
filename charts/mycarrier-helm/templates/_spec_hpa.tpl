{{- /* The HPA's minReplicas: autoscaling.minReplicas, else replicas, else 2. helm.canary.minReplicas reads it too. */ -}}
{{- define "helm.hpa.minReplicas" -}}
{{- $replicas := dig "replicas" 2 .application }}
{{- $configuredMinReplicas := dig "autoscaling" "minReplicas" nil .application }}
{{- $configuredMinReplicas | default $replicas | int -}}
{{- end -}}

{{- define "helm.specs.hpa" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $autoscalingDefaults := $ctx.chartDefaults.autoscaling -}}
{{- $maxMultiplier := $autoscalingDefaults.maxReplicasMultiplier -}}
{{- $minReplicas := include "helm.hpa.minReplicas" . | int }}
{{- $configuredMaxReplicas := dig "autoscaling" "maxReplicas" nil .application }}
{{- $maxReplicas := $configuredMaxReplicas | default (mul $minReplicas $maxMultiplier) }}
maxReplicas: {{ $maxReplicas }}
minReplicas: {{ $minReplicas }}
metrics:
- type: Resource
  resource:
    name: cpu
    target:
      type: Utilization
      averageUtilization: {{ dig "autoscaling" "targetCPUUtilizationPercentage" $autoscalingDefaults.targetCPUUtilizationPercentage .application }}
- type: Resource
  resource:
    name: memory
    target:
      type: Utilization
      averageUtilization: {{ dig "autoscaling" "targetMemoryUtilizationPercentage" $autoscalingDefaults.targetMemoryUtilizationPercentage .application }}
scaleTargetRef:
  {{- if (ne .application.deploymentType "rollout")  }}
  apiVersion: apps/v1
  {{- else if (eq .application.deploymentType "rollout") }}
  apiVersion: argoproj.io/v1alpha1
  {{- end}}
  {{- if (eq .application.deploymentType "deployment")  }}
  kind: Deployment
  {{- else if (eq .application.deploymentType "statefulset") }}
  kind: StatefulSet
  {{- else if (eq .application.deploymentType "rollout") }}
  kind: Rollout
  {{- end}}
  name: {{ $fullName }}
{{- end -}}