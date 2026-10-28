# Design: `mc-mongodb` chart (in-cluster MongoDB with production backups)

**Date:** 2026-10-28
**Charts:** new `charts/mc-mongodb`; later `charts/mycarrier-helm`, `charts/mc-environment`
**Status:** Draft

## Intent

A service team should be able to run its own MongoDB next to its application instead of sharing the central
instance, and in production that MongoDB must be backed up without anyone remembering to set it up.

The work ships in two phases, in order:

1. **Standalone chart.** `charts/mc-mongodb` deploys one MongoDB replica set through the MongoDB operator and, when
   asked, a daily backup CronJob writing to Azure Blob storage plus a restore CronJob that only runs on demand.
2. **Embedded in mycarrier-helm.** A stack sets `mongodb.enabled: true`. mycarrier-helm renders the chart's
   resources, turns backups on in production only, and points the service's injected Mongo connection string at the
   in-cluster instance instead of the shared one.

The chart serves one application user per release. Several services can share a release by using that user's
connection string (from the same namespace, or by copying it); separate users per consumer are out of scope until a
consumer needs them.

## Goals

- Render a `MongoDBCommunity` resource; the operator does the rest.
- Generate credentials in-cluster. Nobody puts a MongoDB password in Vault or Git.
- Backups with a configurable schedule and retention, defaulting to one backup per day kept for 7 days.
- Backups land in the `mycarriermongobackups` storage account: one container per cluster, a folder per
  environment and service.
- Restore is one action in the Argo CD UI, and a sync can never trigger it.
- In mycarrier-helm: backups on in production, off everywhere else, with no per-stack setting needed.
- In mycarrier-helm: the injected connection string switches to the in-cluster instance **if and only if** the stack
  deploys it. Stacks that don't are unchanged.

## Non-goals

- Installing the operator. The operator is installed once per cluster, separately (see Prerequisites).
- Bitnami charts or images in any form.
- Sharding, arbiters, TLS between members, X.509 auth, Prometheus wiring. The CRD supports them; nothing here needs
  them yet.
- Point-in-time recovery beyond what a nightly `mongodump --oplog` gives.
- Alerting on failed backups. A failed backup shows as a failed Job; alerting can come later through the chart's
  alerts feature.
- Creating the per-cluster blob containers or the storage account.

## Anti-goals (failure even if it renders)

- **A sync restores data.** Any design where an Argo sync, self-heal, prune or re-add can start a restore is wrong.
- **A non-production environment writes backups**, or production silently has none.
- **A stack that doesn't deploy MongoDB sees any change** in its rendered output.
- **Passwords rotate on their own.** A re-render or re-sync must not produce a new password.

## Prerequisites (outside this repo)

- MongoDB Controllers for Kubernetes (`mongodb-kubernetes`, Helm repo `https://mongodb.github.io/helm-charts`)
  installed in each app cluster and watching the app namespaces. It replaces the Community Operator (end of life
  November 2025) and still serves `mongodbcommunity.mongodb.com/v1` `MongoDBCommunity`.
- External Secrets Operator with the `Password` generator CRD (`passwords.generators.external-secrets.io`). It is
  present on the management cluster; confirm on each app cluster.
- The `ClusterSecretStore` `vault-backend` (already used by mycarrier-helm).
- A blob container per cluster in `mycarriermongobackups` (`rg_management_controlplane`, subscription
  `99b54c45-a73d-4d40-915e-c0392b589e8c`), and the account's network rules allow the app clusters.
- The storage account name and key in Vault at a path the chart can read (see Open questions).

## The standalone chart (phase 1)

### Shape: named templates first

Every resource is defined as a named template in `templates/_*.tpl` that takes an explicit context dict (name,
namespace, labels, members, version, storage, backup settings, and so on). The chart's own template files are thin
wrappers that build that dict from `.Values` and call the named templates. They render only when `standalone: true`
(the default).

This is required by phase 2. A Helm subchart's values are static: mycarrier-helm cannot compute
`mongodb.backup.enabled` from `environment.name`, and the subchart cannot see the parent's `environment`. Subchart
named templates, however, are callable from the parent. So mycarrier-helm depends on `mc-mongodb` unconditionally,
sets `mongodb.standalone: false`, and calls the named templates with a dict it computes. (A dependency disabled by a
`condition:` is dropped entirely, named templates included, so the dependency must not be gated.)

