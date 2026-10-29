{{/*
The replica set. Passwords come from the generated Secrets (key password); the operator keeps the users in step
with them. statefulSet.spec is merged into the StatefulSet the operator builds. The pods run in the Istio mesh, so
clients with sidecars connect over mutual TLS; a multi-member set also gets a PodDisruptionBudget. The operator labels the pods
app: <name>-svc.
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
      # The agent removes users the chart does not declare, so one added by hand can't outlive a password change.
      ignoreUnknownUsers: false
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
    {{- if .backup.enabled }}
    # restore can rewrite users and grant roles, so only the restore Job's credential holds it.
    - name: restore
      db: admin
      passwordSecretRef:
        name: {{ .name }}-restore-connection
        key: password
      scramCredentialsSecretName: {{ .name }}-restore
      roles:
        - name: restore
          db: admin
    {{- end }}
  statefulSet:
    spec:
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: "true"
            proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
        spec:
          serviceAccountName: {{ .name }}-database
          {{- if gt (int .members) 1 }}
          # One member per node, so a node loss or drain takes at most one member.
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      app: {{ .name }}-svc
                  topologyKey: kubernetes.io/hostname
          {{- end }}
          # Replaces the operator's default pod security context whole, so it repeats all of it.
          securityContext:
            runAsUser: 2000
            runAsNonRoot: true
            fsGroup: 2000
            seccompProfile:
              type: RuntimeDefault
          # Cluster policy requires liveness and readiness probes on every container; the operator sets only the
          # agent's readiness probe. mongod opens its port once the agent has written its configuration, which the
          # startup probe allows up to 10 minutes for. The agent serves its status on 5000.
          containers:
            - name: mongod
              resources:
                {{- toYaml .resources | nindent 16 }}
              startupProbe:
                tcpSocket:
                  port: 27017
                periodSeconds: 10
                failureThreshold: 60
              livenessProbe:
                tcpSocket:
                  port: 27017
                periodSeconds: 30
                failureThreshold: 6
              readinessProbe:
                tcpSocket:
                  port: 27017
                periodSeconds: 10
            - name: mongodb-agent
              livenessProbe:
                tcpSocket:
                  port: 5000
                initialDelaySeconds: 30
                periodSeconds: 30
                failureThreshold: 6
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
{{- if gt (int .members) 1 }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  labels:
    {{- toYaml .labels | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: {{ .name }}-svc
{{- end }}
{{- end }}
