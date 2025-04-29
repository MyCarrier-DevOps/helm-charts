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
  {{- with (dig "tolerations" "" (default .Values.application )) }}
  {{ toYaml . |  indent 2 | trim }}
  {{- end }}
{{- end -}}