Deriving the environment from `.Release.Namespace` was rejected: `environment.namespaceOverride` and standalone
installs break it, and the failure mode is production with no backups.

### Values (standalone)

| Value | Default | Meaning |
|---|---|---|
| `standalone` | `true` | Render from this chart's own templates. mycarrier-helm sets `false`. |
| `nameOverride` / `fullnameOverride` | `""` | Usual naming overrides. |
| `members` | `1` | Replica set members. |
| `version` | latest 8.0 patch MCK supports | MongoDB server version (exact, pinned). |
| `featureCompatibilityVersion` | `"8.0"` | Pinned so upgrades are deliberate. |
| `storage.size` | `10Gi` | Data volume size. |
| `storage.storageClassName` | `""` | Empty uses the cluster default. |
| `resources` | modest requests/limits | mongod container resources. |
| `appUser.name` | `app` | Application user. |
| `appUser.database` | release name | Database the app user's roles apply to (see Open questions on scope). |
| `password.length` | `32` | Generated password length. |
| `backup.enabled` | `false` | Render the backup and restore CronJobs and their storage. |
| `backup.schedule` | `"0 2 * * *"` | Cron schedule. |
| `backup.timeZone` | `"Etc/UTC"` | CronJob time zone. |
| `backup.retentionDays` | `7` | Backups older than this are deleted after each successful backup. |
| `backup.cluster` | none, required when enabled | Blob container name (one per cluster). Render fails if empty. |
| `backup.path` | `<namespace>/<fullname>` | Folder inside the container. |
| `backup.storageSecret.vaultPath` / `.vaultProperty` | see Open questions | Where the storage account name and key live in Vault. |
| `backup.image` | official `mongo` image, same tag as `version` | Has `mongodump` / `mongorestore`. |
| `backup.resources` | modest | Backup and restore container resources. |

A `values.schema.json` validates these, including `members >= 1`, `retentionDays >= 1`, and a required non-empty
`backup.cluster` when `backup.enabled`.

### Resources rendered

All names derive from `<fullname>`; `<ns>` is the release namespace.

1. **Password generation (External Secrets).** A `generators.external-secrets.io/v1alpha1` `Password` and two
   `ExternalSecret`s (app user, backup user), each using `dataFrom[].sourceRef.generatorRef` to produce a Secret
   with key `password`.
   - `refreshInterval: "0"` so the password is generated once.
   - No symbols in the generated password (it ends up in connection strings).
   - `target.deletionPolicy: Retain` and no `Replace=true`/`Force=true` sync options on these objects. The password
     regenerates only if the ExternalSecret is deleted and recreated; when that happens the operator updates the
     user's SCRAM credentials and its connection-string Secret, so the worst case is restarting the app pods.
     **Builder verifies** that the operator reconciles a changed password Secret.
2. **`MongoDBCommunity`** (`mongodbcommunity.mongodb.com/v1`):
   - `type: ReplicaSet`, `members`, `version`, `featureCompatibilityVersion`.
   - `security.authentication.modes: [SCRAM]`.
   - `users`:
     - app user, `db: admin`, `passwordSecretRef` to its generated Secret, `scramCredentialsSecretName`, and
       `connectionStringSecretName: <fullname>-connection` so consumers reference a fixed name rather than the
       operator's default `<resource>-<db>-<user>`.
     - backup user, `db: admin`, roles `backup` and `restore` on `admin`, `connectionStringSecretName:
       <fullname>-backup-connection`.
   - `statefulSet.metadata` / `statefulSet.spec` overrides: data volume claim size and storage class, mongod
     resources, and pod annotation `sidecar.istio.io/inject: "false"`. **Builder verifies** the override paths
     against the MCK samples (the CRD leaves `statefulSet.spec` free-form).
