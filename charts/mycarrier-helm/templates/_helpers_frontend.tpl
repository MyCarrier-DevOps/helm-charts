{{/*
Frontend-specific helper functions for multi-frontend deployments.
This file contains all helpers related to frontend application management,
configuration, and routing.
*/}}

{{/*
Check if an application is a frontend application
*/}}
{{- define "helm.frontend.isFrontend" -}}
{{- if and .application .application.isFrontend -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Check if an application is the primary frontend application
*/}}
{{- define "helm.frontend.isPrimary" -}}
{{- if and .application .application.isFrontend .application.isPrimary -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Get the route prefix for a frontend application
*/}}
{{- define "helm.frontend.routePrefix" -}}
{{- if and .application .application.routePrefix -}}
{{- .application.routePrefix -}}
{{- else -}}
/
{{- end -}}
{{- end -}}

{{/*
Get all frontend applications from the applications values
*/}}
{{- define "helm.frontend.getAllApps" -}}
{{- $frontendApps := dict -}}
{{- range $appName, $appValues := .Values.applications -}}
{{- if $appValues.isFrontend -}}
{{- $_ := set $frontendApps $appName $appValues -}}
{{- end -}}
{{- end -}}
{{- toJson $frontendApps -}}
{{- end -}}

{{/*
Get the primary frontend application name
*/}}
{{- define "helm.frontend.getPrimaryApp" -}}
{{- range $appName, $appValues := .Values.applications -}}
{{- if and $appValues.isFrontend $appValues.isPrimary -}}
{{- $appName -}}
{{- break -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check if multi-frontend routing should be enabled
This requires: multiple frontend apps AND at least one primary app
*/}}
{{- define "helm.frontend.enableMultiRouting" -}}
{{- $frontendCount := 0 -}}
{{- $hasPrimary := false -}}
{{- range $appName, $appValues := .Values.applications -}}
{{- if $appValues.isFrontend -}}
{{- $frontendCount = add $frontendCount 1 -}}
{{- if $appValues.isPrimary -}}
{{- $hasPrimary = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (gt $frontendCount 1) $hasPrimary -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Generate frontend application configuration for environment-specific settings
Usage: include "helm.frontend.appConfig" (merge (dict "appName" $appName "application" $appValues) $)
*/}}
{{- define "helm.frontend.appConfig" -}}
{{- $envName := .Values.environment.name -}}
{{- $appName := .appName -}}
{{- $appValues := .application -}}
{{- if eq $envName "dev" -}}
{{ include "helm.frontend.config.dev" . }}
{{- else if eq $envName "preprod" -}}
{{ include "helm.frontend.config.preprod" . }}
{{- else if eq $envName "prod" -}}
{{ include "helm.frontend.config.prod" . }}
{{- else -}}
{{/* Default to dev configuration for unknown environments */}}
{{ include "helm.frontend.config.dev" . }}
{{- end -}}
{{- end -}}

{{/*
Development environment configuration template
*/}}
{{- define "helm.frontend.config.dev" -}}
{
  "ENVIRONMENT": "{{ .Values.environment.name }}",
  "BASE_API_URL": "https://{{ .Values.environment.name }}.integratedtm.dev/MyCarrierAPI",
  "AUTHORITY_URL": "https://login.integratedtm.dev",
  "WELCOME_URLS": ["/", "/ui/welcome"],
  "CUSTOMER_URLS": ["/ui/customer", "/customers"],
  "CARRIER_URLS": ["/carriers"],
  "ADMIN_URLS": ["/admin/manage-carriers", "/ui/admin"],
  "SPLIT_IO_PROXY_API_KEY": "jhw74t0a9fbwvjr6mgdgg64oc5t1unwutxth",
  "SPLIT_IO_PROXY_URL": " https://split-proxy.dev.mycarrier.dev/api",
  "SIGNAL_R_SERVICE_URL": "https://inf-dev-signalrhandler.azurewebsites.net",
  "NOTIFICATION_SERVICE_URL": "https://app-notification-dev-api.azurewebsites.net",
  "TRUCKLOAD_V3_API_URL": "https://truckload-api.dev.mycarrier.dev",
  "CLAIMS_API_URL": "https://claims-api.dev.mycarrier.dev/api/v1",
  "USER_API_URL": "https://user-api.dev.mycarrier.dev/api/v1",
  "ADDRESS_API_URL": "https://address-api.dev.mycarrier.dev/api/v1",
  "PAYMENT_API_URL": "https://payment-api.dev.mycarrier.dev/api/v1",
  "STRIPE_PUBLIC_KEY": "pk_test_K4DDzgR4xJtYapP63XI2KbH6",
  "IS_GOOGLE_TAG_MANAGER_ACTIVE": false,
  "GTM_AUTH": "BxVNhTzcptN5cBCEwvPz7g|6"
}
{{- end -}}

