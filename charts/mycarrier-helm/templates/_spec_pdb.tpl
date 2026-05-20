{{/*
Returns "true" when the application has a podDisruptionBudget block configured.
Only deploymentType deployment, statefulset, and rollout are eligible.
*/}}
{{- define "helm.pdbCondition" -}}
{{- $pdb := dig "podDisruptionBudget" dict .application -}}
{{- $deploymentType := .application.deploymentType | default "deployment" -}}
{{- $eligible := or (eq $deploymentType "deployment") (eq $deploymentType "statefulset") (eq $deploymentType "rollout") -}}
{{- if and $eligible $pdb (or (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable")) -}}
true
{{- end -}}
{{- end -}}

{{- define "helm.specs.pdb" -}}
{{- $pdb := .application.podDisruptionBudget -}}
{{- if and (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable") -}}
{{- fail (printf "podDisruptionBudget for application %q must set exactly one of minAvailable or maxUnavailable, not both" .appName) -}}
{{- end }}
{{- if hasKey $pdb "minAvailable" }}
minAvailable: {{ $pdb.minAvailable }}
{{- else }}
maxUnavailable: {{ $pdb.maxUnavailable }}
{{- end }}
selector:
  matchLabels:
    {{ include "helm.labels.selector" . | indent 4 | trim }}
{{- end -}}
