{{- define "helm.annotations.vault" -}}
vault.security.banzaicloud.io/vault-addr: "https://vault.mycarrier.tech"
vault.security.banzaicloud.io/mutate-probes: "true"
vault.security.banzaicloud.io/vault-auth-method: azure
vault.security.banzaicloud.io/vault-path: clusterauth
vault.security.banzaicloud.io/vault-role: appcluster
{{- if and .Values (hasKey .Values "secrets") }}
vault.security.banzaicloud.io/vault-env-daemon: "true"
{{- if hasKey .Values.secrets "bulk" }}
{{- if and (ne (kindOf .Values.secrets.bulk) "invalid") (ne .Values.secrets.bulk nil) (kindOf .Values.secrets.bulk | eq "map") (hasKey .Values.secrets.bulk "path") (.Values.secrets.bulk.path) }}
vault.security.banzaicloud.io/vault-env-from-path: "{{ .Values.secrets.bulk.path }}"
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "helm.vault" -}}
{{- $fullname := (include "helm.fullname" . ) }}
{{- $envDependency := (include "helm.envDependency" . ) }}
{{- $metaenv := (include "helm.metaEnvironment" . ) }}
{{- if and .Values (hasKey .Values "secrets") (hasKey .Values.secrets "individual") }}
{{- range .Values.secrets.individual }}
{{- $keyname := .keyName | default "value"}}
{{- if .path }}
{{- $split := (regexSplit "/" .path -1) }}
{{- $val := concat (list (first $split)) (list "data") (rest $split) | join "/" }}
- name: {{ .envVarName }}
  value: "vault:{{ $val }}#{{ $keyname }}"
{{- else }}
- name: {{ .envVarName }}
  {{/* Generate vault path using application name from context if available */}}
  value: {{ printf "vault:secrets/data/%s/%s/%s#%s" $metaenv $.Values.global.appStack .envVarName $keyname }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
