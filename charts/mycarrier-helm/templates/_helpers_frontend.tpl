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