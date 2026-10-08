{{/*
Alert helpers. Alerts render only when alerts.enabled is true and environment.name is listed in
alerts.environments, but are validated in every environment while alerts.enabled is true, so a values mistake fails
the first environment's render rather than prod's. Every alert resource lives under templates/alerts/ so GitOps
consumers can split them by path.
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
fields when alerts are enabled, the shape of additional rules and the rule checks of helm.alerts.rules. The schema
enforces the standard keys and severities. Only alertrulegroup.yaml calls it, in every environment while
alerts.enabled is true; the three alert templates always render together.
*/}}
{{- define "helm.alerts.validate" -}}
{{- $alerts := .Values.alerts -}}
{{- if not $alerts.serviceName -}}
{{- fail "alerts.serviceName is required when alerts are enabled" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]+$" (toString $alerts.displayName)) -}}
{{- fail "alerts.displayName is required when alerts are enabled and must match [A-Za-z0-9]+" -}}
{{- end -}}
{{- $severities := list "sev1" "sev2" "sev3" -}}
{{- range $key, $rule := ($alerts.additional | default dict) -}}
{{- if hasKey $rule "rule" -}}
{{- range $field := list "uid" "title" "condition" "data" -}}
{{- if not (hasKey $rule.rule $field) -}}
{{- fail (printf "alerts.additional.%s.rule.%s is required" $key $field) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- range $field := list "title" "severity" "sql" -}}
{{- if not (index $rule $field) -}}
{{- fail (printf "alerts.additional.%s.%s is required" $key $field) -}}
{{- end -}}
{{- end -}}
{{- if not (has (toString $rule.severity) $severities) -}}
{{- fail (printf "alerts.additional.%s.severity must be one of sev1, sev2, sev3" $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $_ := include "helm.alerts.rules" . -}}
{{- end -}}

{{/*
helm.alerts.rules: every enabled rule as a JSON list, standard rules first, then additional rules by key; fails
when there is none (the CRD requires one).
*/}}
{{- define "helm.alerts.rules" -}}
{{- $alerts := .Values.alerts -}}
{{- $name := include "helm.alerts.name" . -}}
{{- $rules := include "helm.alerts.standardRules" . | fromJsonArray -}}
{{- range $key, $rule := ($alerts.additional | default dict) -}}
{{- if dig "enabled" true $rule -}}
{{- if hasKey $rule "rule" -}}
{{- $raw := deepCopy $rule.rule -}}
{{- $labels := $raw.labels | default dict -}}
{{- $_ := set $labels "alertSource" "mycarrier-helm" -}}
{{- if not (hasKey $labels "service") -}}
{{- $_ := set $labels "service" (lower $alerts.serviceName) -}}
{{- end -}}
{{- $_ := set $raw "labels" $labels -}}
{{- $rules = append $rules $raw -}}
{{- else -}}
{{- $condition := $rule.condition | default dict -}}
{{- $labels := dict
      "alertType" ($rule.alertType | default (snakecase $key))
      "severity" $rule.severity
      "service" (lower $alerts.serviceName)
      "alertSource" "mycarrier-helm"
      "confluence" (include "helm.alerts.confluence" (dict "anchor" "")) -}}
{{- $compact := dict
      "uid" ($rule.uid | default (printf "%s_%s" $name (snakecase $key)))
      "title" $rule.title
      "sql" $rule.sql
      "threshold" (dig "threshold" 0 $condition)
      "evaluator" ($condition.type | default "gt")
      "reducer" ($condition.reducer | default "last")
      "timeRange" ($rule.timeRange | default 300)
      "for" ($rule.for | default "5m")
      "noDataState" ($rule.noDataState | default "OK")
      "execErrState" ($rule.execErrState | default "KeepLast")
      "paused" (ternary $rule.paused $alerts.paused (hasKey $rule "paused"))
      "labels" (mergeOverwrite $labels ($rule.labels | default dict))
      "annotations" ($rule.annotations | default dict) -}}
{{- $rules = append $rules (include "helm.alerts.rule" $compact | fromJson) -}}
{{- end -}}
{{- end -}}
{{- end -}}
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
