{{- define "helm.podDefaultToleration" -}}
tolerations:
  - key: "node.kubernetes.io/unreachable"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 30
  - key: "node.kubernetes.io/not-ready"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 30
  {{- /* Add global tolerations if they exist */}}
  {{- if .Values.tolerations }}
  {{ toYaml .Values.tolerations | indent 2 | trim }}
  {{- end }}
  {{- /* Add application-specific tolerations if they exist */}}
  {{- if .application }}
  {{- with (dig "tolerations" "" .application) }}
  {{ toYaml . |  indent 2 | trim }}
  {{- end }}
  {{- end }}
{{- end -}}
