{{/*
Crossplane-specific helper templates for Azure infrastructure resources
*/}}

{{/*
Generate Azure storage account name (3-24 lowercase alphanumeric characters)
Usage: {{ include "helm.azure.storage.name" . }}
*/}}
{{- define "helm.azure.storage.name" -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
	{{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $appStack := $ctx.defaults.appStack | replace "-" "" | lower -}}
{{- $envName := $ctx.defaults.environmentName | replace "-" "" | lower -}}
{{- printf "st%s%s" $appStack $envName -}}
{{- end -}}

{{/*
Generate Azure resource group name (1-90 chars, alphanumeric, hyphens, underscores, periods, parentheses)
Usage: {{ include "helm.azure.resourceGroup.name" . }}
*/}}
{{- define "helm.azure.resourceGroup.name" -}}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
	{{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
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

{{/*
Sanitize a name for Kubernetes RFC 1123 subdomain compliance.
Must match: [a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*
Lowercases, replaces underscores with hyphens, strips any remaining invalid characters,
and trims leading/trailing hyphens and dots.
If the result exceeds 63 chars, truncates to 54 chars and appends a stable
8-character hash suffix to avoid collisions.
Usage: {{ include "helm.k8s.safename" $name }}
*/}}
{{- define "helm.k8s.safename" -}}
{{- $sanitized := . | lower | replace "_" "-" -}}
{{- $sanitized = regexReplaceAll "[^a-z0-9\\-\\.]" $sanitized "" -}}
{{- $sanitized = $sanitized | trimPrefix "-" | trimPrefix "." | trimSuffix "-" | trimSuffix "." -}}
{{- if le (len $sanitized) 63 -}}
{{- $sanitized -}}
{{- else -}}
{{- printf "%s-%s" ($sanitized | trunc 54 | trimSuffix "-" | trimSuffix ".") ($sanitized | sha256sum | trunc 8) -}}
{{- end -}}
{{- end -}}

{{/*
Prefix a crossplane resource name with the environment name and sanitize for k8s compliance.
Usage: {{ include "helm.crossplane.name" (dict "name" $name "environment" $root.Values.environment.name) }}
*/}}
{{- define "helm.crossplane.name" -}}
{{- include "helm.k8s.safename" (printf "%s-%s" .environment .name) -}}
{{- end -}}

{{/*
Generate Service Bus Topic full name (environment-namespace-topic, max 63 chars for k8s)
Usage: {{ include "helm.azure.servicebus.topic.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "environment" $root.Values.environment.name) }}
*/}}
{{- define "helm.azure.servicebus.topic.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s" .environment .namespace .topic) -}}
{{- end -}}

{{/*
Generate Service Bus Subscription full name (environment-topic-subscription, max 63 chars for k8s)
The namespace context is captured via labels (servicebus.mycarrier.io/namespace).
Usage: {{ include "helm.azure.servicebus.subscription.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name "environment" $root.Values.environment.name) }}
*/}}
{{- define "helm.azure.servicebus.subscription.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s" .environment .topic .subscription) -}}
{{- end -}}

{{/*
Generate Service Bus Subscription Rule full name (environment-rule, max 63 chars for k8s)
The namespace, topic, and subscription context are captured via labels.
Usage: {{ include "helm.azure.servicebus.rule.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name "rule" $rule.name "environment" $root.Values.environment.name) }}
*/}}
{{- define "helm.azure.servicebus.rule.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s" .environment .rule) -}}
{{- end -}}