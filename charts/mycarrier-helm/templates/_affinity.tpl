{{- define "helm.podDefaultAffinity" -}}
{{- if hasPrefix "prod" .Values.environment.name }}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - {{ include "helm.fullname" . | trunc 63 | trimSuffix "-" }}
            - key: environment
              operator: In
              values:
                - {{ .Values.environment.name }}
        topologyKey: kubernetes.io/hostname
{{- end -}}
{{- end -}}
