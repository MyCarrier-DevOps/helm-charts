{{/*
Validates all required KEDA configuration fields.
Must be called before any other KEDA spec helper to fail fast on bad config.
*/}}
{{- define "helm.specs.keda.validate" -}}
{{- $kedaConfig := .application.keda -}}
{{/* Validate keda.type */}}
{{- if not (or (eq $kedaConfig.type "queue") (eq $kedaConfig.type "topic")) }}
  {{- fail (printf "application '%s': keda.type must be 'queue' or 'topic', got '%s'" .appName ($kedaConfig.type | default "<not set>")) }}
{{- end }}
{{/* Validate required fields per type */}}
{{- if eq $kedaConfig.type "topic" }}
  {{- if not $kedaConfig.topicName }}
    {{- fail (printf "application '%s': keda.topicName is required when keda.type is 'topic'" .appName) }}
  {{- end }}
  {{- if not $kedaConfig.subscriptionName }}
    {{- fail (printf "application '%s': keda.subscriptionName is required when keda.type is 'topic'" .appName) }}
  {{- end }}
{{- else }}
  {{- if not $kedaConfig.queueName }}
    {{- fail (printf "application '%s': keda.queueName is required when keda.type is 'queue'" .appName) }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "helm.specs.keda.scaledObject" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $kedaDefaults := $ctx.chartDefaults.keda -}}
{{- $kedaConfig := .application.keda -}}
{{/* Resolve clusterAuthRef: use configured value or default based on environment */}}
{{- $metaEnv := include "helm.metaEnvironment" . | trim -}}
{{- $defaultClusterAuthRef := printf "servicebus-connectionstring-%s" $metaEnv -}}
{{- $clusterAuthRef := dig "clusterAuthRef" $defaultClusterAuthRef $kedaConfig -}}
{{/* Compute min/max replica counts - use kindIs "invalid" to allow 0 */}}
{{- $configuredMinReplicas := dig "minReplicaCount" nil $kedaConfig }}
{{- $minReplicaCount := ternary ($configuredMinReplicas | int) ($kedaDefaults.minReplicaCount | int) (not (kindIs "invalid" $configuredMinReplicas)) }}
{{- $configuredMaxReplicas := dig "maxReplicaCount" nil $kedaConfig }}
{{- $maxReplicaCount := ternary ($configuredMaxReplicas | int) ($kedaDefaults.maxReplicaCount | int) (not (kindIs "invalid" $configuredMaxReplicas)) }}
scaleTargetRef:
  {{- if (ne .application.deploymentType "rollout") }}
  apiVersion: apps/v1
  {{- else }}
  apiVersion: argoproj.io/v1alpha1
  {{- end }}
  {{- if (eq .application.deploymentType "deployment") }}
  kind: Deployment
  {{- else if (eq .application.deploymentType "statefulset") }}
  kind: StatefulSet
  {{- else if (eq .application.deploymentType "rollout") }}
  kind: Rollout
  {{- end }}
  name: {{ $fullName }}
pollingInterval: {{ dig "pollingInterval" ($kedaDefaults.pollingInterval | int) $kedaConfig }}
cooldownPeriod: {{ dig "cooldownPeriod" ($kedaDefaults.cooldownPeriod | int) $kedaConfig }}
{{- if not (kindIs "invalid" (dig "idleReplicaCount" nil $kedaConfig)) }}
idleReplicaCount: {{ $kedaConfig.idleReplicaCount }}
{{- end }}
minReplicaCount: {{ $minReplicaCount }}
maxReplicaCount: {{ $maxReplicaCount }}
{{- if dig "advanced" nil $kedaConfig }}
advanced:
  {{- toYaml $kedaConfig.advanced | nindent 2 }}
{{- end }}
triggers:
{{- if eq $kedaConfig.type "topic" }}
  - type: azure-servicebus
    metadata:
      topicName: {{ $kedaConfig.topicName | quote }}
      subscriptionName: {{ $kedaConfig.subscriptionName | quote }}
      messageCount: {{ dig "messageCount" $kedaDefaults.messageCount $kedaConfig | quote }}
      {{- if dig "activationMessageCount" nil $kedaConfig }}
      activationMessageCount: {{ $kedaConfig.activationMessageCount | quote }}
      {{- end }}
    authenticationRef:
      name: {{ $clusterAuthRef }}
      kind: ClusterTriggerAuthentication
{{- else }}
  - type: azure-servicebus
    metadata:
      queueName: {{ $kedaConfig.queueName | quote }}
      messageCount: {{ dig "messageCount" $kedaDefaults.messageCount $kedaConfig | quote }}
      {{- if dig "activationMessageCount" nil $kedaConfig }}
      activationMessageCount: {{ $kedaConfig.activationMessageCount | quote }}
      {{- end }}
    authenticationRef:
      name: {{ $clusterAuthRef }}
      kind: ClusterTriggerAuthentication
{{- end }}
{{- end -}}