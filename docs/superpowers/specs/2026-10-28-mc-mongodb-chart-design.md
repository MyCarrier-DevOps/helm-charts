# Design: `mc-mongodb` chart (in-cluster MongoDB with production backups)

**Date:** 2026-10-28
**Charts:** new `charts/mc-mongodb`, `charts/mycarrier-helm`, `charts/mc-environment` (one PR)
**Status:** Draft

## Intent

A service team should be able to run its own MongoDB next to its application instead of sharing the central
instance, and in production that MongoDB must be backed up without anyone remembering to set it up.

The work ships in two phases, in one PR:

1. **Standalone chart.** `charts/mc-mongodb` deploys one MongoDB replica set through the MongoDB operator and, when
   asked, a daily backup CronJob writing to Azure Blob storage plus a restore CronJob that only runs on demand.
2. **Embedded in mycarrier-helm.** A stack sets `dependencyDeployments.mongodb.enabled: true`. mycarrier-helm renders the chart's
   resources, turns backups on in production (and elsewhere when the stack asks), and points the service's injected Mongo connection string at the
   in-cluster instance instead of the shared one.

The chart serves one application user per release. Several services can share a release by using that user's
connection string (from the same namespace, or by copying it); separate users per consumer are out of scope until a
consumer needs them.

## Goals

- Render a `MongoDBCommunity` resource; the operator does the rest.
- Generate credentials in-cluster. Nobody puts a MongoDB password in Vault or Git.
- Backups with a configurable schedule and retention, defaulting to one backup per day kept for 7 days.
- Backups land in the `mycarriermongobackups` storage account: one container per cluster (production's is
  `production`), a folder per environment and service.
- Restore is one action in the Argo CD UI, and a sync can never trigger it.
- In mycarrier-helm: backups on in production with no per-stack setting needed; off everywhere else unless the stack
  turns them on and names its cluster's container (for example a tool on the management cluster).
- In mycarrier-helm: the injected connection string switches to the in-cluster instance **if and only if** the stack
  deploys it. Stacks that don't are unchanged.

## Audience

Internal tools only. Product applications use MongoDB Atlas, and their data is never migrated to an in-cluster
instance. A product stack turning this on is a configuration error; the chart doesn't try to detect it, and the
off-by-default switch is the safeguard.

## Non-goals

- Installing the operator. The operator is installed once per cluster, separately (see Prerequisites).
- Bitnami charts or images in any form.
- Sharding, arbiters, MongoDB's own TLS, X.509 auth, Prometheus wiring. The CRD supports them; nothing here needs
  them yet. Traffic is encrypted by the Istio sidecars instead (see Istio).
- An allowlist of clients. A NetworkPolicy is not enforced on the app clusters (AKS `networkPolicy: none`); add one if
  they move to Cilium. An Istio `AuthorizationPolicy` identifies callers only by ServiceAccount, and stacks' pods all
  run as `default`.
- Point-in-time recovery beyond what a nightly `mongodump --oplog` gives.
- Alerting on failed backups. A failed backup shows as a failed Job; alerting can come later through the chart's
  alerts feature.
- Creating the per-cluster blob containers or the storage account, or granting access to them.
- Migrating data from Atlas or the shared instance, or guarding against a product stack enabling this.

## Anti-goals (failure even if it renders)

- **A sync restores data.** Any design where an Argo sync, self-heal, prune or re-add can start a restore is wrong.
- **A non-production environment writes backups without the stack asking**, or production silently has none.
- **A stack that doesn't deploy MongoDB sees any change** in its rendered output.
- **Passwords rotate on their own.** A re-render or re-sync must not produce a new password.

## Prerequisites (outside this repo)

- MongoDB Controllers for Kubernetes (`mongodb-kubernetes`, Helm repo `https://mongodb.github.io/helm-charts`)
  installed in each app cluster and watching the app namespaces. It replaces the Community Operator (end of life
  November 2025) and still serves `mongodbcommunity.mongodb.com/v1` `MongoDBCommunity`.
- External Secrets Operator with the `Password` generator CRD (`passwords.generators.external-secrets.io`). It is
  present on the management cluster; confirm on each app cluster.
