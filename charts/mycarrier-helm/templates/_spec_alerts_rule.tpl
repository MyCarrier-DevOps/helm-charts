{{/*
helm.alerts.rule renders one Grafana alert rule as JSON: a ClickHouse query (refId A) and a classic condition
(refId C). Input dict keys: uid, title, sql, threshold, evaluator, reducer, timeRange, for, noDataState,
execErrState, paused, labels, annotations.
*/}}
{{- define "helm.alerts.rule" -}}
{{- $range := dict "from" .timeRange "to" 0 -}}
{{- $model := dict
      "refId" "A" "editorType" "sql" "format" 1 "queryType" "table" "rawSql" .sql
      "intervalMs" 60000 "maxDataPoints" 43200 -}}
{{- $query := dict
      "refId" "A" "queryType" "table" "relativeTimeRange" $range "datasourceUid" "clickhouse" "model" $model -}}
{{- $condition := dict
      "evaluator" (dict "params" (list .threshold) "type" .evaluator)
      "operator" (dict "type" "and")
      "query" (dict "params" (list "A"))
      "reducer" (dict "type" .reducer) -}}
{{- $expression := dict
      "refId" "C" "datasourceUid" "__expr__" "queryType" "threshold" "relativeTimeRange" $range
      "model" (dict "refId" "C" "type" "classic_conditions" "conditions" (list $condition)) -}}
{{- $rule := dict
      "uid" .uid "title" .title "isPaused" .paused "condition" "C" "data" (list $query $expression)
      "noDataState" .noDataState "execErrState" .execErrState "for" .for
      "annotations" .annotations "labels" .labels -}}
{{- toJson $rule -}}
{{- end -}}
