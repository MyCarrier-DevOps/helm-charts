{{- define "helm.specs.deployment" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $envScaling := include "helm.envScaling" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := fromJson (include "helm.default-context" .) }}
{{- $globalForceAutoscaling := $ctx.defaults.forceAutoscaling }}
{{- if not (or (dig "autoscaling" "enabled" false .application) $globalForceAutoscaling) }}
{{- if eq "0" $envScaling }}
{{- if hasPrefix "feature" $.Values.environment.name }}
{{- if not (kindIs "invalid" .application.replicas) }}
replicas: {{ .application.replicas }}
{{- else }}
replicas: 1
{{- end }}
{{- else }}
{{- if not (kindIs "invalid" .application.replicas) }}
replicas: {{ .application.replicas }}
{{- else }}
replicas: 2
{{- end }}
{{- end }}
{{- else }}
{{- if hasPrefix "feature" $.Values.environment.name }}
replicas: {{ .application.replicas | default 1 }}
{{- else if not (kindIs "invalid" .application.replicas) }}
replicas: {{ .application.replicas }}
{{- else }}
replicas: 2
{{- end }}
{{- end }}
{{- end }}
revisionHistoryLimit: 2
minReadySeconds: {{ .application.minReadySeconds | default 0 }}
strategy:
{{- if .application.updateStrategy }}
  {{ toYaml .application.updateStrategy | indent 2 | trim }}
{{- else }}
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 2
{{- end }}
selector:
  matchLabels:
    {{ include "helm.labels.selector" . | indent 4 | trim }}
