{{- define "helm.podDebugSidecar" -}}
- name: dotnet-debug-tools
  image: mycarrieracr.azurecr.io/dotnet/tools:24.31.2dfb480
  stdin: true
  tty: true
  imagePullPolicy: IfNotPresent
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
    privileged: true
    allowPrivilegeEscalation: true
    capabilities:
      add:
      - SYS_PTRACE
  volumeMounts:
  - name: tmp-dir
    mountPath: /tmp
  - name: debug
    mountPath: /debug
{{- end }}

{{- define "helm.podDebugVolumeMount" -}}
- name: debug
  mountPath: /debug
{{- end }}

{{- define "helm.podDebugVolume" -}}
{{- $fullName := include "helm.fullname" . }}
- name: debug
  persistentVolumeClaim:
    claimName: pvc-{{ $fullName }}
{{- end }}