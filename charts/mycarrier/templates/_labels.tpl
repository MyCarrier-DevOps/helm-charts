
{{- define "helm.labels.standard" -}}
{{- $envScaling := include "helm.envScaling" . -}}
{{- $namespace := include "helm.namespace" . }}
{{- $instance := include "helm.instance" . -}}
app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
app.kubernetes.io/part-of: {{ .Values.global.appStack}}
app.kubernetes.io/component: {{ .Values.application.name}}
app: {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
mycarrier.tech/environment: {{ .Values.global.environment.name }}
mycarrier.tech/envscaling: {{ $envScaling | quote }}
mycarrier.tech/envType: {{ (include "helm.envType" .) | quote }}
mycarrier.tech/service-namespace: {{ $namespace }}
mycarrier.tech/reference: {{ .Values.global.branchlabel | quote }}
{{- end -}}

{{- define "helm.labels.version" }}
version: {{- printf " %s" (.Values.application.version | default .Values.application.image.tag) | trunc 63 | trimSuffix "-" | trimAll "." }}
mycarrier/service-version: {{ .Values.application.image.tag }}
{{- end }}

{{- define "helm.labels.selector" -}}
{{- $instance := include "helm.instance" . -}}
app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
{{- end -}}

{{- define "helm.labels.custom" }}
    {{- range $key, $value := .Values.application.labels }}
      {{- (printf "%s: %s" $key (tpl $value $) ) | nindent 0 -}}
    {{- end }}
{{- end }}


{{- define "helm.labels.dependencies" -}}
{{ $metaenv := (include "helm.metaEnvironment" . ) }}
  {{- $secDict := dict -}}
  {{- $envDict := dict -}}
  {{- if .Values.secrets}}
    {{- if .Values.secrets.individual }}
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
      {{- else if or (contains "p44" (lower .envVarName)) (contains "p44" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.p44" "true"}}
      {{- else if or (contains "intercom" (lower .envVarName)) (contains "intercom" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.intercom" "true"}}
      {{- else if or (contains "loadsure" (lower .envVarName)) (contains "loadsure" (lower (.path | default ""))) }}
        {{ $_ := set $secDict "dependency.loadsure" "true"}}
      {{- else if or (contains "elastic" (lower .envVarName)) (contains "elastic" (lower (.path | default ""))) }}
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
  {{- if .Values.application.env }}
    {{- range $key, $value := .Values.application.env }}
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
