{{/*
Normalizes keda.triggers into a single list, whether the application uses the
legacy flat trigger shape (keda.type/topicName/...) or the list shape
(keda.triggers[]). Returns the list JSON-encoded (toJson) so callers parse it
back with fromJsonArray. Each normalized item keeps its original fields plus a
"path" label used in validation error messages: "keda" for the legacy shape,
"keda.triggers[<i>]" for list items.
*/}}
{{- define "helm.specs.keda.triggers" -}}
{{- $kedaConfig := .application.keda | default dict -}}
{{- $rawTriggers := dig "triggers" (list) $kedaConfig -}}
{{- $triggers := list -}}
{{- if $rawTriggers -}}
  {{- range $i, $t := $rawTriggers }}
    {{- $normalized := merge (dict) $t -}}
    {{- $_ := set $normalized "path" (printf "keda.triggers[%d]" $i) -}}
    {{- $triggers = append $triggers $normalized -}}
  {{- end }}
{{- else -}}
  {{- $normalized := merge (dict) $kedaConfig -}}
  {{- $_ := set $normalized "path" "keda" -}}
  {{- $triggers = append $triggers $normalized -}}
{{- end -}}
{{- $triggers | toJson -}}
{{- end -}}

{{/*
Validates all required KEDA configuration fields.
Must be called before any other KEDA spec helper to fail fast on bad config.
*/}}
{{- define "helm.specs.keda.validate" -}}
{{- $appName := .appName -}}
{{- $kedaConfig := .application.keda | default dict -}}
{{- $rawTriggers := dig "triggers" (list) $kedaConfig -}}
{{/* keda.type (legacy) and keda.triggers (list) are mutually exclusive */}}
{{- if and $kedaConfig.type $rawTriggers }}
  {{- fail (printf "application '%s': keda.type and keda.triggers are mutually exclusive; move the flat trigger into keda.triggers" $appName) }}
{{- end }}
{{/* minReplicaCount/maxReplicaCount are ScaledObject-level only, never per-trigger */}}
{{- range $i, $t := $rawTriggers }}
  {{- if hasKey $t "minReplicaCount" }}
    {{- fail (printf "application '%s': keda.triggers[%d].minReplicaCount is not supported; set keda.minReplicaCount at the keda level (KEDA applies replica bounds to the whole ScaledObject)" $appName $i) }}
  {{- end }}
  {{- if hasKey $t "maxReplicaCount" }}
    {{- fail (printf "application '%s': keda.triggers[%d].maxReplicaCount is not supported; set keda.maxReplicaCount at the keda level (KEDA applies replica bounds to the whole ScaledObject)" $appName $i) }}
  {{- end }}
{{- end }}
{{- $triggers := include "helm.specs.keda.triggers" . | fromJsonArray -}}
{{- range $i, $t := $triggers }}
  {{- $path := $t.path }}
  {{/* Validate <path>.type */}}
  {{- if not (or (eq $t.type "queue") (eq $t.type "topic")) }}
    {{- fail (printf "application '%s': %s.type must be 'queue' or 'topic', got '%s'" $appName $path ($t.type | default "<not set>")) }}
  {{- end }}
  {{/* Validate required fields per type */}}
  {{- if eq $t.type "topic" }}
    {{- if not $t.topicName }}
      {{- fail (printf "application '%s': %s.topicName is required when %s.type is 'topic'" $appName $path $path) }}
    {{- end }}
    {{- if not $t.subscriptionName }}
      {{- fail (printf "application '%s': %s.subscriptionName is required when %s.type is 'topic'" $appName $path $path) }}
    {{- end }}
  {{- else }}
    {{- if not $t.queueName }}
      {{- fail (printf "application '%s': %s.queueName is required when %s.type is 'queue'" $appName $path $path) }}
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
{{/* Resolve clusterAuthRef: use configured value or default based on environment */}}
{{- $metaEnv := include "helm.metaEnvironment" . | trim -}}
{{- $defaultClusterAuthRef := printf "servicebus-connectionstring-%s" $metaEnv -}}
{{- $clusterAuthRef := dig "clusterAuthRef" $defaultClusterAuthRef $kedaConfig -}}
{{/* Compute min/max replica counts - use kindIs "invalid" to allow 0 */}}
{{- $configuredMinReplicas := dig "minReplicaCount" nil $kedaConfig }}
{{- $minReplicaCount := ternary ($configuredMinReplicas | int) ($kedaDefaults.minReplicaCount | int) (not (kindIs "invalid" $configuredMinReplicas)) }}
{{- $configuredMaxReplicas := dig "maxReplicaCount" nil $kedaConfig }}
{{- $maxReplicaCount := ternary ($configuredMaxReplicas | int) ($kedaDefaults.maxReplicaCount | int) (not (kindIs "invalid" $configuredMaxReplicas)) }}
{{- $triggers := include "helm.specs.keda.triggers" . | fromJsonArray -}}
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
{{- range $i, $t := $triggers }}
  {{- $triggerClusterAuthRef := $t.clusterAuthRef -}}
  {{- if not $triggerClusterAuthRef -}}
    {{- $triggerClusterAuthRef = $clusterAuthRef -}}
  {{- end }}
  - type: azure-servicebus
    metadata:
      {{- if eq $t.type "topic" }}
      topicName: {{ $t.topicName | quote }}
      subscriptionName: {{ $t.subscriptionName | quote }}
      {{- else }}
      queueName: {{ $t.queueName | quote }}
      {{- end }}
      messageCount: {{ dig "messageCount" $kedaDefaults.messageCount $t | int | quote }}
      {{- if $t.activationMessageCount }}
      activationMessageCount: {{ $t.activationMessageCount | int | quote }}
      {{- end }}
    authenticationRef:
      name: {{ $triggerClusterAuthRef }}
      kind: ClusterTriggerAuthentication
{{- end }}
{{- end -}}
