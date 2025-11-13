{{/*
Centralized chart defaults for MyCarrier Helm chart.
Provides a single source of truth for reusable default values
that can be referenced across templates to avoid scattered literals.
*/}}
{{- define "helm.chartDefaults.raw" -}}
{{- $defaults := dict -}}

{{- $applicationResources := dict -}}
{{- $_ := set $applicationResources "requests" (dict "cpu" "50m" "memory" "512Mi") -}}
{{- $_ := set $applicationResources "limits" (dict "cpu" "2000m" "memory" "2048Mi") -}}

{{- $jobResources := dict -}}
{{- $_ := set $jobResources "requests" (dict "cpu" "100m" "memory" "128Mi") -}}
{{- $_ := set $jobResources "limits" (dict "cpu" "500m" "memory" "256Mi") -}}

{{- $resources := dict -}}
{{- $_ := set $resources "application" $applicationResources -}}
{{- $_ := set $resources "job" $jobResources -}}
{{- $_ := set $resources "cronjob" $jobResources -}}
{{- $_ := set $resources "testTrigger" $jobResources -}}
{{- $_ := set $defaults "resources" $resources -}}

{{- $service := dict -}}
{{- $_ := set $service "timeout" "151s" -}}
{{- $_ := set $service "retryOn" "5xx,reset" -}}
{{- $_ := set $service "attempts" 3 -}}
{{- $_ := set $service "perTryTimeout" "50s" -}}
{{- $_ := set $service "sessionAffinityTimeoutSeconds" 600 -}}
{{- $_ := set $defaults "service" $service -}}

{{- $autoscaling := dict -}}
{{- $_ := set $autoscaling "targetCPUUtilizationPercentage" 80 -}}
{{- $_ := set $autoscaling "targetMemoryUtilizationPercentage" 80 -}}
{{- $_ := set $autoscaling "maxReplicasMultiplier" 3 -}}
{{- $_ := set $defaults "autoscaling" $autoscaling -}}

{{- $vpa := dict -}}
{{- $_ := set $vpa "updateMode" "Initial" -}}
{{- $_ := set $vpa "controlledValues" "RequestsOnly" -}}
{{- $_ := set $vpa "defaultRequestCpu" "100m" -}}
{{- $_ := set $vpa "defaultRequestMemory" "128Mi" -}}
{{- $_ := set $vpa "defaultLimitCpu" "1000m" -}}
{{- $_ := set $vpa "defaultLimitMemory" "1Gi" -}}
{{- $_ := set $vpa "resourceMultiplier" 3 -}}
{{- $_ := set $defaults "vpa" $vpa -}}

{{- $cronjob := dict -}}
{{- $_ := set $cronjob "successfulJobsHistoryLimit" 3 -}}
{{- $_ := set $cronjob "failedJobsHistoryLimit" 1 -}}
{{- $_ := set $defaults "cronjob" $cronjob -}}

{{- $job := dict -}}
{{- $_ := set $job "activeDeadlineSeconds" 600 -}}
{{- $_ := set $job "backoffLimit" 0 -}}
{{- $_ := set $defaults "job" $job -}}

{{- $_ := set $defaults "imagePullSecret" "imagepull" -}}
{{- $_ := set $defaults "restartPolicy" "Never" -}}

{{- $defaults | toJson -}}
{{- end -}}

{{/*
Returns the cached chart defaults dictionary. This helper should be used
by templates to retrieve default values without recomputing the map.
*/}}
{{- define "helm.chartDefaults" -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $ctx.chartDefaults | toJson -}}
{{- end -}}
