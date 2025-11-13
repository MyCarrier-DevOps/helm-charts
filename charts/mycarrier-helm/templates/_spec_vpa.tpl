{{- define "helm.specs.vpa" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $vpaDefaults := $ctx.chartDefaults.vpa -}}
{{- $cpuRequest := dig "resources" "requests" "cpu" $vpaDefaults.defaultRequestCpu .application }}
{{- $memoryRequest := dig "resources" "requests" "memory" $vpaDefaults.defaultRequestMemory .application }}
{{- $cpuLimit := dig "resources" "limits" "cpu" $vpaDefaults.defaultLimitCpu .application }}
{{- $memoryLimit := dig "resources" "limits" "memory" $vpaDefaults.defaultLimitMemory .application }}
{{- $configuredMinCpu := dig "vpa" "resources" "cpu" "minimum" nil .application }}
{{- $configuredMinMemory := dig "vpa" "resources" "memory" "minimum" nil .application }}
{{- $configuredMaxCpu := dig "vpa" "resources" "cpu" "maximum" nil .application }}
{{- $configuredMaxMemory := dig "vpa" "resources" "memory" "maximum" nil .application }}
{{- $minCpu := $configuredMinCpu | default $cpuRequest }}
{{- $minMemory := $configuredMinMemory | default $memoryRequest }}
{{- $maxCpu := "" }}
{{- $maxMemory := "" }}
{{- if $configuredMaxCpu }}
  {{- $maxCpu = $configuredMaxCpu }}
{{- else }}
  {{- $maxCpu = include "helm.vpa.multiplyResource" (dict "value" $cpuLimit "multiplier" $vpaDefaults.resourceMultiplier) }}
{{- end }}
{{- if $configuredMaxMemory }}
  {{- $maxMemory = $configuredMaxMemory }}
{{- else }}
  {{- $maxMemory = include "helm.vpa.multiplyResource" (dict "value" $memoryLimit "multiplier" $vpaDefaults.resourceMultiplier) }}
{{- end }}
targetRef:
  apiVersion: "apps/v1"
  kind: {{ if (eq .application.deploymentType "deployment") }}Deployment{{ else if (eq .application.deploymentType "statefulset") }}StatefulSet{{ end }}
  name: {{ $fullName }}
updatePolicy:
  updateMode: {{ dig "vpa" "updateMode" $vpaDefaults.updateMode .application }}
resourcePolicy:
  containerPolicies:
  - containerName: {{ .appName | default $fullName | lower | trunc 63 }}
    controlledValues: {{ dig "vpa" "controlledValues" $vpaDefaults.controlledValues .application }}
    minAllowed:
      cpu: {{ $minCpu | quote }}
      memory: {{ $minMemory | quote }}
    maxAllowed:
      cpu: {{ $maxCpu | quote }}
      memory: {{ $maxMemory | quote }}
  - containerName: istio-proxy
    mode: "Off"
  - containerName: vault-agent
    mode: "Off"
{{- end -}}

{{/*
Helper function to multiply Kubernetes resource values (CPU and Memory)
Supports various CPU formats: 100m, 1, 2.5
Supports various memory formats: 128Mi, 1Gi, 512M, 1G
*/}}
{{- define "helm.vpa.multiplyResource" -}}
{{- $value := .value | toString -}}
{{- $multiplier := .multiplier | int -}}
{{- if hasSuffix "m" $value -}}
  {{- $numValue := trimSuffix "m" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fm" $result -}}
{{- else if hasSuffix "Mi" $value -}}
  {{- $numValue := trimSuffix "Mi" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fMi" $result -}}
{{- else if hasSuffix "Gi" $value -}}
  {{- $numValue := trimSuffix "Gi" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fGi" $result -}}
{{- else if hasSuffix "M" $value -}}
  {{- $numValue := trimSuffix "M" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fM" $result -}}
{{- else if hasSuffix "G" $value -}}
  {{- $numValue := trimSuffix "G" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fG" $result -}}
{{- else if hasSuffix "Ki" $value -}}
  {{- $numValue := trimSuffix "Ki" $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- printf "%.0fKi" $result -}}
{{- else -}}
  {{- $numValue := $value | float64 -}}
  {{- $result := mulf $numValue $multiplier -}}
  {{- $resultInt := printf "%.0f" $result | float64 -}}
  {{- if eq $result $resultInt -}}
    {{- printf "%.0f" $result -}}
  {{- else -}}
    {{- printf "%.1f" $result -}}
  {{- end -}}
{{- end -}}
{{- end -}}