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
Truncate a name to 63 characters for Kubernetes RFC 1123 compliance.
If the name fits, use it as-is. If it exceeds 63 chars, truncate to 54 chars
and append a stable 8-character hash suffix to avoid collisions.
Usage: {{ include "helm.k8s.safename" $name }}
*/}}
{{- define "helm.k8s.safename" -}}
{{- if le (len .) 63 -}}
{{- . -}}
{{- else -}}
{{- printf "%s-%s" (. | trunc 54 | trimSuffix "-") (. | sha256sum | trunc 8) -}}
{{- end -}}
{{- end -}}

{{/*
Generate Service Bus Topic full name (namespace-topic, max 63 chars for k8s)
Usage: {{ include "helm.azure.servicebus.topic.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name) }}
*/}}
{{- define "helm.azure.servicebus.topic.fullname" -}}
{{- $name := printf "%s-%s" .namespace .topic | lower -}}
{{- include "helm.k8s.safename" $name -}}
{{- end -}}

{{/*
Generate Service Bus Subscription full name (namespace-topic-subscription, max 63 chars for k8s)
Usage: {{ include "helm.azure.servicebus.subscription.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name) }}
*/}}
{{- define "helm.azure.servicebus.subscription.fullname" -}}
{{- $name := printf "%s-%s-%s" .namespace .topic .subscription | lower -}}
{{- include "helm.k8s.safename" $name -}}
{{- end -}}

{{/*
Generate Service Bus Subscription Rule full name (subscription-rule, max 63 chars for k8s)
The namespace and topic context are captured via labels, so we use just subscription-rule
to keep names shorter and more readable.
Usage: {{ include "helm.azure.servicebus.rule.fullname" (dict "namespace" $sbInstance.name "topic" $topic.name "subscription" $subscription.name "rule" $rule.name) }}
*/}}
{{- define "helm.azure.servicebus.rule.fullname" -}}
{{- $name := printf "%s-%s" .subscription .rule | lower -}}
{{- include "helm.k8s.safename" $name -}}
{{- end -}}