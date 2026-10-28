{{/*
The replica set. Passwords come from the generated Secrets (key password); the operator keeps the users in step
with them. statefulSet.spec is merged into the StatefulSet the operator builds.
Usage: include "mc-mongodb.mongodbcommunity" $ctx
*/}}
{{- define "mc-mongodb.mongodbcommunity" -}}
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  type: ReplicaSet
  members: {{ .members }}
  version: {{ .version | quote }}
  featureCompatibilityVersion: {{ .featureCompatibilityVersion | quote }}
  security:
    authentication:
      modes:
        - SCRAM
  users:
    - name: {{ .appUser.name }}
      db: admin
      passwordSecretRef:
        name: {{ .name }}-connection
        key: password
      scramCredentialsSecretName: {{ .name }}-app
      roles:
        - name: readWriteAnyDatabase
          db: admin
        - name: dbAdminAnyDatabase
          db: admin
    - name: backup
      db: admin
      passwordSecretRef:
        name: {{ .name }}-backup-connection
        key: password
      scramCredentialsSecretName: {{ .name }}-backup
      roles:
        - name: backup
          db: admin
        - name: restore
          db: admin
  statefulSet:
    spec:
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          serviceAccountName: {{ .name }}-database
          # Replaces the operator's default pod security context whole, so it repeats all of it.
          securityContext:
            runAsUser: 2000
            runAsNonRoot: true
            fsGroup: 2000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: mongod
              resources:
                {{- toYaml .resources | nindent 16 }}
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            accessModes:
              - ReadWriteOnce
            {{- with .storage.storageClassName }}
            storageClassName: {{ . }}
            {{- end }}
            resources:
              requests:
                storage: {{ .storage.size }}
{{- end }}
