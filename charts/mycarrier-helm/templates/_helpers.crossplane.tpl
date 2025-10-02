{{/*
Crossplane-specific helper templates for Azure infrastructure resources
*/}}

{{/*
Generate Azure storage account name (3-24 lowercase alphanumeric characters)
Usage: {{ include "helm.azure.storage.name" . }}
*/}}
{{- define "helm.azure.storage.name" -}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $appStack := $ctx.defaults.appStack | replace "-" "" | lower -}}
{{- $envName := $ctx.defaults.environmentName | replace "-" "" | lower -}}
{{- printf "st%s%s" $appStack $envName -}}
{{- end -}}

{{/*
Generate Azure resource group name (1-90 chars, alphanumeric, hyphens, underscores, periods, parentheses)
Usage: {{ include "helm.azure.resourceGroup.name" . }}
*/}}
{{- define "helm.azure.resourceGroup.name" -}}
{{- $ctx := include "helm.context" . | fromJson -}}
{{- $appStack := $ctx.defaults.appStack -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- printf "rg-%s-%s" $appStack $envName -}}
{{- end -}}

{{/*
Resolve Azure storage instance name with priority: explicit name > newStorageAccount.name > existingStorageAccount.name > generated name
Usage: {{ include "helm.azure.storage.instanceName" (dict "instance" $instance "root" $) }}
*/}}
{{- define "helm.azure.storage.instanceName" -}}
{{- $instance := .instance -}}
{{- $root := .root -}}
{{- if $instance.name -}}
{{- $instance.name -}}
{{- else if and $instance.newStorageAccount $instance.newStorageAccount.name -}}
{{- $instance.newStorageAccount.name -}}
{{- else if and $instance.existingStorageAccount $instance.existingStorageAccount.name -}}
{{- $instance.existingStorageAccount.name -}}
{{- else -}}
{{- include "helm.azure.storage.name" $root -}}
{{- end -}}
{{- end -}}