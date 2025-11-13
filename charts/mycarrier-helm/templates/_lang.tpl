{{- define "helm.lang.vars.csharp" -}}
{{- $metaenv := (include "helm.metaEnvironment" . ) }}
{{- if eq $metaenv "dev" }}
- name: Auth_IdentityApiKey_BaseUrl
  value: "vault:secrets/data/dev/shared/auth_identityapikey_baseurl#value"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "vault:secrets/data/dev/shared/auth_mycarriercustomer_baseurl#value"
- name: Auth_MyCarrierApi_BaseUrl
  value: "vault:secrets/data/dev/shared/auth_mycarrierapi_baseurl#value"
- name: Auth_UserService_BaseUrl
  value: "vault:secrets/data/dev/shared/auth_userservice_baseurl#value"
- name: AuthEnvironment
  value: "Development"
- name: Auth_Environment
  value: "Development"
{{- end }}
{{- if eq $metaenv "preprod" }}
- name: Auth_IdentityApiKey_BaseUrl
  value: "vault:secrets/data/preprod/shared/auth_identityapikey_baseurl#value"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "vault:secrets/data/preprod/shared/auth_mycarriercustomer_baseurl#value"
- name: Auth_MyCarrierApi_BaseUrl
  value: "vault:secrets/data/preprod/shared/auth_mycarrierapi_baseurl#value"
- name: Auth_UserService_BaseUrl
  value: "vault:secrets/data/preprod/shared/auth_userservice_baseurl#value"
- name: AuthEnvironment
  value: "PreProd"
- name: Auth_Environment
  value: "PreProd"
{{- end }}
{{- if eq $metaenv "prod" }}
- name: Auth_IdentityApiKey_BaseUrl
  value: "vault:secrets/data/prod/shared/auth_identityapikey_baseurl#value"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "vault:secrets/data/prod/shared/auth_mycarriercustomer_baseurl#value"
- name: Auth_MyCarrierApi_BaseUrl
  value: "vault:secrets/data/prod/shared/auth_mycarrierapi_baseurl#value"
- name: Auth_UserService_BaseUrl
  value: "vault:secrets/data/prod/shared/auth_userservice_baseurl#value"
- name: AuthEnvironment
  value: "Production"
- name: Auth_Environment
  value: "Production"
{{- end }}
{{- if .Values.global.dependencies.mongodb }}
- name: KeyVault_MongoConnection
  value: "MongoConnection_{{ $metaenv }}"
- name: KeyVaultMongoConnection
  value: "MongoConnection_{{ $metaenv }}"
- name: MongoConnection_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/mongodb-{{ .Values.global.appStack | lower }}-{{ $metaenv }}#value"
{{- end }}
{{- if .Values.global.dependencies.redpanda }}
- name: redpanda_bootstrapservers
  value: "vault:secrets/data/{{ $metaenv }}/shared/redpanda_bootstrapservers#value"
- name: redpanda_saslusername
  value: "vault:secrets/data/{{ $metaenv }}/shared/redpanda_saslusername#value"
- name: redpanda_saslpassword
  value: "vault:secrets/data/{{ $metaenv }}/shared/redpanda_saslpassword#value"
{{- end }}
{{- if .Values.global.dependencies.elasticsearch }}
- name: KeyVault_ElasticSearch
  value: "ElasticSearchApiKey_{{ .Values.global.appStack | title }}_{{ $metaenv | title }}"
