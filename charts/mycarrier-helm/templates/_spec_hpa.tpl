{{- define "helm.specs.hpa" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $replicas := dig "replicas" 2 .application }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $autoscalingDefaults := $ctx.chartDefaults.autoscaling -}}
{{- $maxMultiplier := $autoscalingDefaults.maxReplicasMultiplier -}}
{{- $configuredMinReplicas := dig "autoscaling" "minReplicas" nil .application }}
{{- $minReplicas := $configuredMinReplicas | default $replicas }}
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