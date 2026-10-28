{{/*
The ServiceAccount the database pods run under, with the operator's database Role (the MongoDB agent reads Secrets
and patches its pods). The operator's own, mongodb-kubernetes-appdb, exists only in the operator's namespace, and a
shared name would collide between releases in one namespace.
Usage: include "mc-mongodb.rbac" $ctx
*/}}
{{- define "mc-mongodb.rbac" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}-database
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ .name }}-database
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
  - apiGroups: [""]
    resources: [pods]
    verbs: [patch, delete, get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .name }}-database
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ .name }}-database
subjects:
  - kind: ServiceAccount
    name: {{ .name }}-database
    namespace: {{ .namespace }}
{{- end }}
