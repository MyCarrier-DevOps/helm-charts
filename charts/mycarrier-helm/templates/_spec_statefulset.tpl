{{- define "helm.specs.statefulset" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $envScaling := include "helm.envScaling" . }}
{{- $namespace := include "helm.namespace" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $imagePullSecret := $ctx.chartDefaults.imagePullSecret -}}
replicas: {{ if and (not (kindIs "invalid" .application.replicas)) (or (eq "1" $envScaling) (and (eq "0" $envScaling) (eq "0" (default "0" .application.replicas | toString)))) }}{{ .application.replicas }}{{ else }}{{ 1 }}{{ end }}
serviceName: {{ $fullName }}
{{- if .application.updateStrategy }}
updateStrategy:
  {{ toYaml .application.updateStrategy | indent 2 | trim }}
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
      {{ include "helm.labels.custom" . | indent 6 | trim }}
      {{ include "helm.otel.labels" $ | indent 6 | trim }}
    annotations:
      {{ include "helm.annotations.vault" $ | indent 6 | trim }}
      {{ include "helm.annotations.istio" . | indent 6 | trim }}
      {{ include "helm.otel.annotations" $ | indent 6 | trim }}
      {{- with .application.annotations }}
      {{ toYaml . |  indent 6 | trim }}
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
          {{ toYaml .args | indent 8 | trim }}
        env:
          {{ include "helm.lang.vars" $ | indent 10 | trim }}
          {{ include "helm.otel.language" $ | indent 10 | trim }}
          {{ include "helm.otel.envVars" $ | indent 10 | trim }}
          {{ include "helm.vault" $ | indent 10 | trim }}
        {{- range $key, $value := .env }}
          - name: "{{ $key }}"
            value: "{{ $value }}"
        {{- end }}
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
        {{ include "helm.containerSecurityContext" $ | indent 8 | trim }}
    {{- end }}
    {{- end }}
    {{ if $.application.enableDebugMode }}shareProcessNamespace: true {{ end }}
    containers:
      - name: {{ .appName | default $fullName | lower | trunc 63 }}
        image: "{{ .application.image.registry }}/{{ .application.image.repository }}:{{ .application.image.tag }}"
        command: {{ .application.command | default "" }}
        args: {{ .application.args | default "" }}
        imagePullPolicy: {{ .application.pullPolicy | default "IfNotPresent" }}
        {{- if .application.ports }}
        ports:
          {{- range $key, $value := .application.ports }}
          - name: {{ $key | lower }}
            containerPort: {{ $value }}
          {{- end }}
        {{- end }}
        {{- if and .application.probes (hasKey .application.probes "enableLiveness") (.application.probes.enableLiveness)}}
        {{- if .application.probes.livenessProbe }}
        livenessProbe:
          {{ toYaml .application.probes.livenessProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultLivenessProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        {{- if and .application.probes (hasKey .application.probes "enableReadiness") (.application.probes.enableReadiness)}}
        {{- if .application.probes.readinessProbe }}
        readinessProbe:
          {{ toYaml .application.probes.readinessProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultReadinessProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        {{- if and .application.probes (hasKey .application.probes "enableStartup") (.application.probes.enableStartup)}}
        {{- if .application.probes.startupProbe }}
        startupProbe:
          {{ toYaml .application.probes.startupProbe | indent 10 | trim }}
        {{- else }}
        {{ include "helm.defaultStartupProbe" . | indent 8 | trim }}
        {{- end }}
        {{- end }}
        env:
          {{ include "helm.lang.vars" . | indent 10 | trim }}
          {{ include "helm.otel.language" $ | indent 10 | trim }}
          {{ include "helm.otel.envVars" $ | indent 10 | trim }}
          {{- range $key, $value := $.Values.global.env }}
          - name: "{{ $key }}"
            {{- if kindIs "map" $value }}
            valueFrom: 
              {{ toYaml $value | indent 14 | trim}}
            {{- else }}
            value: "{{ tpl (toString $value) $ }}"
            {{- end }}
          {{- end }}
          {{- range $key, $value := .application.env }}
          - name: "{{ $key }}"
            {{- if kindIs "map" $value }}
            valueFrom: 
              {{ toYaml $value | indent 14 | trim}}
            {{- else }}
            value: "{{ tpl (toString $value) $ }}"
            {{- end }}
          {{- end }}
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
          {{ include "helm.secretVolumeMounts" $ | indent 10 | trim }}
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