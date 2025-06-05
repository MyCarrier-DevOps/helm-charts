{{- define "helm.lang.vars.csharp" -}}
{{- $metaenv := (include "helm.metaEnvironment" . ) }}
{{- if eq $metaenv "dev" }}
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://mycarrier-proxy-api.dev.mycarrier.dev"
- name: AuthEnvironment
  value: "Development"
- name: Auth_Environment
  value: "Development"
{{- end }}
{{- if eq $metaenv "preprod" }}
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://mycarrier-proxy-api.preprod.mycarrier.dev"
- name: AuthEnvironment
  value: "PreProd"
- name: Auth_Environment
  value: "PreProd"
{{- end }}
{{- if eq $metaenv "prod" }}
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://prod-mycarrier-customer.azurewebsites.net"
- name: AuthEnvironment
  value: "Production"
- name: Auth_Environment
  value: "Production"
{{- end }}
{{- if .Values.global.dependencies.mongodb }}
- name: KeyVaultMongoConnection
  value: "MongoConnection_{{ $metaenv }}"
- name: MongoConnection_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/{{ .Values.global.appStack | lower }}/shared/mongodb-{{ .Values.global.appStack | lower }}-{{ $metaenv }}#value"
{{- end }}
{{- if .Values.global.dependencies.elasticsearch }}
- name: KeyVault_ElasticSearch
  value: "ElasticSearchApiKey-{{ .Values.global.appStack | title }}-{{ $metaenv | title }}"
- name: ElasticSearchApiKey-{{ .Values.global.appStack | title }}-{{ $metaenv | title }}
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
- name: Auth_BasicCredentialUrl
  value: "https://app-common-basiccredential-{{ $metaenv }}-api.azurewebsites.net/"
- name: CustomerCredentialUrl
  value: "https://app-common-basiccredential-{{ $metaenv }}-api.azurewebsites.net/"
- name: KeyVault_SplitIoProxyApiKey
  value: "SplitIoProxyApiKey_{{ $metaenv }}"
- name: SplitIoProxyApiKey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/splitioproxyapikey-{{ $metaenv }}#value"
- name: splitioproxyurl_k8s_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/splitioproxyurl-k8s-{{ $metaenv }}#value"
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
- name: allowanonymouskey_{{ $metaenv }}
  value: "vault:secrets/data/{{ $metaenv }}/shared/allowanonymouskey-{{ $metaenv }}#value"
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
