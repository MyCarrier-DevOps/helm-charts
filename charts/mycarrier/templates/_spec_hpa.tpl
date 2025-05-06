{{- define "helm.specs.hpa" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
maxReplicas: {{ dig "autoscaling" "maxReplicas" 5 .application }}
minReplicas: {{ dig "autoscaling" "minReplicas" 2 .application }}
metrics:
- type: Resource
  resource:
    name: cpu
    target:
      type: Utilization
      averageUtilization: {{ dig "autoscaling" "targetCPUUtilizationPercentage" 80 .application }}
{{- if dig "autoscaling" "targetMemoryUtilizationPercentage" false .application }}
- type: Resource
  resource:
    name: memory
    target:
      type: Utilization
      averageUtilization: {{ dig "autoscaling" "targetMemoryUtilizationPercentage" 80 .application }}
{{- end }}
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