- name: ElasticSearchApiKey_{{ .Values.global.appStack | title }}_{{ $metaenv | title }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/elasticsearchapikey-{{ .Values.global.appStack | lower }}-{{ $metaenv }}#value"
{{- if eq $metaenv "prod" }}
- name: ElasticSearch_Url
  value: "https://c64e43ba7ea74be2b5d36dd233d427f5.eastus.azure.elastic-cloud.com:443"
{{- else }}
- name: ElasticSearch_Url
  value: "https://c073a0b068f34d408d23c5ab2a28f852.eastus2.azure.elastic-cloud.com:443"
{{- end }}
{{- end }}
{{- if .Values.global.dependencies.redis }}
- name: Auth_KeyVault_RedisConnection
  value: "RedisConnection{{ $metaenv | title }}"
- name: KeyVault_RedisConnection
  value: "RedisConnection{{ $metaenv | title }}"
- name: RedisConnection{{ $metaenv | title }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/redisconnection{{ $metaenv }}#value"
{{- end }}
{{- if .Values.global.dependencies.azureservicebus }}
- name: ServiceBusNamespace
  value: "inf-{{ $metaenv }}-servicebus.servicebus.windows.net"
- name: ServiceBusFullyQualifiedNamespace
  value: "inf-{{ $metaenv }}-servicebus.servicebus.windows.net"
- name: ServiceBusConnectionNamespace
  value: "inf-{{ $metaenv }}-servicebus.servicebus.windows.net"
{{- end }}
{{- if .Values.global.dependencies.loadsure }}
- name: KeyVault_LoadsureClaimsToken
  value: "LoadsureClaimsToken_{{ $metaenv }}"
- name: KeyVault_LoadsureToken
  value: "LoadsureToken_{{ $metaenv }}"
- name: LoadsureClaimsToken_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/loadsureclaimstoken-{{ $metaenv }}#value"
- name: LoadsureToken_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/loadsuretoken-{{ $metaenv }}#value"
{{- end }}
{{- if .Values.global.dependencies.chargify }}
- name: KeyVault_MaxioApiKey
  value: "ChargifyApiKey_{{ $metaenv }}"
- name: Maxio_BaseAddress
  value: "ChargifyBaseUrl_{{ $metaenv }}"
- name: ChargifyApiKey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/chargifyapikey-{{ $metaenv }}#value"
- name: ChargifyBaseUrl_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/chargifybaseurl-{{ $metaenv }}#value"
{{- end }}
- name: Analytics_Broker_Topic_Name
  value: "mc-{{ .Values.global.appStack | lower }}-analytics-{{ $metaenv }}"
- name: Auth_BasicCredentialUrl
  value: "https://app-common-basiccredential-{{ $metaenv }}-api.azurewebsites.net/"
- name: CustomerCredentialUrl
  value: "https://app-common-basiccredential-{{ $metaenv }}-api.azurewebsites.net/"
- name: SplitIo_ApiKey
  value: "vault:secrets/data/{{ $metaenv }}/shared/SplitIo_ApiKey#value"
- name: mycarrier_jwt_secret
  value: "vault:secrets/data/{{ $metaenv }}/shared/mycarrier_jwt_secret#value"
- name: KeyVault_SplitIoProxyApiKey
  value: "SplitIoProxyApiKey_{{ $metaenv }}"
- name: SplitIoProxyApiKey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/splitioproxyapikey-{{ $metaenv }}#value"
- name: splitioproxyurl_k8s_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/splitioproxyurl-k8s-{{ $metaenv }}#value"
- name: Auth_KeyVault_SplitIoProxyApiKey
  value: "SplitIoProxyApiKey-{{ $metaenv }}"
- name: Auth_KeyVault_SplitIoProxyUrl
  value: "SplitIoProxyUrl-{{ $metaenv }}"
- name: KeyVault_SplitIoProxyUrl
  value: "SplitIoProxyUrl_{{ $metaenv }}"
- name: SplitIoProxyUrl_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/splitioproxyurl-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityBaseUrl
  value: "StrivacityBaseUrl_{{ $metaenv }}"
- name: KeyVault_StrivacityBaseUrl
  value: "StrivacityBaseUrl_{{ $metaenv }}"
- name: StrivacityBaseUrl_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacitybaseurl-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityApiKey
  value: "StrivacityApiKey_{{ $metaenv }}"
- name: KeyVault_StrivacityApiKey
  value: "StrivacityApiKey_{{ $metaenv }}"
- name: StrivacityApiKey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacityapikey-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityApiSecret
  value: "StrivacityApiSecret_{{ $metaenv }}"
- name: KeyVault_StrivacityApiSecret
  value: "StrivacityApiSecret_{{ $metaenv }}"
- name: StrivacityApiSecret_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacityapisecret-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityIdentityStore
  value: "StrivacityIdentityStore_{{ $metaenv }}"
- name: KeyVault_StrivacityIdentityStore
  value: "StrivacityIdentityStore_{{ $metaenv }}"
- name: StrivacityIdentityStore_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacityidentitystore-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityApiAudience
  value: "StrivacityApiAudience_{{ $metaenv }}"
- name: KeyVault_StrivacityApiAudience
  value: "StrivacityApiAudience_{{ $metaenv }}"
- name: StrivacityApiAudience_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacityapiaudience-{{ $metaenv }}#value"
- name: Auth_KeyVault_StrivacityInviteClientId
  value: "StrivacityInviteClientId_{{ $metaenv }}"
- name: KeyVault_StrivacityInviteClientId
  value: "StrivacityInviteClientId_{{ $metaenv }}"
- name: StrivacityInviteClientId_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/strivacityinviteclientid-{{ $metaenv }}#value"
- name: KeyVault_AllowAnonymousKey
  value: "allowanonymouskey_{{ $metaenv }}"
- name: allowanonymouskey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/allowanonymouskey-{{ $metaenv }}#value"
- name: SplitCommonUser
  value: "appstackuser@mycarrier.io"
- name: Auth_SplitCommonUser
  value: "appstackuser@mycarrier.io"
- name: KeyVault_IsActive
  value: "false"
{{- end -}}
{{- define "helm.lang.vars.js" -}}
{{- $metaenv := (include "helm.metaEnvironment" . ) }}
{{- if eq $metaenv "dev" }}
{{- end }}
{{- if eq $metaenv "preprod" }}
{{- end }}
{{- if eq $metaenv "prod" }}
{{- end }}
{{- end -}}

{{- define "helm.lang.vars" -}}
{{- $csharp := (include "helm.lang.vars.csharp" . ) }}
{{- if eq .Values.global.language "csharp" }}
{{ include "helm.lang.vars.csharp" . }}
{{- end }}
{{- end -}}

{{/* Language-specific endpoint definitions
Returns YAML array that can be converted to Go data structures with fromYamlArray
Expects context with: .Values, .fullName, .application
*/}}
{{- define "helm.lang.endpoint.list" -}}
{{- $disableDefaults := dig "networking" "istio" "disableDefaultEndpoints" false .application -}}
{{- if and (eq .Values.global.language "csharp") (not $disableDefaults) -}}
- kind: "exact"
  match: "/liveness"
- kind: "exact"
  match: "/health"
{{- if contains "api" (.fullName | lower) }}
- kind: "prefix"
  match: "/api"
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Helper function to normalize paths for deduplication
Removes all trailing wildcards and slashes
*/}}
{{- define "helm.normalizePath" -}}
{{- . | trimSuffix "*" | trimSuffix "/" | trimSuffix "*" | trimSuffix "/" -}}
{{- end -}}

