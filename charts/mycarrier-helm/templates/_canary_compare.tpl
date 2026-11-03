{{- /* The canary compare check (Tech Spec D4, DEVOPS-322): canary against stable, by pod-template hash, on the 5xx ratio
       and the p95 of http.server.request.duration in ClickStack's ClickHouse. Rendered by analysistemplate.yaml and run
       by the Rollout as background analysis (helm.canary.backgroundAnalysis) from its first weight until promotion. */ -}}

{{- /* True when the chart's compare template renders for this application: a canary Rollout whose steps render
       (helm.canary.stepsRendered; nothing else would run it), analysis.compare.enabled, and no
       applications.<app>.analysisTemplates entry named compare, which replaces it. */ -}}
{{- define "helm.canary.compare.wanted" -}}
{{- $custom := false -}}
{{- range (.application.analysisTemplates | default list) }}{{ if eq (toString .name) "compare" }}{{ $custom = true }}{{ end }}{{ end -}}
{{- if and (eq (include "helm.canary.stepsRendered" .) "true") (include "helm.canary.config" . | fromJson).analysis.compare.enabled (not $custom) }}true{{ else }}false{{ end -}}
{{- end -}}

{{- /* The histogram table the environment's metrics land in. The OTel collector routes them by namespace and
       environment (compliance observability-bootstrapper-otel-dp.yaml): prod to prod_, preprod, qa and uat to
       preprod_, everything else to dev_. */ -}}
{{- define "helm.canary.compare.table" -}}
{{- $environment := lower (toString .Values.environment.name) -}}
{{- if hasPrefix "prod" $environment -}}
hyperdx.prod_otel_metrics_histogram
{{- else if or (hasPrefix "preprod" $environment) (eq $environment "qa") (eq $environment "uat") -}}
hyperdx.preprod_otel_metrics_histogram
{{- else -}}
hyperdx.dev_otel_metrics_histogram
{{- end -}}
{{- end -}}

{{- /* The ClickHouse query, sent as the request body. Its parameters come in the URL: window (seconds), namespace,
       prefix (<fullName>-), canary and stable (the pod-template hashes).
       - Pods: the namespace's pods named <fullName>-<hash>-<suffix> (the chart sets k8s.pod.name from metadata.name,
         _otel.tpl), with the hash the second-to-last part of the name.
       - Requests with an http.route only: kubelet probes and CORS preflights have none, and would otherwise pad the
         canary's count and lower its 5xx ratio.
       - The histograms are cumulative, so each series (pod, attributes, start time) counts its last point minus its
         first in the window, for the request count and for each bucket.
       - p95 is interpolated in the bucket that holds the 95th percentile of the summed bucket deltas.
       - The query has no GROUP BY at the top, so it always answers exactly one row, also with no data: zeros, never an
         empty body or null. Every value is a Float64, which ClickHouse writes as a JSON number. */ -}}
{{- define "helm.canary.compare.query" -}}
WITH
  series AS (
    SELECT
      splitByChar('-', ResourceAttributes['k8s.pod.name'])[-2] AS hash,
      toInt32OrZero(Attributes['http.response.status_code']) >= 500 AS server_error,
      toInt64(argMax(Count, TimeUnix)) - toInt64(argMin(Count, TimeUnix)) AS delta,
      arrayMap((last, first) -> toInt64(last) - toInt64(first), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)) AS buckets,
      any(ExplicitBounds) AS bounds
    FROM {{ include "helm.canary.compare.table" . }}
    WHERE MetricName = 'http.server.request.duration'
      AND TimeUnix >= now64(9) - toIntervalSecond({window:UInt32})
      AND ResourceAttributes['k8s.namespace.name'] = {namespace:String}
      AND startsWith(ResourceAttributes['k8s.pod.name'], {prefix:String})
      AND Attributes['http.route'] != ''
    GROUP BY ResourceAttributes['k8s.pod.name'], Attributes, StartTimeUnix
    HAVING hash IN ({canary:String}, {stable:String})
  ),
  sides AS (
    SELECT
      hash,
      count() AS series,
      sum(delta) AS requests,
      sumIf(delta, server_error) AS errors,
      arrayCumSum(sumForEach(buckets)) AS cumulative,
      any(bounds) AS bounds,
      0.95 * requests AS target,
      arrayFirstIndex(c -> c >= target, cumulative) AS i,
      if(i = 0, 0,
        if(i = 1, 0, bounds[i - 1])
        + (if(i <= length(bounds), bounds[i], bounds[length(bounds)]) - if(i = 1, 0, bounds[i - 1]))
          * (target - if(i = 1, 0, cumulative[i - 1])) / greatest(cumulative[i] - if(i = 1, 0, cumulative[i - 1]), 1)) AS p95
    FROM series
    GROUP BY hash
  )
SELECT
  toFloat64(sumIf(series, hash = {canary:String})) AS canary_series,
  toFloat64(sumIf(series, hash = {stable:String})) AS stable_series,
  toFloat64(sumIf(requests, hash = {canary:String})) AS canary_requests,
  toFloat64(sumIf(requests, hash = {stable:String})) AS stable_requests,
  toFloat64(sumIf(if(requests > 0, errors / requests, 0), hash = {canary:String})) AS canary_5xx_ratio,
  toFloat64(sumIf(if(requests > 0, errors / requests, 0), hash = {stable:String})) AS stable_5xx_ratio,
  toFloat64(sumIf(p95, hash = {canary:String})) AS canary_p95,
  toFloat64(sumIf(p95, hash = {stable:String})) AS stable_p95
FROM sides
FORMAT JSONEachRow
{{- end -}}

{{- /* The metric's failureCondition. Only it is set, so a measurement that does not fail is Successful (Argo Rollouts):
       - no stable data at all fails: stable pods export their cumulative series every minute, so none means the
         metric is not emitted or the pods are not matched, and the check could never fire;
       - with at least minRequests on each side, a canary 5xx ratio above stable's by more than max5xxDelta fails, and
         so does a canary p95 above maxP95Ratio x stable's that is also more than minP95DeltaSeconds slower (the
         histogram's lowest buckets are 5 to 25 ms wide, so a ratio alone flags fast endpoints);
       - fewer requests pass: too little traffic to judge, and the dark stage's tests, health and alerts still
         gate the canary. */ -}}
{{- define "helm.canary.compare.failureCondition" -}}
{{- $c := (include "helm.canary.config" . | fromJson).analysis.compare -}}
{{- printf "result.stable_series == 0 || (result.canary_requests >= %v && result.stable_requests >= %v && (result.canary_5xx_ratio - result.stable_5xx_ratio > %v || (result.canary_p95 > result.stable_p95 * %v && result.canary_p95 - result.stable_p95 > %v)))" $c.minRequests $c.minRequests $c.max5xxDelta $c.maxP95Ratio $c.minP95DeltaSeconds -}}
{{- end -}}

{{- /* The query window in seconds: analysis.compare.interval plus one 60 s metric export, so consecutive windows
       overlap by an export and no requests between two measurements go uncounted. */ -}}
{{- define "helm.canary.compare.windowSeconds" -}}
{{- add (include "helm.canary.durationSeconds" (include "helm.canary.config" . | fromJson).analysis.compare.interval | int) 60 -}}
{{- end -}}
