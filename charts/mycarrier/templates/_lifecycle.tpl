{{- define "helm.defaultPreStopDelay" -}}
{{- if and (dig "ports" false .application) (or (dig "ports" "http" false .application) (dig "ports" "healthcheck" false .application)) }}
{{- printf "sleep 1 && " }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLifecyclePostStart" -}}
{{- if .Values.enableVaultCA }}
{{- printf "curl -k https://vault.infra:8200/v1/pki/ca/pem --output /usr/local/share/ca-certificates/vault.crt;update-ca-certificates" }}
{{- end }}
{{- end -}}

{{- define "helm.defaultLifecyclePreStop" -}}
{{- $language := include "helm.getLanguage" . -}}
{{- if $language }}
  {{- if contains "csharp" $language }}
  {{- printf "pkill dotnet" }}
  {{- else if contains "nodejs" $language }}
  {{- printf "pkill node" }}
  {{- else if contains "nginx" $language }}
  {{- printf "pkill -QUIT nginx" }}
  {{- else if contains "java" $language }}
  {{- printf "pkill java" }}
  {{- else if contains "python" $language }}
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
# {{/* Use dig to safely access nested properties from application context */}}
# {{- $postStartCommand := dig "lifecycle" "postStart" "echo postStartTest" .application }}
# {{- $preStopCommand := dig "lifecycle" "preStop" $defaultPreStop .application }}
#
# lifecycle:
#   postStart:
#     exec:
#       command: [ "/bin/sh", "-c", {{ printf "%s; %s" $postStartCommand $customPostStart | trim | quote }} ]
#   preStop:
#     exec:
#       command: [ "/bin/sh", "-c", {{ printf "%s%s" $customPreStopDelay $preStopCommand | trim | quote }} ]
# {{- end -}}