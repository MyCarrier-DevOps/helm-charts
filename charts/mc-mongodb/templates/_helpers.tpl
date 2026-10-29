{{/*
Chart name.
*/}}
{{- define "mc-mongodb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name. Truncated to 44 so <fullname>-restore stays within the 52 characters Kubernetes allows a CronJob, and the
longest derived name, <fullname>-restore-connection, within 63.
*/}}
{{- define "mc-mongodb.fullname" -}}
{{- $name := "" }}
{{- if .Values.fullnameOverride }}
{{- $name = .Values.fullnameOverride }}
{{- else }}
{{- $chart := default .Chart.Name .Values.nameOverride }}
{{- if contains $chart .Release.Name }}
{{- $name = .Release.Name }}
{{- else }}
{{- $name = printf "%s-%s" .Release.Name $chart }}
{{- end }}
{{- end }}
{{- $name | trunc 44 | trimSuffix "-" }}
{{- end }}

{{- define "mc-mongodb.labels" -}}
app.kubernetes.io/name: {{ include "mc-mongodb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Render context: the only input the resource templates read. mycarrier-helm builds the same dict itself.
Usage: include "mc-mongodb.context" . | fromJson
*/}}
{{- define "mc-mongodb.context" -}}
{{- $name := include "mc-mongodb.fullname" . }}
{{- $v := .Values }}
{{- $backup := deepCopy $v.backup }}
{{- $_ := set $backup "path" (default (printf "%s/%s" .Release.Namespace $name) $v.backup.path) }}
{{- dict
  "name" $name
  "namespace" .Release.Namespace
  "labels" (include "mc-mongodb.labels" . | fromYaml)
  "members" $v.members
  "version" $v.version
  "featureCompatibilityVersion" $v.featureCompatibilityVersion
  "storage" $v.storage
  "resources" $v.resources
  "appUser" (dict "name" $v.appUser.name "database" (default $name $v.appUser.database))
  "password" $v.password
  "backup" $backup
  | toJson }}
{{- end }}
