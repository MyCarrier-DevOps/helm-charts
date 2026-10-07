{{/*
Alert helpers. Alerts render only when alerts.enabled is true and environment.name is listed in
alerts.environments; every alert resource lives under templates/alerts/ so GitOps consumers can split them by path.
*/}}

{{/* helm.alerts.enabled: "true" when the alert templates render. */}}
{{- define "helm.alerts.enabled" -}}
{{- $alerts := .Values.alerts | default dict -}}
{{- if and $alerts.enabled (has .Values.environment.name ($alerts.environments | default list)) -}}
true
{{- end -}}
{{- end -}}

{{/* helm.alerts.name: displayName lowercased, the stem of every resource name and rule uid. */}}
{{- define "helm.alerts.name" -}}
{{- .Values.alerts.displayName | lower -}}
{{- end -}}

{{/* helm.alerts.sqlList: a list as a SQL string list, 'a','b', with single quotes doubled. */}}
{{- define "helm.alerts.sqlList" -}}
{{- $items := list -}}
{{- range . -}}
{{- $items = append $items (printf "'%s'" (replace "'" "''" (toString .))) -}}
{{- end -}}
{{- join "," $items -}}
{{- end -}}

{{/*
helm.alerts.validate fails the render, naming the field, for what values.schema.json cannot express: required
fields when alerts are enabled and the shape of additional rules. The schema enforces the standard keys and
severities. Only alertrulegroup.yaml calls it; the three alert templates always render together.
*/}}
{{- define "helm.alerts.validate" -}}
{{- $alerts := .Values.alerts -}}
{{- if not $alerts.serviceName -}}
{{- fail "alerts.serviceName is required when alerts are enabled" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]+$" (toString $alerts.displayName)) -}}
{{- fail "alerts.displayName is required when alerts are enabled and must match [A-Za-z0-9]+" -}}
{{- end -}}
{{- end -}}

{{/* helm.alerts.rules: every enabled rule as a JSON list; fails when there is none (the CRD requires one). */}}
{{- define "helm.alerts.rules" -}}
{{- $alerts := .Values.alerts -}}
{{- $rules := include "helm.alerts.standardRules" . | fromJsonArray -}}
{{- if not $rules -}}
{{- fail "alerts are enabled but no alert rule is enabled; a rule group needs at least one (enable a standard alert or add one under alerts.additional)" -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $rules -}}
{{- $uid := toString .uid -}}
{{- if or (gt (len $uid) 40) (not (regexMatch "^[A-Za-z0-9_-]+$" $uid)) -}}
{{- fail (printf "alert rule uid %q must be at most 40 characters of [A-Za-z0-9_-]" $uid) -}}
{{- end -}}
{{- if hasKey $seen $uid -}}
{{- fail (printf "alert rule uid %q is used more than once" $uid) -}}
{{- end -}}
{{- $_ := set $seen $uid true -}}
{{- end -}}
{{- toJson $rules -}}
{{- end -}}

{{/* helm.alerts.confluence: the "I've got an alert from grafana" runbook, optionally at an anchor. */}}
{{- define "helm.alerts.confluence" -}}
https://integratedtransportationmanagement.atlassian.net/wiki/spaces/~7120202a257556b56643019e4eca311640971f/pages/4527325285/I+ve+got+an+alert+from+grafana+what+do+I+do{{ .anchor }}
{{- end -}}
