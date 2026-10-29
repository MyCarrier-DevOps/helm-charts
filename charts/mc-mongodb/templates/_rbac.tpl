{{/*
The ServiceAccount the database pods run under, with what the operator's database Role is used for. The operator's
own, mongodb-kubernetes-appdb, exists only in the operator's namespace, and a shared name would collide between releases
in one namespace. The namespace is shared with every other stack in the environment, so the Role names its objects.
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
  # The readiness probe reads the automation config Secret and patches its own pod; the version hook deletes its own pod.
  # The names cover MongoDB's 50-member maximum, so a scale-down, which goes one member at a time, keeps access.
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [{{ .name }}-config]
    verbs: [get]
  - apiGroups: [""]
    resources: [pods]
    resourceNames:
      {{- range $i := until 50 }}
      - {{ $.name }}-{{ $i }}
      {{- end }}
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
