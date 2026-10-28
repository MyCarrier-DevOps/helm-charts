# mc-mongodb

A MongoDB replica set for internal tools, run by the MongoDB operator. Passwords are generated in the cluster, and
optional backups write to Azure Blob storage with an on-demand restore.

**Internal tools only.** Product applications use MongoDB Atlas, and their data is never moved into an in-cluster
instance.

## What it deploys

- A `MongoDBCommunity` replica set (`members`, default 1) with SCRAM authentication and two users:
  - the app user (`appUser.name`, default `app`) with `readWriteAnyDatabase` and `dbAdminAnyDatabase`: an app has a
    primary database and may create any number of others;
  - `backup`, with the `backup` and `restore` roles.
- A ServiceAccount, Role and RoleBinding (`<fullname>-database`) for the database pods, with the operator's database
  rules: the MongoDB agent reads Secrets and gets, patches and deletes its pods. The operator's own
  `mongodb-kubernetes-appdb` exists only in the operator's namespace.
- An External Secrets `Password` generator and one `ExternalSecret` per user. Each password is generated once
  (`refreshPolicy: CreatedOnce`) and kept if the ExternalSecret goes away (`deletionPolicy: Retain`).
- With `backup.enabled`:
  - a static blob `PersistentVolume` and claim;
  - a backup `CronJob` (default daily at 02:00 UTC, keeping 7 days);
  - a suspended restore `CronJob`.

MongoDB, backup and restore pods run without an Istio sidecar. They meet the clusters' Kyverno policies:
- the replica set's containers get liveness and readiness probes, which the operator doesn't set itself;
- backup and restore run as the `mongo` image's non-root user (999) on a read-only root filesystem.

## Prerequisites

- MongoDB Controllers for Kubernetes (`mongodb-kubernetes`, Helm repo `https://mongodb.github.io/helm-charts`) installed
  in the cluster and watching the namespace.
- External Secrets Operator with the `Password` generator (`passwords.generators.external-secrets.io`) and
  `refreshPolicy` support on `ExternalSecret`.
