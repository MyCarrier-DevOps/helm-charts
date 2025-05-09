{{- define "helm.secretVolumeMounts" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $env := .Values.environment.name -}}
{{- if and .Values (hasKey .Values "secrets") (hasKey .Values.secrets "mounted") -}}
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
{{- $env := .Values.environment.name -}}
{{- if and .Values (hasKey .Values "secrets") (hasKey .Values.secrets "mounted") -}}
{{- range .Values.secrets.mounted -}}
- name: {{ $fullName }}-{{ .name }}-{{ $env }}
  secret:
    secretName: {{ $fullName }}-{{ .name }}-{{ $env }}
{{- end -}}
{{- end -}}
{{- end -}}

