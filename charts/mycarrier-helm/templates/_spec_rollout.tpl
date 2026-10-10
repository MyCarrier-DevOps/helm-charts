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
{{- $canary := eq (include "helm.canary.enabled" .) "true" }}
{{- if $canary }}
{{- $canaryConfig := include "helm.canary.config" . | fromJson }}
{{- /* DEVOPS-307 defaults: a canary that makes no progress for this long aborts (and the Rollout goes back to
       stable); a GitOps revert to one of the last 2 revisions skips the steps. applications.<app>.progressDeadlineSeconds
       overrides the release-wide value for a slow-starting app; it is not a step setting, so lockstep is unaffected. */}}
progressDeadlineSeconds: {{ dig "progressDeadlineSeconds" $canaryConfig.progressDeadlineSeconds .application }}
progressDeadlineAbort: true
rollbackWindow:
  revisions: 2
{{- end }}
strategy:
{{- if $canary }}
{{- /* The canary contract: the chart's stable and -preview Services, the Tech Spec's canary defaults (stable keeps
       full capacity, 30 s before an aborted canary scales down, at least one pod per ReplicaSet), Istio weights on
       every route that reaches the app (helm.canary.virtualServices), and the release-wide steps (helm.canary.steps). */}}
  canary:
    stableService: {{ $fullName }}
    canaryService: {{ $fullName }}-preview
    dynamicStableScale: false
    abortScaleDownDelaySeconds: 30
    minPodsPerReplicaSet: 1
    trafficRouting:
      istio:
        virtualServices:
          {{- include "helm.canary.virtualServices" . | nindent 10 }}
    steps:
      {{- include "helm.canary.steps" . | nindent 6 }}
{{- else }}
{{- /* While migrating (either way): a bare canary, so the Rollout takes over no Service and no VirtualService. With
       stableService set, the controller points the stable Service at the Rollout's ReplicaSet as soon as it is fully
       available, which is at 1 pod before the autoscaler (wave 11) scales it, and the Deployment's pods stop getting
       traffic. Without it, both sets of pods serve behind the existing Services. A Rollout's first rollout runs no
       steps, so nothing is lost on the way in; release 2 renders the canary contract. maxUnavailable: 0 keeps every
       Rollout pod serving while it is replaced (on the way back its template becomes the Deployment's). */}}
  canary:
    maxUnavailable: 0
{{- end }}
{{- /* With workloadRef the pod template comes from the Deployment; Argo Rollouts rejects a Rollout that sets both.
       Otherwise the Rollout renders the Deployment's pod template (helm.specs.podTemplate), so the switch between
       them changes no pod setting (preStop hook, ComputedEnvironmentName, env order, debug sidecar). */}}
{{- if not .application.migratingToRollouts }}
{{ include "helm.specs.podTemplate" . }}
{{- end }}
{{- end -}}
