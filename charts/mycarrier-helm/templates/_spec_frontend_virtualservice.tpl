{{- define "helm.specs.multifrontend.virtualservice" -}}
{{- $frontendApps := .frontendApps }}
{{- $primaryApp := .primaryApp }}
{{- $domain := include "helm.domain" $ }}
{{- $domainPrefix := include "helm.domain.prefix" $ }}
{{- $namespace := include "helm.namespace" $ }}
{{- $metaenv := include "helm.metaEnvironment" $ }}
{{- $envName := $.Values.environment.name -}}
{{- $isFeatureEnv := hasPrefix "feature" $envName -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $serviceDefaults := $ctx.chartDefaults.service -}}

hosts:
{{/* Generate hosts from primary frontend app */}}
{{- if $primaryApp }}
{{- $primaryAppValues := index $frontendApps $primaryApp }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
{{- $baseFullName := include "helm.basename" (merge (dict "appName" $primaryApp "application" $primaryAppValues) $) }}
- {{ $fullName }}
{{- if $metaenv }}
- {{ $baseFullName }}.{{ $metaenv }}.internal
{{- end }}
{{- if $isFeatureEnv }}
- {{ $fullName }}.{{ $domainPrefix }}.{{ $domain }}
{{- end }}
{{- if and (not $primaryAppValues.staticHostname) (not $isFeatureEnv) }}
- {{ (list ($.Values.global.appStack) ("frontend")) | join "-" | lower | trunc 63 | trimSuffix "-" }}.{{ $domainPrefix }}.{{ $domain }}
{{- end }}
{{- if and ($primaryAppValues.staticHostname) (not $isFeatureEnv) }}
- {{ $primaryAppValues.staticHostname | trimSuffix "."}}.{{ $domain }}
{{- end }}
{{- end }}

gateways:
- mesh
- istio-system/default

http:
{{- if not $isFeatureEnv }}
{{/* Environment header matching for non-feature environments */}}
{{- range $appName, $appValues := $frontendApps }}
{{- $fullName := include "helm.fullname" (merge (dict "appName" $appName "application" $appValues) $) }}
- name: {{ $fullName }}-env-match
  route:
    {{- if and $appValues.service $appValues.service.ports }}
    {{- range $appValues.service.ports }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
    {{- end }}
    {{- else }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 4200 (dig "ports" "http" nil $appValues) }}
    {{- end }}
  match:
    - headers:
        environment:
          exact: {{ $envName }}
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
  {{- $pathMatch := dict "uri" (dict "prefix" $appValues.routePrefix) }}
  {{- $_ := set $pathMatch "withoutHeaders" (dict "environment" (dict)) }}
  match:
    - {{- toYaml $pathMatch | nindent 6 }}
  route:
  {{- if and $appValues.service $appValues.service.ports }}
  {{- range $appValues.service.ports }}
  - destination:
      host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
      port:
        number: {{ .port }}
  {{- end }}
  {{- else }}
  - destination:
      host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
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
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $appValues }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $appValues }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $appValues }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $appValues }}
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
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $appValues }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $appValues }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $appValues }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $appValues }}
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
      host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
      port:
        number: 80
  {{- $catchallMatch := dict "uri" (dict "exact" "/") }}
  {{- $_ := set $catchallMatch "withoutHeaders" (dict "environment" (dict)) }}
  match:
    - {{- toYaml $catchallMatch | nindent 6 }}
    {{- if and (not $isFeatureEnv) (eq $metaenv "dev") }}
    - headers:
        environment:
          regex: "^feature-[a-z0-9-]+$"
    {{- end }}
  headers:
    {{ include "helm.istioIngress.responseHeaders" $ | indent 4 | trim }}
  {{- with $primaryAppValues.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $primaryAppValues }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $primaryAppValues }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $primaryAppValues }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $primaryAppValues }}
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
  {{- $defaultMatch := dict "withoutHeaders" (dict "environment" (dict)) }}
  {{- if not (eq $primaryAppValues.routePrefix "/") }}
    {{- $_ := set $defaultMatch "uri" (dict "prefix" (default "/" $primaryAppValues.routePrefix)) }}
  {{- end }}
  match:
    - {{- toYaml $defaultMatch | nindent 6 }}
    {{- if and (not $isFeatureEnv) (eq $metaenv "dev") }}
    - headers:
        environment:
          regex: "^feature-[a-z0-9-]+$"
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
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $primaryAppValues }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $primaryAppValues }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $primaryAppValues }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $primaryAppValues }}
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
{{- $primaryBaseFullName := (list (.Values.global.appStack) ($primaryApp)) | join "-" | lower | trunc 63 | trimSuffix "-" }}
{{- $metaNamespace := include "helm.metaEnvironment" $ }}

exportTo:
- .
- {{ $metaNamespace }}
hosts:
{{- /* allow both internal and external hostnames */}}
- {{ $primaryFullName }}
- {{ $primaryFullName }}.{{ $namespace }}.svc
- {{ $primaryFullName }}.{{ $namespace }}.svc.cluster.local
- {{ $primaryBaseFullName }}
- {{ $primaryBaseFullName }}.{{ $metaNamespace }}.internal
- {{ $primaryBaseFullName }}.{{ $metaNamespace }}.svc
- {{ $primaryBaseFullName }}.{{ $metaNamespace }}.svc.cluster.local
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
      environment:
        exact: {{ .Values.environment.name }}
    uri:
      prefix: {{ $appValues.routePrefix }}
  route:
    {{- if and $appValues.service $appValues.service.ports }}
    {{- range $appValues.service.ports }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
    {{- end }}
    {{- else }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
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
        environment:
          exact: {{ .Values.environment.name }}
{{- end -}}