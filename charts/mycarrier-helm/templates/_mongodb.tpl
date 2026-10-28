{{/*
In-cluster MongoDB (dependencyDeployments.mongodb), rendered from the mc-mongodb subchart's named templates.
*/}}

{{- define "helm.mongodb.enabled" -}}
{{- if dig "mongodb" "enabled" false (.Values.dependencyDeployments | default dict) }}true{{ end -}}
{{- end -}}

{{/* <appStack>-mongodb, cut to the 45 characters mc-mongodb allows so <name>-backup-connection stays within 63. */}}
{{- define "helm.mongodb.name" -}}
{{- printf "%s-mongodb" (.Values.global.appStack | lower) | trunc 45 | trimSuffix "-" -}}
{{- end -}}

{{/*
The mc-mongodb render context. The subchart's values (.Values.mc-mongodb) supply the defaults; the stack's
dependencyDeployments.mongodb overrides the settings it exposes; the environment decides the rest. Production (a meta
environment starting with prod) always backs up and never otherwise.
Usage: include "helm.mongodb.context" . | fromJson
*/}}
{{- define "helm.mongodb.context" -}}
{{- $defaults := index .Values "mc-mongodb" }}
{{- $stack := .Values.dependencyDeployments.mongodb }}
{{- $name := include "helm.mongodb.name" . }}
{{- $appStack := .Values.global.appStack | lower }}
{{- $isProd := hasPrefix "prod" (include "helm.metaEnvironment" .) }}
{{- $backup := mergeOverwrite (deepCopy $defaults.backup) (pick ($stack.backup | default dict) "schedule" "timeZone" "retentionDays") }}
{{- $_ := set $backup "enabled" $isProd }}
{{- $_ := set $backup "container" "production" }}
{{- $_ := set $backup "path" (printf "%s/%s" .Values.environment.name $appStack) }}
{{- dict
  "name" $name
  "namespace" (include "helm.namespace" .)
  "labels" (dict
    "app.kubernetes.io/name" $name
    "app.kubernetes.io/part-of" .Values.global.appStack
    "app.kubernetes.io/managed-by" .Release.Service
    "mycarrier.tech/environment" .Values.environment.name)
  "members" (default (ternary 3 1 $isProd) $stack.members)
  "version" (default $defaults.version $stack.version)
  "featureCompatibilityVersion" $defaults.featureCompatibilityVersion
  "storage" (mergeOverwrite (deepCopy $defaults.storage) ($stack.storage | default dict))
  "resources" (default $defaults.resources $stack.resources)
  "appUser" (dict "name" $defaults.appUser.name "database" $appStack)
  "password" $defaults.password
  "backup" $backup
  | toJson }}
{{- end -}}
