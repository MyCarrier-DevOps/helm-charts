{{- define "helm.secretVolumeMounts" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $env := .Values.global.environment.name -}}
{{if .Values.secrets.mounted -}}
{{- range .Values.secrets.mounted -}}
- name: {{ $fullName }}-{{ .name }}-{{ $env }}
  mountPath: {{ .mount.path }}
  {{- if .subPath }}
  subPath: {{ .subPath }}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "helm.secretVolumes" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $env := .Values.global.environment.name -}}
{{if .Values.secrets.mounted -}}
{{- range .Values.secrets.mounted -}}
- name: {{ $fullName }}-{{ .name }}-{{ $env }}
  secret:
    secretName: {{ $fullName }}-{{ .name }}-{{ $env }}
{{- end -}}
{{- end -}}
{{- end -}}

