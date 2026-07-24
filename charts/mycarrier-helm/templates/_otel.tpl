{{- define "helm.getLanguage" -}}
{{- /* This helper resolves the language from application or falls back to global */}}
{{- if and (hasKey . "application") .application (hasKey .application "language") -}}
  {{- .application.language -}}
{{- else -}}
  {{- .Values.global.language -}}
{{- end -}}
{{- end -}}

{{- /*
Is the chart managing OpenTelemetry configuration for this release?

Returns "true" unless `manualOtelConfig` is set truthy. `manualOtelConfig: true` means the consumer
supplies their own OTEL_* configuration, so the chart injects nothing OTel-related anywhere.

Defaults to chart-managed (an unset or null key means false here), making this an explicit opt-out.
Note this is the OPPOSITE default from `disableOtelAutoinstrumentation`, which is opt-in.
*/}}
{{- define "helm.otel.chartManaged" -}}
{{- $manual := .Values.manualOtelConfig -}}
{{- if kindIs "invalid" $manual -}}
{{- $manual = false -}}
{{- end -}}
{{- if not $manual -}}true{{- end -}}
{{- end -}}

{{- /*
Is the OTel Operator's automatic instrumentation enabled?

Returns "true" only when `disableOtelAutoinstrumentation` is *explicitly* false. An unset or null
key falls back to the documented default of disabled.

Do NOT reduce this to `not (.Values.disableOtelAutoinstrumentation | default true)`. Sprig's
`default` treats boolean false as empty, so `default true false` yields true and an explicit
`false` is swallowed. The null check has to be separate from the negation.
*/}}
{{- define "helm.otel.autoinstrumentation.enabled" -}}
{{- if include "helm.otel.chartManaged" . -}}
{{- $disabled := .Values.disableOtelAutoinstrumentation -}}
{{- if kindIs "invalid" $disabled -}}
{{- $disabled = true -}}
{{- end -}}
{{- if not $disabled -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{- define "helm.otel.annotations" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if $language }}
{{- $languageList := list "nodejs" "java" "python" }}
{{- if and (has $language $languageList) (include "helm.otel.autoinstrumentation.enabled" .) }}
sidecar.opentelemetry.io/inject: "true"
instrumentation.opentelemetry.io/container-names: "{{ include "helm.fullname" . }}"
instrumentation.opentelemetry.io/inject-{{ $language }}: {{ include "helm.fullname" . }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "helm.otel.labels" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if $language -}}
language: {{ $language | default "undefined" | quote}}
{{- end -}}
{{- end -}}

{{- /*
The consumer-supplied OTEL_EXPORTER_OTLP_ENDPOINT for THIS container, or "" if none.

Resolution is per-container and mutually exclusive, mirroring exactly which env sources render into
the container being built. It is deliberately NOT a flat fallback chain ending at global.env:
global.env does not reach jobs, cronjobs or initContainers, so treating it as a universal fallback
would suppress the injected endpoint in those containers while the global value never arrives,
leaving them with no endpoint at all.

Keeping the branches exclusive also lets a job's telemetry config deviate from its application's
without either inheriting from or overriding the other.
*/}}
{{- define "helm.otel.userEndpoint" -}}
{{- $key := "OTEL_EXPORTER_OTLP_ENDPOINT" -}}
{{- if hasKey . "otelUserEnv" -}}
{{- /* initContainers: only their own env renders, so callers pass it explicitly */ -}}
{{- dig $key "" (.otelUserEnv | default dict) -}}
{{- else if hasKey . "job" -}}
{{- dig $key "" ((dig "env" dict (.job | default dict)) | default dict) -}}
{{- else if hasKey . "cronjob" -}}
{{- dig $key "" ((dig "env" dict (.cronjob | default dict)) | default dict) -}}
{{- else if hasKey . "application" -}}
{{- /* main containers: global.env and application.env both render, application wins */ -}}
{{- $appEnv := (dig "env" dict (.application | default dict)) | default dict -}}
{{- $globalEnv := (dig "env" dict (.Values.global | default dict)) | default dict -}}
{{- dig $key (dig $key "" $globalEnv) $appEnv -}}
{{- end -}}
{{- end -}}

{{- /*
The complete OTel env contribution for one container, as a single contiguous block.

Emitted as one block rather than split across helpers because it depends on Kubernetes $(VAR)
expansion, which only resolves variables defined EARLIER in the same env list.
OTEL_EXPORTER_OTLP_ENDPOINT interpolates $(OTEL_HOST_IP), and OTEL_RESOURCE_ATTRIBUTES
interpolates five OTEL_RESOURCE_ATTRIBUTES_* vars. Keeping every fieldRef var ahead of every var
that interpolates one makes that contract structural instead of dependent on call-site ordering.

Order: fieldRef vars -> protocol/endpoint -> resource attributes -> exporters -> language-specific.
*/}}
{{- define "helm.otel.env" -}}
{{- if include "helm.otel.chartManaged" . -}}
{{- $language := include "helm.getLanguage" . -}}
{{- $userEndpoint := include "helm.otel.userEndpoint" . -}}
- name: K8S_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: OTEL_RESOURCE_ATTRIBUTES_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: OTEL_RESOURCE_ATTRIBUTES_POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: OTEL_RESOURCE_ATTRIBUTES_POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: OTEL_RESOURCE_ATTRIBUTES_POD_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.uid
- name: OTEL_RESOURCE_ATTRIBUTES_POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: OTEL_HOST_IP
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: status.hostIP
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
{{- if not $userEndpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: http://$(OTEL_HOST_IP):4317
{{- end }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: >-
    k8s.node.name=$(OTEL_RESOURCE_ATTRIBUTES_NODE_NAME), k8s.pod.name=$(OTEL_RESOURCE_ATTRIBUTES_POD_NAME), k8s.namespace.name=$(OTEL_RESOURCE_ATTRIBUTES_POD_NAMESPACE), k8s.pod.uid=$(OTEL_RESOURCE_ATTRIBUTES_POD_UID), k8s.pod.ip=$(OTEL_RESOURCE_ATTRIBUTES_POD_IP)
{{- if $language }}
- name: OTEL_TRACES_EXPORTER
  value: otlp
- name: OTEL_METRICS_EXPORTER
  value: otlp
- name: OTEL_LOGS_EXPORTER
  value: otlp
- name: OTEL_SERVICE_NAME
  value: {{ .Values.global.appStack }}
{{- if contains "nodejs" $language }}
- name: OTEL_NODE_RESOURCE_DETECTORS
  value: "env,host,os"
{{- if include "helm.otel.autoinstrumentation.enabled" . }}
- name: NODE_OPTIONS
  value: "--require @opentelemetry/auto-instrumentations-node/register"
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "helm.otel.volumeMounts" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if and $language (include "helm.otel.chartManaged" .) }}
- name: otel-log
  mountPath: /var/log/opentelemetry
{{- end -}}
{{- end -}}

{{- define "helm.otel.volumes" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if and $language (include "helm.otel.chartManaged" .) }}
- name: otel-log
  emptyDir: {}
{{- end -}}
{{- end -}}
