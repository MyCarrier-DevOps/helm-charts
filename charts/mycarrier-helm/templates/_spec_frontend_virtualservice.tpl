{{- define "helm.specs.multifrontend.virtualservice" -}}
{{- $frontendApps := .frontendApps }}
{{- $primaryApp := .primaryApp }}
{{- $domain := include "helm.domain" $ }}
{{- $domainPrefix := include "helm.domain.prefix" $ }}
{{- $namespace := include "helm.namespace" $ }}

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
    {{- if and $appValues.service $appValues.service.ports }}
    {{- range $appValues.service.ports }}
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ .port }}
    {{- end }}
    {{- else }}
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
    {{- end }}
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
  {{- if and $appValues.service $appValues.service.ports }}
  {{- range $appValues.service.ports }}
  - destination:
      host: {{ $fullName }}
      port:
        number: {{ .port }}
  {{- end }}
  {{- else }}
  - destination:
      host: {{ $fullName }}
      port:
        number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
  {{- end }}
  rewrite:
    uri: /
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

{{/* Handle path-based redirects for any frontend app */}}
{{- range $appName, $appValues := $frontendApps }}
{{- if and $appValues.networking $appValues.networking.istio $appValues.networking.istio.pathRedirects }}
{{- range $sourcePath, $targetPath := $appValues.networking.istio.pathRedirects }}
- name: {{ $appName }}-{{ $sourcePath | replace "/" "" }}-redirect
  match:
  - uri:
      exact: /{{ $sourcePath }}
  redirect:
    uri: /{{ $targetPath }}
{{- end }}
{{- end }}
{{- end }}

{{/* Catch-all route for the primary frontend app */}}
{{- if $primaryApp }}
{{- $primaryAppValues := index $frontendApps $primaryApp }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
- name: {{ $fullName }}-catchall
  route:
  - destination:
      host: {{ $fullName }}
      port:
        number: 80
  match:
  - uri:
      exact: /
  headers:
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
  {{- with $primaryAppValues.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  timeout: {{ default "151s" (dig "service" "timeout" nil $primaryAppValues) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" nil $primaryAppValues) }}
    attempts: {{ default 3 (dig "service" "attempts" nil $primaryAppValues) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" nil $primaryAppValues) }}
{{- end }}

{{/* Default/root route (primary frontend app) - must come last */}}
{{- if $primaryApp }}
{{- $primaryAppValues := index $frontendApps $primaryApp }}
{{- $primaryFullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
{{- $primaryIstioConfig := dig "networking" "istio" dict $primaryAppValues }}
{{- $primaryIstioEnabled := true }}
{{- if and $primaryIstioConfig (hasKey $primaryIstioConfig "enabled") }}
{{- $primaryIstioEnabled = $primaryIstioConfig.enabled }}
{{- end }}
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
  {{- if $primaryIstioEnabled }}
  headers:
    {{- if and (hasKey $primaryIstioConfig "responseHeaders") $primaryIstioConfig.responseHeaders }}
    {{- with $primaryIstioConfig.responseHeaders }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
    {{- else }}
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
    {{- end }}
  {{- with $primaryIstioConfig.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{- end }}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $primaryAppValues) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $primaryAppValues) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $primaryAppValues) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $primaryAppValues) }}
{{- end }}
{{- end -}}

{{- define "helm.specs.multifrontend.offload.virtualservice" -}}
{{- $frontendApps := .frontendApps }}
{{- $primaryApp := .primaryApp }}
{{- $domain := include "helm.domain" $ }}
{{- $domainPrefix := include "helm.domain.prefix" $ }}
{{- $namespace := include "helm.namespace" $ }}
{{- $primaryAppValues := .primaryAppValues }}
{{- $primaryFullName := .primaryFullName }}

hosts:
{{ if (not $primaryAppValues.staticHostname)}}- {{ (list (.Values.global.appStack) ("frontend")) | join "-" | lower | trunc 63 | trimSuffix "-" }}.{{ $domainPrefix }}.{{ $domain }}{{ end -}}
{{- if $primaryAppValues.staticHostname }}- {{ $primaryAppValues.staticHostname | trimSuffix "."}}.{{ $domain }}{{- end }}
gateways:
- mesh
- istio-system/default
http:
{{/* Path-based routing for feature environments */}}
{{- range $appName, $appValues := $frontendApps }}
{{- if and $appValues.routePrefix (ne $appValues.routePrefix "/") (not $appValues.isPrimary) }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $appName "application" $appValues) $) }}
- name: {{ $appName }}-offload-route
  match:
  - headers:
      Environment:
        exact: {{ .Values.environment.name }}
    uri:
      prefix: {{ $appValues.routePrefix }}
  route:
    {{- if and $appValues.service $appValues.service.ports }}
    {{- range $appValues.service.ports }}
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ .port }}
    {{- end }}
    {{- else }}
    - destination:
        host: {{ $fullName }}
        port:
          number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
    {{- end }}
{{- end }}
{{- end }}
{{/* Default route for primary app */}}
- name: {{ $primaryApp }}-offload-default
  route:
    {{- if and $primaryAppValues.service $primaryAppValues.service.ports }}
    {{- range $primaryAppValues.service.ports }}
    - destination:
        host: {{ $primaryFullName }}
        port:
          number: {{ .port }}
    {{- end }}
    {{- else }}
    - destination:
        host: {{ $primaryFullName }}
        port:
          number: {{ default 4200 (dig "ports" "http" nil $primaryAppValues) }}
    {{- end }}
  match:
    - headers:
        Environment:
          exact: {{ .Values.environment.name }}
{{- end -}}