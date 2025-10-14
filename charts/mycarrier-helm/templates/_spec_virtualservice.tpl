{{- define "helm.specs.virtualservice" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $domain := include "helm.domain" $ }}
{{- $domainPrefix := include "helm.domain.prefix" $ }}
{{- $namespace := include "helm.namespace" $ }}
hosts:
- {{ $fullName }}
{{ if hasPrefix "feature" $.Values.environment.name }}- {{ $fullName }}.{{ $domainPrefix }}.{{ $domain }}{{ end -}}
{{ if and (not .application.staticHostname) (not (hasPrefix "feature" $.Values.environment.name))}}- {{ (list ($.Values.global.appStack) (.appName)) | join "-" | lower | trunc 63 | trimSuffix "-" }}.{{ $domainPrefix }}.{{ $domain }}{{ end -}}
{{ if and (.application.staticHostname) (not (hasPrefix "feature" $.Values.environment.name)) }}- {{ .application.staticHostname | trimSuffix "."}}.{{ $domain }}{{ end }}
gateways:
- mesh
- istio-system/default
http:
{{- if not (hasPrefix "feature" $.Values.environment.name) }}
- name: {{ $fullName }}
  route:
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ default 8080 (dig "ports" "http" nil .application) }}
  match:
    - headers:
        Environment:
          exact: {{ $.Values.environment.name }}
{{- end }}
{{- if and .application.networking .application.networking.istio .application.networking.istio.redirects }}
{{- range $key, $value := .application.networking.istio.redirects }}
- name: {{ $key }}
  match:
  - authority:
      prefix: {{ if and (not (contains "prod" $namespace)) ( not $.application.staticHostname) }}{{ $namespace }}-{{ end }}{{ $key }}.{{ $domain }}
  redirect:
    uri: /
    authority: {{ if and (not (contains "prod" $namespace)) ( not $.application.staticHostname) }}{{ $namespace }}-{{ end }}{{ $value }}.{{ $domain }}
{{- end }}
{{- end }}
{{- if and .application.networking .application.networking.istio .application.networking.istio.routes }}
{{- range $key, $value := .application.networking.istio.routes }}
- name: {{ $key }}
  {{- toYaml $value | nindent 2 }}
  route:
  - destination:
      host: {{ $key }}
      port:
        number: 80
  headers:
    {{- if and $.application.networking.istio.responseHeaders -}}
    {{- with $.application.networking.istio.responseHeaders -}}
    {{ toYaml . | indent 4 | trim -}}
    {{- end -}}
    {{- else }}
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
    {{- end }}
  {{- with $.application.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml $ | indent 4 | trim }}
  {{- end }}
  {{/* Safely access service properties with default values if not defined */}}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $.application) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $.application) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $.application) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $.application) }}
{{- end }}
{{- end }}


{{- $hasAllowedEndpoints := false -}}
{{- if and .application.networking .application.networking.istio (hasKey .application.networking.istio "allowedEndpoints") -}}
  {{/* Check if there are user-defined endpoints or language defaults */}}
  {{- $langEndpointsYaml := include "helm.lang.endpoint.list" . -}}
  {{- if or .application.networking.istio.allowedEndpoints $langEndpointsYaml -}}
    {{- $hasAllowedEndpoints = true -}}
  {{- end -}}
{{- end -}}

{{ if $hasAllowedEndpoints -}}
{{/* Use centralized helper template for endpoint rules generation */}}
{{ include "helm.virtualservice.allowedEndpoints" . }}
{{- else }}
- name: {{ if (eq .application.deploymentType "rollout")  }}canary{{ else }}{{ $fullName }}{{- end }}
  route:
  {{- if and .application.service .application.service.ports }}
  {{- range .application.service.ports }}
  - destination:
      host: {{ $fullName }}
      port:
        number: {{ .port }}
    weight: 100
  {{- if (eq $.application.deploymentType "rollout")  }}
  - destination:
      host: {{ $fullName }}-preview
      port:
        number: {{ .port }}
    weight: 0
  {{- end }}
  {{- end }}
  {{- else }}
  - destination:
      host: {{ $fullName }}
      port:
        number: {{ default 8080 (dig "ports" "http" nil .application) }}
    weight: 100
  {{- if (eq .application.deploymentType "rollout")  }}
  - destination:
      host: {{ $fullName }}-preview
      port:
        number: {{ default 8080 (dig "ports" "http" nil .application) }}
    weight: 0
  {{- end }}
  {{- end }}
  {{- if and .application.networking .application.networking.istio }}
  {{- if .application.networking.istio.enabled }}
  headers:
    {{- if .application.networking }}
    {{- if and .application.networking.istio.responseHeaders }}
    {{- with .application.networking.istio.responseHeaders }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
    {{- else }}
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
    {{- end }}
    {{- end }}
  {{- with .application.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{- end }}
  {{- end }}
  {{/* Safely access service properties with default values if not defined */}}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" .application) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" .application) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 .application) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" .application) }}
{{- end }}
{{- end -}}