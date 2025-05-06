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
timeout: {{ default "151s" .timeout }}
retries:
  retryOn: {{ default "5xx,reset" .retryOn }}
  attempts: {{ default 3 .attempts }}
  perTryTimeout: {{ default "50s" .perTryTimeout }}
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