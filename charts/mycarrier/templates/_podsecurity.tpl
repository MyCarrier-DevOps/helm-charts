{{- define "helm.podSecurityContext" -}}
{{- if and (not .Values.enableVaultCA) (not .Values.disableSecurity) }}
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  runAsNonRoot: true
{{- end }}
{{- end -}}

{{- define "helm.containerSecurityContext" -}}
{{- if and (not .Values.enableVaultCA) (not .Values.disableSecurity) }}
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  privileged: false
  runAsNonRoot: true
  readOnlyRootFilesystem: {{ if and .application .application.securityContext .application.securityContext.readOnlyRootFilesystem }}true{{ else }}false{{ end }}
  allowPrivilegeEscalation: false
{{- end }}
{{- end -}}

