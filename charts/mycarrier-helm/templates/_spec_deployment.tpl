{{- define "helm.specs.deployment" -}}
{{- if and (ne "true" (include "helm.hpaCondition" . | trim)) (ne "true" (include "helm.kedaCondition" . | trim)) }}
{{- include "helm.specs.replicas" . }}
{{- end }}
revisionHistoryLimit: 2
minReadySeconds: {{ .application.minReadySeconds | default 0 }}
strategy:
{{- /* Only the Deployment strategy keys: a leftover updateStrategy.canary block (refused for any app that renders a
       Rollout since 4.5.0; canary settings live in global.strategy.canary) is not a Deployment strategy. */}}
{{- $deploymentStrategy := pick (.application.updateStrategy | default dict) "type" "rollingUpdate" }}
{{- if $deploymentStrategy }}
  {{ toYaml $deploymentStrategy | indent 2 | trim }}
{{- else }}
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 2
{{- end }}
selector:
  matchLabels:
    {{ include "helm.labels.selector" . | indent 4 | trim }}
{{ include "helm.specs.podTemplate" . }}
{{- end -}}