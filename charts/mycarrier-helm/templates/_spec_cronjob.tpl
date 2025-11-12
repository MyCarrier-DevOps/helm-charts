{{- define "helm.specs.cronjob" -}}
{{- $fullName := include "helm.fullname" . }}
schedule: {{ .cronjob.schedule | quote }}
{{- if hasKey .cronjob "timeZone" }}
timeZone: {{ .cronjob.timeZone | quote }}
{{- end }}
{{- if hasKey .cronjob "concurrencyPolicy" }}
concurrencyPolicy: {{ .cronjob.concurrencyPolicy }}
{{- end }}
{{- if hasKey .cronjob "suspend" }}
suspend: {{ .cronjob.suspend }}
{{- end }}
{{- if hasKey .cronjob "successfulJobsHistoryLimit" }}
successfulJobsHistoryLimit: {{ .cronjob.successfulJobsHistoryLimit }}
{{- else }}
successfulJobsHistoryLimit: 3
{{- end }}
{{- if hasKey .cronjob "failedJobsHistoryLimit" }}
failedJobsHistoryLimit: {{ .cronjob.failedJobsHistoryLimit }}
{{- else }}
failedJobsHistoryLimit: 1
{{- end }}
{{- if hasKey .cronjob "startingDeadlineSeconds" }}
startingDeadlineSeconds: {{ .cronjob.startingDeadlineSeconds }}
{{- end }}
jobTemplate:
  spec:
    {{- if hasKey .cronjob "activeDeadlineSeconds" }}
    activeDeadlineSeconds: {{ .cronjob.activeDeadlineSeconds }}
    {{- end }}
    backoffLimit: {{ .cronjob.backoffLimit | default 0 }}
    template:
      metadata:
        labels:
          {{ include "helm.labels.dependencies" . | indent 10 | trim }}
          {{ include "helm.labels.standard" . | indent 10 | trim }}
          {{ include "helm.otel.labels" . | indent 10 | trim }}
        annotations:
          {{ include "helm.annotations.vault" . | indent 10 | trim }}
          {{ include "helm.otel.annotations" . | indent 10 | trim }}
      spec:
        {{ include "helm.podSecurityContext" . | indent 8 | trim }}
        serviceAccountName: default
        imagePullSecrets:
          - name: {{ .cronjob.imagePullSecret | default "imagepull" }}
        restartPolicy: {{ .cronjob.restartPolicy | default "Never" }}
        containers:
          - image: "{{ .cronjob.image.registry }}/{{ .cronjob.image.repository }}:{{ .cronjob.image.tag }}"
            imagePullPolicy: {{ .cronjob.imagePullPolicy | default "IfNotPresent"}}
            name: {{ .cronjob.name }}
            {{- with .cronjob.command }}
            command: {{ . }}
            {{- end }}
            {{- with .cronjob.args }}
            args:
              {{ toYaml . | indent 14 | trim }}
            {{- end }}
            env:
              {{ include "helm.vault" . | indent 14 | trim }}
              {{ include "helm.otel.envVars" $ | indent 14 | trim }}
              {{- if hasKey $ "helm.otel.language" }}
              {{ include "helm.otel.language" $ | indent 14 | trim }}
              {{- end }}
              {{- range $key, $value := $.cronjob.env }}
              - name: "{{ $key }}"
                {{- if kindIs "map" $value }}
                valueFrom:
                  {{- toYaml $value | nindent 18 }}
                {{- else }}
                value: "{{ tpl (toString $value) $ }}"
                {{- end }}
              {{- end }}
            {{- if or $.Values.configmap $.Values.useSecret .cronjob.secretName .cronjob.configMapName }}
            envFrom:
              {{- if $.Values.configmap }}
              - configMapRef:
                  name: "{{ include "helm.fullname" $ }}"
              {{- end }}
              {{- if .cronjob.configMapName }}
              - configMapRef:
                  name: "{{ .cronjob.configMapName }}"
              {{- end }}
              {{- if or $.Values.useSecret .cronjob.secretName }}
              - secretRef:
                  name: {{ .cronjob.secretName | default (printf "%s-secret" (include "helm.fullname" $)) }}
              {{- end }}
            {{- end }}
            resources:
              {{- if .cronjob.resources }}
              {{ toYaml .cronjob.resources | indent 14 | trim }}
              {{- else }}
              requests:
                memory: "128Mi"
                cpu: "100m"
              limits:
                memory: "256Mi"
                cpu: "500m"
              {{- end }}
            {{ include "helm.containerSecurityContext" . | indent 12 | trim }}
            volumeMounts:
              - name: tmp-dir
                mountPath: /tmp
              {{ include "helm.otel.volumeMounts" . | indent 14 | trim }}
              {{- if $.Values.secrets.mounted }}
              {{ include "helm.secretVolumeMounts" $ | indent 14 | trim -}}
              {{- end }}
            {{- if .cronjob.volumes }}
              {{- range .cronjob.volumes }}
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
          {{ include "helm.otel.volumes" . | indent 10 | trim }}
          {{- if $.Values.secrets.mounted }}
          {{ include "helm.secretVolumes" $ | indent 10 | trim -}}
          {{- end }}
        {{- if .cronjob.volumes }}
          {{- range .cronjob.volumes }}
          - name: {{ .name }}
            {{ if ( or (and ( .kind ) (eq (.kind | lower) "emptydir")) (not .kind)) }}emptyDir: {}{{- end }}
          {{- end }}
        {{- end }}
{{- end -}}
