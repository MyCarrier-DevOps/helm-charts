{{- define "helm.specs.vpa" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
targetRef:
  apiVersion: "apps/v1"
  kind: {{ if (eq .application.deploymentType "deployment") }}Deployment{{ else if (eq .application.deploymentType "statefulset") }}StatefulSet{{ end }}
  name: {{ $fullName }}
updatePolicy:
  updateMode: {{ dig "vpa" "updateMode" "Initial" .application }}
resourcePolicy:
  containerPolicies:
  - containerName: {{ .appName | default $fullName | lower | trunc 63 }}
    controlledValues: {{ dig "vpa" "controlledValues" "RequestsOnly" .application }}
    minAllowed:
      cpu: {{ dig "resources" "limits" "cpu" "100m" .application }}
      memory: {{ dig "resources" "limits" "memory" "128Mi" .application }}
    maxAllowed:
      cpu: {{ dig "resources" "limits" "cpu" "1000m" .application }}
      memory: {{ dig "resources" "limits" "memory" "1Gi" .application }}
  - containerName: istio-proxy
    mode: "Off"
  - containerName: vault-agent
    mode: "Off"
{{- end -}}