{{- define "helm.secretVolumeMounts" -}}
{{- $globalAppStack := .Values.global.appStack -}}
{{- $env := .Values.environment.name -}}
{{- if and .Values (hasKey .Values "secrets") (hasKey .Values.secrets "mounted") -}}
{{- range .Values.secrets.mounted -}}
- name: {{ $globalAppStack }}-{{ .name }}-{{ $env }}
  mountPath: {{ .mount.path }}
  {{- if .subPath }}
  subPath: {{ .subPath }}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "helm.secretVolumes" -}}
{{- $globalAppStack := .Values.global.appStack -}}
{{- $env := .Values.environment.name -}}
{{- if and .Values (hasKey .Values "secrets") (hasKey .Values.secrets "mounted") -}}
{{- range .Values.secrets.mounted -}}
- name: {{ $globalAppStack }}-{{ .name }}-{{ $env }}
  secret:
    secretName: {{ $globalAppStack }}-{{ .name }}-{{ $env }}
{{- end -}}
{{- end -}}
{{- end -}}

