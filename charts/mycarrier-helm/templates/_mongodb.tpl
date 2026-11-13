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
MONGODB_URI for a container of a stack that deploys the in-cluster MongoDB: the connection string, read from the
connection Secret, whatever global.language is. dependencyDeployments.mongodb.enabled alone turns it on. A container
whose own env (.env, a map keyed by variable name) sets MONGODB_URI keeps that value, and the name renders once.
Usage: include "helm.mongodb.env" (dict "root" $ "env" <the container's own env>)
*/}}
{{- define "helm.mongodb.env" -}}
{{- if and (include "helm.mongodb.enabled" .root) (not (hasKey (.env | default dict) "MONGODB_URI")) }}
- name: MONGODB_URI
  valueFrom:
    secretKeyRef:
      name: {{ include "helm.mongodb.name" .root }}-connection
      key: connectionString
{{- end }}
{{- end -}}

{{/*
Annotations for kube-linter, chart-renderer's render check, on a workload whose containers read the connection Secret
through an env var: MONGODB_URI above, the csharp MongoConnection_<env>, or a stack's own secretKeyRef. kube-linter
finds no such Secret in the render, because an ExternalSecret creates it in the cluster (env-value-from), and refuses a
Secret read through an env var (read-secret-from-env-var). An ignore covers the whole object, so it renders only when
the stack deploys MongoDB and .spec, the workload's rendered spec (a Deployment's, a StatefulSet's or a CronJob's),
has such a reference; every other workload stays linted. A key the object's own annotations (.annotations, optional)
already set keeps that value and is left out here, so it renders once.
Usage: include "helm.mongodb.lintIgnores" (dict "root" $ "spec" $spec "annotations" <the object's own annotations>)
*/}}
{{- define "helm.mongodb.lintIgnores" -}}
{{- if include "helm.mongodb.enabled" .root }}
{{- $secret := printf "%s-connection" (include "helm.mongodb.name" .root) }}
{{- $spec := .spec | fromYaml }}
{{- $podSpec := dig "template" "spec" dict (dig "jobTemplate" "spec" $spec $spec) }}
{{- $reads := false }}
{{- range concat ($podSpec.initContainers | default list) ($podSpec.containers | default list) }}
{{- range .env | default list }}
{{- if eq (dig "valueFrom" "secretKeyRef" "name" "" .) $secret }}
{{- $reads = true }}
{{- end }}
{{- end }}
{{- end }}
{{- if $reads }}
{{- $ignores := dict
  "ignore-check.kube-linter.io/env-value-from" (printf "reads Secret %s, which the in-cluster MongoDB's ExternalSecret creates in the cluster; the render holds no Secret" $secret)
  "ignore-check.kube-linter.io/read-secret-from-env-var" "the in-cluster MongoDB's connection string exists only as a key of that Secret, and the containers read it from an env var" }}
{{- $own := .annotations | default dict }}
{{- range $check, $reason := $ignores }}
{{- if not (hasKey $own $check) }}
{{ $check }}: {{ $reason | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
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
