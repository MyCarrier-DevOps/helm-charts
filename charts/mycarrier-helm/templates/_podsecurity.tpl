{{/*
Resolve the workload-item securityContext dict (opt-in hardening block) regardless of
whether the caller context is an application (.application.securityContext), a cronjob
item (.cronjob.securityContext), a job item (.job.securityContext), or neither (defaults
to an empty dict so all lookups below are no-ops and rendered output is unchanged).
*/}}
{{- define "helm.workloadSecurityContext" -}}
{{- $sc := dict -}}
{{- if and .application .application.securityContext -}}
{{- $sc = .application.securityContext -}}
{{- end -}}
{{- if and .cronjob .cronjob.securityContext -}}
{{- $sc = .cronjob.securityContext -}}
{{- end -}}
{{- if and .job .job.securityContext -}}
{{- $sc = .job.securityContext -}}
{{- end -}}
{{- $sc | toJson -}}
{{- end -}}

{{- define "helm.podSecurityContext" -}}
{{- if and (not .Values.enableVaultCA) (not .Values.disableSecurity) }}
{{- $sc := include "helm.workloadSecurityContext" . | fromJson }}
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  runAsNonRoot: true
{{- with $sc.fsGroup }}
  fsGroup: {{ int64 . }}
{{- end }}
{{- with $sc.seccompProfile }}
  seccompProfile:
{{ toYaml . | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "helm.containerSecurityContext" -}}
{{- if and (not .Values.enableVaultCA) (not .Values.disableSecurity) }}
{{- $sc := include "helm.workloadSecurityContext" . | fromJson }}
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  privileged: false
  runAsNonRoot: true
  readOnlyRootFilesystem: {{ if $sc.readOnlyRootFilesystem }}true{{ else }}false{{ end }}
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
{{- if .application }}
{{- with (dig "securityContext" "addCapabilities" (list) .application) }}
    add:
{{ toYaml . | indent 6 }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