{{/*
Helper function to process prefix paths for Istio VirtualService
Converts wildcard patterns to Istio-compatible prefix paths by replacing * with /
Generic algorithm handles all patterns consistently without hardcoded special cases
*/}}
{{- define "helm.processPrefixPath" -}}
{{- $path := . -}}
{{- /* Replace all * with / for Istio prefix matching */ -}}
{{- $processed := $path | replace "*" "/" -}}
{{- /* Remove duplicate slashes that may result from replacement */ -}}
{{- $processed | replace "//" "/" -}}
{{- end -}}

{{/*
Helper function to process endpoint names - replaces special characters for Kubernetes naming
Replaces * with "wildcard", / with -, and removes leading/trailing dashes
*/}}
{{- define "helm.processEndpointName" -}}
{{- $name := . -}}
{{- $name = $name | replace "*" "wildcard" | replace "/" "-" | trimAll "-" -}}
{{- $name -}}
{{- end -}}

{{/*
Helper function to process regex endpoint names for Kubernetes naming conventions
Replaces regex special characters with dashes and removes leading/trailing dashes
*/}}
{{- define "helm.processRegexEndpointName" -}}
{{- . | regexReplaceAll "[/\\.\\?\\+\\*]" "-" | regexReplaceAll "[\\^$]" "" | trimAll "-" -}}
{{- end -}}