3. **When `backup.enabled`:**
   - **Storage key `ExternalSecret`** from `vault-backend`, producing Secret `<fullname>-backup-storage` with keys
     `azurestorageaccountname` and `azurestorageaccountkey` (what `blob.csi.azure.com` expects in
     `nodeStageSecretRef`).
   - **Static `PersistentVolume`** (cluster-scoped, so the name must be unique per cluster: `<ns>-<fullname>-backup`):
     - `csi.driver: blob.csi.azure.com`, `storageClassName: azureblob-fuse-premium` (as the existing debug PV),
       `ReadWriteMany`, `persistentVolumeReclaimPolicy: Retain`.
     - `volumeHandle: <ns>-<fullname>-backup`.
     - `volumeAttributes.containerName: <backup.cluster>`, `storageAccount: mycarriermongobackups`,
       `resourceGroup: rg_management_controlplane`.
     - `nodeStageSecretRef` to the storage key Secret.
   - **`PersistentVolumeClaim`** in `<ns>`, bound to that PV by `volumeName`.
   - **Backup `CronJob`** `<fullname>-backup`:
     - Mounts the PVC with `subPath: <backup.path>`.
     - Reads the backup user's connection string from `<fullname>-backup-connection`.
     - Runs `mongodump --oplog --gzip --archive=/backups/<UTC timestamp>.archive.gz`, reading from a secondary when
       `members > 1`.
     - After a successful dump only, deletes `*.archive.gz` older than `backup.retentionDays`. A failed dump never
       prunes.
     - `concurrencyPolicy: Forbid`, a few history entries, `sidecar.istio.io/inject: "false"`.
   - **Restore `CronJob`** `<fullname>-restore`:
     - `suspend: true`, so the schedule never fires.
     - Same mount and secret as the backup CronJob.
     - Restores the newest archive, or the file named in env `RESTORE_FILE` when set (empty by default).
     - `mongorestore --drop --gzip --archive=<file> --nsExclude 'admin.*' --nsExclude 'config.*'`, plus
       `--oplogReplay` if it can be combined with `--nsExclude`. Excluding `admin.*` stops the restore from
       overwriting the users and roles the operator manages. **Builder verifies** the `--oplogReplay` /
       `--nsExclude` combination against the `mongorestore` version in the image, and drops `--oplog` from backup
       if the two can't be combined.

### Restoring

- **Newest backup:** in Argo CD, open `<fullname>-restore` and run the CronJob's built-in **Create Job** action, or
  `kubectl create job --from=cronjob/<fullname>-restore <name> -n <ns>`.
- **A specific backup:** `kubectl create job --from=cronjob/<fullname>-restore <name> -n <ns> --dry-run=client -o
  yaml`, set `RESTORE_FILE`, then `kubectl apply`.

Nothing about a restore lives in Git, so no sync can start one. The chart README documents both procedures, plus
how to list the available archives (exec into a Job from the restore CronJob, or browse the container in the portal).

### Istio

MongoDB pods and the backup and restore pods run without sidecars:

- A sidecar in a Job's pod keeps the Job from ever completing.
- Replica-set member traffic through sidecars adds failure modes for no benefit.

App pods with sidecars reach a non-mesh destination in plaintext, and no `PeerAuthentication` exists on the
management cluster. **Builder confirms** there is no STRICT mTLS policy on the app clusters that would block app
pods from connecting.

### Tests

helm-unittest suites under `charts/mc-mongodb/tests/`, written test-first:

- Defaults render the generator, the ExternalSecrets and the `MongoDBCommunity`, and no backup resources.
- `backup.enabled` renders the PV, PVC, storage ExternalSecret and both CronJobs with the right names, `subPath`,
  schedule, time zone and retention.
- The restore CronJob is always `suspend: true`.
- `backup.enabled` with an empty `backup.cluster` fails to render.
- `standalone: false` renders nothing.
- The PV name and `volumeHandle` include the namespace.

The release workflow picks up a new chart folder automatically; the unit-test workflow runs its suites.

## Embedding in mycarrier-helm (phase 2)

Phase 2 starts once phase 1 is released to `charts.mycarrier.dev`, because mycarrier-helm depends on a published
version of it.

- **Dependency:** `mc-mongodb` in mycarrier-helm's `Chart.yaml` with `alias: mongodb` and no `condition`. The
  release and unit-test workflows don't run `helm dependency build` today. **Builder checks** whether
  chart-releaser's packaging fetches dependencies and adds a `helm dependency build` step to `main.yml`,
  `manual-helm-release.yml` and `unit-tests.yaml` as needed. mycarrier-helm's `values.yaml` sets
  `mongodb.standalone: false` so the subchart's own templates never render.
- **Values a stack sets:** `mongodb.enabled` (default `false`), plus optional `mongodb.members`, `mongodb.version`,
  `mongodb.storage.*`, `mongodb.resources`, `mongodb.backup.schedule`, `mongodb.backup.timeZone` and
  `mongodb.backup.retentionDays`.
