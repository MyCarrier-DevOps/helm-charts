# Verified upstream behaviour (temporary; folded into README in Task 7)

## MongoDB Controllers for Kubernetes (mongodb/mongodb-kubernetes, master, 2026-10-28)
- Service: `<metadata.name>-svc` unless `statefulSet.spec.serviceName` is set
  (`mongodb-community-operator/api/v1/mongodbcommunity_types.go` `ServiceName()`).
- Replica set name: `metadata.name` (same file, connection string builder `?replicaSet=%s` with `m.Name`).
- Data volume claim template: `data-volume`; logs: `logs-volume` (`DataVolumeName()`, `LogsVolumeName()`).
- mongod container name: `mongod` (`controllers/construct/mongodbstatefulset.go` `MongodbName`).
- Override paths: `spec.statefulSet.spec` is merged into the generated StatefulSet ("only those attributes passed will
  be set", docs/mongodbcommunity/deploy-configure.md), so pod annotations go in
  `statefulSet.spec.template.metadata.annotations`, pod security context in `statefulSet.spec.template.spec.securityContext`,
  container resources in `statefulSet.spec.template.spec.containers[name=mongod].resources`, and the claim in
  `statefulSet.spec.volumeClaimTemplates[metadata.name=data-volume]`.
- Default pod security context already sets `seccompProfile: RuntimeDefault` unless the operator runs with
  `MANAGED_SECURITY_CONTEXT=true` (`pkg/kube/podtemplatespec/podspec_template.go`). The chart sets it anyway.
- PVCs: the operator sets an owner reference on the StatefulSet, not on claims, and never sets
  `persistentVolumeClaimRetentionPolicy`; the docs state "When you delete MongoDB resources, persistent volumes remain."
- Password changes: the controller watches each `passwordSecretRef` Secret and regenerates SCRAM credentials when the
  password no longer matches (`pkg/authentication/scram/scram.go` `needToGenerateNewCredentials`;
  `replica_set_controller.go` secretWatcher).
- `scramCredentialsSecretName` gets `-scram-credentials` appended (CRD description).

## mongo:8.0.34 image (podman, 2026-10-28)
- Contains mongodump/mongorestore 100.20.0, GNU bash 5.2, GNU date (`date -u -d "-7 days"` works).
- `mongorestore --oplogReplay` with `--nsExclude` fails: `Failed: cannot use --oplogReplay with excludes specified`.
  **Outcome: no-oplog.** Backups run without `--oplog`; restores without `--oplogReplay`.
- Without oplog: `mongorestore --drop --gzip --archive=<f> --nsExclude='admin.*' --nsExclude='config.*'` restored the
  dumped databases and left `admin.system.users` untouched (a user created after the dump survived).
- `--drop` drops only collections present in the archive; collections created after the backup survive a restore.

## blob.csi.azure.com (kubernetes-sigs/blob-csi-driver docs/driver-parameters.md)
- Static PV attributes: `containerName` (required), `storageAccount` (required), `resourceGroup`, `subscriptionID`
  (requires `resourceGroup`).
- Without `nodeStageSecretRef` and without a namespace Secret `azure-storage-account-<account>-secret`, the driver
  "will use the kubelet identity to obtain the account key during volume mount". This is the kubelet-identity path the
  chart uses; it needs the kubelet identity to be able to list the account's keys.
- `AzureStorageAuthType: MSI` (blobfuse authenticating as an identity, no key) needs `AzureStorageIdentityClientID`
  (or ResourceID) set explicitly today; falling back to the kubelet identity is only an open upstream PR (#2430). Not
  used: it would need a per-cluster client ID value.
