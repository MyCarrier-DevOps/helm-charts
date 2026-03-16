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
{{/* Validate authentication: must have either namespace (pod identity) or connectionStringSecret */}}
{{- if dig "namespace" "" $kedaConfig }}
  {{/* Pod identity mode: namespace is sufficient, no connectionStringSecret needed */}}
{{- else }}
  {{- if not (dig "connectionStringSecret" nil $kedaConfig) }}
    {{- fail (printf "application '%s': keda requires either namespace (for pod identity) or connectionStringSecret (name/key or vault)" .appName) }}
  {{- end }}
  {{- if not (dig "connectionStringSecret" "vault" nil $kedaConfig) }}
    {{- if not (and (dig "connectionStringSecret" "name" "" $kedaConfig) (dig "connectionStringSecret" "key" "" $kedaConfig)) }}
      {{- fail (printf "application '%s': keda.connectionStringSecret requires either vault (path+property) or name+key" .appName) }}
    {{- end }}
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
      {{- if dig "namespace" "" $kedaConfig }}
      namespace: {{ $kedaConfig.namespace | quote }}
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
      {{- if dig "namespace" "" $kedaConfig }}
      namespace: {{ $kedaConfig.namespace | quote }}
      {{- end }}
    authenticationRef:
      name: {{ $fullName }}-keda-trigger-auth
{{- end }}
{{- end -}}

{{/*
Determines the K8s secret name and key for the TriggerAuthentication.
When vault is configured, the ExternalSecret creates a secret named "<fullName>-keda-servicebus".
When a direct secret reference is used, it points to the user-specified secret.
*/}}
{{- define "helm.specs.keda.triggerAuth" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $kedaConfig := .application.keda -}}
{{- if dig "namespace" "" $kedaConfig }}
podIdentity:
  provider: azure
{{- else }}
secretTargetRef:
  - parameter: connection
    {{- if dig "connectionStringSecret" "vault" nil $kedaConfig }}
    name: {{ $fullName }}-keda-servicebus
    key: connectionString
    {{- else }}
    name: {{ $kedaConfig.connectionStringSecret.name }}
    key: {{ $kedaConfig.connectionStringSecret.key }}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
Generates an ExternalSecret that syncs the Azure Service Bus connection string
from Vault into a K8s Secret for KEDA TriggerAuthentication.
*/}}
{{- define "helm.specs.keda.externalSecret" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $kedaConfig := .application.keda -}}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ $fullName }}-keda-servicebus-es
  namespace: {{ $namespace }}
  labels:
    {{ include "helm.labels.dependencies" . | indent 4 | trim }}
    {{ include "helm.labels.standard" . | indent 4 | trim }}
    {{ include "helm.labels.version" . | indent 4 | trim }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1000"
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  refreshInterval: {{ dig "connectionStringSecret" "vault" "refreshInterval" "15m" $kedaConfig }}
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ dig "connectionStringSecret" "vault" "secretStoreName" "vault-backend" $kedaConfig }}
  target:
    name: {{ $fullName }}-keda-servicebus
    creationPolicy: Owner
  data:
    - secretKey: connectionString
      remoteRef:
        key: {{ $kedaConfig.connectionStringSecret.vault.path }}
        property: {{ $kedaConfig.connectionStringSecret.vault.property }}
        conversionStrategy: Default
        decodingStrategy: None
{{- end -}}