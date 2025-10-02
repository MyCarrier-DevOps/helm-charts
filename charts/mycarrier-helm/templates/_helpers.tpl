{{- define "helm.domain" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}

{{- if and .Values.environment (hasKey .Values.environment "domainOverride") (hasKey .Values.environment.domainOverride "enabled") -}}
  {{- if .Values.environment.domainOverride.enabled -}}
    {{- .Values.environment.domainOverride.domain -}}
  {{- else -}}
    {{- hasPrefix "prod" $envName | ternary "mycarriertms.com" "mycarrier.dev" -}}
  {{- end -}}
{{- else -}}
  {{- hasPrefix "prod" $envName | ternary "mycarriertms.com" "mycarrier.dev" -}}
{{- end -}}
{{- end -}}

{{- define "helm.domain.prefix" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $metaenv := (include "helm.metaEnvironment" . ) -}}

{{- hasPrefix "prod" $envName | ternary "api" $metaenv -}}
{{- end -}}

{{- define "helm.namespace" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}

{{- if hasPrefix "feature" $envName }}
{{- (list ("dev") $appStack) | join "-" | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- (list $envName $appStack) | join "-" | lower | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end -}}

{{- define "helm.fullname" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}

{{/* Get app name - first try .appName, then from application if present */}}
{{- $appName := .appName | default "" -}}
{{- if not $appName -}}
  {{- if and .Values .Values.application .Values.application.name -}}
    {{- $appName = .Values.application.name -}}
  {{- end -}}
{{- end -}}

{{- if hasPrefix "feature" $envName }}
{{- (list $appStack $appName $envName) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- else }}
{{- (list $appStack $appName) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- end }}
{{- end -}}

{{- define "helm.basename" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}

{{/* Get app name - first try .appName, then from application if present */}}
{{- $appName := .appName | default "" -}}
{{- if not $appName -}}
  {{- if and .Values .Values.application .Values.application.name -}}
    {{- $appName = .Values.application.name -}}
  {{- end -}}
{{- end -}}
{{- (list $appStack $appName) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "helm.instance" -}}
{{/* Get standardized context with defaults - use cached version if available */}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}

{{/* Get app name - first try .appName, then from application if present */}}
{{- $appName := .appName | default "" -}}
{{- if not $appName -}}
  {{- if and .Values .Values.application .Values.application.name -}}
    {{- $appName = .Values.application.name -}}
  {{- end -}}
{{- end -}}

{{- (list $appStack $appName $envName) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "helm.envScaling" -}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $forceAutoscaling := $ctx.defaults.forceAutoscaling -}}

{{- $envList := list "dev" "preprod" -}}
{{- if and (or (has $envName $envList) (hasPrefix "feature" $envName)) (not $forceAutoscaling) -}}
  {{- 0 -}}
{{- else -}}
  {{- 1 -}}
{{- end -}}
{{- end -}}

{{- define "helm.annotations.istio" -}}
{{- if .application.istioDisabled }}
sidecar.istio.io/inject: 'false'
{{- else }}
proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
sidecar.istio.io/inject: 'true'
{{- end -}}
{{- end -}}

{{- define "helm.annotations.virtualservice" -}}
external-dns.alpha.kubernetes.io/cloudflare-proxied: 'false'
{{- end -}}

{{- define "helm.istioIngress.responseHeaders" -}}
response:
  set:
    X-Frame-Options: "DENY"
    X-XSS-Protection: "1; mode=block"
    X-Content-Type-Options: "nosniff"
    Referrer-Policy: "origin-when-cross-origin"
    Strict-Transport-Security: "max-age=7884000; includeSubDomains; preload"
    Content-Security-Policy: "default-src https: 'unsafe-eval' 'unsafe-inline' blob: data: wss:; object-src 'none'; img-src http://*.osm.org https: data: blob:;"
{{- end -}}

{{- define "helm.resources" -}}
resources:
  requests:
    cpu: 50m
    memory: {{ dig "resources" "requests" "memory" "64Mi" .application }}
  limits:
    cpu: {{ dig "resources" "limits" "cpu" "2000m" .application }}
    memory: {{ dig "resources" "limits" "memory" "2048Mi" .application }}
{{- end -}}

{{- define "helm.podDefaultNodeSelector" -}}
{{- with (dig "nodeSelector" "" .application) }}
nodeSelector:
  {{ toYaml . |  indent 2 | trim }}
{{- end }}
{{- end -}}

{{- define "helm.podDefaultPriorityClassName" -}}
{{- with (dig "priorityClassName" "" .application) }}
priorityClassName: {{ toYaml . |  indent 2 | trim }}
{{- end }}
{{- end -}}

{{- define "helm.selectorExpressions" -}}
{{- $instance := include "helm.instance" . -}}
- key: app.kubernetes.io/name
  operator: In
  values: 
    - {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
- key: app.kubernetes.io/instance
  operator: In
  values: 
    - {{ $instance | trunc 63 }} 
{{- end -}}

{{/* 
Create loop context for multiple applications
Usage: 
{{- range $appName, $appValues := .Values.applications }}
{{- $appContext := (merge (dict "appName" $appName "application" $appValues) $) }}
{{- include "helm.template-name" $appContext }}
{{- end }}
*/}}
{{- define "helm.apps.loop" -}}
{{- range $appName, $appValues := .Values.applications }}
{{- $appContext := (merge (dict "appName" $appName "application" $appValues) $) }}
{{ include . $appContext }}
{{- end }}
{{- end -}}


{{- define "helm.deployment" -}}
{{ .Values.deployment | default "deployment" }}
{{- end -}}