{{/*
Pre-production environment configuration template
*/}}
{{- define "helm.frontend.config.preprod" -}}
{
  "ENVIRONMENT": "preprod",
  "BASE_API_URL": "https://preprod.integratedtm.dev/MyCarrierAPI",
  "AUTHORITY_URL": "https://login.integratedtm.dev",
  "WELCOME_URLS": ["/", "/ui/welcome"],
  "CUSTOMER_URLS": ["/ui/customer", "/customers"],
  "CARRIER_URLS": ["/carriers"],
  "ADMIN_URLS": ["/admin/manage-carriers", "/ui/admin"],
  "SPLIT_IO_PROXY_API_KEY": "jhw74t0a9fbwvjr6mgdgg64oc5t1unwutxth",
  "SPLIT_IO_PROXY_URL": " https://split-proxy.preprod.mycarrier.dev/api",
  "SIGNAL_R_SERVICE_URL": "https://inf-preprod-signalrhandler.azurewebsites.net",
  "NOTIFICATION_SERVICE_URL": "https://app-notification-preprod-api.azurewebsites.net",
  "TRUCKLOAD_V3_API_URL": "https://truckload-api.preprod.mycarrier.dev",
  "CLAIMS_API_URL": "https://claims-api.preprod.mycarrier.dev/api/v1",
  "USER_API_URL": "https://user-api.preprod.mycarrier.dev/api/v1",
  "ADDRESS_API_URL": "https://address-api.preprod.mycarrier.dev/api/v1",
  "PAYMENT_API_URL": "https://payment-api.preprod.mycarrier.dev/api/v1",
  "STRIPE_PUBLIC_KEY": "pk_test_K4DDzgR4xJtYapP63XI2KbH6",
  "IS_GOOGLE_TAG_MANAGER_ACTIVE": false,
  "GTM_AUTH": "BxVNhTzcptN5cBCEwvPz7g|6"
}
{{- end -}}

{{/*
Production environment configuration template
*/}}
{{- define "helm.frontend.config.prod" -}}
{
  "ENVIRONMENT": "prod",
  "BASE_API_URL": "https://mycarriertms.com/MyCarrierAPI",
  "AUTHORITY_URL": "https://login.integratedtm.com",
  "WELCOME_URLS": ["/", "/ui/welcome"],
  "CUSTOMER_URLS": ["/ui/customer", "/customers"],
  "CARRIER_URLS": ["/carriers"],
  "ADMIN_URLS": ["/admin/manage-carriers", "/ui/admin"],
  "SPLIT_IO_PROXY_API_KEY": "jhw74t0a9fbwvjr6mgdgg64oc5t1unwutxth",
  "SPLIT_IO_PROXY_URL": " https://split-proxy.mycarriertms.com/api",
  "SIGNAL_R_SERVICE_URL": "https://inf-prod-signalrhandler.azurewebsites.net",
  "NOTIFICATION_SERVICE_URL": "https://app-notification-prod-api.azurewebsites.net",
  "TRUCKLOAD_V3_API_URL": "https://truckload-api.mycarriertms.com",
  "CLAIMS_API_URL": "https://claims-api.mycarriertms.com/api/v1",
  "USER_API_URL": "https://user-api.mycarriertms.com/api/v1",
  "ADDRESS_API_URL": "https://address-api.mycarriertms.com/api/v1",
  "PAYMENT_API_URL": "https://payment-api.mycarriertms.com/api/v1",
  "STRIPE_PUBLIC_KEY": "pk_live_your_production_key_here",
  "IS_GOOGLE_TAG_MANAGER_ACTIVE": true,
  "GTM_AUTH": "production_gtm_auth_here"
}
{{- end -}}

{{/*
Generate ConfigMap name for a frontend application
*/}}
{{- define "helm.frontend.configMapName" -}}
{{- $fullName := include "helm.fullname" . -}}
{{ $fullName }}-config
{{- end -}}

{{/*
Generate the mount path for app.settings.json based on application type
*/}}
{{- define "helm.frontend.configMountPath" -}}
{{- $appName := .appName -}}
{{- if and .application .application.configMountPath -}}
{{- .application.configMountPath -}}
{{- else if eq $appName "mycarrier-frontend" -}}
/app/ui/frontend/src/app.settings.json
{{- else -}}
/app/ui/{{ $appName | replace "-portal" "" }}/environments/app.settings.json
{{- end -}}
{{- end -}}