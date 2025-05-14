{{/*
RBAC helper functions to provide consistent service account and role configuration.
This file contains all RBAC-related helpers for consistent rendering of
ServiceAccounts, Roles, RoleBindings, and ClusterRoles.
*/}}

{{/*
Default ServiceAccount specification
*/}}
{{- define "helm.specs.serviceaccount" -}}
{{- $fullName := include "helm.fullname" . }}
automountServiceAccountToken: {{ default true .automountServiceAccountToken }}
{{- with .annotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .labels }}
labels:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Default Role specification
*/}}
{{- define "helm.specs.role" -}}
{{- $fullName := include "helm.fullname" . }}
rules:
{{- if .rules }}
{{ toYaml .rules | indent 2 }}
{{- else }}
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
{{- end }}
{{- end -}}

{{/*
Default RoleBinding specification
*/}}
{{- define "helm.specs.rolebinding" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $namespace := include "helm.namespace" $ }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: {{ default "Role" .roleRef.kind }}
  name: {{ default $fullName .roleRef.name }}
subjects:
{{- if .subjects }}
{{ toYaml .subjects | indent 2 }}
{{- else }}
  - kind: ServiceAccount
    name: {{ default $fullName .serviceAccountName }}
    namespace: {{ $namespace }}
{{- end }}
{{- end -}}

{{/*
Get ServiceAccount name
*/}}
{{- define "helm.serviceAccountName" -}}
{{- $fullName := include "helm.fullname" . }}
{{- if .application.serviceAccount }}
{{- default $fullName .application.serviceAccount.name }}
{{- else }}
{{- $fullName }}
{{- end }}
{{- end -}}