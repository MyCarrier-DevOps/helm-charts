{{- define "helm.specs.rollout" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $envScaling := include "helm.envScaling" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $imagePullSecret := $ctx.chartDefaults.imagePullSecret -}}
{{- if and (ne "true" (include "helm.hpaCondition" . | trim)) (ne "true" (include "helm.kedaCondition" . | trim)) (not $.Values.scaling) }}
replicas: {{ if and (not (kindIs "invalid" .application.replicas)) (or (eq "1" $envScaling) (and (eq "0" $envScaling) (eq "0" (default "0" .application.replicas | toString)))) }}{{ .application.replicas }}{{ else }}{{ 2 }}{{ end }}
{{- end }}
revisionHistoryLimit: 10
selector:
  matchLabels:
    {{ include "helm.labels.selector" . | indent 4 | trim }}
analysis:
  successfulRunHistoryLimit: {{ dig "updateStrategy" "successfulRunHistoryLimit" 10 .application }}
  unsuccessfulRunHistoryLimit: {{ dig "updateStrategy" "unsuccessfulRunHistoryLimit" 10 .application }}
minReadySeconds: {{ .application.minReadySeconds | default 0 }}
{{- if .application.migratingToRollouts }}
workloadRef:
  apiVersion: {{ .application.apiVersion | default "apps/v1" }}
  kind: Deployment
  name: {{ $fullName }}
  scaleDown: onsuccess
{{- end }}
strategy:
{{- if dig "updateStrategy" "bluegreen" false .application }}
  blueGreen:
    activeService: {{ $fullName }}
    previewService: {{ $fullName }}-preview
    previewReplicaCount: 1
    autoPromotionEnabled: {{ dig "updateStrategy" "bluegreen" "autoPromotionEnabled" true .application }}
    autoPromotionSeconds: {{ dig "updateStrategy" "bluegreen" "autoPromotionSeconds" 30 .application }}
    scaleDownDelaySeconds: {{ dig "updateStrategy" "bluegreen" "scaleDownDelaySeconds" 60 .application }}
    scaleDownDelayRevisionLimit: {{ dig "updateStrategy" "bluegreen" "scaleDownDelayRevisionLimit" 5 .application }}
    abortScaleDownDelaySeconds: {{ dig "updateStrategy" "bluegreen" "abortScaleDownDelaySeconds" 60 .application }}
    activeMetadata:
      labels:
        {{- include "helm.labels.dependencies" . | indent 8 | trim }}
        {{ include "helm.labels.standard" . | indent 8 | trim }}
        {{ include "helm.labels.version" . | indent 8 | trim }}
        role: active
        strategy: bluegreen
    previewMetadata:
      labels:
        {{- include "helm.labels.dependencies" . | indent 8 | trim }}
        {{ include "helm.labels.standard" . | indent 8 | trim }}
        {{ include "helm.labels.version" . | indent 8 | trim }}
        role: preview
        strategy: bluegreen
    {{- if dig "updateStrategy" "bluegreen" "prePromotionAnalysis" false .application }}
    prePromotionAnalysis:
      templates:
      {{ toYaml (dig "updateStrategy" "bluegreen" "prePromotionAnalysis" "templates" list .application) | indent 6 | trim }}
      {{- if dig "updateStrategy" "bluegreen" "prePromotionAnalysis" "args" false .application }}
      args:
      {{ toYaml (dig "updateStrategy" "bluegreen" "prePromotionAnalysis" "args" list .application) | indent 6 | trim }}
      {{- end }}
    {{- end }}
{{- end }}
{{- if dig "updateStrategy" "canary" false .application }}
  canary:
    {{- with (dig "updateStrategy" "canary" dict .application) }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
{{- end }}
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
      {{ include "helm.annotations.gateway" . | indent 6 | trim }}
      {{ include "helm.otel.annotations" $ | indent 6 | trim }}
      {{/* Istio/gateway annotations are reserved: application.istioDisabled, networking.istio.enabled,
           and service.istioDisabled are the supported per-workload knobs for opting out of Istio sidecar
           injection / the gateway annotation (see helm.annotations.istio / helm.annotations.gateway).
           Allowing application.annotations to override sidecar.istio.io/inject, proxy.istio.io/config,
           or mycarrier.io/gateway is therefore redundant and was closing over a duplicate-key defect
           (last-key-wins on the rendered YAML, silently skipped by scanners). */}}
      {{- $reserved := merge (dict) (include "helm.annotations.vault" $ | fromYaml) (include "helm.annotations.istio" . | fromYaml) (include "helm.annotations.gateway" . | fromYaml) (include "helm.otel.annotations" $ | fromYaml) }}
      {{- $extra := include "helm.annotations.userExtra" (dict "reserved" $reserved "user" .application.annotations) }}
      {{- if $extra }}
      {{ $extra | indent 6 | trim }}
      {{- end }}
  spec:
    {{ include "helm.podDefaultAffinity" . | indent 4 | trim }}
    {{ include "helm.podSecurityContext" $ | indent 4 | trim }}
    {{ include "helm.podDefaultToleration" $ | indent 4 | trim }}
    {{ include "helm.podDefaultNodeSelector" . | indent 4 | trim }}
    {{ include "helm.podDefaultPriorityClassName" . | indent 4 | trim }}
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
          {{- toYaml .args | nindent 10 }}
        env:
          {{ include "helm.lang.vars" $ | indent 10 | trim }}
          {{ include "helm.otel.env" (merge (dict "otelUserEnv" .env) $) | indent 10 | trim }}
          {{ include "helm.vault" $ | indent 10 | trim }}
        {{- range $key, $value := omit (.env | default dict) "ComputedEnvironmentName" "ActiveOffloads" "KeyVault_RedisConnection" "Auth_KeyVault_RedisConnection" "KeyVault_IsActive" "KeyVault_SplitIoProxyApiKey" "KeyVault_SplitIoProxyUrl"}}
          - name: "{{ $key }}"
            value: "{{ $value }}"
        {{- end }}
        {{ include "helm.containerSecurityContext" $ | indent 8 | trim }}
    {{- end }}
    {{- end }} 
    containers:
      - name: {{ .appName | default $fullName | lower | trunc 63  }}
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
        {{- if dig "probes" "enableReadiness" true .application }}
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
          {{ include "helm.lang.vars" . | indent 10 | trim }}
          {{ include "helm.otel.env" $ | indent 10 | trim }}
          {{ include "helm.application.env" . | indent 10 | trim }}
          
          {{ include "helm.vault" $ | indent 10 | trim }}
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
      - name: {{ .application.pullSecret | default $imagePullSecret }}
{{- end -}}