{{/*
Helper function to process exact endpoint names for Kubernetes naming conventions
Replaces / with - and removes leading/trailing dashes
*/}}
{{- define "helm.processExactEndpointName" -}}
{{- . | replace "/" "-" | trimAll "-" -}}
{{- end -}}

{{/*
Centralized endpoint name generation for all kinds
*/}}
{{- define "helm.renderEndpointName" -}}
{{- if eq .kind "regex" -}}
  {{- include "helm.processRegexEndpointName" .match -}}
{{- else if eq .kind "prefix" -}}
  {{- include "helm.processEndpointName" .match -}}
{{- else -}}
  {{- include "helm.processExactEndpointName" .match -}}
{{- end -}}
{{- end -}}

{{/*
Centralized match rendering for all kinds
*/}}
{{- define "helm.renderEndpointMatch" -}}
{{- if eq .kind "regex" -}}
- uri:
    regex: {{ .match | quote }}
{{- else if eq .kind "prefix" -}}
- uri:
    prefix: {{ include "helm.processPrefixPath" .match | quote }}
{{- else -}}
- uri:
    exact: {{ .match | quote }}
{{- end -}}
{{- end -}}

{{/*
Centralized HTTP rule name and match rendering for all endpoint kinds
*/}}
{{- define "helm.renderEndpointRule" -}}
{{- $endpointName := include "helm.renderEndpointName" . -}}
{{- $ruleType := .ruleType -}}
{{- $fullName := .fullName }}
- name: {{ $fullName }}-{{ $ruleType }}-{{ $endpointName }}
  match:
{{ include "helm.renderEndpointMatch" . | indent 2 }}
{{- end }}

{{/*
Helper template to generate VirtualService HTTP rules for language-specific and user-defined endpoints
This template generates the complete HTTP rules as strings to avoid duplication
*/}}
{{- define "helm.virtualservice.allowedEndpoints" -}}
{{- $namespace := include "helm.namespace" . }}
{{- $fullName := include "helm.fullname" . -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $serviceDefaults := $ctx.chartDefaults.service -}}
{{- $mergedEndpoints := list -}}
{{- $istioConfig := dig "networking" "istio" dict $.application -}}

{{/* Add language-specific endpoints first using centralized template */}}
{{- $contextWithFullName := dict "Values" $.Values "application" $.application "fullName" $fullName }}
{{- $langEndpointsYaml := include "helm.lang.endpoint.list" $contextWithFullName | trim -}}
{{- if ne $langEndpointsYaml "" }}
  {{- $langEndpoints := fromYamlArray $langEndpointsYaml -}}
  {{- $mergedEndpoints = concat $mergedEndpoints $langEndpoints -}}
{{- end }}

{{/* Add user-defined endpoints */}}
{{- if and (hasKey $istioConfig "allowedEndpoints") $istioConfig.allowedEndpoints -}}
  {{- $mergedEndpoints = concat $mergedEndpoints $istioConfig.allowedEndpoints -}}
{{- end }}

{{/* Exit early if no endpoints to process */}}
{{- if lt (len $mergedEndpoints) 1 -}}
{{- else -}}

