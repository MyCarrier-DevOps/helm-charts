{{/*
The standard alerts every stack gets, ported from AlertManagement's service-alert template. Rule uids keep
AlertManagement's scheme so Grafana keeps each rule's state, silences and history at cutover; they never depend on
severity or title.
*/}}

{{/*
helm.alerts.standardSettings: the language's standard alerts (helm.lang.alerts) with alerts.standard applied over
each alert, as a JSON object. An override replaces the default, including false, 0 and empty lists.
*/}}
{{- define "helm.alerts.standardSettings" -}}
{{- $settings := include "helm.lang.alerts" . | fromYaml -}}
{{- range $key, $override := (.Values.alerts.standard | default dict) -}}
{{- if not (hasKey $settings $key) -}}
{{- fail (printf "alerts.standard.%s is set, but language %q has no standard alerts; use alerts.additional" $key (toString $.Values.global.language)) -}}
{{- end -}}
{{- $_ := mergeOverwrite (index $settings $key) $override -}}
{{- end -}}
{{- toJson $settings -}}
{{- end -}}

{{/* helm.alerts.standardRules: the enabled standard rules as a JSON list, in catalogue order. */}}
{{- define "helm.alerts.standardRules" -}}
{{- $alerts := .Values.alerts -}}
{{- $standard := include "helm.alerts.standardSettings" . | fromJson -}}
{{- $ctx := dict
      "alerts" $alerts
      "name" (include "helm.alerts.name" .)
      "excludedPaths" (dig "filters" "excludedPaths" (list) $alerts)
      "observabilityName" ($alerts.observabilityName | default .Values.global.appStack) -}}
{{- $rules := list -}}
{{- range $key := list "serverErrorRatio" "clientErrorRatio" "serverErrorCount" "http503Returned" "http503Received" "availabilityProbe" "nonHttpErrors" -}}
{{- $rule := index $standard $key -}}
{{- if and $rule $rule.enabled -}}
{{- $rules = append $rules (include (printf "helm.alerts.standard.%s" $key) (merge (dict "rule" $rule) $ctx) | fromJson) -}}
{{- end -}}
{{- end -}}
{{- toJson $rules -}}
{{- end -}}

{{/*
helm.alerts.standardRule applies what every standard rule shares: the [SevN] title prefix (unless title is set),
labels, the description annotation and per-rule overrides of paused, noDataState and execErrState.
*/}}
{{- define "helm.alerts.standardRule" -}}
{{- $rule := .rule -}}
{{- $severity := toString $rule.severity -}}
{{- $labels := dict
      "alertType" .alertType
      "severity" $severity
      "service" (lower .alerts.serviceName)
      "alertSource" "mycarrier-helm"
      "confluence" (include "helm.alerts.confluence" (dict "anchor" .anchor)) -}}
{{- if .hyperdx -}}
{{- $_ := set $labels "hyperdx" .hyperdx -}}
{{- end -}}
{{- $params := dict
      "uid" .uid
      "title" ($rule.title | default (printf "[%s] %s" (title $severity) .title))
      "sql" .sql
      "threshold" .threshold
      "evaluator" .evaluator
      "reducer" .reducer
      "timeRange" 300
      "for" $rule.for
      "noDataState" ($rule.noDataState | default .noDataState)
      "execErrState" ($rule.execErrState | default "KeepLast")
      "paused" (ternary $rule.paused .alerts.paused (hasKey $rule "paused"))
      "labels" $labels
      "annotations" (dict "description" .description) -}}
{{- include "helm.alerts.rule" $params -}}
{{- end -}}