- A blob container per cluster in `mycarriermongobackups` (`rg_management_controlplane`, subscription
  `99b54c45-a73d-4d40-915e-c0392b589e8c`); production's container is `production`. The account's network rules allow
  the app clusters.
- Each cluster's AKS kubelet identity has `Storage Blob Data Contributor` on its container. Blobfuse signs in as that
  identity (`AzureStorageAuthType: msi`, lowercase); blob CSI driver v1.27.0 or later (v1.26.7 / v1.25.10) fills in the
  kubelet identity's client ID, and both app clusters run v1.27.11. No account key is fetched, so the identity needs no
  `listKeys`. The PV source is immutable, so the auth mode is fixed before the first backup deploys.

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
| `appUser.database` | `<fullname>` | The app's primary database: the path of the connection string the chart builds, which services read their database name from. It doesn't limit access. |
| `password.length` | `32` | Generated password length. |
| `backup.enabled` | `false` | Render the backup and restore CronJobs and their storage. |
| `backup.schedule` | `"0 2 * * *"` | Cron schedule. |
| `backup.timeZone` | `"Etc/UTC"` | CronJob time zone. |
| `backup.retentionDays` | `7` | Backups older than this are deleted after each successful backup. |
| `backup.container` | none, required when enabled | Blob container name (one per cluster, e.g. `production`). Render fails if empty. |
| `backup.path` | `<namespace>/<fullname>` | Folder inside the container. |
| `backup.storageAccount` | `mycarriermongobackups` | Storage account. |
| `backup.resourceGroup` | `rg_management_controlplane` | Its resource group. |
| `backup.subscriptionId` | `99b54c45-a73d-4d40-915e-c0392b589e8c` | Its subscription (it is not the clusters' subscription). |
| `backup.image` | official `mongo` image, same tag as `version` | Has `mongodump` / `mongorestore`. |
| `backup.resources` | modest | Backup and restore container resources. |

A `values.schema.json` validates these, including `members >= 1`, `retentionDays >= 1`, and a required non-empty
`backup.container` when `backup.enabled`.

### Resources rendered

All names derive from `<fullname>`; `<ns>` is the release namespace.

1. **Credentials (External Secrets).** A `generators.external-secrets.io/v1alpha1` `Password` and two
   `ExternalSecret`s (app user, backup user), each using `dataFrom[].sourceRef.generatorRef`. Each one's
   `target.template` writes a Secret with two keys:
   - `password`, which the operator reads through `passwordSecretRef`;
   - `connectionString`, built in the template from that password:
     `mongodb://<user>:<password>@<fullname>-svc.<ns>.svc.cluster.local:27017/<database>?replicaSet=<fullname>&authSource=admin`.
     For the app user `<database>` is `appUser.database`; for the backup user it is omitted.
   Services take their database name from the connection string, which the operator's own connection-string Secret
   doesn't carry (its path is the auth database, `admin`), so the chart builds its own. The app Secret is
   `<fullname>-connection`; the backup Secret is `<fullname>-backup-connection`. **Builder verifies** the operator's
   Service name and that the generated password needs no URL-encoding.
   - `refreshInterval: "0"` so the password is generated once.
   - No symbols in the generated password (it ends up in connection strings).
   - `target.deletionPolicy: Retain` and no `Replace=true`/`Force=true` sync options on these objects. The password
     regenerates only if the ExternalSecret is deleted and recreated; when that happens the operator updates the
     user's SCRAM credentials, and the regenerated Secret already holds a matching connection string, so the worst case is
     restarting the app pods.
     **Builder verifies** that the operator reconciles a changed password Secret.
2. **`MongoDBCommunity`** (`mongodbcommunity.mongodb.com/v1`):
   - `type: ReplicaSet`, `members`, `version`, `featureCompatibilityVersion`.
   - `security.authentication.modes: [SCRAM]`.
   - `users`:
     - app user, `db: admin`, `passwordSecretRef` (key `password`) to its generated Secret,
       `scramCredentialsSecretName`, and roles `readWriteAnyDatabase` and `dbAdminAnyDatabase` on `admin`. Apps rely
       on a primary database (the connection string's) plus any number of secondary databases and collections they
       create themselves.
     - backup user, `db: admin`, role `backup` on `admin`.
     - with backups, a restore user, `db: admin`, role `restore` on `admin`, with its own generated Secret
       (`<fullname>-restore-connection`) that only the restore Job reads. `restore` can rewrite users and grant roles.
   - `security.authentication.ignoreUnknownUsers: false`, so the agent removes users the chart does not declare.
     - `connectionStringSecretName` is left to the operator's default; nothing consumes that Secret.
   - `statefulSet.metadata` / `statefulSet.spec` overrides: data volume claim size and storage class, mongod
     resources, the Istio sidecar annotations, the ServiceAccount, probes and, with more than one member, required pod
     anti-affinity on `kubernetes.io/hostname`. A multi-member set also gets a PodDisruptionBudget (`maxUnavailable: 1`). **Builder verifies** the override paths
     against the MCK samples (the CRD leaves `statefulSet.spec` free-form).
3. **When `backup.enabled`:**
   - **Static `PersistentVolume`** (cluster-scoped, so the name must be unique per cluster: `<ns>-<fullname>-backup`):
     - `csi.driver: blob.csi.azure.com`, `storageClassName: azureblob-fuse-premium` (as the existing debug PV),
       `ReadWriteMany`, `persistentVolumeReclaimPolicy: Retain`.
     - `volumeHandle: <ns>-<fullname>-backup`.
     - `volumeAttributes`: `containerName: <backup.container>`, `storageAccount`, `resourceGroup`,
       `subscriptionID` from values, and managed-identity auth (`AzureStorageAuthType: msi`), which uses the kubelet
       identity. `claimRef` reserves the PV for its claim. No `nodeStageSecretRef`. **Builder verifies** the attribute names against the blob CSI driver's
       static-provisioning docs, including that it doesn't try to fetch an account key cross-subscription.
   - **`PersistentVolumeClaim`** in `<ns>`, bound to that PV by `volumeName`.
   - **Backup `CronJob`** `<fullname>-backup`:
     - Mounts the PVC with `subPath: <backup.path>`.
     - Reads the backup user's connection string from `<fullname>-backup-connection`.
     - Runs `mongodump --oplog --gzip --archive=/backups/<UTC timestamp>.archive.gz`, reading from a secondary when
       `members > 1`.
     - After a successful dump only, deletes `*.archive.gz` older than `backup.retentionDays`. A failed dump never
       prunes.
     - `concurrencyPolicy: Forbid`, a few history entries, an Istio sidecar, no ServiceAccount token.
   - **Restore `CronJob`** `<fullname>-restore`:
     - `suspend: true`, so the schedule never fires.
     - Same mount as the backup CronJob; reads the restore user's Secret.
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

MongoDB pods and the backup and restore pods run with Istio sidecars, so traffic between members and from clients
with sidecars is encrypted by Istio's automatic mutual TLS. The app clusters run Istio 1.27 with native sidecars
(istio-proxy as an init container that always restarts), so a Job's sidecar does not keep it from completing. Istio
rewrites the TCP probes to its agent, which still checks the container's port.

No STRICT `PeerAuthentication`: a client without a sidecar can still connect in plaintext, with a SCRAM login. The
clusters' STRICT policy (`mtls-strict` in `istio-system`, selector `mtls: strict`) does not take effect outside
`istio-system`; a labelled pod still reports PERMISSIVE.

### Tests

helm-unittest suites under `charts/mc-mongodb/tests/`, written test-first:

- Defaults render the generator, the ExternalSecrets and the `MongoDBCommunity`, and no backup resources.
- `backup.enabled` renders the PV, PVC and both CronJobs with the right names, `subPath`,
  schedule, time zone and retention.
- The restore CronJob is always `suspend: true`.
- `backup.enabled` with an empty `backup.container` fails to render.
- The app connection string's path is `appUser.database`, and the app user holds `readWriteAnyDatabase` and
  `dbAdminAnyDatabase`.
- `standalone: false` renders nothing.
- The PV name and `volumeHandle` include the namespace.

The release workflow picks up a new chart folder automatically; the unit-test workflow runs its suites.

### Database pod ServiceAccount

MCK 1.14.0 runs the replica set's pods under ServiceAccount `mongodb-kubernetes-appdb`
(`mongodb-community-operator/controllers/construct/mongodbstatefulset.go`), and its chart creates that account and its
Role only in the operator's namespace when it watches all namespaces. The chart therefore renders
`<name>-database` (ServiceAccount, Role with the operator's database rules, RoleBinding) and sets
`statefulSet.spec.template.spec.serviceAccountName` to it; the operator's pod-template merge keeps a non-empty
override. A per-release name keeps two releases in one namespace (two stacks in `dev`) from sharing one.

### Cluster policies

The app clusters enforce Kyverno policies in app namespaces (`prod` included): liveness and readiness probes on every
StatefulSet container, a read-only root filesystem, non-root users, and images only from Harbor, ACR, ghcr.io and a
few named upstream paths. Checked with the Kyverno CLI against both clusters' policies, using the StatefulSet MCK
1.14.0 actually builds (on a local cluster):
- `mongod` gets TCP startup, liveness and readiness probes on 27017 (the startup probe allows 10 minutes for the
  agent's first configuration); the agent's liveness probe opens its status port, 127.0.0.1:5000, from inside
  the container (the port is not bound to the pod IP, so a tcpSocket probe fails), and it keeps the operator's
  readiness probe.
- Backup and restore pods run as uid/gid 999 (the `mongo` image's user), read-only root, `/tmp` as an emptyDir.
- `mongo:8.0.34` is rewritten to `harbor.mycarrier.tech/proxy-cache` by the clusters' harbor-container-webhook. The
  operator's images come through a Harbor quay.io proxy project, set in the operator's values.

## Embedding in mycarrier-helm (phase 2)

Both phases ship together: mycarrier-helm depends on `mc-mongodb` from this repository (`file://../mc-mongodb`), so a
mycarrier-helm release packages the `mc-mongodb` of the same commit. chart-releaser's `cr package` updates
dependencies before packaging (`DependencyUpdate = true`), which resolves a local dependency without a repository;
`unit-tests.yaml` runs `helm dependency update` before the unit tests and the guidance examples. The version
constraint is `>=0.1.0`, because the release workflow bumps `mc-mongodb`'s version.

- **Dependency:** `mc-mongodb` in mycarrier-helm's `Chart.yaml`, without an alias and without a `condition`.
  mycarrier-helm's `values.yaml` sets `mc-mongodb.standalone: false` so the subchart's own templates never render.
  The subchart's values key stays `mc-mongodb`, which reads as the chart rather than as a switch; stacks don't set it.
- **Values a stack sets:** all under `dependencyDeployments.mongodb`, so deploying a database reads differently from
  using one (`global.dependencies.mongodb`): `enabled` (default `false`), plus optional `members`, `version`,
  `storage.*`, `resources`, `backup.enabled`, `backup.container`, `backup.schedule`, `backup.timeZone` and
  `backup.retentionDays`. mycarrier-helm's schema defines them and rejects anything else. mycarrier-helm reads the remaining defaults
  from the subchart's values (`.Values.mc-mongodb`) and layers the stack's settings over them.
- **What mycarrier-helm computes:**
  - Production means `hasPrefix "prod" $metaenv`. This covers plain `prod` (what `_lang.tpl` checks) and any
    `prod-*` environment, which the chart's domain and affinity helpers already treat as production. It errs toward
    backing up: a production-like environment that gets backups costs storage, while a production environment
    without backups is an anti-goal.
  - Name: `<appStack>-mongodb`.
  - Backup: always enabled in production (`backup.enabled: false` there fails the render); elsewhere enabled when the
    stack sets `backup.enabled: true`. Backups are optional in any environment because the chart can run outside the
    app clusters (the management cluster), where a tool may well need them.
  - Backup path: `<meta environment>/<appStack>/<namespace>` (appStack lowercased), so releases of one stack in different namespaces of an environment back up to separate folders.
  - Backup container: the stack's `backup.container`, defaulting to `production` in production. The chart cannot tell
    which cluster it renders on, so enabling backups outside production without a container fails the render.
  - Database: `appStack`, the same in every environment, so a production backup restores into a matching database
    elsewhere.
  - Members: `dependencyDeployments.mongodb.members` if set, otherwise 3 in production and 1 elsewhere.
- **Data on removal:** Argo prunes the `MongoDBCommunity` when a stack turns `dependencyDeployments.mongodb.enabled` off or an
  environment is removed. The StatefulSet's data claims keep the default PVC retention (`Retain`), so the disks
  survive the resource being pruned and can be reattached by turning it back on. Deleting a feature namespace
  deletes its claims, so feature environments leave nothing behind. **Builder verifies** MCK doesn't set
  `persistentVolumeClaimRetentionPolicy.whenDeleted: Delete` or owner references on the claims.
- **Feature environments:** each feature namespace gets its own empty MongoDB when the stack enables it, without
  backups unless the stack turns them on (feature environments' meta environment is dev).
- **Connection string swap:** in `_lang.tpl`, when `dependencyDeployments.mongodb.enabled`, `MongoConnection_<metaenv>` becomes
  `valueFrom.secretKeyRef` (Secret `<appStack>-mongodb-connection`, key `connectionString`) instead of the
  Vault reference. This is a new env shape there: the block emits only `value:` today. `KeyVault_MongoConnection`
  and `KeyVaultMongoConnection` keep naming that variable. When it is false, nothing in the rendered
  output changes (a test pins this).
  - That block only renders for `global.language: csharp` stacks without `disableLanguageSecrets`. Other stacks
    reference `<appStack>-mongodb-connection` themselves; the guidance documents the Secret name and key.
- **Labels:** `dependency.mongo` keeps following `global.dependencies.mongodb`, unchanged.
- **mc-environment:** add `dependencyDeployments` to the per-environment values forwarding list in `appset.yaml` and
  to its schema (environment items are `additionalProperties: false`). The schema types it as an object that
  mycarrier-helm validates, as it does `alerts`: a `$ref` to mycarrier-helm's schema on `main` can't resolve until this
  merges, and an unresolvable remote pointer fails every mc-environment render.
- **Guidance:** update `agent-guidance/helm/.apm/instructions/helm.instructions.md` with the values, defaults,
  production behaviour, Secret names and restore procedure, with a renderable example. Not a breaking change: the
  default is off and the off output is unchanged.
- **Tests:** production enables backup and gives 3 members; dev, preprod and feature environments render no backup
  resources; the connection-string swap appears only when enabled; a stack without `dependencyDeployments` renders
  exactly what it renders today.

## Answered during review

- Production's backup container is named `production`, not after the cluster.
- Storage access is the AKS kubelet identity through Azure RBAC; the chart carries no storage credentials.
- Services read their primary database name from the connection string, and create any number of further
  databases and collections, so the app user has `readWriteAnyDatabase` + `dbAdminAnyDatabase`.
- Internal tools only; no migration, and no guard beyond off by default.

## Decisions taken here (not discussed explicitly)

- Chart name `mc-mongodb` (matches `mc-environment`); stacks reach it through `dependencyDeployments.mongodb`.
- Named templates with a computed context so mycarrier-helm can drive environment-dependent values.
- External Secrets `Password` generator for credentials, with the regeneration caveat above.
- A backup user with only `backup`, and a restore user with only `restore`, read only by the restore Job.
- The chart builds the connection string itself (ExternalSecret template) so it carries the database name.
- Database name under mycarrier-helm is `appStack`.
- Restore of a specific file uses `kubectl create job --from … --dry-run` with `RESTORE_FILE`; no values key.
- Istio sidecars on MongoDB, backup and restore pods, with automatic mutual TLS; no STRICT policy and no client
  allowlist.
- MongoDB 8.0, pinned, with `featureCompatibilityVersion` pinned.
- Members default 1, and 3 in production under mycarrier-helm.
- Feature environments get their own MongoDB when enabled.
- The swap only touches the existing injection path; non-csharp stacks wire the Secret themselves.
- Production is `hasPrefix "prod"` on the meta environment, erring toward backups.
- Pruning the resource keeps the data disks (default PVC retention). Feature namespaces outlive offloads, so a stack's
  disks there are kept too, and its next MongoDB in that environment reattaches them.
- One app user per release; per-consumer users wait for a consumer that needs them.
