{{- define "helm.labels.standard" -}}
{{/* Get standardized context with defaults */}}
{{- $ctx := fromJson (include "helm.default-context" .) -}}
{{- $envScaling := include "helm.envScaling" . -}}
{{- $namespace := include "helm.namespace" . -}}
{{- $instance := include "helm.instance" . -}}

{{/* Extract values from context */}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}
{{- $branchLabel := $ctx.defaults.branchLabel -}}

{{/* Get app name - first try .appName, then from application if present */}}
{{- $appName := .appName | default "" -}}

app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
app.kubernetes.io/part-of: {{ $appStack }}
app.kubernetes.io/component: {{ $appName | quote | default "" }}
app: {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
mycarrier.tech/environment: {{ $envName }}
mycarrier.tech/envscaling: {{ $envScaling | quote }}
mycarrier.tech/envType: {{ (include "helm.envType" .) | quote }}
mycarrier.tech/service-namespace: {{ $namespace }}
mycarrier.tech/reference: {{ $branchLabel | quote }}
{{- end -}}

{{- define "helm.labels.version" }}
{{- $version := "" -}}
{{- if and (hasKey . "application") .application -}}
  {{- if .application.version -}}
    {{- if kindIs "map" .application.version -}}
      {{- $version = index .application.version "tag" | default "" -}}
    {{- else -}}
      {{- $version = .application.version -}}
    {{- end -}}
  {{- else if .application.image -}}
    {{- if kindIs "map" .application.image -}}
      {{- $version = .application.image.tag | default "" -}}
    {{- end -}}
  {{- end -}}
{{- else if .job -}}
  {{- if .job.version -}}
    {{- $version = .job.version -}}
  {{- else if .job.image -}}
    {{- if kindIs "map" .job.image -}}
      {{- $version = .job.image.tag | default "" -}}
    {{- else -}}
      {{- $version = .job.image | default "" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
version: {{- printf " %s" $version | trunc 63 | trimSuffix "-" | trimAll "." }}
mycarrier/service-version: {{ $version }}
{{- end }}

{{- define "helm.labels.selector" -}}
{{- $instance := include "helm.instance" . -}}
app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
{{- end -}}

{{- define "helm.labels.custom" }}
    {{- range $key, $value := dig "labels" (dict) .application }}
      {{- (printf "%s: %s" $key (tpl (toString $value) $) ) | nindent 0 -}}
    {{- end }}
{{- end }}

{{- define "helm.labels.dependencies" -}}
{{ $metaenv := (include "helm.metaEnvironment" . ) }}
  {{- $secDict := dict -}}
  {{- $envDict := dict -}}
  {{- if $.Values.global.dependencies.azservicebus -}}
  {{ $_ := set $secDict "dependency.azservicebus" "true"}}
  {{- end -}}
  {{- if $.Values.global.dependencies.mongodb }}
  {{ $_ := set $secDict "dependency.mongo" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.redis)}}
  {{ $_ := set $secDict "dependency.redis" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.postgres) }}
  {{ $_ := set $secDict "dependency.postgres" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.sqlserver) }}
  {{ $_ := set $secDict "dependency.sqlserver" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.clickhouse) }}
  {{ $_ := set $secDict "dependency.clickhouse" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.redpanda) }}
  {{ $_ := set $secDict "dependency.redpanda" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.loadsure) }}
  {{ $_ := set $secDict "dependency.loadsure" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.elasticsearch) }}
  {{ $_ := set $secDict "dependency.elasticsearch" "true"}}
  {{- end -}}
  {{- if ($.Values.global.dependencies.chargify) }}
  {{ $_ := set $secDict "dependency.chargify" "true"}}
  {{- end -}}
  {{- if and .Values (hasKey .Values "secrets") -}}
    {{- if and .Values.secrets (hasKey .Values.secrets "individual") -}}
      {{- range .Values.secrets.individual }}
      {{- if or (contains "servicebus" (lower .envVarName)) (contains "servicebus" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.azservicebus" "true"}}
      {{- else if or (contains "splitio" (lower .envVarName)) (contains "splitio" (lower (.path | default ""))) }}
        {{- if or (contains "proxy" (lower .envVarName)) (contains "proxy" (lower (.path | default ""))) -}}
          {{ $_ := set $secDict "dependency.splitproxy" "true"}}
        {{- else -}}
          {{ $_ := set $secDict "dependency.split" "true"}}
        {{- end -}}
      {{- else if or (contains "mongo" (lower .envVarName)) (contains "mongo" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.mongo" "true"}}
      {{- else if or (contains "redis" (lower .envVarName)) (contains "redis" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.redis" "true"}}
      {{- else if or (contains "postgres" (lower .envVarName)) (contains "postgres" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.postgres" "true"}}
      {{- else if or (contains "sqlserver" (lower .envVarName)) (contains "sqlserver" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.sqlserver" "true"}}
      {{- else if or (contains "clickhouse" (lower .envVarName)) (contains "clickhouse" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.clickhouse" "true"}}
      {{- else if or (contains "redpanda" (lower .envVarName)) (contains "redpanda" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.redpanda" "true"}}
      {{- else if or (contains "intercom" (lower .envVarName)) (contains "intercom" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.intercom" "true"}}
      {{- else if or (contains "loadsure" (lower .envVarName)) (contains "loadsure" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.loadsure" "true"}}
      {{- else if or (contains "elastic" (lower .envVarName)) (contains "elastic" (lower (.path | default "")))}}
        {{ $_ := set $secDict "dependency.elasticsearch" "true"}}
      {{- else if or (contains "smc" (lower .envVarName)) (contains "smc" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.smc" "true"}}
      {{- else if or (contains "chargify" (lower .envVarName)) (contains "chargify" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.chargify" "true"}}
      {{- else if or (contains "snowflake" (lower .envVarName)) (contains "snowflake" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.snowflake" "true"}}
      {{- else if or (contains "sigma" (lower .envVarName)) (contains "sigma" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.sigma" "true"}}
      {{- end }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if and (hasKey . "application") .application (hasKey .application "env") -}}
    {{- range $key, $value := .application.env }}
      {{- if (contains "servicebus" (lower $key)) }}
        {{ $_ := set $envDict "dependency.azservicebus" "true"}}
      {{- else if (contains "splitio" (lower $key)) }}
        {{- if (contains "proxy" (lower $key)) -}}
          {{ $_ := set $envDict "dependency.splitproxy" "true"}}
        {{- else -}}
          {{ $_ := set $envDict "dependency.split" "true"}}
        {{- end -}}
      {{- else if (contains "Mongo" (lower $key)) }}
        {{ $_ := set $envDict "dependency.mongodb" "true"}}
      {{- else if (contains "p44" (lower $key)) }}
        {{ $_ := set $envDict "dependency.p44" "true"}}
      {{- else if (contains "strivacity" (lower $key)) }}
        {{ $_ := set $envDict "dependency.strivacity" "true"}}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- $labelDict := mergeOverwrite $envDict $secDict -}}
  {{- range $key, $value := $labelDict -}}
  {{ $key | nindent 0 }}: {{ $value | quote}}
  {{- end }}
{{- end }}
