{{- define "helm.specs.multifrontend.virtualservice" -}}
{{- $frontendApps := dict }}
{{- $primaryApp := "" }}
{{- $domain := include "helm.domain" $ }}
{{- $domainPrefix := include "helm.domain.prefix" $ }}
{{- $namespace := include "helm.namespace" $ }}

{{/* Collect all frontend applications */}}
{{- range $appName, $appValues := .Values.applications }}
{{- if $appValues.isFrontend }}
{{- $_ := set $frontendApps $appName $appValues }}
{{- if $appValues.isPrimary }}
{{- $primaryApp = $appName }}
{{- end }}
{{- end }}
{{- end }}

hosts:
{{/* Generate hosts from primary frontend app */}}
{{- if $primaryApp }}
{{- $primaryAppValues := index $frontendApps $primaryApp }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
- {{ $fullName }}
{{- if hasPrefix "feature" $.Values.environment.name }}
- {{ $fullName }}.{{ $domainPrefix }}.{{ $domain }}
{{- end }}
{{- if and (not $primaryAppValues.staticHostname) (not (hasPrefix "feature" $.Values.environment.name)) }}
- {{ (list ($.Values.global.appStack) ("frontend")) | join "-" | lower | trunc 63 | trimSuffix "-" }}.{{ $domainPrefix }}.{{ $domain }}
{{- end }}
{{- if and ($primaryAppValues.staticHostname) (not (hasPrefix "feature" $.Values.environment.name)) }}
- {{ $primaryAppValues.staticHostname | trimSuffix "."}}.{{ $domain }}
{{- end }}
{{- end }}

gateways:
- mesh
- istio-system/default

http:
{{- if not (hasPrefix "feature" $.Values.environment.name) }}
{{/* Environment header matching for non-feature environments */}}
{{- range $appName, $appValues := $frontendApps }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $appName "application" $appValues) $) }}
- name: {{ $fullName }}-env-match
  route:
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
  match:
    - headers:
        Environment:
          exact: {{ $.Values.environment.name }}
{{- if and $appValues.routePrefix (ne $appValues.routePrefix "/") }}
      uri:
        prefix: {{ $appValues.routePrefix }}
{{- end }}
{{- end }}
{{- end }}

{{/* Path-based routing rules - order matters (most specific first) */}}
{{- range $appName, $appValues := $frontendApps }}
{{- if and $appValues.routePrefix (ne $appValues.routePrefix "/") (not $appValues.isPrimary) }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $appName "application" $appValues) $) }}
- name: {{ $appName }}-path-route
  match:
  - uri:
      prefix: {{ $appValues.routePrefix }}
  route:
  - destination:
      host: {{ $fullName }}
      port:
        number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
  headers:
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
  {{- with $appValues.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{/* Safely access service properties with default values if not defined */}}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $appValues) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $appValues) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $appValues) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $appValues) }}
{{- end }}
{{- end }}

{{/* Handle custom routes for any frontend app */}}
{{- range $appName, $appValues := $frontendApps }}
{{- if and $appValues.networking $appValues.networking.istio $appValues.networking.istio.routes }}
{{- range $key, $value := $appValues.networking.istio.routes }}
- name: {{ $key }}-custom-route
  {{- toYaml $value | nindent 2 }}
  route:
  - destination:
      host: {{ $key }}
      port:
        number: 80
  headers:
    {{- if and $appValues.networking.istio.responseHeaders }}
    {{- with $appValues.networking.istio.responseHeaders }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
    {{- else }}
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
    {{- end }}
  {{- with $appValues.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $appValues) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $appValues) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $appValues) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $appValues) }}
{{- end }}
{{- end }}
{{- end }}

{{/* Handle redirects for any frontend app */}}
{{- range $appName, $appValues := $frontendApps }}
{{- if and $appValues.networking $appValues.networking.istio $appValues.networking.istio.redirects }}
{{- range $key, $value := $appValues.networking.istio.redirects }}
- name: {{ $key }}-redirect
  match:
  - authority:
      prefix: {{ if and (not (contains "prod" $namespace)) (not $appValues.staticHostname) }}{{ $namespace }}-{{ end }}{{ $key }}.{{ $domain }}
  redirect:
    uri: /
    authority: {{ if and (not (contains "prod" $namespace)) (not $appValues.staticHostname) }}{{ $namespace }}-{{ end }}{{ $value }}.{{ $domain }}
{{- end }}
{{- end }}
{{- end }}

{{/* Default/root route (primary frontend app) - must come last */}}
{{- if $primaryApp }}
{{- $primaryAppValues := index $frontendApps $primaryApp }}
{{- $primaryFullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
- name: {{ if (eq $primaryAppValues.deploymentType "rollout") }}canary{{ else }}{{ $primaryApp }}-default{{ end }}
  {{- if not (eq $primaryAppValues.routePrefix "/") }}
  match:
  - uri:
      prefix: {{ default "/" $primaryAppValues.routePrefix }}
  {{- end }}
  route:
  {{- if and $primaryAppValues.service $primaryAppValues.service.ports }}
  {{- range $primaryAppValues.service.ports }}
  - destination:
      host: {{ $primaryFullName }}
      port:
        number: {{ .port }}
    weight: 100
  {{- if (eq $primaryAppValues.deploymentType "rollout") }}
  - destination:
      host: {{ $primaryFullName }}-preview
      port:
        number: {{ .port }}
    weight: 0
  {{- end }}
  {{- end }}
  {{- else }}
  - destination:
      host: {{ $primaryFullName }}
      port:
        number: {{ default 4200 (dig "ports" "http" nil $primaryAppValues) }}
    weight: 100
  {{- if (eq $primaryAppValues.deploymentType "rollout") }}
  - destination:
      host: {{ $primaryFullName }}-preview
      port:
        number: {{ default 4200 (dig "ports" "http" nil $primaryAppValues) }}
    weight: 0
  {{- end }}
  {{- end }}
  {{- if and $primaryAppValues.networking $primaryAppValues.networking.istio }}
  {{- if $primaryAppValues.networking.istio.enabled }}
  headers:
    {{- if $primaryAppValues.networking }}
    {{- if and $primaryAppValues.networking.istio.responseHeaders }}
    {{- with $primaryAppValues.networking.istio.responseHeaders }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
    {{- else }}
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
    {{- end }}
    {{- end }}
  {{- with $primaryAppValues.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{- end }}
  {{- end }}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $primaryAppValues) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $primaryAppValues) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $primaryAppValues) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $primaryAppValues) }}
{{- end }}
{{- end -}}