# mc-mongodb Chart (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone `charts/mc-mongodb` chart that renders a `MongoDBCommunity` replica set with generated credentials and, when enabled, a backup CronJob writing to Azure Blob plus a suspended restore CronJob.

**Architecture:** Every resource is a named template taking one context dict, built by `mc-mongodb.context` from `.Values`. Thin wrapper files in `templates/` call those named templates only when `standalone: true`, so mycarrier-helm can later call the same named templates with a context it computes (phase 2, separate plan). Scripts are inline in the named templates, not in `files/`: a parent chart's `.Files` cannot see a subchart's files.

**Tech Stack:** Helm 3/4, helm-unittest 1.1.0, MongoDB Controllers for Kubernetes (MCK) 1.14.0 (`mongodbcommunity.mongodb.com/v1`), External Secrets Operator (`external-secrets.io/v1`, `generators.external-secrets.io/v1alpha1`), `blob.csi.azure.com`.

**Spec:** `docs/superpowers/specs/2026-10-28-mc-mongodb-chart-design.md`

## Global Constraints

- Never edit `version:` in `Chart.yaml` after creation; the release workflow bumps it. Create it at `0.1.0`.
- No Bitnami charts, images or `common` library.
- MongoDB `version: "8.0.34"`, `featureCompatibilityVersion: "8.0"`; backup/restore image `mongo:8.0.34`.
- Storage defaults: account `mycarriermongobackups`, resource group `rg_management_controlplane`, subscription `99b54c45-a73d-4d40-915e-c0392b589e8c`, storage class `azureblob-fuse-premium`, auth via kubelet identity (no secrets).
- Backup defaults: schedule `"0 2 * * *"`, time zone `"Etc/UTC"`, retention `7` days.
- Passwords: ESO `Password` generator, `symbols: 0`, `refreshPolicy: CreatedOnce`, `target.deletionPolicy: Retain`; never `Replace=true` or `Force=true` on these objects.
- No Istio sidecar on MongoDB, backup or restore pods (`sidecar.istio.io/inject: "false"`).
- Every pod this chart defines sets `securityContext.seccompProfile.type: RuntimeDefault` (the development cluster's Kyverno `restrict-seccomp` enforces it).
- The restore CronJob is always `suspend: true`; no values key can change that.
- Commits carry only the user's authorship; no `Co-Authored-By` or tool attribution anywhere.
- Run helm commands through `rtk proxy` when you need the full output or test totals (RTK truncates them, even when redirected to a file). In helm-unittest `set:`, never use `[i]` list paths; nest YAML instead.

## Review Focus

1. **Names longer than the 63-character label limit** (long release names): every rendered name and label value must stay valid, so a long release name still renders. Task 2 pins this.
2. **Two releases in different namespaces with the same release name:** the cluster-scoped PV names and `volumeHandle`s must not collide. Task 4 pins this.
3. **A failed `mongodump`** must leave the previous backups untouched (no prune) and must not leave a file that looks like a complete archive. Task 5 pins this.
4. **Restore with no archives present, or `RESTORE_FILE` naming a missing file:** the Job fails with a clear message instead of running `mongorestore` on nothing. Task 6 pins this.
5. **`standalone: false`** must render zero documents from every template, or phase 2 renders everything twice. Task 7 pins this across all wrappers.

---

### Task 1: Pin the upstream facts the templates depend on

The spec marks several facts "builder verifies". Settle them first; later tasks use the results. No chart files in this task.

**Files:**
- Create: `charts/mc-mongodb/VERIFIED.md` (temporary notes; deleted in Task 7 after the README absorbs anything users need)

**Interfaces:**
- Produces, recorded in `VERIFIED.md`, each with its source (URL, command output):
  - MCK Service name for a `MongoDBCommunity` named `X` (expected `X-svc`).
  - The `statefulSet.spec` override paths for pod annotations, pod `securityContext`, the `mongod` container's resources and the data volume claim template (expected: `template.metadata.annotations`, `template.spec.securityContext`, `template.spec.containers[name=mongod].resources`, `volumeClaimTemplates[metadata.name=data-volume]`). Use the MCK repo's community samples.
  - Whether MCK sets owner references or a `persistentVolumeClaimRetentionPolicy` that deletes data claims.
  - Whether MCK reconciles a changed `passwordSecretRef` Secret into new SCRAM credentials.
  - blob CSI static-PV attribute names for managed-identity auth using the kubelet identity (expected `AzureStorageAuthType: MSI`; check whether `AzureStorageIdentityClientID` is needed or the kubelet identity is the default), and that setting `subscriptionID`/`resourceGroup`/`storageAccount` with MSI does not make the driver fetch an account key. Source: kubernetes-sigs/blob-csi-driver `docs/driver-parameters.md`.
  - Whether `mongorestore` 100.x in `mongo:8.0.34` accepts `--oplogReplay` together with `--nsExclude`. Check this locally: run `mongo:8.0.34` as a single-node replica set with Docker, insert into two databases, `mongodump --oplog --gzip --archive`, then `mongorestore --drop --gzip --archive --nsExclude 'admin.*' --nsExclude 'config.*' --oplogReplay`. Record the result as one of two outcomes: **combined**, or **no-oplog** (backup drops `--oplog` and restore drops `--oplogReplay`).
  - That `mongo:8.0.34` contains `mongodump`, `mongorestore`, `bash` and GNU `date` (`docker run --rm mongo:8.0.34 bash -c 'mongodump --version; date -u -d "-7 days" +%Y%m%dT%H%M%SZ'`).

- [ ] **Step 1: Gather each fact above from its source and write `VERIFIED.md`.**
- [ ] **Step 2: Commit.** `git add charts/mc-mongodb/VERIFIED.md && git commit -m "chore(mc-mongodb): record verified upstream behaviour"`

If any finding contradicts the spec (for example, MCK deletes data claims), stop and report it before continuing.

---

### Task 2: Chart skeleton, context and naming

**Files:**
- Create: `charts/mc-mongodb/Chart.yaml`, `charts/mc-mongodb/package.json`, `charts/mc-mongodb/.helmignore`, `charts/mc-mongodb/values.yaml`, `charts/mc-mongodb/templates/_helpers.tpl`
- Test: `charts/mc-mongodb/tests/context_test.yaml` (with `charts/mc-mongodb/templates/context-debug.yaml`, test-only: see Step 3)

**Interfaces:**
- Produces:
  - `include "mc-mongodb.fullname" .`: the usual fullname rules (`fullnameOverride`, else release name if it contains the chart name, else `<release>-mc-mongodb`), truncated so that `<fullname>-backup-connection` (the longest derived name, 18 more characters) stays ≤ 63: truncate fullname to 45 and trim a trailing `-`.
  - `include "mc-mongodb.context" . | fromJson` → dict:
    ```
    name, namespace, labels (map: app.kubernetes.io/name, instance, managed-by, helm.sh/chart),
    members, version, featureCompatibilityVersion,
    storage {size, storageClassName}, resources,
    appUser {name, database}, password {length},
    backup {enabled, schedule, timeZone, retentionDays, container, path,
            storageAccount, resourceGroup, subscriptionId, image, resources}
    ```
    `appUser.database` defaults to `name`; `backup.path` defaults to `<namespace>/<name>`. Every other key comes straight from `.Values`. Named templates in later tasks take only this dict and never read `.Values`, `.Release` or `.Chart`.
- `values.yaml` keys and defaults are exactly the spec's values table, with the Global Constraints values. Each key carries a `## @param` comment (readme-generator style, as in other charts).

- [ ] **Step 1: Write the failing test** `tests/context_test.yaml`, rendering `templates/context-debug.yaml`. That file is a ConfigMap, rendered only when `.Values.debugContext` is true, whose `data` holds selected context fields as strings under flat keys: `name`, `namespace`, `appUserDatabase`, `backupPath`, `members`, `version`, `backupEnabled`, `retentionDays`. Assert each with `equal` on `data.<key>`. Every test sets `debugContext: true`.
  - default release `mydb` in namespace `tools`: `name` is `mydb-mc-mongodb`, `appUser.database` is `mydb-mc-mongodb`, `backup.path` is `tools/mydb-mc-mongodb`, `members` is `1`, `version` is `"8.0.34"`, `backup.enabled` is `false`, `backup.retentionDays` is `7`.
  - `fullnameOverride: inventory` gives `name` `inventory`.
  - a 70-character release name gives a `name` of ≤ 45 characters without a trailing `-`.
  - `backup.path: custom/dir` and `appUser.database: primary` override the defaults.
- [ ] **Step 2: Run** `rtk proxy helm unittest charts/mc-mongodb -f tests/context_test.yaml`. Expected: FAIL (templates missing).
- [ ] **Step 3: Implement** `Chart.yaml` (`apiVersion: v2`, `name: mc-mongodb`, `type: application`, `version: 0.1.0`, `appVersion: "8.0.34"`, description, `annotations.category: Database`), `package.json` (copy the shape of `charts/istio-sidecars/package.json`), `values.yaml`, `_helpers.tpl` (`mc-mongodb.name`, `mc-mongodb.fullname`, `mc-mongodb.labels`, `mc-mongodb.context`), and `templates/context-debug.yaml`. Add `debugContext: false` to values with a comment saying it exists for tests.
- [ ] **Step 4: Run the test.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(mc-mongodb): chart skeleton and render context`

---

### Task 3: Generated credentials

**Files:**
- Create: `charts/mc-mongodb/templates/_credentials.tpl`, `charts/mc-mongodb/templates/credentials.yaml`
- Test: `charts/mc-mongodb/tests/credentials_test.yaml`

**Interfaces:**
- Consumes: `mc-mongodb.context` (Task 2).
- Produces: `include "mc-mongodb.credentials" $ctx`, which renders three documents:
  - `Password` (`generators.external-secrets.io/v1alpha1`) named `<name>-password`: `length: password.length`, `digits: 6`, `symbols: 0`, `noUpper: false`, `allowRepeat: true`.
  - `ExternalSecret` `<name>-app` → Secret `<name>-connection`.
  - `ExternalSecret` `<name>-backup` → Secret `<name>-backup-connection`.
  - Both ExternalSecrets: `refreshPolicy: CreatedOnce`, `target.creationPolicy: Owner`, `target.deletionPolicy: Retain`, `dataFrom[0].sourceRef.generatorRef` → the Password, and `target.template.engineVersion: v2` with `data.password: {{ .password }}` and `data.connectionString`:
    - app: `mongodb://<appUser.name>:{{ .password }}@<name>-svc.<namespace>.svc.cluster.local:27017/<appUser.database>?replicaSet=<name>&authSource=admin`
    - backup: same with user `backup` and no database path (`...:27017/?replicaSet=<name>&authSource=admin`)
    - ESO template braces are escaped for Helm (`{{ "{{ .password }}" }}`).
  - Secret names `<name>-connection` and `<name>-backup-connection`, and the key names `password` and `connectionString`, are the contract Tasks 4–6 and phase 2 use.
- `templates/credentials.yaml`: `{{- if .Values.standalone }}{{ include "mc-mongodb.credentials" (include "mc-mongodb.context" . | fromJson) }}{{- end }}`. Every wrapper in later tasks follows this shape.

- [ ] **Step 1: Write the failing tests** (release `mydb`, namespace `tools`):
  - 3 documents. Doc 0 is kind `Password` with `spec.symbols: 0` and `spec.length: 32`.
  - The app ExternalSecret has `spec.refreshPolicy: CreatedOnce`, `spec.target.name: mydb-mc-mongodb-connection` and `spec.target.deletionPolicy: Retain`, and its `connectionString` template equals `mongodb://app:{{ .password }}@mydb-mc-mongodb-svc.tools.svc.cluster.local:27017/mydb-mc-mongodb?replicaSet=mydb-mc-mongodb&authSource=admin`.
  - The backup ExternalSecret targets `mydb-mc-mongodb-backup-connection`, and its connection string has user `backup` and path `/`.
  - `password.length: 48` sets `spec.length: 48`.
  - Neither ExternalSecret has an `argocd.argoproj.io/sync-options` annotation (`notExists`).
- [ ] **Step 2: Run** the suite. Expected: FAIL (no template).
- [ ] **Step 3: Implement** `_credentials.tpl` and `credentials.yaml`. Labels come from `$ctx.labels`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(mc-mongodb): generated credentials and connection strings`

---

### Task 4: MongoDBCommunity resource

**Files:**
- Create: `charts/mc-mongodb/templates/_mongodbcommunity.tpl`, `charts/mc-mongodb/templates/mongodbcommunity.yaml`
- Test: `charts/mc-mongodb/tests/mongodbcommunity_test.yaml`

**Interfaces:**
- Consumes: the context (Task 2); Secret names and key `password` (Task 3); override paths (Task 1's `VERIFIED.md`).
- Produces: `include "mc-mongodb.mongodbcommunity" $ctx` → one `MongoDBCommunity` named `<name>`:
  - `type: ReplicaSet`, `members`, `version`, `featureCompatibilityVersion`, `security.authentication.modes: [SCRAM]`.
  - `users`:
    - app user (`appUser.name`), `db: admin`, `passwordSecretRef: {name: <name>-connection, key: password}`, `scramCredentialsSecretName: <name>-app`, roles `readWriteAnyDatabase` and `dbAdminAnyDatabase` on `admin`.
    - `backup`, `db: admin`, `passwordSecretRef: {name: <name>-backup-connection, key: password}`, `scramCredentialsSecretName: <name>-backup`, roles `backup` and `restore` on `admin`.
  - `statefulSet.spec`, using the paths from Task 1:
    - pod annotation `sidecar.istio.io/inject: "false"`;
    - pod `securityContext.seccompProfile.type: RuntimeDefault`;
    - `mongod` container `resources`;
    - `data-volume` claim with `storage.size` and, only when non-empty, `storage.storageClassName`.

- [ ] **Step 1: Write the failing tests:**
  - kind `MongoDBCommunity`, apiVersion `mongodbcommunity.mongodb.com/v1`, `spec.members: 1`, `spec.version: "8.0.34"`.
  - `members: 3` gives `spec.members: 3`.
  - the app user's roles contain `{name: readWriteAnyDatabase, db: admin}` and `{name: dbAdminAnyDatabase, db: admin}`; the backup user's roles contain `backup` and `restore` on `admin`.
  - the app user's `passwordSecretRef.name` is `mydb-mc-mongodb-connection`.
  - the pod annotation `sidecar.istio.io/inject` is `"false"` and seccomp is `RuntimeDefault`, at the verified paths.
  - default render has no `storageClassName` on the claim (`notExists`); `storage.storageClassName: managed-csi-premium` sets it; `storage.size: 50Gi` sets the request.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(mc-mongodb): MongoDBCommunity replica set`

---

### Task 5: Backup storage and backup CronJob

**Files:**
- Create: `charts/mc-mongodb/templates/_backup.tpl`, `charts/mc-mongodb/templates/backup.yaml`
- Test: `charts/mc-mongodb/tests/backup_test.yaml`

**Interfaces:**
- Consumes: the context; Secret `<name>-backup-connection` key `connectionString` (Task 3); CSI attributes and the oplog outcome (Task 1).
- Produces:
  - `include "mc-mongodb.backupVolumeName" $ctx` → `<namespace>-<name>-backup`, truncated to 63 with a trailing `-` trimmed. Task 6 uses it.
  - `include "mc-mongodb.backupPodSpec" (dict "ctx" $ctx "script" <string>)` → the pod `spec` shared by backup and restore:
    - `restartPolicy: Never`, pod seccomp `RuntimeDefault`;
    - one container `mongo`, image `backup.image`, `command: ["/bin/bash", "-c", <script>]`;
    - env `MONGODB_URI` from `secretKeyRef` `<name>-backup-connection`/`connectionString`, and `RETENTION_DAYS`;
    - volume `backups` from PVC `<backupVolumeName>`, mounted at `/backups` with `subPath: backup.path`;
    - `backup.resources`.
    Task 6 reuses it.
  - `include "mc-mongodb.backup" $ctx` renders nothing unless `backup.enabled`. When enabled it fails the render with `backup.container is required when backup.enabled is true` if `container` is empty; otherwise it renders:
    - `PersistentVolume` `<backupVolumeName>`:
      - `capacity.storage: 1Ti` (nominal), `accessModes: [ReadWriteMany]`, `persistentVolumeReclaimPolicy: Retain`, `storageClassName: azureblob-fuse-premium`;
      - `csi.driver: blob.csi.azure.com`, `csi.volumeHandle: <backupVolumeName>`;
      - `csi.volumeAttributes`: `containerName`, `storageAccount`, `resourceGroup`, `subscriptionID`, plus the MSI attributes from Task 1. No `nodeStageSecretRef`.
    - `PersistentVolumeClaim` `<backupVolumeName>` in `namespace`, `volumeName: <backupVolumeName>`, the same storage class and access mode, request `1Ti`.
    - `CronJob` `<name>-backup`:
      - `schedule`, `timeZone`, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`;
      - pod annotation `sidecar.istio.io/inject: "false"`;
      - pod spec from `backupPodSpec` with the backup script.
- Backup script (the oplog flag follows Task 1's outcome):
  ```bash
  set -euo pipefail
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mongodump --uri="$MONGODB_URI" --readPreference=secondaryPreferred --oplog --gzip --archive="/backups/$ts.archive.gz.partial"
  mv "/backups/$ts.archive.gz.partial" "/backups/$ts.archive.gz"
  cutoff=$(date -u -d "-${RETENTION_DAYS} days" +%Y%m%dT%H%M%SZ)
  for f in /backups/*.archive.gz; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .archive.gz)
    if [[ "$name" < "$cutoff" ]]; then rm -f "$f"; fi
  done
  rm -f /backups/*.archive.gz.partial
  ```
  Retention compares the timestamp in the file name rather than mtime, which blobfuse may not preserve. `set -e` means a failed dump exits before the `mv` and the prune.

- [ ] **Step 1: Write the failing tests:**
  - default: 0 documents.
  - `backup.enabled: true` without `backup.container`: `failedTemplate` with `backup.container is required`.
  - `backup.enabled: true, backup.container: production`, release `mydb`, namespace `tools`: PV named `tools-mydb-mc-mongodb-backup`, `csi.volumeHandle` equal to its name, `containerName: production`, `storageAccount: mycarriermongobackups`, `persistentVolumeReclaimPolicy: Retain`, and no `nodeStageSecretRef`.
  - same release name in namespace `other`: PV named `other-mydb-mc-mongodb-backup`.
  - PVC `volumeName` equals the PV name.
  - CronJob: `spec.schedule: "0 2 * * *"`, `spec.timeZone: Etc/UTC`, `concurrencyPolicy: Forbid`; the volume mount has `subPath: tools/mydb-mc-mongodb`; `RETENTION_DAYS` is `"7"`; `MONGODB_URI` comes from `mydb-mc-mongodb-backup-connection`.
  - `backup.schedule: "30 3 * * *"`, `backup.retentionDays: 14` and `backup.path: prod/inventory` are reflected.
  - the script (`matchRegex` on the command's last element) writes to `.partial`, `mv`s after `mongodump`, and contains `set -euo pipefail`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Check the script against real MongoDB.** With the Task 1 Docker replica set, run the script inside `mongo:8.0.34` with `/backups` bind-mounted, `RETENTION_DAYS=7`, and two pre-made files named eight days and one day ago. Expected: a new `.archive.gz`, the eight-day file gone, the one-day file kept. Then point `MONGODB_URI` at a dead host. Expected: non-zero exit, no new archive, and both old files still present.
- [ ] **Step 6: Commit.** `feat(mc-mongodb): blob backup volume and backup CronJob`

---

### Task 6: Restore CronJob

**Files:**
- Create: `charts/mc-mongodb/templates/_restore.tpl`, `charts/mc-mongodb/templates/restore.yaml`
- Test: `charts/mc-mongodb/tests/restore_test.yaml`

**Interfaces:**
- Consumes: `mc-mongodb.backupVolumeName` and `mc-mongodb.backupPodSpec` (Task 5); the oplog outcome (Task 1).
- Produces: `include "mc-mongodb.restore" $ctx`. It renders nothing unless `backup.enabled`. When enabled it renders `CronJob` `<name>-restore`:
  - `suspend: true` (hard-coded); schedule `"0 0 31 2 *"` (never matches); `concurrencyPolicy: Forbid`;
  - pod annotation `sidecar.istio.io/inject: "false"`;
  - pod spec from `backupPodSpec` with the restore script and an extra env `RESTORE_FILE` with value `""`.
- Restore script (`--oplogReplay` only if Task 1 says **combined**):
  ```bash
  set -euo pipefail
  if [ -n "${RESTORE_FILE:-}" ]; then file="/backups/$RESTORE_FILE"; else file=$(ls -1 /backups/*.archive.gz 2>/dev/null | sort | tail -n 1 || true); fi
  if [ -z "$file" ] || [ ! -f "$file" ]; then echo "no backup to restore (looked for: ${file:-any *.archive.gz in /backups})" >&2; exit 1; fi
  echo "restoring $file"
  mongorestore --uri="$MONGODB_URI" --drop --gzip --archive="$file" --nsExclude='admin.*' --nsExclude='config.*' --oplogReplay
  ```

- [ ] **Step 1: Write the failing tests:**
  - default: 0 documents.
  - with backup enabled: `spec.suspend: true`, and `RESTORE_FILE` is present with value `""`.
  - `backup.schedule: "*/5 * * * *"` does not change the restore schedule (`"0 0 31 2 *"`).
  - mounts the same PVC and `subPath` as the backup CronJob.
  - the script contains `--nsExclude='admin.*'` and `--drop`, and exits non-zero when no file is found (`matchRegex` on `exit 1`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Check the script against real MongoDB.** Using the Task 5 backups, drop a non-admin database, run the restore script with `RESTORE_FILE` unset, and confirm the database is back and `admin.system.users` is unchanged. Then run with an empty `/backups` and with `RESTORE_FILE=missing.archive.gz`. Expected: both exit 1 with the message.
- [ ] **Step 6: Commit.** `feat(mc-mongodb): on-demand restore CronJob`

---

### Task 7: Schema, standalone switch, README and final render

**Files:**
- Create: `charts/mc-mongodb/values.schema.json`, `charts/mc-mongodb/README.md`, `charts/mc-mongodb/tests/standalone_test.yaml`
- Delete: `charts/mc-mongodb/VERIFIED.md`

**Interfaces:**
- Consumes: every wrapper (Tasks 2–6).
- The schema (draft-07, with `description` and `default` on each property, as in other charts in this repo):
  - types for every values key; `members` minimum 1; `backup.retentionDays` minimum 1; `password.length` minimum 16;
  - `backup.schedule` and `backup.container` as strings;
  - top-level `additionalProperties: false` to catch typos.

- [ ] **Step 1: Write the failing tests** in `standalone_test.yaml`:
  - with `standalone: false, backup.enabled: true, backup.container: production`, each of `credentials.yaml`, `mongodbcommunity.yaml`, `backup.yaml` and `restore.yaml` has 0 documents.
  - `members: 0` fails schema validation; `backup.retentionDays: 0` fails; an unknown top-level key `foo: bar` fails.
- [ ] **Step 2: Run.** Expected: the schema cases FAIL (no schema yet). The standalone cases pass already; that's expected, since this suite pins them for phase 2.
- [ ] **Step 3: Implement** `values.schema.json`.
- [ ] **Step 4: Run the whole chart:** `rtk proxy helm unittest charts/mc-mongodb > $SCRATCH/ut.txt 2>&1; tail -5 $SCRATCH/ut.txt`. Expected: all suites pass.
- [ ] **Step 5: Write the README.** Cover:
  - what the chart deploys and its prerequisites (from the spec);
  - the values table (or the readme-generator output, if the repo's workflow produces it);
  - the Secret contract: `<fullname>-connection`, key `connectionString`;
  - both restore procedures: the Argo CD **Create Job** action, and `kubectl create job --from=cronjob/<fullname>-restore … --dry-run=client -o yaml` with `RESTORE_FILE`;
  - how to list archives;
  - the internal-tools-only note;
  - anything from `VERIFIED.md` an operator of the chart needs. Then delete `VERIFIED.md`.
- [ ] **Step 6: Render-check.**
  - `rtk proxy helm template t charts/mc-mongodb -n tools --set backup.enabled=true --set backup.container=production > $SCRATCH/render.yaml`, then `rtk proxy helm lint charts/mc-mongodb --set backup.enabled=true --set backup.container=production`. Expected: lint passes, and the render contains `Password`, two `ExternalSecret`s, `MongoDBCommunity`, `PersistentVolume`, `PersistentVolumeClaim` and two `CronJob`s.
  - If `kubeconform` is available, run it with `-ignore-missing-schemas` and the default Kubernetes schemas for the core kinds.
- [ ] **Step 7: Commit.** `feat(mc-mongodb): values schema and README`

---

## After the plan

- Open one PR for the spec, this plan and the chart. The release workflow publishes `mc-mongodb` on merge.
- Before any stack depends on it: install MCK 1.14.0 in the app clusters, create the `production` container, grant the production cluster's kubelet identity Storage Blob Data Contributor on it, and confirm the app clusters' ESO serves `refreshPolicy` and the `Password` generator.
- **Verify on a dev cluster after the operator is installed:** password reconciliation on Secret change (Task 1 may only find documentation), and an app pod with a sidecar connecting to the sidecar-less replica set.
- Phase 2 (mycarrier-helm embedding, mc-environment forwarding, guidance) gets its own plan once `mc-mongodb` is published.
