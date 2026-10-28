{{/*
Restore: the newest archive, or RESTORE_FILE when set. admin and config are excluded so the users and roles the
operator manages are never overwritten. --drop replaces only the collections in the archive.
*/}}
{{- define "mc-mongodb.restoreScript" -}}
set -euo pipefail
if [ -n "${RESTORE_FILE:-}" ]; then
  file="/backups/$RESTORE_FILE"
else
  file=$(ls -1 /backups/*.archive.gz 2>/dev/null | sort | tail -n 1 || true)
fi
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "no backup to restore (looked for: ${file:-any *.archive.gz in /backups})" >&2
  exit 1
fi
echo "restoring $file"
mongorestore --uri="$MONGODB_URI" --drop --gzip --archive="$file" --nsExclude='admin.*' --nsExclude='config.*'
{{- end }}

{{/*
Restore CronJob. Always suspended with a schedule that never matches: it runs only when someone creates a Job from
it (Argo CD's Create Job action or kubectl create job --from), so no sync can start a restore.
Usage: include "mc-mongodb.restore" $ctx
*/}}
{{- define "mc-mongodb.restore" -}}
{{- if .backup.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ .name }}-restore
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  suspend: true
  schedule: "0 0 31 2 *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        metadata:
          labels:
            {{- toYaml .labels | nindent 12 }}
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          {{- $env := list (dict "name" "RESTORE_FILE" "value" "") }}
          {{- include "mc-mongodb.backupPodSpec" (dict "ctx" . "script" (include "mc-mongodb.restoreScript" .) "env" $env) | nindent 10 }}
{{- end }}
{{- end }}