- **What mycarrier-helm computes:**
  - Production means `hasPrefix "prod" $metaenv`. This covers plain `prod` (what `_lang.tpl` checks) and any
    `prod-*` environment, which the chart's domain and affinity helpers already treat as production. It errs toward
    backing up: a production-like environment that gets backups costs storage, while a production environment
    without backups is an anti-goal.
  - Name: `<appStack>-mongodb`.
  - Backup: enabled exactly when production. A stack cannot turn it on outside production or off in production.
  - Backup path: `<environment.name>/<appStack>`.
  - Backup container: the cluster name (see Open questions).
  - Members: `mongodb.members` if set, otherwise 3 in production and 1 elsewhere.
- **Data on removal:** Argo prunes the `MongoDBCommunity` when a stack turns `mongodb.enabled` off or an
  environment is removed. The StatefulSet's data claims keep the default PVC retention (`Retain`), so the disks
  survive the resource being pruned and can be reattached by turning it back on. Deleting a feature namespace
  deletes its claims, so feature environments leave nothing behind. **Builder verifies** MCK doesn't set
  `persistentVolumeClaimRetentionPolicy.whenDeleted: Delete` or owner references on the claims.
- **Feature environments:** each feature namespace gets its own empty MongoDB when the stack enables it, without
  backups (feature environments' meta environment is dev).
- **Connection string swap:** in `_lang.tpl`, when `mongodb.enabled`, `MongoConnection_<metaenv>` becomes
  `valueFrom.secretKeyRef` (Secret `<appStack>-mongodb-connection`, key `connectionString.standard`) instead of the
  Vault reference. This is a new env shape there: the block emits only `value:` today. `KeyVault_MongoConnection`
  and `KeyVaultMongoConnection` keep naming that variable. When `mongodb.enabled` is false, nothing in the rendered
  output changes (a test pins this).
  - That block only renders for `global.language: csharp` stacks without `disableLanguageSecrets`. Other stacks
    reference `<appStack>-mongodb-connection` themselves; the guidance documents the Secret name and key.
- **Labels:** `dependency.mongo` keeps following `global.dependencies.mongodb`, unchanged.
- **mc-environment:** add `mongodb` to the per-environment values forwarding list in `appset.yaml` and to its schema
  (environment items are `additionalProperties: false`).
- **Guidance:** update `agent-guidance/helm/.apm/instructions/helm.instructions.md` with the values, defaults,
  production behaviour, Secret names and restore procedure, with a renderable example. Not a breaking change: the
  default is off and the off output is unchanged.
- **Tests:** production enables backup and gives 3 members; dev, preprod and feature environments render no backup
  resources; the connection-string swap appears only when enabled; a stack with `mongodb.enabled: false` renders
  exactly what it renders today.

## Open questions (need an answer before phase 1 is planned)

1. **Storage account key in Vault:** the Vault path and properties holding the `mycarriermongobackups` account name
   and key, readable through `vault-backend` from every app cluster.
2. **Cluster name:** no value in mycarrier-helm or mc-environment names the cluster. How should mycarrier-helm learn
   which container to write to (a value chart-renderer sets, a per-cluster global, a fixed mapping from meta
   environment)? And what are the container names?
3. **App user scope:** `readWrite` + `dbAdmin` on one database (the service's), or `readWriteAnyDatabase` so a
   service can create databases freely as it may against the shared instance today.

## Decisions taken here (not discussed explicitly)

- Chart name `mc-mongodb` (matches `mc-environment`), aliased `mongodb` inside mycarrier-helm.
- Named templates with a computed context so mycarrier-helm can drive environment-dependent values.
- External Secrets `Password` generator for credentials, with the regeneration caveat above.
- A separate backup user with `backup` + `restore` roles; the app user can't run `mongodump --oplog`.
- Fixed connection-string Secret names via `connectionStringSecretName`.
- Restore of a specific file uses `kubectl create job --from … --dry-run` with `RESTORE_FILE`; no values key.
- No sidecars on MongoDB, backup or restore pods.
- Storage account key auth through `nodeStageSecretRef`, as the debug PV does.
- MongoDB 8.0, pinned, with `featureCompatibilityVersion` pinned.
- Members default 1, and 3 in production under mycarrier-helm.
- Feature environments get their own MongoDB when enabled.
- The swap only touches the existing injection path; non-csharp stacks wire the Secret themselves.
- Production is `hasPrefix "prod"` on the meta environment, erring toward backups.
- Pruning the resource keeps the data disks (default PVC retention); feature namespaces take theirs with them.
- One app user per release; per-consumer users wait for a consumer that needs them.
