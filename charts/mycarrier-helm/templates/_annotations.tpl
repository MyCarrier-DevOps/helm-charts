{{/*
Emit the user-supplied annotations that do NOT collide with chart-managed keys.
Chart-managed keys always win: a colliding user key is dropped rather than emitted
as a duplicate YAML key. Returns "" when nothing survives, so callers can guard with `if`.
*/}}
{{- define "helm.annotations.userExtra" -}}
{{- $reserved := .reserved | default dict -}}
{{- $out := dict -}}
{{- range $k, $v := (.user | default dict) -}}
{{- if not (hasKey $reserved $k) -}}
{{- $_ := set $out $k $v -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}

{{/*
The chart-managed CronJob *metadata* annotations (as opposed to the pod-template annotations
covered by helm.annotations.vault / helm.otel.annotations). Kept as its own define so
cronjob.yaml can derive its reserved-key set from the exact same source it renders from,
rather than hardcoding the key twice and risking drift.
*/}}
{{- define "helm.annotations.cronjobMetadata" -}}
argocd.argoproj.io/sync-options: Prune=true
{{- end -}}
