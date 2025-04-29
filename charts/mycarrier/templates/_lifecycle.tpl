{{- define "helm.defaultPreStopDelay" -}}
{{- if and (or ($.Values.application.ports)) (or (.Values.application.ports.http) (.Values.application.ports.healthcheck) ) }}
{{- printf "sleep 1 && " }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLifecyclePostStart" -}}
{{- if .Values.enableVaultCA }}
{{- printf "curl -k https://vault.infra:8200/v1/pki/ca/pem --output /usr/local/share/ca-certificates/vault.crt;update-ca-certificates" }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLifecyclePreStop" -}}
{{- if .Values.global.language }}
  {{- if contains "csharp" .Values.global.language }}
  {{- printf "pkill dotnet" }}
  {{- else if contains "nodejs" .Values.global.language }}
  {{- printf "pkill node" }}
  {{- else if contains "nginx" .Values.global.language }}
  {{- printf "pkill -QUIT nginx" }}
  {{- else if contains "java" .Values.global.language }}
  {{- printf "pkill java" }}
  {{- else if contains "python" .Values.global.language }}
  {{- printf "pkill vault-env || true" }}
  {{- end }}
{{- else }}
{{- printf "pkill vault-env || true" }}
{{- end }}
{{- end -}}

# {{- define "helm.lifecycle" -}}
# {{- $customPostStart := include "helm.defaultLifecyclePostStart" . }}
# {{- $defaultPreStop := include "helm.defaultLifecyclePreStop" . }}
# {{- $customPreStopDelay := include "helm.defaultPreStopDelay" . }}
# {{- $postStartCommand := dig "lifecycle" "postStart" "echo postStartTest" (default .Values.application) }}
# {{- $preStopCommand := dig "lifecycle" "preStop" $defaultPreStop (default .Values.application) }}

# lifecycle:
#   postStart:
#     exec:
#       command: [ "/bin/sh", "-c", {{ printf "%s; %s" $postStartCommand $customPostStart | trim | quote }} ]
#   preStop:
#     exec:
#       command: [ "/bin/sh", "-c", {{ printf "%s%s" $customPreStopDelay $preStopCommand | trim | quote }} ]
# {{- end -}}