{{- define "helm.alerts.standard.serverErrorRatio" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_sev1_http_errors" (trunc 23 .name))
      "title" (printf "%s Server HTTP Errors > %v%% in 5m" .alerts.displayName .rule.threshold)
      "alertType" "server_http_errors"
      "sql" (include "helm.alerts.sql.errorRatio" (dict "column" "ServerError" "service" .alerts.serviceName "excluded" .excludedPaths))
      "evaluator" "gt" "reducer" "last" "threshold" .rule.threshold "noDataState" "OK"
      "description" (printf "More than %v%% server http errors in %s service over the last 5 minutes." .rule.threshold .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.status" (dict "service" .alerts.serviceName "filter" "SpanAttributes.url.path:*+SpanAttributes.http.response.status_code:%3E=500"))) -}}
{{- end -}}

{{- define "helm.alerts.standard.clientErrorRatio" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_sev2_http_errors" (trunc 23 .name))
      "title" (printf "%s Client HTTP Errors > %v%% in 5m" .alerts.displayName .rule.threshold)
      "alertType" "client_http_errors"
      "sql" (include "helm.alerts.sql.errorRatio" (dict "column" "ClientError" "service" .alerts.serviceName "excluded" .excludedPaths))
      "evaluator" "gt" "reducer" "last" "threshold" .rule.threshold "noDataState" "OK"
      "description" (printf "More than %v%% client http errors in %s service over the last 5 minutes." .rule.threshold .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.status" (dict "service" .alerts.serviceName "filter" "SpanAttributes.url.path:*+SpanAttributes.http.response.status_code:%3E=400+SpanAttributes.http.response.status_code:%3C499"))) -}}
{{- end -}}

{{- define "helm.alerts.standard.serverErrorCount" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_http_errors" (trunc 28 .name))
      "title" (printf "%s HTTP Errors > %v in 5m" .alerts.displayName .rule.threshold)
      "alertType" "http_errors"
      "sql" (include "helm.alerts.sql.serverErrorCount" (dict "service" .alerts.serviceName "excluded" .excludedPaths))
      "evaluator" "gt" "reducer" "last" "threshold" .rule.threshold "noDataState" "OK"
      "description" (printf "More than %v http errors in %s service over the last 5 minutes." .rule.threshold .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.status" (dict "service" .alerts.serviceName "filter" "SpanAttributes.url.path:*+SpanAttributes.http.response.status_code:%3E=500"))) -}}
{{- end -}}

{{- define "helm.alerts.standard.http503Returned" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_sev1_503_returned" (trunc 21 .name))
      "title" (printf "%s HTTP 503 Service Unavailable in 5m" .alerts.displayName)
      "alertType" "http_503_returned"
      "sql" (include "helm.alerts.sql.http503Returned" (dict "service" .alerts.serviceName "excluded" (concat (.rule.probePaths | default list) .excludedPaths)))
      "evaluator" "gt" "reducer" "last" "threshold" (.rule.threshold | default 0) "noDataState" "OK"
      "description" (printf "%s returned HTTP 503 Service Unavailable to a caller over the last 5 minutes. Kubernetes probe endpoints are excluded." .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.503" (dict "service" .alerts.serviceName "kind" "Server" "column" "SpanAttributes[%27url.path%27]+as+UrlPath"))) -}}
{{- end -}}

{{- define "helm.alerts.standard.http503Received" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_sev2_503_received" (trunc 21 .name))
      "title" (printf "%s Dependency HTTP 503 in 5m" .alerts.displayName)
      "alertType" "http_503_received"
      "sql" (include "helm.alerts.sql.http503Received" (dict "service" .alerts.serviceName "excludedHosts" (.rule.excludedHosts | default list)))
      "evaluator" "gt" "reducer" "last" "threshold" (.rule.threshold | default 0) "noDataState" "OK"
      "description" (printf "%s received HTTP 503 Service Unavailable from an upstream dependency over the last 5 minutes." .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.503" (dict "service" .alerts.serviceName "kind" "Client" "column" "SpanAttributes[%27server.address%27]+as+Dependency"))) -}}
{{- end -}}

{{- define "helm.alerts.standard.availabilityProbe" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" "#Sev1-availability-probe-failure-alert"
      "uid" (printf "%s_avail_probe_fail" (trunc 23 .name))
      "title" (printf "%s Availability Probe Failure" .alerts.displayName)
      "alertType" "availability_probe_failure"
      "sql" (include "helm.alerts.sql.availabilityProbe" (dict "service" .observabilityName "excludedComponents" (.rule.excludedComponents | default list)))
      "evaluator" "eq" "reducer" "min" "threshold" 0 "noDataState" "KeepLast"
      "description" (printf "Availability probe failure in %s over the last 1 minutes." .alerts.displayName)
      "hyperdx" "") -}}
{{- end -}}

{{- define "helm.alerts.standard.nonHttpErrors" -}}
{{- include "helm.alerts.standardRule" (dict
      "alerts" .alerts "rule" .rule "anchor" ""
      "uid" (printf "%s_non_http_errors" (trunc 24 .name))
      "title" (printf "%s Non HTTP Errors > %v in 5m" .alerts.displayName .rule.threshold)
      "alertType" "non_http_errors"
      "sql" (include "helm.alerts.sql.nonHttpErrors" (dict "service" .alerts.serviceName "suffix" (.rule.apiServiceSuffix | default "")))
      "evaluator" "gt" "reducer" "last" "threshold" .rule.threshold "noDataState" "OK"
      "description" (printf "More than %v non http errors in %s service over the last 5 minutes." .rule.threshold .alerts.displayName)
      "hyperdx" (include "helm.alerts.hyperdx.logs" (dict "service" .alerts.serviceName "suffix" (.rule.apiServiceSuffix | default "")))) -}}
{{- end -}}

{{/* ── ClickHouse queries ─────────────────────────────────────────────────────────────────────────────── */}}

{{- define "helm.alerts.sql.pathFilter" -}}
{{- if . }}
    AND SpanAttributes['url.path'] NOT IN ({{ include "helm.alerts.sqlList" . }})
{{- end -}}
{{- end -}}

{{- define "helm.alerts.sql.errorRatio" -}}
WITH
(
  SELECT count(*) as value
  FROM hyperdx.l5m_traces
  WHERE {{ .column }} = 1
    AND SpanAttributes['url.path'] != ''
{{- include "helm.alerts.sql.pathFilter" .excluded }}
    AND ServiceName LIKE '{{ .service }}%'
    AND Timestamp > now() - INTERVAL 5 MINUTE
) as http_errors,
(
  SELECT count(*) as value
  FROM hyperdx.l5m_traces
  WHERE ServerError = 0 AND ClientError = 0
    AND SpanAttributes['url.path'] != ''
{{- include "helm.alerts.sql.pathFilter" .excluded }}
    AND ServiceName LIKE '{{ .service }}%'
    AND Timestamp > now() - INTERVAL 5 MINUTE
) as http_non_errors

select http_errors * 100 / http_non_errors as value
{{- end -}}

{{- define "helm.alerts.sql.serverErrorCount" -}}
SELECT count(*) as value
FROM hyperdx.l5m_traces
WHERE ServerError = 1
    AND SpanAttributes['url.path'] != ''
{{- include "helm.alerts.sql.pathFilter" .excluded }}
    AND ServiceName LIKE '{{ .service }}%'
    AND Timestamp > now() - INTERVAL 5 MINUTE
{{- end -}}

{{- define "helm.alerts.sql.http503Returned" -}}
SELECT count(*) as value
FROM hyperdx.l5m_traces
WHERE HttpStatus = 503
    AND SpanKind = 'Server'
    AND SpanAttributes['url.path'] != ''
{{- include "helm.alerts.sql.pathFilter" .excluded }}
    AND ServiceName LIKE '{{ .service }}%'
    AND Timestamp > now() - INTERVAL 5 MINUTE
{{- end -}}

{{- define "helm.alerts.sql.http503Received" -}}
SELECT count(*) as value
FROM hyperdx.l5m_traces
WHERE HttpStatus = 503
    AND SpanKind = 'Client'
{{- if .excludedHosts }}
    AND SpanAttributes['server.address'] NOT IN ({{ include "helm.alerts.sqlList" .excludedHosts }})
{{- end }}
    AND ServiceName LIKE '{{ .service }}%'
    AND Timestamp > now() - INTERVAL 5 MINUTE
{{- end -}}

{{- define "helm.alerts.sql.availabilityProbe" -}}
SELECT
  Service,
  Component,
  state
FROM observability.availability
WHERE
  Service = '{{ .service }}'
{{- if .excludedComponents }}
  AND Component NOT IN ({{ include "helm.alerts.sqlList" .excludedComponents }})
{{- end }}
ORDER BY Timestamp DESC
{{- end -}}

{{- define "helm.alerts.sql.nonHttpErrors" -}}
SELECT count(*) as value
FROM hyperdx.prod_otel_logs
WHERE SeverityText = 'Error'
    AND ServiceName LIKE '{{ .service }}%'
{{- if .suffix }}
    AND ServiceName NOT LIKE '{{ .service }}%{{ .suffix }}'
{{- end }}
    AND Timestamp > now() - INTERVAL 5 MINUTE
{{- end -}}

{{/* ── HyperDX search links ───────────────────────────────────────────────────────────────────────────── */}}

{{- define "helm.alerts.hyperdx.status" -}}
https://hyperdx.mycarrier.tech/search?isLive=false&source=68097c857e80cf9d5670b13c&where=ServiceName:{{ .service }}*+{{ .filter }}&select=Timestamp,+ServiceName,+StatusCode,+round(Duration+/+1e6)+as+DurationMs,+SpanAttributes[%27http.response.status_code%27]+as+HttpResponseCode,+SpanName&whereLanguage=lucene&orderBy=Timestamp+DESC&from=1749156178000&to=1749157078000&filters=[]
{{- end -}}

{{- define "helm.alerts.hyperdx.503" -}}
https://hyperdx.mycarrier.tech/search?isLive=false&source=68097c857e80cf9d5670b13c&where=ServiceName:{{ .service }}*+SpanKind:{{ .kind }}+SpanAttributes.http.response.status_code:503&select=Timestamp,+ServiceName,+SpanName,+{{ .column }},+SpanAttributes[%27http.response.status_code%27]+as+HttpResponseCode&whereLanguage=lucene&orderBy=Timestamp+DESC
{{- end -}}

{{- define "helm.alerts.hyperdx.logs" -}}
https://hyperdx.mycarrier.tech/search?isLive=false&source=68097c577e80cf9d5670b11c&where=SeverityText+=+%27Error%27+AND+ServiceName+LIKE+%27{{ .service }}%25%27{{ if .suffix }}+AND+ServiceName+NOT+LIKE+%27{{ .service }}%25{{ .suffix }}%27{{ end }}&select=Timestamp,+ServiceName,+SeverityText,+Body&whereLanguage=sql&orderBy=TimestampTime+DESC
{{- end -}}
