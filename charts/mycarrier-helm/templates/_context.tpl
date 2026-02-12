{{/*
Define a helper that creates a context with default values to avoid nil pointer errors.
This can be used throughout the chart to ensure consistent access to common values.

PERFORMANCE OPTIMIZATION: This function now returns a dict directly instead of JSON.
The cached version should be used in loops to avoid recomputation.
*/}}
{{- define "helm.default-context" -}}
{{- $defaults := dict -}}
{{- $_ := set $defaults "environmentName" "dev" -}}
{{- $_ := set $defaults "appStack" "app" -}}
{{- $_ := set $defaults "branchLabel" "" -}}
{{- $_ := set $defaults "commitDeployed" "" -}}
{{- $_ := set $defaults "correlationId" "" -}}
{{/* forceAutoscaling has no default - nil means "not set" and allows prod auto-scaling */}}

{{- $context := deepCopy . -}}

{{/* Get environment name if available, otherwise use default */}}
{{- if and .Values .Values.environment .Values.environment.name -}}
  {{- $_ := set $defaults "environmentName" .Values.environment.name -}}
{{- end -}}

{{/* Get app stack if available, otherwise use default */}}
{{- if and .Values .Values.global .Values.global.appStack -}}
  {{- $_ := set $defaults "appStack" .Values.global.appStack -}}
{{- end -}}

{{/* Get branch label if available, otherwise use default */}}
{{- if and .Values .Values.global .Values.global.branchlabel -}}
  {{- $_ := set $defaults "branchLabel" .Values.global.branchlabel -}}
{{- end -}}

{{/* Get deployed commit if available, otherwise use default */}}
{{- if and .Values .Values.global .Values.global.commitDeployed -}}
  {{- $_ := set $defaults "commitDeployed" .Values.global.commitDeployed -}}
{{- end -}}

{{/* Get correlation ID if available, otherwise use default */}}
{{- if and .Values .Values.global .Values.global.correlationId -}}
  {{- $_ := set $defaults "correlationId" .Values.global.correlationId -}}
{{- end -}}

{{/* Get force autoscaling if available, otherwise use default */}}
{{- if and .Values .Values.global (hasKey .Values.global "forceAutoscaling") -}}
  {{- $_ := set $defaults "forceAutoscaling" .Values.global.forceAutoscaling -}}
{{- end -}}

{{/* Add defaults to context */}}
{{- $chartDefaults := include "helm.chartDefaults.raw" . | fromJson -}}
{{- $_ := set $context "defaults" $defaults -}}
{{- $_ := set $context "chartDefaults" $chartDefaults -}}

{{- $context | toJson -}}
{{- end -}}

{{/*
PERFORMANCE OPTIMIZATION: Get or create cached context.
This helper checks if a precomputed context exists in .ctx, otherwise computes it.
This eliminates redundant JSON serialization/deserialization in helper functions.

Usage in templates:
  {{- $ctx := include "helm.context" . | fromJson -}}
  
Usage in loops (precompute once):
  {{- $globalCtx := include "helm.context" $ | fromJson -}}
  {{- range $appName, $appValues := .Values.applications }}
    {{- $appContext := merge (dict "appName" $appName "application" $appValues "ctx" $globalCtx) $ }}
*/}}
{{- define "helm.context" -}}
{{- if .ctx -}}
  {{- .ctx | toJson -}}
{{- else -}}
  {{- include "helm.default-context" . -}}
{{- end -}}
{{- end -}}