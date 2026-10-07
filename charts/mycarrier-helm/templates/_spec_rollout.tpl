{{- define "helm.specs.rollout" -}}
{{- $fullName := include "helm.fullname" . }}
{{- /* Same replica count as the Deployment (helm.specs.replicas), so a switch between them keeps the pod count. */}}
{{- if and (ne "true" (include "helm.hpaCondition" . | trim)) (ne "true" (include "helm.kedaCondition" . | trim)) (not $.Values.scaling) }}
{{- include "helm.specs.replicas" . }}
{{- end }}
revisionHistoryLimit: 10
selector:
  matchLabels:
    {{ include "helm.labels.selector" . | indent 4 | trim }}
analysis:
  successfulRunHistoryLimit: {{ dig "updateStrategy" "successfulRunHistoryLimit" 10 .application }}
  unsuccessfulRunHistoryLimit: {{ dig "updateStrategy" "unsuccessfulRunHistoryLimit" 10 .application }}
minReadySeconds: {{ .application.minReadySeconds | default 0 }}
{{- /* migratingToRollouts renders both workloads for one release; deploymentType picks the one the HPA/KEDA autoscaler
       targets. On the way in (deploymentType rollout) the chart keeps the Deployment so its pods keep serving; on the
       way back (deploymentType deployment) it keeps the Rollout. Either way the Rollout borrows the Deployment's pod
       template. scaleDown: never because onsuccess/progressively scale the Deployment to 0 as soon as the Rollout is
       Healthy, which happens at 1 pod before the autoscaler (sync wave 11) takes the Rollout over. The next release
       removes migratingToRollouts and Argo CD prunes the workload deploymentType does not name. */}}
{{- if .application.migratingToRollouts }}
workloadRef:
  apiVersion: {{ .application.apiVersion | default "apps/v1" }}
  kind: Deployment
  name: {{ $fullName }}
  scaleDown: never
{{- end }}
strategy:
{{- /* While migrating (either way): a bare canary, so the Rollout takes over no Service and no VirtualService. With
       stableService set, the controller points the stable Service at the Rollout's ReplicaSet as soon as it is fully
       available, which is at 1 pod before the autoscaler (wave 11) scales it, and the Deployment's pods stop getting
       traffic. Without it, both sets of pods serve behind the existing Services. A Rollout's first rollout runs no
       steps, so nothing is lost on the way in; release 2 renders the configured strategy. maxUnavailable: 0 keeps
       every Rollout pod serving while it is replaced (on the way back its template becomes the Deployment's).
       Without a canary block the Rollout gets the same bare canary: the Rollout CRD rejects an empty strategy, and
       Argo CD would still prune the Deployment in that sync, leaving the Rollout frozen on its old spec. */}}
{{- if or .application.migratingToRollouts (not (dig "updateStrategy" "canary" false .application)) }}
  canary:
    maxUnavailable: 0
{{- else }}
  canary:
    {{- with (dig "updateStrategy" "canary" dict .application) }}
    {{ toYaml . | indent 4 | trim }}
    {{- end }}
{{- end }}
{{- /* With workloadRef the pod template comes from the Deployment; Argo Rollouts rejects a Rollout that sets both.
       Otherwise the Rollout renders the Deployment's pod template (helm.specs.podTemplate), so the switch between
       them changes no pod setting (preStop hook, ComputedEnvironmentName, env order, debug sidecar). */}}
{{- if not .application.migratingToRollouts }}
{{ include "helm.specs.podTemplate" . }}
{{- end }}
{{- end -}}
