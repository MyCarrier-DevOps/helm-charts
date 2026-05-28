{{- define "helm.envType" -}}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}

{{- if has $envName (list "dev" "preprod" "prod") }}
{{- printf "standard" }}
{{- else }}
{{- printf "standard" }}
{{- /* printf "ephemeral" */}}
{{- end }}
{{- end -}}

{{- define "helm.envDependency" -}}
{{- $envType := (include "helm.envType" . ) }}
{{- if eq $envType "ephemeral" }}
{{- if and .Values.globalEnv .Values.globalEnv.dependencyenv }}
{{- .Values.globalEnv.dependencyenv }}
{{- else }}
{{- printf "dev" }}
{{- end }}
{{- else }}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}
{{- $envName }}
{{- end }}
{{- end -}}

{{- define "helm.metaEnvironment" -}}
{{- $envName := "" }}
{{- if .Values }}
  {{- if .Values.environment }}
    {{- if .Values.environment.name }}
      {{- $envName = .Values.environment.name }}
    {{- else }}
      {{- $envName = "dev" }}
    {{- end }}
  {{- else }}
    {{- $envName = "dev" }}
  {{- end }}
{{- else }}
  {{- $envName = "dev" }}
{{- end }}

{{- if hasPrefix "feature" $envName }}
{{- printf "dev" -}}
{{- else }}
{{- $envName }}
{{- end }}
{{- end -}}

{{/*
Helper to get the environment header value for routing.
- For preprod environment, returns a regex pattern matching "preprod", "uat", or "qa"
- For feature environments, the actual environment name is used (e.g., "feature20")
- For other environments, the meta environment is used (prod, dev)
*/}}
{{- define "helm.environmentHeaderValue" -}}
{{- $envName := .Values.environment.name -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if eq $metaenv "preprod" -}}
{{- printf "^(preprod|uat|qa)$" -}}
{{- else if hasPrefix "feature" $envName -}}
{{- $envName -}}
{{- else -}}
{{- $metaenv -}}
{{- end -}}
{{- end -}}

{{/*
Helper to determine if the environment header should use regex matching.
Returns "true" for preprod (which accepts preprod/uat/qa), "false" otherwise.
*/}}
{{- define "helm.environmentHeaderIsRegex" -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if eq $metaenv "preprod" -}}
{{- printf "true" -}}
{{- else -}}
{{- printf "false" -}}
{{- end -}}
{{- end -}}

{{/*
Helper to determine if the environment is a "simple" environment (prod or preprod).
Simple environments don't require complex header-based routing with withoutHeaders fallbacks.
They use a straightforward default route without header matching requirements.
*/}}
{{- define "helm.isSimpleEnvironment" -}}
{{- $metaenv := include "helm.metaEnvironment" . -}}
{{- if or (eq $metaenv "prod") (eq $metaenv "preprod") -}}
{{- printf "true" -}}
{{- else -}}
{{- printf "false" -}}
{{- end -}}
{{- end -}}

{{/*
Renders the merged env block for an application container.
Combines .Values.global.env and .application.env into a single, deduplicated set,
where keys defined on the application override matching keys from global.
Keys managed by other helpers (otel/vault/keyvault/computed) are stripped from
both sources so they cannot be redefined here.

Usage: {{ include "helm.application.env" . | indent <N> | trim }}
where the call-site dot exposes both `.Values.global.env` and `.application.env`.
*/}}
{{- define "helm.application.env" -}}
{{- $omitKeys := list "OTEL_EXPORTER_OTLP_ENDPOINT" "ComputedEnvironmentName" "ActiveOffloads" "KeyVault_RedisConnection" "Auth_KeyVault_RedisConnection" "KeyVault_IsActive" "KeyVault_SplitIoProxyApiKey" "KeyVault_SplitIoProxyUrl" -}}
{{- $merged := dict -}}
{{- with $.Values.global.env -}}
{{- range $k, $v := . -}}
{{- if not (has $k $omitKeys) -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and .application.env (not (kindIs "invalid" .application.env)) -}}
{{- range $k, $v := .application.env -}}
{{- if not (has $k $omitKeys) -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $key, $value := $merged }}
- name: "{{ $key }}"
  {{- if kindIs "map" $value }}
  {{- if or (hasKey $value "valueFrom") (hasKey $value "value") }}
  {{ toYaml $value | indent 2 | trim }}
  {{- else }}
  valueFrom:
    {{ toYaml $value | indent 4 | trim }}
  {{- end }}
  {{- else }}
  value: "{{ tpl (toString $value) $ }}"
  {{- end }}
{{- end -}}
{{- end -}}
