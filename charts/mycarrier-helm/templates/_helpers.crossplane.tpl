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
Generate Azure resource group name using the default naming convention.
Delegates to helm.azure.resourceGroup.defaultName for consistency.
Kept for backward compatibility with storage claim template.
Usage: {{ include "helm.azure.resourceGroup.name" . }}
*/}}
{{- define "helm.azure.resourceGroup.name" -}}
{{- include "helm.azure.resourceGroup.defaultName" (dict "root" .) -}}
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
Prefix a crossplane resource name with environment and appStack, then sanitize for k8s compliance.
Usage: {{ include "helm.crossplane.name" (dict "name" $name "environment" $root.Values.environment.name "appStack" $root.Values.global.appStack) }}
*/}}
{{- define "helm.crossplane.name" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s" .environment .appStack .name) -}}
{{- end -}}

{{/*
Generate Service Bus Topic full name (environment-appStack-namespace-topic, max 63 chars for k8s)
Usage: {{ include "helm.azure.servicebus.topic.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "environment" $root.Values.environment.name "appStack" $root.Values.global.appStack) }}
*/}}
{{- define "helm.azure.servicebus.topic.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s-%s" .environment .appStack .namespace .topic) -}}
{{- end -}}

{{/*
Generate Service Bus Subscription full name (environment-appStack-topic-subscription, max 63 chars for k8s)
The namespace context is captured via labels (servicebus.mycarrier.io/namespace).
Usage: {{ include "helm.azure.servicebus.subscription.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name "environment" $root.Values.environment.name "appStack" $root.Values.global.appStack) }}
*/}}
{{- define "helm.azure.servicebus.subscription.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s-%s" .environment .appStack .topic .subscription) -}}
{{- end -}}

{{/*
Generate Service Bus Subscription Rule full name (environment-appStack-rule, max 63 chars for k8s)
The namespace, topic, and subscription context are captured via labels.
Usage: {{ include "helm.azure.servicebus.rule.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name "rule" $rule.name "environment" $root.Values.environment.name "appStack" $root.Values.global.appStack) }}
*/}}
{{- define "helm.azure.servicebus.rule.fullname" -}}
{{- include "helm.k8s.safename" (printf "%s-%s-%s" .environment .appStack .rule) -}}
{{- end -}}

{{/*
Generate default Resource Group name based on environment.
Uses metaEnvironment to map feature-* environments to "dev".
Output: inf-{metaEnv} (e.g., inf-dev, inf-preprod, inf-prod)
Usage: {{ include "helm.azure.resourceGroup.defaultName" (dict "root" $root) }}
*/}}
{{- define "helm.azure.resourceGroup.defaultName" -}}
{{- $metaEnv := include "helm.metaEnvironment" .root -}}
{{- printf "inf-%s" $metaEnv -}}
{{- end -}}

{{/*
Generate default Service Bus namespace name based on environment.
Uses metaEnvironment to map feature-* environments to "dev".
Output: inf-{metaEnv}-servicebus (e.g., inf-dev-servicebus, inf-preprod-servicebus, inf-prod-servicebus-prem)
Note: prod uses the Premium-tier namespace inf-prod-servicebus-prem.
Usage: {{ include "helm.azure.servicebus.name" (dict "root" $root) }}
*/}}
{{- define "helm.azure.servicebus.name" -}}
{{- $metaEnv := include "helm.metaEnvironment" .root -}}
{{- if eq $metaEnv "prod" -}}
{{- printf "inf-%s-servicebus-prem" $metaEnv -}}
{{- else -}}
{{- printf "inf-%s-servicebus" $metaEnv -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Kubernetes namespace for a Crossplane resource.
Falls back to helm.namespace (environment.name or environment.namespaceOverride) if no explicit namespace is provided.
Usage: {{ include "helm.crossplane.namespace" (dict "namespace" $instance.namespace "root" $root) }}
*/}}
{{- define "helm.crossplane.namespace" -}}
{{- .namespace | default (include "helm.namespace" .root | trim) -}}
{{- end -}}

{{/*
Resolve global Crossplane defaults (providerConfigRef, location).
Returns a JSON object with defaults applied. Use once per template, cache the result.
Usage: {{ $defaults := include "helm.crossplane.defaults" (dict "root" $root) | fromJson }}
*/}}
{{- define "helm.crossplane.defaults" -}}
{{- $providerConfigRef := "default" -}}
{{- $location := "" -}}
{{- with .root.Values.infrastructure.azure.defaults -}}
  {{- $providerConfigRef = .providerConfigRef | default $providerConfigRef -}}
  {{- if .location }}{{ $location = .location }}{{ end -}}
{{- end -}}
{{- dict "providerConfigRef" $providerConfigRef "location" $location | toJson -}}
{{- end -}}

{{/*
Render managementPolicies block with a default of ["Observe"].
Usage: {{ include "helm.crossplane.managementPolicies" (dict "policies" $instance.managementPolicies) | nindent 2 }}
*/}}
{{- define "helm.crossplane.managementPolicies" -}}
{{- if .policies -}}
managementPolicies:
  {{- toYaml .policies | nindent 2 }}
{{- else -}}
managementPolicies:
  - "Observe"
{{- end -}}
{{- end -}}