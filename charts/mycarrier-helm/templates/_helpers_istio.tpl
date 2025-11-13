{{/*
Istio helper functions to provide consistent Istio configuration.
This file contains all Istio-related helpers for consistent rendering of
Istio resources and configs.
*/}}

{{/*
Provide consistent response headers for Istio VirtualServices
*/}}
{{- define "helm.istio.responseHeaders" -}}
response:
  headers:
    add:
      - name: Strict-Transport-Security
        value: "max-age=31536000; includeSubDomains; preload"
      - name: X-Frame-Options
        value: SAMEORIGIN
      - name: X-XSS-Protection
        value: "1; mode=block"
      - name: X-Content-Type-Options
        value: nosniff
      - name: Referrer-Policy
        value: no-referrer-when-downgrade
{{- end -}}

{{/*
Annotations for Istio VirtualServices
*/}}
{{- define "helm.istio.annotations" -}}
istio.io/managed: "true"
{{- end -}}

{{/*
Default CORS policy for Istio resources
*/}}
{{- define "helm.istio.corsPolicy" -}}
allowOrigins:
  - exact: "*"
allowMethods:
  - GET
  - POST
  - PUT
  - DELETE
  - PATCH
  - OPTIONS
allowHeaders:
  - content-type
  - authorization
  - x-requested-with
  - x-forwarded-for
  - x-forwarded-proto
maxAge: "24h"
allowCredentials: true
{{- end -}}

{{/*
Default timeout settings for Istio routes
*/}}
{{- define "helm.istio.timeouts" -}}
{{- $serviceDefaults := dict -}}
{{- if and .root .root.ctx -}}
  {{- $serviceDefaults = .root.ctx.chartDefaults.service -}}
{{- else if .ctx -}}
  {{- $serviceDefaults = .ctx.chartDefaults.service -}}
{{- else -}}
  {{- $serviceDefaults = (include "helm.chartDefaults.raw" . | fromJson).service -}}
{{- end -}}
timeout: {{ default $serviceDefaults.timeout .timeout }}
retries:
  retryOn: {{ default $serviceDefaults.retryOn .retryOn }}
  attempts: {{ default $serviceDefaults.attempts .attempts }}
  perTryTimeout: {{ default $serviceDefaults.perTryTimeout .perTryTimeout }}
{{- end -}}

{{/*
Default destination settings for Istio routes
*/}}
{{- define "helm.istio.destination" -}}
destination:
  host: {{ .host }}
  port:
    number: {{ .port }}
{{- end -}}