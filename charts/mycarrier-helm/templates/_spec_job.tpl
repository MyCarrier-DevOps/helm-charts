{{- define "helm.specs.job" -}}
{{- $fullName := include "helm.fullname" . }}
{{- $ctx := .ctx -}}
{{- if not $ctx -}}
  {{- $ctx = include "helm.context" . | fromJson -}}
{{- end -}}
{{- $chartDefaults := $ctx.chartDefaults -}}
{{- $jobDefaults := $chartDefaults.job -}}
{{- $resourceDefaults := $chartDefaults.resources.job -}}
{{- $imagePullSecret := $chartDefaults.imagePullSecret -}}
{{- $restartPolicy := $chartDefaults.restartPolicy -}}
activeDeadlineSeconds: {{ .job.activeDeadlineSeconds | default $jobDefaults.activeDeadlineSeconds }}
backoffLimit: {{ .job.backoffLimit | default $jobDefaults.backoffLimit }}
template:
  metadata:
    labels:
      {{ include "helm.labels.dependencies" . | indent 6 | trim }}
      {{ include "helm.labels.standard" . | indent 6 | trim }}
      {{ include "helm.otel.labels" . | indent 6 | trim }}
    annotations:
      argocd.argoproj.io/sync-options: Prune=true,Replace=true
      argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
      {{- if .job.timing }}
      {{- $order := .job.order | default 0 }}
      {{- if eq .job.timing "pre-deploy" }}
      argocd.argoproj.io/sync-wave: {{ ((sub $order 100) | toString | quote) }}
      argocd.argoproj.io/hook: PreSync
      {{- else if eq .job.timing "post-deploy" }}
      argocd.argoproj.io/sync-wave: {{ ((add $order 100) | toString | quote) }}
      argocd.argoproj.io/hook: PostSync
      {{- end }}
      {{- end }}
      {{ include "helm.annotations.vault" . | indent 6 | trim }}
      {{ include "helm.otel.annotations" . | indent 6 | trim }}
  spec:
    {{ include "helm.podSecurityContext" . | indent 4 | trim }}
    serviceAccountName: default
    imagePullSecrets:
      - name: {{ .job.imagePullSecret | default $imagePullSecret }}
    restartPolicy: {{ .job.restartPolicy | default $restartPolicy }}
    containers:
      - image: "{{ .job.image.registry }}/{{ .job.image.repository }}:{{ .job.image.tag }}"
        imagePullPolicy: {{ .job.imagePullPolicy | default "IfNotPresent"}}
        name: {{ .job.name }}
        {{- with .job.command }}
        command: {{ . }}
        {{- end }}
        {{- with .job.args }}
        args:
          {{ toYaml . | indent 10 | trim }}
        {{- end }}
        env:
          {{ include "helm.vault" . | indent 10 | trim }}
          {{ include "helm.otel.envVars" $ | indent 10 | trim }}
          {{- if hasKey $ "helm.otel.language" }}
          {{ include "helm.otel.language" $ | indent 10 | trim }}
          {{- end }}
          {{- range $key, $value := .job.env }}
          - name: "{{ $key }}"
            {{- if kindIs "map" $value }}
            valueFrom:
              {{- toYaml $value | nindent 14 }}
            {{- else }}
            value: "{{ tpl (toString $value) $ }}"
            {{- end }}
          {{- end }}
        {{- if or $.Values.configmap $.Values.useSecret .job.secretName }}
        envFrom:
          {{- if $.Values.configmap }}
          - configMapRef:
              name: "{{ include "helm.fullname" $ }}"
          {{- end }}
          {{- if .job.configMapName }}
          - configMapRef:
              name: "{{ .job.configMapName }}"
          {{- end }}
          {{- if or $.Values.useSecret .job.secretName }}
          - secretRef:
              name: {{ .job.secretName | default (printf "%s-secret" (include "helm.fullname" $)) }}
          {{- end }}
        {{- end }}
        resources:
          {{- if .job.resources }}
          {{ toYaml .job.resources | indent 10 | trim }}
          {{- else }}
          requests:
            memory: {{ quote $resourceDefaults.requests.memory }}
            cpu: {{ quote $resourceDefaults.requests.cpu }}
          limits:
            memory: {{ quote $resourceDefaults.limits.memory }}
            cpu: {{ quote $resourceDefaults.limits.cpu }}
          {{- end }}
        {{ include "helm.containerSecurityContext" . | indent 8 | trim }}
        volumeMounts:
          - name: tmp-dir
            mountPath: /tmp
          {{ include "helm.otel.volumeMounts" . | indent 10 | trim }}
          {{- if $.Values.secrets.mounted }}
          {{ include "helm.secretVolumeMounts" $ | indent 10 | trim -}}
          {{- end }}
        {{- if .job.volumes }}
          {{- range .job.volumes }}
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
      {{ include "helm.otel.volumes" . | indent 6 | trim }}
      {{- if $.Values.secrets.mounted }}
      {{ include "helm.secretVolumes" $ | indent 6 | trim -}}
      {{- end }}
    {{- if .job.volumes }}
      {{- range .job.volumes }}
      - name: {{ .name }}
        {{ if ( or (and ( .kind ) (eq (.kind | lower) "emptydir")) (not .kind)) }}emptyDir: {}{{- end }}
      {{- end }}
    {{- end }}
{{- end -}}