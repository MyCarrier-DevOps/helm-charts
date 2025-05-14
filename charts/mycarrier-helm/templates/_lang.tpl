{{- define "helm.lang.vars.csharp" -}}
{{- $metaenv := (include "helm.metaEnvironment" . ) }}
{{- if eq $metaenv "dev" }}
- name: CustomerCredentialUrl
  value: "https://app-common-basiccredential-dev-api.azurewebsites.net/"
- name: Auth_BasicCredentialUrl
  value: "https://app-common-basiccredential-dev-api.azurewebsites.net/"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://mycarrier-proxy-api.dev.mycarrier.dev"
- name: AuthEnvironment
  value: "Development"
- name: Auth_Environment
  value: "Development"
- name: KeyVault_RedisConnection
  value: "RedisConnectionDev"
- name: Auth_KeyVault_RedisConnection
  value: "RedisConnectionDev"
{{- end }}
{{- if eq $metaenv "preprod" }}
- name: CustomerCredentialUrl
  value: "https://app-common-basiccredential-preprod-api.azurewebsites.net/"
- name: Auth_BasicCredentialUrl
  value: "https://app-common-basiccredential-preprod-api.azurewebsites.net/"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://mycarrier-proxy-api.preprod.mycarrier.dev"
- name: AuthEnvironment
  value: "PreProd"
- name: Auth_Environment
  value: "PreProd"
- name: KeyVault_RedisConnection
  value: "RedisConnectionPreProd"
- name: Auth_KeyVault_RedisConnection
  value: "RedisConnectionPreProd"
{{- end }}
{{- if eq $metaenv "prod" }}
- name: CustomerCredentialUrl
  value: "https://app-common-basiccredential-prod-api.azurewebsites.net/"
- name: Auth_BasicCredentialUrl
  value: "https://app-common-basiccredential-prod-api.azurewebsites.net/"
- name: Auth_MyCarrierCustomer_BaseUrl
  value: "https://prod-mycarrier-customer.azurewebsites.net"
- name: AuthEnvironment
  value: "Production"
- name: Auth_Environment
  value: "Production"
- name: KeyVault_RedisConnection
  value: "RedisConnectionProd"
- name: Auth_KeyVault_RedisConnection
  value: "RedisConnectionProd"
{{- end }}
- name: KeyVault_SplitIoProxyApiKey
  value: "SplitIoProxyApiKey-{{ $metaenv }}"
- name: KeyVault_SplitIoProxyUrl
  value: "SplitIoProxyUrl-{{ $metaenv }}"
- name: KeyVault_StrivacityBaseUrl
  value: "StrivacityBaseUrl-{{ $metaenv }}"
- name: KeyVault_StrivacityApiKey
  value: "StrivacityApiKey-{{ $metaenv }}"
- name: KeyVault_StrivacityApiSecret
  value: "StrivacityApiSecret-{{ $metaenv }}"
- name: KeyVault_StrivacityIdentityStore
  value: "StrivacityIdentityStore-{{ $metaenv }}"
- name: KeyVault_StrivacityApiAudience
  value: "StrivacityApiAudience-{{ $metaenv }}"
- name: KeyVault_StrivacityInviteClientId
  value: "StrivacityInviteClientId-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityBaseUrl
  value: "StrivacityBaseUrl-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityApiKey
  value: "StrivacityApiKey-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityApiSecret
  value: "StrivacityApiSecret-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityIdentityStore
  value: "StrivacityIdentityStore-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityApiAudience
  value: "StrivacityApiAudience-{{ $metaenv }}"
- name: Auth_KeyVault_StrivacityInviteClientId
  value: "StrivacityInviteClientId-{{ $metaenv }}"
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
