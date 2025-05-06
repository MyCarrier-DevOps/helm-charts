{{/*
Define a helper that creates a context with default values to avoid nil pointer errors.
This can be used throughout the chart to ensure consistent access to common values.
*/}}
{{- define "helm.default-context" -}}
{{- $defaults := dict -}}
{{- $_ := set $defaults "environmentName" "dev" -}}
{{- $_ := set $defaults "appStack" "app" -}}
{{- $_ := set $defaults "branchLabel" "" -}}
{{- $_ := set $defaults "forceAutoscaling" false -}}

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

{{/* Get force autoscaling if available, otherwise use default */}}
{{- if and .Values .Values.global (hasKey .Values.global "forceAutoscaling") -}}
  {{- $_ := set $defaults "forceAutoscaling" .Values.global.forceAutoscaling -}}
{{- end -}}

{{/* Add defaults to context */}}
{{- $_ := set $context "defaults" $defaults -}}

{{- $context | toJson -}}
{{- end -}}