{{/*
Name of the backup PersistentVolume and its claim. PVs are cluster-scoped, so the namespace is part of the name.
Not truncated: PV and PVC names allow 253 characters, and cutting the release name off would let two releases share
a volume.
Usage: include "mc-mongodb.backupVolumeName" $ctx
*/}}
{{- define "mc-mongodb.backupVolumeName" -}}
{{- printf "%s-%s-backup" .namespace .name }}
{{- end }}

{{/*
Pod spec shared by the backup and restore CronJobs.
Usage: include "mc-mongodb.backupPodSpec" (dict "ctx" $ctx "script" $script "env" $extraEnv)
*/}}
{{- define "mc-mongodb.backupPodSpec" -}}
restartPolicy: Never
# The mongo image's mongodb user, on a read-only root filesystem (cluster policy); /tmp is the only scratch space.
securityContext:
  runAsNonRoot: true
  runAsUser: 999
  runAsGroup: 999
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: mongo
    image: {{ .ctx.backup.image }}
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
    command:
      - /bin/bash
      - -c
      - {{ .script | quote }}
    env:
      - name: MONGODB_URI
        valueFrom:
          secretKeyRef:
            name: {{ .ctx.name }}-backup-connection
            key: connectionString
      - name: RETENTION_DAYS
        value: {{ .ctx.backup.retentionDays | toString | quote }}
      - name: HOME
        value: /tmp
      {{- with .env }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    volumeMounts:
      - name: backups
        mountPath: /backups
        subPath: {{ .ctx.backup.path }}
      - name: tmp
        mountPath: /tmp
    resources:
      {{- toYaml .ctx.backup.resources | nindent 6 }}
volumes:
  - name: backups
    persistentVolumeClaim:
      claimName: {{ include "mc-mongodb.backupVolumeName" .ctx }}
  - name: tmp
    emptyDir: {}
{{- end }}

{{/*
Backup: a timestamped mongodump archive, written under a temporary name and renamed once complete, then deletion of
archives older than the retention (by the timestamp in the name; blobfuse may not keep mtimes). set -e stops a
failed dump before the rename and the prune.
*/}}
{{- define "mc-mongodb.backupScript" -}}
set -euo pipefail
ts=$(date -u +%Y%m%dT%H%M%SZ)
mongodump --uri="$MONGODB_URI" --readPreference=secondaryPreferred --gzip --archive="/backups/$ts.archive.gz.partial"
mv "/backups/$ts.archive.gz.partial" "/backups/$ts.archive.gz"
echo "wrote $ts.archive.gz"
cutoff=$(date -u -d "-${RETENTION_DAYS} days" +%Y%m%dT%H%M%SZ)
for f in /backups/*.archive.gz; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .archive.gz)
  if [[ "$name" < "$cutoff" ]]; then
    echo "deleting $name.archive.gz"
    rm -f "$f"
  fi
done
rm -f /backups/*.archive.gz.partial
{{- end }}

{{/*
Backup volume, claim and CronJob. Renders nothing unless backup.enabled.
Usage: include "mc-mongodb.backup" $ctx
*/}}
{{- define "mc-mongodb.backup" -}}
{{- if .backup.enabled }}
{{- if not .backup.container }}
{{- fail "backup.container is required when backup.enabled is true" }}
{{- end }}
{{- $volume := include "mc-mongodb.backupVolumeName" . }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ $volume }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-fuse-premium
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
  csi:
    driver: blob.csi.azure.com
    volumeHandle: {{ $volume }}
    volumeAttributes:
      containerName: {{ .backup.container }}
      storageAccount: {{ .backup.storageAccount }}
      resourceGroup: {{ .backup.resourceGroup }}
      subscriptionID: {{ .backup.subscriptionId }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $volume }}
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azureblob-fuse-premium
  volumeName: {{ $volume }}
  resources:
    requests:
      storage: 1Ti
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ .name }}-backup
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  schedule: {{ .backup.schedule | quote }}
  timeZone: {{ .backup.timeZone }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: {{ .backup.activeDeadlineSeconds }}
      template:
        metadata:
          labels:
            {{- toYaml .labels | nindent 12 }}
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          {{- include "mc-mongodb.backupPodSpec" (dict "ctx" . "script" (include "mc-mongodb.backupScript" .)) | nindent 10 }}
{{- end }}
{{- end }}
