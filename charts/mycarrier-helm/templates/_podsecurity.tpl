{{/*
Resolve the workload-item securityContext dict (opt-in hardening block) regardless of
whether the caller context is an application (.application.securityContext), a cronjob
item (.cronjob.securityContext), a job item (.job.securityContext), or neither (defaults
to an empty dict so all lookups below are no-ops and rendered output is unchanged).
The three sources are mutually exclusive (application -> cronjob -> job precedence,
matching the exclusive if/else-if chain used in _labels.tpl) since a single caller
context only ever carries one of .application/.cronjob/.job.
*/}}
{{- define "helm.workloadSecurityContext" -}}
{{- $sc := dict -}}
{{- if and .application .application.securityContext -}}
{{- $sc = .application.securityContext -}}
{{- else if and .cronjob .cronjob.securityContext -}}
{{- $sc = .cronjob.securityContext -}}
{{- else if and .job .job.securityContext -}}
{{- $sc = .job.securityContext -}}
{{- end -}}
{{- $sc | toJson -}}
{{- end -}}

{{/*
enableVaultCA no longer gates hardening here: its only other consumer,
helm.defaultLifecyclePostStart's root-requiring vault.crt postStart hook, is
dead code (helm.lifecycle, its sole caller, is fully commented out in
_lifecycle.tpl). Kyverno require-run-as-non-root is Enforce on dev, so
disableSecurity remains the sole explicit break-glass opt-out.
*/}}
{{- define "helm.podSecurityContext" -}}
{{- if not .Values.disableSecurity }}
{{- $sc := include "helm.workloadSecurityContext" . | fromJson }}
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  runAsNonRoot: true
{{- if hasKey $sc "fsGroup" }}
  fsGroup: {{ int64 $sc.fsGroup }}
{{- end }}
{{- if hasKey $sc "seccompProfile" }}
  seccompProfile:
{{ toYaml $sc.seccompProfile | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
enableVaultCA no longer gates hardening here: its only other consumer,
helm.defaultLifecyclePostStart's root-requiring vault.crt postStart hook, is
dead code (helm.lifecycle, its sole caller, is fully commented out in
_lifecycle.tpl). Kyverno require-run-as-non-root is Enforce on dev, so
disableSecurity remains the sole explicit break-glass opt-out.
*/}}
{{- define "helm.containerSecurityContext" -}}
{{- if not .Values.disableSecurity }}
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

