{{- define "helm.specs.keda.scaledObject" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $kedaDefaults := $ctx.chartDefaults.keda -}}
{{- $kedaConfig := .application.keda -}}
{{- $replicas := dig "replicas" 2 .application }}
{{- $configuredMinReplicas := dig "minReplicaCount" nil $kedaConfig }}
{{- $minReplicaCount := $configuredMinReplicas | default ($kedaDefaults.minReplicaCount | int) }}
{{- $configuredMaxReplicas := dig "maxReplicaCount" nil $kedaConfig }}
{{- $maxReplicaCount := $configuredMaxReplicas | default ($kedaDefaults.maxReplicaCount | int) }}
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
      name: {{ $fullName }}-keda-trigger-auth
{{- else }}
  - type: azure-servicebus
    metadata:
      queueName: {{ $kedaConfig.queueName | quote }}
      messageCount: {{ dig "messageCount" $kedaDefaults.messageCount $kedaConfig | quote }}
      {{- if dig "activationMessageCount" nil $kedaConfig }}
      activationMessageCount: {{ $kedaConfig.activationMessageCount | quote }}
      {{- end }}
    authenticationRef:
      name: {{ $fullName }}-keda-trigger-auth
{{- end }}
{{- end -}}

{{- define "helm.specs.keda.triggerAuth" -}}
{{- $kedaConfig := .application.keda -}}
secretTargetRef:
  - parameter: connection
    name: {{ $kedaConfig.connectionStringSecret.name }}
    key: {{ $kedaConfig.connectionStringSecret.key }}
{{- end -}}