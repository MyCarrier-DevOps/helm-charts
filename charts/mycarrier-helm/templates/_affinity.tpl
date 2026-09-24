{{- define "helm.podDefaultAffinity" -}}
{{- if or (hasPrefix "prod" .Values.environment.name) (dig "affinity" "enablePodAntiAffinity" false .application) }}
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