{{/* Deduplicate endpoints by kind+normalizedPath AND check for name conflicts */}}
{{- $seenPaths := dict -}}
{{- $seenNames := dict -}}
{{- $unique := list -}}
{{- range $mergedEndpoints -}}
  {{/* Normalize input - convert all endpoints to unified object format */}}
  {{- $endpoint := dict -}}
  {{- if typeIs "string" . -}}
    {{/* Convert string to object based on presence of wildcard */}}
    {{- if contains "*" . -}}
      {{- $endpoint = dict "kind" "prefix" "match" . -}}
    {{- else -}}
      {{- $endpoint = dict "kind" "exact" "match" . -}}
    {{- end -}}
  {{- else -}}
    {{/* Already an object, use as-is */}}
    {{- $endpoint = . -}}
  {{- end -}}
  
  {{/* Process normalized endpoint - single path for all types */}}
  {{- $kind := $endpoint.kind -}}
  {{- $match := $endpoint.match -}}
  {{- $endpointName := "" -}}
  {{- $normalizedPath := "" -}}
  
  {{- if eq $kind "prefix" -}}
    {{- $endpointName = include "helm.processEndpointName" $match -}}
    {{- $normalizedPath = include "helm.normalizePath" $match -}}
  {{- else if eq $kind "exact" -}}
    {{- $endpointName = include "helm.processExactEndpointName" $match -}}
    {{- $normalizedPath = $match -}}
  {{- else if eq $kind "regex" -}}
    {{- $endpointName = include "helm.processRegexEndpointName" $match -}}
    {{- $normalizedPath = $match -}}
  {{- end -}}
  
  {{/* Deduplication using kind:normalizedPath and name conflict detection */}}
  {{- $pathKey := printf "%s:%s" $kind $normalizedPath -}}
  {{- if not (hasKey $seenPaths $pathKey) -}}
    {{/* Also check if endpoint name already exists (name conflict detection) */}}
    {{- if not (hasKey $seenNames $endpointName) -}}
      {{- $_ := set $seenPaths $pathKey true -}}
      {{- $_ := set $seenNames $endpointName true -}}
      {{- if eq $kind "prefix" -}}
        {{- $unique = append $unique (dict "kind" "prefix" "match" $match "normalized" $normalizedPath) -}}
      {{- else -}}
        {{- $unique = append $unique (dict "kind" $kind "match" $match) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* render HTTP rules using centralized helper */}}
{{- if gt (len $unique) 0 }}
{{- range $unique }}
{{- $ruleContext := dict "kind" .kind "match" .match "ruleType" "allowed" "fullName" $fullName }}
{{ include "helm.renderEndpointRule" $ruleContext }}
  route:
    {{- if and $.application.service $.application.service.ports }}
    {{- range $.application.service.ports }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
      weight: 100
    {{- if eq $.application.deploymentType "rollout" }}
    - destination:
        host: "{{ $fullName }}-preview.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ .port }}
      weight: 0
    {{- end }}
    {{- end }}
    {{- else }}
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 100
    {{- if eq $.application.deploymentType "rollout" }}
    - destination:
        host: "{{ $fullName }}-preview.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 0
    {{- end }}
    {{- end }}
  {{- with $istioConfig.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  {{/* Safely access service properties with default values if not defined */}}
  timeout: {{ dig "service" "timeout" $serviceDefaults.timeout $.application }}
  retries:
    retryOn: {{ dig "service" "retryOn" $serviceDefaults.retryOn $.application }}
    attempts: {{ dig "service" "attempts" $serviceDefaults.attempts $.application }}
    perTryTimeout: {{ dig "service" "perTryTimeout" $serviceDefaults.perTryTimeout $.application }}
{{- end }}


- name: {{ $fullName }}-forbidden
  route:
    - destination:
        host: "{{ $fullName }}.{{ $namespace }}.svc.cluster.local"
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}      
  fault:
    delay:
      fixedDelay: 29s
      percentage:
        value: 100
    abort:
      httpStatus: 403
      percentage:
        value: 100
{{- end }}
{{- end -}}
{{- end -}}