- For backups:
  - a container per cluster in the `mycarriermongobackups` storage account (production's is `production`);
  - the cluster's kubelet identity able to read that account's keys, because the blob CSI driver mounts with the key
    it fetches through the kubelet identity;
  - network access from the cluster to the account.

## Connecting

Secret `<fullname>-connection`, key `connectionString`:

```
mongodb://app:<password>@<fullname>-svc.<namespace>.svc.cluster.local:27017/<appUser.database>?replicaSet=<fullname>&authSource=admin
```

The connection string's path is the app's primary database. It defaults to the full name; set `appUser.database` to
choose it.

The full name is the release name, plus `-mc-mongodb` unless the release name already contains it, truncated to 45
characters. `fullnameOverride` replaces it.

If a password Secret is ever regenerated (its ExternalSecret deleted and recreated), the operator updates the user to
the new password and the Secret already holds the matching connection string. Restart the app's pods to pick it up.

## Backups

```yaml
backup:
  enabled: true
  container: production
  # schedule: "0 2 * * *"
  # timeZone: Etc/UTC
  # retentionDays: 7
  # path: <namespace>/<fullname>
```

Each run writes `<UTC timestamp>.archive.gz` (a gzipped `mongodump` archive of every database) into `backup.path`
inside the container. Archives are written under a `.partial` name and renamed once complete. After a successful dump,
archives older than `retentionDays` are deleted, judged by the timestamp in the file name. A failed dump deletes
nothing.

Backups don't capture the oplog: `mongorestore` can't replay an oplog while excluding the `admin` database, and the
restore must exclude it.

## Restoring

A restore replaces the collections in the archive (`--drop`). It never touches `admin` or `config`, so the users the
operator manages stay as they are. Collections created after the backup was taken are left in place.

**Newest backup:** in Argo CD, open the `<fullname>-restore` CronJob and run its **Create Job** action. Or:

```bash
kubectl create job --from=cronjob/<fullname>-restore restore-$(date +%s) -n <namespace>
```

**A specific backup:**

```bash
kubectl create job --from=cronjob/<fullname>-restore restore-$(date +%s) -n <namespace> --dry-run=client -o yaml \
  | sed 's/value: ""$/value: "20261028T020000Z.archive.gz"/' \
  | kubectl apply -f -
```

The `sed` sets `RESTORE_FILE`, the only env var with an empty value. Check the output before applying if in doubt.

**Listing archives:** browse the container in the Azure portal, or:

```bash
az storage blob list --account-name mycarriermongobackups --container-name production \
  --prefix <backup.path>/ --auth-mode login --query '[].name' -o tsv
```

The restore CronJob is always suspended with a schedule that never matches. Nothing in Git starts a restore, so no
sync can trigger one.

## Embedding

The resources are named templates that take one context dict (`mc-mongodb.context` builds it from these values). With
`standalone: false` the chart's own templates render nothing, so a parent chart can call `mc-mongodb.credentials`,
`mc-mongodb.mongodbcommunity`, `mc-mongodb.backup` and `mc-mongodb.restore` with a context it computes.

mycarrier-helm does this for `dependencyDeployments.mongodb` (`templates/_mongodb.tpl` there): it takes defaults from
this chart's values, applies the stack's overrides, and decides members and backups from the environment.

## Parameters

### Rendering

| Name               | Description                                                                            | Value   |
| ------------------ | -------------------------------------------------------------------------------------- | ------- |
| `standalone`       | Render from this chart's own templates. mycarrier-helm sets false.                      | `true`  |
| `debugContext`     | Render a ConfigMap holding the computed render context (used by the chart's tests only) | `false` |
| `nameOverride`     | Override the chart name used in resource names                                          | `""`    |
| `fullnameOverride` | Override the full resource name                                                         | `""`    |

### MongoDB

| Name                          | Description                                                       | Value    |
| ----------------------------- | ----------------------------------------------------------------- | -------- |
| `members`                     | Number of replica set members                                     | `1`      |
| `version`                     | MongoDB server version (exact)                                    | `8.0.34` |
| `featureCompatibilityVersion` | Pinned feature compatibility version, so upgrades are deliberate  | `8.0`    |
| `storage.size`                | Data volume size per member                                       | `10Gi`   |
| `storage.storageClassName`    | Storage class for the data volume (empty uses the cluster default) | `""`     |
| `resources`                   | Resources for the mongod container                                | `{...}`  |
| `appUser.name`                | Application user name                                             | `app`    |
| `appUser.database`            | Primary database in the connection string (defaults to the full name) | `""` |
| `password.length`             | Length of each generated password (minimum 16)                    | `32`     |

### Backups

| Name                    | Description                                                         | Value                                  |
| ----------------------- | ------------------------------------------------------------------- | -------------------------------------- |
| `backup.enabled`        | Render the backup and restore CronJobs and their blob storage volume | `false`                                |
| `backup.schedule`       | Cron schedule for backups                                           | `0 2 * * *`                            |
| `backup.timeZone`       | Time zone for the backup schedule                                   | `Etc/UTC`                              |
| `backup.retentionDays`  | Days to keep backups                                                | `7`                                    |
| `backup.container`      | Blob container, one per cluster. Required when backups are enabled.  | `""`                                   |
| `backup.path`           | Folder inside the container (defaults to `<namespace>/<fullname>`)   | `""`                                   |
| `backup.storageAccount` | Storage account holding the backup containers                       | `mycarriermongobackups`                |
| `backup.resourceGroup`  | Resource group of the storage account                               | `rg_management_controlplane`           |
| `backup.subscriptionId` | Subscription of the storage account                                 | `99b54c45-a73d-4d40-915e-c0392b589e8c` |
| `backup.activeDeadlineSeconds` | Longest a backup Job may run before it is failed              | `21600`                                |
| `backup.image`          | Image providing mongodump and mongorestore                          | `mongo:8.0.34`                         |
| `backup.resources`      | Resources for the backup and restore containers                     | `{...}`                                |