template:
  metadata:
    labels:
      {{ include "helm.labels.dependencies" . | indent 6 | trim }}
      {{ include "helm.labels.standard" . | indent 6 | trim }}
      {{ include "helm.labels.version" . | indent 6 | trim }}
      {{ include "helm.otel.labels" $ | indent 6 | trim }}
      {{ include "helm.labels.custom" . | indent 6 | trim }}
    annotations:
      {{ include "helm.annotations.vault" $ | indent 6 | trim }}
      {{ include "helm.annotations.istio" . | indent 6 | trim }}
      {{ include "helm.otel.annotations" $ | indent 6 | trim }}
      {{ with .application.annotations }}
      {{ toYaml . |  indent 6 | trim }}
      {{- end }}
  spec:
    {{ include "helm.podDefaultAffinity" . | indent 4 | trim }}
    {{ include "helm.podSecurityContext" $ | indent 4 | trim }}
    {{ include "helm.podDefaultToleration" $ | indent 4 | trim }}
    {{- include "helm.podDefaultNodeSelector" . | indent 4 | trim }}
    {{- include "helm.podDefaultPriorityClassName" . | indent 4 | trim }}
    {{- with .application.serviceAccount }}
    serviceAccountName: {{ .name | default $fullName }}
    {{- end }}
    terminationGracePeriodSeconds: {{ .application.terminationGracePeriodSeconds | default "10" }}
    {{- with .application.initContainers }}
    initContainers:
    {{- range . }}
      - name: {{ .name }}
        image: "{{ .image }}:{{ .tag | default $.Chart.AppVersion }}"
        command: {{ .command }}
        args:
          {{ toYaml .args | indent 8 | trim }}
        env:
          {{ include "helm.lang.vars" $ | indent 10 | trim }}
          {{ include "helm.otel.language" $ | indent 10 | trim }}
          {{ include "helm.otel.envVars" $ | indent 10 | trim }}
          {{ include "helm.vault" $ | indent 10 | trim }}
        {{- range $key, $value := omit .env "OTEL_EXPORTER_OTLP_ENDPOINT" "ComputedEnvironmentName" "ActiveOffloads" "KeyVault_RedisConnection" "Auth_KeyVault_RedisConnection" "KeyVault_IsActive" "KeyVault_SplitIoProxyApiKey" "KeyVault_SplitIoProxyUrl"}}
          - name: "{{ $key }}"
            value: "{{ $value }}"
        {{- end }}
        {{ include "helm.containerSecurityContext" $ | indent 8 | trim }}
    {{- end }}
    {{- end }}
    containers:
      - name: {{ .appName | default $fullName | lower | trunc 63 }}
        image: "{{ .application.image.registry }}/{{ .application.image.repository }}:{{ .application.image.tag }}"
        {{- if .application.command }}command: {{ .application.command }}{{end}}
        {{- if .application.args }}args: {{ .application.args | default "" }}{{end}}
        imagePullPolicy: {{ .application.pullPolicy | default "IfNotPresent" }}
        {{- if .application.ports }}
        ports:
          {{- range $key, $value := .application.ports }}
          - name: {{ $key | lower }}
            containerPort: {{ $value }}
            protocol: TCP
          {{- end }}
        {{- end }}
        {{- if dig "probes" "enableLiveness" true .application }}
        {{- if and (dig "probes" false .application) (dig "livenessProbe" false .application.probes) }}
        livenessProbe:
          {{ toYaml .application.probes.livenessProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultLivenessProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        {{- if dig "probes" "enableReadiness" false .application }}
        {{- if and (dig "probes" false .application) (dig "readinessProbe" false .application.probes) }}
        readinessProbe:
          {{ toYaml .application.probes.readinessProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultReadinessProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        {{- if dig "probes" "enableStartup" true .application }}
        {{- if and (dig "probes" false .application) (dig "startupProbe" false .application.probes) }}
        startupProbe:
          {{ toYaml .application.probes.startupProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultStartupProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        env:
          {{ include "helm.lang.vars" $ | indent 10 | trim }}
          {{ include "helm.vault" $ | indent 10 | trim }}
          - name: "ComputedEnvironmentName"
            value: "{{ $.Values.environment.name | default "dev" }}"
          {{- range $key, $value := $.Values.global.env }}
          - name: "{{ $key }}"
            {{- if kindIs "map" $value }}
            valueFrom: 
              {{ toYaml $value | indent 14 | trim}}
            {{- else }}
            value: "{{ tpl (toString $value) $ }}"
            {{- end }}
          {{- end }}
          {{- if and (.application.env) (not (kindIs "invalid" .application.env)) }}
          {{- range $key, $value := omit .application.env "OTEL_EXPORTER_OTLP_ENDPOINT" "ComputedEnvironmentName" "ActiveOffloads" "KeyVault_RedisConnection" "Auth_KeyVault_RedisConnection" "KeyVault_IsActive" "KeyVault_SplitIoProxyApiKey" "KeyVault_SplitIoProxyUrl" }}
          - name: "{{ $key }}"
            {{- if kindIs "map" $value }}
            valueFrom:
              {{ toYaml $value | indent 14 | trim}}
            {{- else }}
            value: "{{ tpl (toString $value) $ }}"
            {{- end }}
          {{- end }}
          {{- end }}
          {{ include "helm.otel.language" $ | indent 10 | trim }}
          {{ include "helm.otel.envVars" $ | indent 10 | trim }}
        {{- if or $.Values.configmap $.Values.useSecret }}
        envFrom:
          {{- if $.Values.configmap }}
          - configMapRef:
              name: "{{ $fullName }}"
          {{- end }}
          {{- if $.Values.useSecret }}
          - secretRef:
              name: "{{ $fullName }}-secret"
          {{- end }}
        {{- end }}
        {{ include "helm.resources" . | indent 8 | trim }}
        {{ include "helm.containerSecurityContext" $ | indent 8 | trim }}
        volumeMounts:
          - name: tmp-dir
            mountPath: /tmp
          {{ include "helm.otel.volumeMounts" $ | indent 10 | trim }}
          {{- if $.Values.secrets.mounted }}
          {{ include "helm.secretVolumeMounts" $ | indent 10 | trim -}}
          {{- end }}
        {{- if .application.volumes }}
          {{- range .application.volumes }}
          - name: {{ .name }}
            mountPath: {{ .mountPath }}
            {{- if .subPath }}
            subPath: {{ .subPath }}
            {{- end }}
          {{- end }}
        {{- end }}
    volumes:
      - name: tmp-dir
        emptyDir: {}
      {{ include "helm.otel.volumes" $ | indent 6 | trim }}
      {{- if $.Values.secrets.mounted }}
      {{ include "helm.secretVolumes" $ | indent 6 | trim -}}
      {{- end }}
    {{- if .application.volumes }}
      {{- range .application.volumes }}
      - name: {{ .name }}
        {{ if ( or (and ( .kind ) (eq (.kind | lower) "emptydir")) (not .kind)) }}emptyDir: {}{{- end }}
      {{- end }}
    {{- end }}
    imagePullSecrets:
      - name: {{ .application.pullSecret | default "imagepull"}}
{{- end -}}