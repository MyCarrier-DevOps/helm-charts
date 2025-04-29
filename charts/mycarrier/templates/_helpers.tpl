{{- define "helm.domain" -}}
{{- if .Values.environment.domainOverride.enabled }}
{{- .Values.environment.domainOverride.domain }}
{{- else }}
{{- hasPrefix "prod" .Values.environment.name | ternary "mycarriertms.com" "mycarrier.dev" }}
{{- end }}
{{- end -}}

{{- define "helm.domain.prefix" -}}
{{ $metaenv := (include "helm.metaEnvironment" . ) }}
{{- hasPrefix "prod" .Values.environment.name | ternary "api" $metaenv }}
{{- end -}}

{{- define "helm.namespace" -}}
{{- if hasPrefix "feature" .Values.environment.name }}
{{- (list ("dev") (.Values.global.appStack)) | join "-" | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- (list (.Values.environment.name) (.Values.global.appStack)) | join "-" | lower | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end -}}

{{- define "helm.fullname" -}}
{{- if hasPrefix "feature" .Values.environment.name }}
{{- default (list (.Values.global.appStack) (.Values.application.name) (.Values.environment.name)) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- else }}
{{- default (list (.Values.global.appStack) (.Values.application.name)) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- end }}
{{- end -}}

{{- define "helm.instance" -}}
{{- default (list (.Values.global.appStack) (.Values.application.name) (.Values.environment.name)) | join "-" | lower | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "helm.envScaling" -}}
{{- $envList := list "dev" "preprod" }}
{{- if and (or (has .Values.environment.name $envList) (hasPrefix "feature" .Values.environment.name) ) (not .Values.global.forceAutoscaling) }}{{ 0 }}{{ else }}{{ 1 }}{{ end }}
{{- end -}}

{{- define "helm.annotations.istio" -}}
{{- if .Values.service }}
proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
{{- if .Values.service.istioDisabled }}
sidecar.istio.io/inject: 'false'
{{- else }}
sidecar.istio.io/inject: 'true'
{{- end }}
{{- else }}
sidecar.istio.io/inject: 'true'
{{- end }}
{{- end -}}

# {{- if hasPrefix "prod" .Values.environment.name }}
# external-dns.alpha.kubernetes.io/target: {{ include "helm.ingressDomain" . }}
# {{- else }}
# external-dns.alpha.kubernetes.io/target: dev-ingress.{{ include "helm.ingressDomain" . }} 
# {{- end }}
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
    memory: {{ dig "resources" "requests" "memory" "64Mi" (default .Values.application) }}
  limits:
    cpu: {{ dig "resources" "limits" "cpu" "2000m" (default .Values.application) }}
    memory: {{ dig "resources" "limits" "memory" "2048Mi" (default .Values.application) }}
{{- end -}}


{{- define "helm.podDefaultNodeSelector" -}}
{{- with (dig "nodeSelector" "" (default .Values.application )) }}
nodeSelector:
  {{ toYaml . |  indent 2 | trim }}
{{- end }}
{{- end -}}

{{- define "helm.podDefaultPriorityClassName" -}}
{{- with (dig "priorityClassName" "" (default .Values.application )) }}
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

