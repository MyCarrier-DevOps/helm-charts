{{/*
In-cluster MongoDB (dependencyDeployments.mongodb), rendered from the mc-mongodb subchart's named templates.
*/}}

{{- define "helm.mongodb.enabled" -}}
{{- if dig "mongodb" "enabled" false (.Values.dependencyDeployments | default dict) }}true{{ end -}}
{{- end -}}

{{/* <appStack>-mongodb, cut to the 44 characters mc-mongodb allows so <name>-restore stays within the 52 Kubernetes
allows a CronJob. */}}
{{- define "helm.mongodb.name" -}}
{{- printf "%s-mongodb" (.Values.global.appStack | lower) | trunc 44 | trimSuffix "-" -}}
{{- end -}}

{{/*
The mc-mongodb render context. The subchart's values (.Values.mc-mongodb) supply the defaults; the stack's
dependencyDeployments.mongodb overrides the settings it exposes; the environment decides the rest. Production (a meta
environment starting with prod) always backs up, to the production container unless the stack names another; any other
environment backs up when the stack turns it on and names its cluster's container.
Usage: include "helm.mongodb.context" . | fromJson
*/}}
{{- define "helm.mongodb.context" -}}
{{- $defaults := index .Values "mc-mongodb" }}
{{- $stack := .Values.dependencyDeployments.mongodb }}
{{- $name := include "helm.mongodb.name" . }}
{{- $appStack := .Values.global.appStack | lower }}
{{- $metaEnv := include "helm.metaEnvironment" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $isProd := hasPrefix "prod" $metaEnv }}
{{- $stackBackup := $stack.backup | default dict }}
{{- if and $isProd (eq (toString $stackBackup.enabled) "false") }}
{{- fail "dependencyDeployments.mongodb.backup.enabled: production always backs up" }}
{{- end }}
{{- $backup := mergeOverwrite (deepCopy $defaults.backup) (pick $stackBackup "schedule" "timeZone" "retentionDays") }}
{{- $_ := set $backup "enabled" (or $isProd (eq (toString $stackBackup.enabled) "true")) }}
{{- $_ := set $backup "container" (default (ternary "production" "" $isProd) $stackBackup.container) }}
{{- if and $backup.enabled (not $backup.container) }}
{{- fail "dependencyDeployments.mongodb.backup.container: name the backup container of the cluster this environment runs on" }}
{{- end }}
{{- /* Production containers are named production*, and only production uses them: a container set for every environment
in helm/values.yaml fails here instead of silently stopping production backups. */}}
{{- if and $backup.enabled (ne $isProd (hasPrefix "production" $backup.container)) }}
{{- fail (printf "dependencyDeployments.mongodb.backup.container: %q does not match this environment; production backs up to a production* container, and no other environment does. Set it in helm/values.{env}.yaml" $backup.container) }}
{{- end }}
{{- $_ := set $backup "path" (printf "%s/%s/%s" $metaEnv $appStack $namespace) }}
{{- dict
  "name" $name
  "namespace" $namespace
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
