{{/*
Generated credentials: one Password generator and an ExternalSecret per user. Each ExternalSecret writes a Secret
holding the generated password (read by the operator) and the connection string consumers use. CreatedOnce keeps
the password stable across syncs; deleting and recreating an ExternalSecret regenerates it (its Secret is owned and
goes with it), and the operator then updates the user to match.
Usage: include "mc-mongodb.credentials" $ctx
*/}}
{{- define "mc-mongodb.credentials" -}}
{{- $host := printf "%s-svc.%s.svc.cluster.local:27017" .name .namespace }}
{{- $query := printf "replicaSet=%s&authSource=admin" .name }}
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: {{ .name }}-password
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  length: {{ .password.length }}
  digits: 6
  symbols: 0
  noUpper: false
  allowRepeat: true
{{- range $user := list
  (dict "suffix" "app" "secret" (printf "%s-connection" .name) "username" .appUser.name "database" .appUser.database)
  (dict "suffix" "backup" "secret" (printf "%s-backup-connection" .name) "username" "backup" "database" "") }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $.name }}-{{ $user.suffix }}
  namespace: {{ $.namespace }}
  labels:
    {{- toYaml $.labels | nindent 4 }}
spec:
  refreshPolicy: CreatedOnce
  target:
    name: {{ $user.secret }}
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      data:
        password: {{ "{{ .password }}" | quote }}
        connectionString: {{ printf "mongodb://%s:{{ .password }}@%s/%s?%s" $user.username $host $user.database $query | quote }}
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: {{ $.name }}-password
{{- end }}
{{- end }}
