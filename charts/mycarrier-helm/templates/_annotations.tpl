{{/*
Emit the user-supplied annotations that do NOT collide with chart-managed keys.
Chart-managed keys always win: a colliding user key is dropped rather than emitted
as a duplicate YAML key. Returns "" when nothing survives, so callers can guard with `if`.
*/}}
{{- define "helm.annotations.userExtra" -}}
{{- $reserved := .reserved | default dict -}}
{{- /* Fail fast on a CHART-AUTHORED parse failure only. `fromYaml` returns a non-empty
     {"Error": "..."} map (not nil) when one of the chart's own annotation snippets fails
     to parse as YAML, so a plain `hasKey $reserved "Error"` here can only be tripped by
     chart-managed content: $reserved is built exclusively from `include ... | fromYaml`
     calls over chart templates (helm.annotations.vault/istio/gateway, helm.otel.annotations,
     helm.annotations.cronjobMetadata/jobMetadata, the argocd reserved-key dict) — user
     annotations are never merged into $reserved, only compared against it below — so a
     user annotation literally keyed "Error" cannot land in $reserved and cannot trigger
     this guard. Do NOT generalise this into failing on user input: the chart's policy is
     that a colliding user key is silently dropped (see the file header comment), never
     fatal. */ -}}
{{- if hasKey $reserved "Error" }}{{- fail (printf "helm.annotations.userExtra: chart-managed annotations failed to parse: %v" (get $reserved "Error")) }}{{- end }}
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

{{/*
The chart-managed Job *metadata* annotations (as opposed to the pod-template annotations
covered by helm.annotations.vault / helm.otel.annotations). Kept as its own define so
jobs.yaml can derive its reserved-key set from the exact same source it renders from,
rather than hardcoding the key twice and risking drift.
*/}}
{{- define "helm.annotations.jobMetadata" -}}
argocd.argoproj.io/sync-options: Force=true,Replace=true
{{- end -}}
