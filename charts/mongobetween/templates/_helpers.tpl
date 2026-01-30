{{/*
Expand the name of the chart.
*/}}
{{- define "mongobetween.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mongobetween.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mongobetween.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongobetween.labels" -}}
helm.sh/chart: {{ include "mongobetween.chart" . }}
{{ include "mongobetween.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongobetween.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongobetween.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mongobetween.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mongobetween.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Dragonfly fullname
*/}}
{{- define "mongobetween.dragonflyName" -}}
{{- printf "%s-dragonfly" (include "mongobetween.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Dragonfly connection URL
*/}}
{{- define "mongobetween.dragonflyUrl" -}}
{{- if .Values.dragonfly.enabled }}
{{- printf "%s.%s.svc.cluster.local:6379" (include "mongobetween.dragonflyName" .) .Release.Namespace }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
MongoDB URI with pool tuning parameters
*/}}
{{- define "mongobetween.mongodbUri" -}}
{{- $uri := .Values.mongodb.uri }}
{{- if $uri }}
{{- $separator := "?" }}
{{- if contains "?" $uri }}
{{- $separator = "&" }}
{{- end }}
{{- printf "%s%sminPoolSize=%d&maxPoolSize=%d&maxConnecting=%d&maxIdleTimeMS=%d&connectTimeoutMS=%d&serverSelectionTimeoutMS=%d&heartbeatFrequencyMS=%d" $uri $separator (int .Values.poolTuning.minPoolSize) (int .Values.poolTuning.maxPoolSize) (int .Values.poolTuning.maxConnecting) (int .Values.poolTuning.maxIdleTimeMS) (int .Values.poolTuning.connectTimeoutMS) (int .Values.poolTuning.serverSelectionTimeoutMS) (int .Values.poolTuning.heartbeatFrequencyMS) }}
{{- end }}
{{- end }}

{{/*
Get the MongoDB URI secret name
*/}}
{{- define "mongobetween.mongodbSecretName" -}}
{{- if .Values.mongodb.existingSecret }}
{{- .Values.mongodb.existingSecret }}
{{- else }}
{{- printf "%s-mongodb" (include "mongobetween.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get the MongoDB URI secret key
*/}}
{{- define "mongobetween.mongodbSecretKey" -}}
{{- if .Values.mongodb.existingSecret }}
{{- .Values.mongodb.existingSecretKey }}
{{- else }}
{{- "uri" }}
{{- end }}
{{- end }}

{{/*
Proxy listen address
*/}}
{{- define "mongobetween.proxyAddress" -}}
{{- printf "%s:%d" .Values.proxy.address (int .Values.proxy.port) }}
{{- end }}

{{/*
Health check address
*/}}
{{- define "mongobetween.healthAddress" -}}
{{- printf ":%d" (int .Values.health.port) }}
{{- end }}
