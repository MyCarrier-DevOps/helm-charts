{{- define "helm.otel.annotations" -}}
{{- if .Values.global.language }}
{{- $languageList := list "nodejs" "java" "python" }}
{{- if and (has .Values.global.language $languageList) (not .Values.disableOtelAutoinstrumentation | default true) }}
sidecar.opentelemetry.io/inject: "true"
instrumentation.opentelemetry.io/container-names: "{{ include "helm.fullname" . }}"
instrumentation.opentelemetry.io/inject-{{ .Values.global.language }}: {{ include "helm.fullname" . }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "helm.otel.labels" -}}
{{- if .Values.global.language -}}
language: {{ .Values.global.language | default "undefined" | quote}}
{{- end -}}
{{- end -}}

{{- define "helm.otel.envVars" -}}
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
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: http://$(OTEL_HOST_IP):4317
- name: OTEL_RESOURCE_ATTRIBUTES
  value: >-
    k8s.node.name=$(OTEL_RESOURCE_ATTRIBUTES_NODE_NAME), k8s.pod.name=$(OTEL_RESOURCE_ATTRIBUTES_POD_NAME), k8s.namespace.name=$(OTEL_RESOURCE_ATTRIBUTES_POD_NAMESPACE), k8s.pod.uid=$(OTEL_RESOURCE_ATTRIBUTES_POD_UID), k8s.pod.ip=$(OTEL_RESOURCE_ATTRIBUTES_POD_IP)
{{- end -}}

{{- define "helm.otel.language" -}}
{{- if .Values.global.language }}
{{- if and (contains "csharp" .Values.global.language) (not .Values.disableOtelAutoinstrumentation | default true) }}
- name: "COR_ENABLE_PROFILING"
  value: "1"
- name: "COR_PROFILER"
  value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
- name: "CORECLR_ENABLE_PROFILING"
  value: "1"
- name: "CORECLR_PROFILER"
  value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
- name: "CORECLR_PROFILER_PATH"
  value: "/opt/opentelemetry/OpenTelemetry.AutoInstrumentation.Native.so"
- name: "OTEL_DOTNET_AUTO_HOME"
  value: "/opt/opentelemetry"
- name: "DOTNET_ADDITIONAL_DEPS"
  value: "/opt/opentelemetry/AdditionalDeps"
- name: "DOTNET_SHARED_STORE"
  value: "/opt/opentelemetry/store"
- name: "DOTNET_STARTUP_HOOKS"
  value: "/opt/opentelemetry/netcoreapp3.1/OpenTelemetry.AutoInstrumentation.StartupHook.dll"
- name: "OTEL_DOTNET_AUTO_INTEGRATIONS_FILE"
  value: "/opt/opentelemetry/integrations.json"
- name: "OTEL_DOTNET_AUTO_TRACES_ENABLED_INSTRUMENTATIONS"
  value: "AspNet,HttpClient,MongoDb,SqlClient,Elasticsearch,MassTransit"
- name: "OTEL_DOTNET_AUTO_METRICS_ENABLED_INSTRUMENTATIONS"
  value: "AspNet,HttpClient,NetRuntime"
  {{/* value: {{ coalesce Values.application.env.OTEL_DOTNET_AUTO_METRICS_ENABLED_INSTRUMENTATIONS .Values.statefulset.env.OTEL_DOTNET_AUTO_METRICS_ENABLED_INSTRUMENTATIONS "AspNet,HttpClient,NetRuntime" }} */}}
- name: "OTEL_DOTNET_AUTO_SQLCLIENT_ADD_DB_STATEMENT"
  value: "true"
{{- end }}
{{- $languageList := list "nodejs" "java" "python" }}
{{- if has .Values.global.language $languageList }}
{{- end }}
{{- if contains "nodejs" .Values.global.language }}
- name: OTEL_TRACES_EXPORTER
  value: otlp
- name: OTEL_METRICS_EXPORTER
  value: otlp
- name: OTEL_LOGS_EXPORTER
  value: otlp
- name: OTEL_NODE_RESOURCE_DETECTORS
  value: "env,host,os"
- name: OTEL_SERVICE_NAME
  value: {{ .Values.global.appStack }}
{{- if not (.Values.disableOtelAutoinstrumentation | default true) }}
- name: NODE_OPTIONS
  value: "--require @opentelemetry/auto-instrumentations-node/register"
{{- end }}
{{- end }}
{{- if contains "java" .Values.global.language }}
{{- end }}
{{- if contains "python" .Values.global.language }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "helm.otel.volumeMounts" -}}
{{- if .Values.global.language }}
- name: otel-log
  mountPath: /var/log/opentelemetry
{{- end -}}
{{- end -}}  

{{- define "helm.otel.volumes" -}}
{{- if .Values.global.language }}
- name: otel-log
  emptyDir: {}
{{- end -}}
{{- end -}}
