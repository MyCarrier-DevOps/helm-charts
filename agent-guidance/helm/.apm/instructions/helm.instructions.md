---
description: Conventions for writing a service's helm/ values with mycarrier-helm and mc-environment.
applyTo: "helm/**"
---
# Helm Configuration Instructions

When writing or evaluating Helm chart configurations, follow the conventions in this document.

## Helm Chart Reference

MyCarrier services use one of two shared Helm charts from `https://charts.mycarrier.dev`:

| Chart | Docs | Purpose |
|-------|------|---------|
| **mycarrier-helm** | [README](https://github.com/MyCarrier-DevOps/helm-charts/tree/main/charts/mycarrier-helm) | Deploys applications directly via ArgoCD |
| **mc-environment** | [README](https://github.com/MyCarrier-DevOps/helm-charts/tree/main/charts/mc-environment) | Wrapper that generates an ArgoCD `ApplicationSet` — one `Application` per environment — each targeting `mycarrier-helm` |

**CRITICAL: Before making any changes, read the existing helm files to determine which chart layout is in use.** The two charts have different file structures and different YAML shapes. Applying the wrong pattern will break deployment.

A stack does not choose chart versions: the pipeline renders both charts at the versions it is configured with (see [Chart version](#chart-version)).

## Target Files
- These instructions apply specifically to Helm YAML files with pattern `helm/**/*.yaml`

---

## Identifying the Chart Layout

### How to detect which chart the repository uses

| Signal | **mycarrier-helm** (direct) | **mc-environment** (wrapper) |
|--------|----------------------------|------------------------------|
| `helm/deployment/values.yaml` root key | `applications:` | `environments:` |
| `helm/values.{env}.yaml` exists at root level | ✅ Yes | ❌ Normally no (env config is inside `environments[]`) |
| `helm/deployment/values.{env}.yaml` root key | `applications:` | `environments:` (plus a top-level `alerts:` in prod when the stack alerts) |
| `helm/values.yaml` has `mycarrierChartVersion:` | ❌ No | Sometimes (a leftover pin; the pipeline overrides it) |

**Quick check**: Look at `helm/deployment/values.yaml`. If the root key is `applications:`, it's **mycarrier-helm**. If the root key is `environments:`, it's **mc-environment**. This is the most reliable signal — do not rely on the presence of `mycarrierChartVersion`.

---

## Layout A: mycarrier-helm (Direct)

Used when the repository deploys directly via ArgoCD without an ApplicationSet wrapper.

### File Structure

| File | Purpose | What belongs here |
|------|---------|-------------------|
| `/helm/values.yaml` | **Base values** — global settings, appStack, language, dependencies, shared alert settings | `global.appStack`, `global.language`, `global.dependencies`, `alerts.*` (except `enabled`) |
| `/helm/values.{env}.yaml` | **Environment overrides** — environment name, env-specific URLs, secrets, Redis key prefixes | `environment.name`, `global.env.*`, `secrets`, `disableOtelAutoinstrumentation`, `alerts.enabled` (prod only) |
| `/helm/deployment/values.yaml` | **Application definitions** — all deployable services (image, ports, securityContext) | `applications.*` with `image`, `ports`, `deploymentType`, `securityContext` |
| `/helm/deployment/values.{env}.yaml` | **Per-env deployment overrides** — image tags, networking, test triggers, app-level env vars | `applications.*.image.tag`, `applications.*.networking`, `applications.*.testtrigger`, `applications.*.env` |

Environments: `dev`, `preprod`, `prod` (and `qa`, `uat` or other names where a stack has them), plus `feature<N>` (for example `feature13`) for offload branches. Every `helm/values.{env}.yaml` sets `environment.name`; without it the chart renders for `dev`.

### Merge Order (lowest → highest precedence)

```
helm/values.yaml                    ← global base
helm/values.{env}.yaml              ← environment overrides
helm/deployment/values.yaml         ← application base definitions
helm/deployment/values.{env}.yaml   ← environment-specific app overrides
```

The pipeline skips files that do not exist. There is no fallback to another environment's file in this layout.

### Example (Layout A)

```yaml
# helm/values.yaml
global:
  appStack: myservice
  language: csharp
  dependencies:
    mongodb: true
    redis: true

# helm/values.dev.yaml
global:
  env:
    RedisKeyPrefix: 'dev:myservice:'
environment:
  name: dev
secrets:
  individual:
    - envVarName: MY_SECRET
      path: secrets/dev/shared/my-secret

# helm/deployment/values.yaml
applications:
  api:
    deploymentType: deployment
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/api
    ports:
      http: 8080

# helm/deployment/values.dev.yaml
applications:
  api:
    image:
      tag: 1.0.0
```

---

## Layout B: mc-environment (Wrapper)

Used when the repository manages **multiple environments from a single chart release** via an ArgoCD ApplicationSet. The wrapper generates one ArgoCD `Application` per entry in the `environments[]` array, each deploying `mycarrier-helm` with merged values.

### File Structure

| File | Purpose | What belongs here |
|------|---------|-------------------|
| `/helm/values.yaml` | **Base values** — `global` (appStack, language, dependencies) and shared alert settings | `global.*`, `alerts.*` (except `enabled`) |
| `/helm/deployment/values.yaml` | **Default environment list** — rendered only for an environment that has no `values.{env}.yaml` of its own and none for its class | `environments: [{ name, global, environment, applications, secrets, ... }]` |
| `/helm/deployment/values.{env}.yaml` | **The environment's entry** — its complete env-specific config | `environments: [{ name, global, environment, applications, secrets, ... }]`; in prod, a top-level `alerts.enabled` |

By convention there are no `helm/values.{env}.yaml` files at root level — all environment-specific config lives inside `environments[]` entries in the deployment files.

**Each file's `environments` list replaces the one before it.** Helm merges maps but replaces lists, so `helm/deployment/values.{env}.yaml` holds the environment's complete entry: nothing from the entries in `helm/deployment/values.yaml` carries over.

### Values Merge Logic

For each `environments[]` entry, mc-environment builds the values of the generated Application:
1. Root-level `global` from `helm/values.yaml`, with `environments[].global` merged over it. `environments[].global` cannot set `deploymentStrategy`: the render fails, because the repository's `deployment-strategy` property sets it for every environment
2. `environments[].environment`, with `name` set to the entry's `name`
3. `environments[].applications`, `jobs`, `cronjobs`, `secrets`, `infrastructure`, `extraObjects` and the platform flags (see [mc-environment Specific Properties](#mc-environment-specific-properties)), unchanged
4. The root-level `alerts`, unchanged and the same for every entry

The result is serialized into the ArgoCD `Application.spec.source.helm.values`, and Argo CD renders `mycarrier-helm` with it.

### Environments and their classes

The pipeline files every environment under a class (its metaEnv):

| Environment name | Class |
|------------------|-------|
| `dev`, `feature*` | `dev` |
| `preprod`, `qa`, `uat`, `preprod-*`, `qa-*`, `uat-*` | `preprod` |
| `prod` | `prod` |
| anything else | its own name |

An environment renders to `Apps/<metaEnv>-<project>/<project>-<app>/<env>` in the GitOps repository (`<app>` is the `helm/` subdirectory, normally `deployment`). When `helm/deployment/values.<env>.yaml` is missing, the pipeline uses `values.<metaEnv>.yaml` instead. Client-specific environments such as `preprod-saia` or `uat-saia` are environments of their class (`preprod`). The fallback file's `environments` entries render unchanged — their `name`, not the environment being deployed, sets the namespace — so an environment that must deploy as itself needs its own file.

The class is the pipeline's. mycarrier-helm itself treats only `feature*` as dev: to the chart, `qa`, `uat` and `preprod-saia` are environments of their own name, so they get no csharp shared settings (see [Language secrets](#language-secrets)), external hosts under `<env>.mycarrier.dev`, automatic HPA as in prod, and `servicebus-connectionstring-<env>` for KEDA.

### Chart version

The pipeline renders mc-environment at its configured version and sets `mycarrierChartVersion` — the mycarrier-helm version every generated Application deploys — on every render, overriding any value in the stack's files. Leave `mycarrierChartVersion` out of `helm/values.yaml`: a pin there has no effect in the pipeline (only a local render without the pipeline reads it).

### Example (Layout B)

```yaml
# helm/values.yaml
global:
  appStack: myservice
  language: csharp
  dependencies:                      # optional — omit if no infra dependencies needed
    mongodb: true
    redis: true
  env:
    LOG_LEVEL: info

# helm/deployment/values.yaml (rendered for dev, which has no values.dev.yaml here)
environments:
  - name: dev
    global:
      env:
        RedisKeyPrefix: 'dev:myservice:'
        ServiceBusNamespace: "inf-dev-servicebus.servicebus.windows.net"
    applications:
      api:
        deploymentType: deployment
        image:
          registry: mycarrieracr.azurecr.io
          repository: appstack/myservice/api
          tag: "1.0.0"
        ports:
          http: 8080
    secrets:
      individual:
        - envVarName: MY_SECRET
          path: secrets/dev/shared/my-secret
    disableOtelAutoinstrumentation: true

# helm/deployment/values.prod.yaml
environments:
  - name: prod
    global:
      env:
        RedisKeyPrefix: 'prod:myservice:'
        ServiceBusNamespace: "inf-prod-servicebus.servicebus.windows.net"
    applications:
      api:
        deploymentType: deployment
        image:
          registry: mycarrieracr.azurecr.io
          repository: appstack/myservice/api
          tag: "release-v1.0.0"
        ports:
          http: 8080
    secrets:
      individual:
        - envVarName: MY_SECRET
          path: secrets/prod/shared/my-secret
    disableOtelAutoinstrumentation: true
```

### mc-environment Specific Properties

Each `environments[]` entry supports these fields:

| Property | Description | Default |
|----------|-------------|---------|
| `name` | Environment name (required). Becomes `environment.name`, the namespace the Application deploys to, and the Application name `<appStack>-<name>` | — |
| `global` | Merged over the root-level `global` | `{}` |
| `environment` | mycarrier-helm `environment` block (`name` is always the entry's `name`) | `{}` |
| `applications`, `jobs`, `cronjobs`, `secrets`, `infrastructure`, `dependencyDeployments`, `extraObjects` | Passed to mycarrier-helm unchanged | — |
| `enableVaultCA`, `manualOtelConfig`, `deployment` | Passed to mycarrier-helm | `false`, `false`, `deployment` |
| `disableOtelAutoinstrumentation` | Passed to mycarrier-helm; **defaults to `false` here** (auto-instrumentation on), the opposite of direct mycarrier-helm | `false` |

Do not set `tolerations` on an entry: the schema accepts it, but mc-environment writes a non-empty list into the ApplicationSet in a form that is not valid YAML, and the render fails (`did not find expected ',' or ']'`).

At the root, mc-environment reads only `environments`, `global`, `alerts` (passed to every entry; see [Alerts](#alerts)) and `mycarrierChartVersion` (set by the pipeline); the platform flags above take effect only inside an entry. The schema rejects unknown keys at the root and in an entry. It also accepts `releaseName`, `applicationName`, `destinationNamespace`, `helm`, `annotations`, `labels`, `syncPolicy`, `isEnvironmentDeploy`, `networking`, `serviceAccount` and `serviceMonitor` on an entry, but mc-environment does not use them: leave them out, and put `networking`, `serviceAccount` and `serviceMonitor` under `applications.<app>`. The Argo CD sync policy is fixed by the chart. `disableSecurity` cannot be set through mc-environment.

### mc-environment: Feature Environments

Feature environments are entries named `feature<N>` (e.g., `feature13`). Give each its own `helm/deployment/values.feature<N>.yaml`; a feature environment without one renders the entries of `values.dev.yaml` as they are (normally the dev entry, not a feature environment). The entry is complete — copy the dev entry and change the environment-specific values:

```yaml
# helm/deployment/values.feature13.yaml
environments:
  - name: feature13
    global:
      env:
        RedisKeyPrefix: 'feature13:myservice:'
    applications:
      api:
        deploymentType: deployment
        image:
          registry: mycarrieracr.azurecr.io
          repository: appstack/myservice/api
          tag: "1.0.0-feature"
        ports:
          http: 8080
    secrets:                     # usually the dev secrets
      individual:
        - envVarName: MY_SECRET
          path: secrets/dev/shared/my-secret
```

---

## Layout Comparison — Decision Guide

| Change Type | Layout A (mycarrier-helm) | Layout B (mc-environment) |
|-------------|--------------------------|---------------------------|
| Add global env var for all envs | `helm/values.yaml` → `global.env` | `helm/values.yaml` → `global.env` |
| Add env-specific URL | `helm/values.{env}.yaml` → `global.env` | `helm/deployment/values.{env}.yaml` → `environments[].global.env` |
| Add a new application | `helm/deployment/values.yaml` → `applications` | Every `helm/deployment/values.{env}.yaml` → `environments[].applications` (entries are not merged) |
| Change image tag | `helm/deployment/values.{env}.yaml` → `applications.<app>.image.tag` | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.image.tag` |
| Add a secret | `helm/values.{env}.yaml` → `secrets` | `helm/deployment/values.{env}.yaml` → `environments[].secrets` |
| Add test triggers | `helm/deployment/values.{env}.yaml` → `applications.<app>.testtrigger` | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.testtrigger` |
| Enable alerts | `helm/values.yaml` → `alerts` settings; `helm/values.prod.yaml` → `alerts.enabled: true` | `helm/values.yaml` → `alerts` settings; `helm/deployment/values.prod.yaml` → top-level `alerts.enabled: true` |
| Change chart version | N/A (set by the pipeline) | N/A (set by the pipeline) |
| Add a feature environment | Handled via offload mechanism | Add `helm/deployment/values.feature<N>.yaml` with its `environments[]` entry |

---

## Global Configuration (Both Layouts)

The `global` block in `helm/values.yaml` is shared across both chart layouts. The following sections document `mycarrier-helm` values. In **Layout A**, these are set at root level. In **Layout B**, application/secret/environment values are nested inside `environments[]` entries but the same schema applies.

```yaml
# helm/values.yaml — global base (same shape for both layouts)
global:
  appStack: "myservice"              # Application stack name — the first part of every resource name and hostname
  language: "csharp"                 # Programming language: csharp | nodejs | python | go
  disableLanguageSecrets: false      # true: no language default secrets or env vars (the stack supplies its own)
  dependencies:                      # Infrastructure dependency flags
    mongodb: false
    redis: false
    azureservicebus: false
    elasticsearch: false
    postgres: false
    sqlserver: false
    clickhouse: false
    redpanda: false
    loadsure: false
    chargify: false
  env: {}                            # Global env vars shared by all applications
```

```yaml
# helm/values.{env}.yaml — Layout A (Layout B: environments[].environment)
environment:
  name: "prod"                       # dev | preprod | prod | qa | uat | feature<N>; any other DNS-1123 name is a generic environment
  domainOverride:                    # optional
    enabled: false
    domain: "example.com"
```

| Value | Default | Notes |
|-------|---------|-------|
| `global.appStack` | `app` | Always set it. Resource names are `<appStack>-<application>`, with `-<featureN>` appended in feature environments |
| `global.language` | `csharp` (mc-environment: `nodejs`) | `csharp`, `nodejs`, `python` or `go` — the schema rejects anything else. Selects default probes, [language secrets](#language-secrets), the default endpoint allowlist and the [standard alerts](#standard-alerts). Always set it |
| `global.disableLanguageSecrets` | `false` | See [Language secrets](#language-secrets) |
| `global.dependencies.<name>` | `false` | See [Supported Dependencies](#supported-dependencies) |
| `global.env` | `{}` | Environment variables for every application container (not init containers, `jobs[]` or `cronjobs[]`) |
| `global.strategy.canary` | preset `standard` | Canary settings for every Rollout of the release (see [Rollouts](#rollouts)) |
| `global.forceAutoscaling` | unset | Leave unset. `true` creates an HPA for non-migration apps in every environment; `false` turns off automatic HPA everywhere, prod included (see [HPA](#hpa-horizontal-pod-autoscaler)) |
| `environment.name` | `dev` | The environment the chart renders for and the namespace it deploys to |
| `environment.namespaceOverride` | `""` | Deploy to a different namespace |
| `environment.domainOverride` | disabled | Replace the external domain (see [Domain Conventions](#domain-conventions)) |
| `environment.dependencyenv` | `dev` | Accepted, but has no effect |
| `disableOtelAutoinstrumentation`, `manualOtelConfig` | `true`, `false` | See [OpenTelemetry](#opentelemetry) |

The pipeline sets `global.gitbranch`, `global.branchlabel`, `global.commitDeployed`, `global.correlationId`, `global.v2migration` and `global.argoEventsInstance` on every render; do not set them in values files.

### Language secrets

With `language: csharp`, the chart adds Vault-backed environment variables to every application container and its init containers:
- shared settings for dev (including feature environments), preprod and prod, such as the `Auth_*` service base URLs and `MyCarrierSqlConnections`;
- common settings (Split.io, Strivacity, credential URLs) and the connection settings of each dependency flagged in `global.dependencies`, named after the environment.

Other environment names (`qa`, `uat`, `preprod-saia`, …) get the common and dependency settings but no shared settings: supply those through `global.env` and `secrets`. Other languages get none of this.

`jobs[]` and `cronjobs[]` get none of these settings and no `global.env` either: their containers receive only `secrets`, the OpenTelemetry settings and their own `env`, so list everything a Job or CronJob needs in its `env`. Init containers get these settings, `secrets` and the OpenTelemetry settings, plus their own `env`, but not `global.env` or the application's `env`.

`global.disableLanguageSecrets: true` turns all of it off, for a stack that supplies its own settings. It also stops the chart from dropping `KeyVault_IsActive`, `KeyVault_SplitIoProxyApiKey` and `KeyVault_SplitIoProxyUrl` (with redis, also `KeyVault_RedisConnection` and `Auth_KeyVault_RedisConnection`) from a csharp stack's own `env`.

### Supported Dependencies
Set to `true` in `global.dependencies`: `mongodb`, `redis`, `azureservicebus`, `elasticsearch`, `postgres`, `sqlserver`, `clickhouse`, `redpanda`, `loadsure`, `chargify`. For a csharp stack with language secrets on, `mongodb`, `redis`, `azureservicebus`, `elasticsearch`, `redpanda`, `loadsure` and `chargify` inject that dependency's connection settings from Vault; the other flags inject nothing.

`global.dependencies` says which shared services the app uses. To run a dependency in the stack's own namespace instead, see [Dependency deployments](#dependency-deployments).

### Dependency deployments

`dependencyDeployments` deploys a dependency in-cluster alongside the stack. It is for internal tools only: product applications use the shared services, such as MongoDB Atlas, and their data is never moved into an in-cluster instance. Off by default; a stack that leaves it out renders exactly as before. It needs mycarrier-helm 4.7.16 or later: an older version ignores the key without an error. mc-environment deploys 4.7.16 by default when no `mycarrierChartVersion` is set.

#### `dependencyDeployments.mongodb`

```yaml
dependencyDeployments:
  mongodb:
    enabled: true
```

This deploys a MongoDB replica set named `<appStack>-mongodb` (cut to 44 characters) in the environment's namespace, run by the MongoDB operator, with a password generated in the cluster. Secret `<appStack>-mongodb-connection`, key `connectionString`, holds:

```
mongodb://app:<password>@<appStack>-mongodb-svc.<namespace>.svc.cluster.local:27017/<appStack>?replicaSet=<appStack>-mongodb&authSource=admin
```

The database in the string is `appStack` in every environment. The `app` user can create and use any number of further databases and collections.

| Value | Description | Default |
|-------|-------------|---------|
| `enabled` | Deploy MongoDB with the stack | `false` |
| `members` | Replica set members | `3` in production, `1` elsewhere |
| `version` | MongoDB server version (exact), an 8.x release: the chart pins feature compatibility version 8.0, and the schema rejects older servers | `8.0.34` |
| `storage.size` | Data volume per member. Set it before the first deploy: the operator cannot resize the volumes, so a later change leaves the replica set failing to reconcile until they are resized by hand | `10Gi` |
| `storage.storageClassName` | Storage class for the data volume. Set it before the first deploy, as for `storage.size` | cluster default |
| `resources` | Resources for the `mongod` container; replaces the default as a whole | requests `250m` / `512Mi`, limit `1Gi` memory |
| `backup.schedule` | Cron schedule for backups | `0 2 * * *` |
| `backup.timeZone` | Time zone for the schedule | `Etc/UTC` |
| `backup.retentionDays` | Days to keep backups | `7` |

The schema rejects any other key, including `backup.enabled`: the environment decides backups, not the stack. The root `mc-mongodb` key holds the subchart's defaults and is internal to the chart: leave it out of a stack's values.

**Environments.** In production (an environment whose meta environment starts with `prod`), MongoDB backs up daily (by default) to the `production` container of the `mycarriermongobackups` storage account, folder `<environment.name>/<appStack>`, and the chart renders a suspended `<appStack>-mongodb-restore` CronJob for restores. A replica set of more than one member places each member on its own node (so production needs at least three schedulable nodes) and lets voluntary disruptions, such as a node drain, take one member at a time. The MongoDB pods run with an Istio sidecar, so application pods (which have sidecars) connect over mutual TLS. Dev, preprod, `qa`, `uat` and feature environments get no backups. Each feature environment gets its own MongoDB, empty on its first deploy there.

**Connection string.** For a csharp stack with `global.dependencies.mongodb: true` and language secrets on, `MongoConnection_<env>` in every application container and init container reads the connection Secret instead of Vault; `KeyVault_MongoConnection` and `KeyVaultMongoConnection` still name it. Jobs and CronJobs get no language secrets: set `secretName: <appStack>-mongodb-connection` on the job, which loads the Secret's keys as env vars `connectionString` and `password`. Without `global.dependencies.mongodb`, or for other languages, nothing is injected: add the variable in `global.env`, for example `MONGODB_URI: { valueFrom: { secretKeyRef: { name: <appStack>-mongodb-connection, key: connectionString } } }`. Use `global.env`, not an application's `env`: feature environments from the legacy offload generator do not get the applications' `env`.

A `pre-deploy` job runs before the replica set and its Secret exist on an environment's first sync, including each new feature environment. If it reads the Secret, it waits for it and blocks that sync. Give such a job `runAsHook: false`, or run the migration from an application.

**Turning it off** removes the replica set and its password Secrets; its data disks are kept. Turning it back on reattaches the disks with the data, and generates new passwords, which the operator applies to the users: restart the application pods so they read the new connection string. Feature namespaces outlive offloads, so removing a feature environment keeps the stack's disks there too, and the stack's next MongoDB in that environment starts with the old data; delete the `data-volume-<appStack>-mongodb-*` and `logs-volume-<appStack>-mongodb-*` claims in that namespace to start empty.

**Restoring** (production): in Argo CD, run **Create Job** on the `<appStack>-mongodb-restore` CronJob to restore the newest backup, or follow the mc-mongodb [README](https://github.com/MyCarrier-DevOps/helm-charts/tree/main/charts/mc-mongodb#restoring) to restore a specific one. A restore drops and reloads every collection in the backup, so writes made since that backup are lost: only the people who own the stack's data should run it.

Where it goes: `helm/values.yaml` to deploy it in every environment, or `helm/values.{env}.yaml` for some. In mc-environment, set it on each `environments[]` entry.

```yaml
# helm/values.yaml
global:
  appStack: toolbox
  language: csharp
  dependencies:
    mongodb: true
dependencyDeployments:
  mongodb:
    enabled: true

# helm/values.prod.yaml
environment:
  name: prod
dependencyDeployments:
  mongodb:
    storage:
      size: 50Gi
    backup:
      retentionDays: 14

# helm/deployment/values.yaml
applications:
  api:
    deploymentType: deployment
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/toolbox/api
    ports:
      http: 8080

# helm/deployment/values.prod.yaml
applications:
  api:
    image:
      tag: 1.0.0
```

---

## Domain Conventions

- **Prod** (every environment whose name starts with `prod`): services are hosted under the `mycarriertms.com` domain
- **Every other environment** (dev, feature, preprod, qa, uat, …): services are hosted under the `mycarrier.dev` domain
- `environment.domainOverride.enabled: true` replaces the domain with `environment.domainOverride.domain`

## Service URL Patterns

Microservices follow predictable URL patterns based on environment:

### External URLs

| Environment | Pattern | Example |
|-------------|---------|---------|
| Dev | `https://{service}-{component}.dev.mycarrier.dev` | `https://address-api.dev.mycarrier.dev` |
| Feature | `https://{service}-{component}-{featureN}.dev.mycarrier.dev` | `https://address-api-feature13.dev.mycarrier.dev` |
| PreProd | `https://{service}-{component}.preprod.mycarrier.dev` | `https://address-api.preprod.mycarrier.dev` |
| Other non-prod (qa, uat, …) | `https://{service}-{component}.{env}.mycarrier.dev` | `https://address-api.qa.mycarrier.dev` |
| Prod | `https://{service}-{component}.api.mycarriertms.com` | `https://address-api.api.mycarriertms.com` |

- `{service}` is `global.appStack`; `{component}` is the application's key under `applications`
- Non-prod URLs contain the environment name segment (`dev` for feature environments)
- Prod URLs use `api` instead of an environment name
- `staticHostname: <name>` replaces the default host with `<name>.<domain>`

### In-Cluster (Kubernetes Internal) URLs
For inter-service communication within the same cluster:
Pattern: `http://{service}-{component}.{env}.svc.cluster.local:{port}` (in a feature environment: `http://{service}-{component}-{featureN}.{featureN}.svc.cluster.local:{port}`)

The Service listens on the target application's `ports` values (for example 8080) unless that application maps other ports in `service.ports`; leave out `:{port}` only when it is 80.

Examples:
- `http://address-api.preprod.svc.cluster.local:8080`
- `http://shipment-api.prod.svc.cluster.local:8080`

Choose **in-cluster URLs** when the target service runs in the same Kubernetes cluster (saves egress, lower latency). Choose **external URLs** when the service is outside the cluster or the environment does not have the service deployed locally.

### Component Segment Naming
- The `component` segment indicates the type of service (e.g., `api`, `admin-api`, `internal-api`).

---

## Environment Variable Conventions

### Naming Rules
**All environment variables must be POSIX-compliant:**
- Use letters, numbers, and underscores only
- Must start with a letter or underscore
- No hyphens, dots, or other special characters

```yaml
# ✅ Valid
AddressService_BaseAddress: https://address-api.dev.mycarrier.dev
RedisKeyPrefix: 'dev:myservice:'
MyCarrierApi_BaseAddress: http://mycarrierproxy-api.dev.svc.cluster.local

# ❌ Invalid
address-service-url: https://...     # hyphens not allowed
redis.key.prefix: 'dev:myservice:'   # dots not allowed
```

### Scope Rules
| Scope | Where to define | Applies to |
|-------|----------------|------------|
| All apps, all envs | `helm/values.yaml` → `global.env` | Every application container in every environment |
| All apps, one env | `helm/values.{env}.yaml` → `global.env` | Every application container in that environment |
| One app, all envs | `helm/deployment/values.yaml` → `applications.<app>.env` | Only that application |
| One app, one env | `helm/deployment/values.{env}.yaml` → `applications.<app>.env` | Only that application in that environment |

App-level `env` overrides `global.env` for the same key. `global.env` does not reach init containers, `jobs[]` or `cronjobs[]`: give those their own `env`.

---

## Secrets Management

Secrets are loaded from **HashiCorp Vault** — never hardcode secrets in values files.

### Bulk Secrets
Load all keys from a single Vault path as environment variables:
```yaml
secrets:
  bulk:
    path: "secrets/data/dev/myservice"
```

### Individual Secrets
Map specific Vault keys to specific environment variable names:
```yaml
secrets:
  individual:
    - envVarName: MY_SECRET_VAR
      path: secrets/dev/shared/my-secret-name   # without /data/: the chart inserts it
      keyName: value                             # optional, default value
```

This renders `MY_SECRET_VAR` as `vault:secrets/data/dev/shared/my-secret-name#value`. Without `path`, the chart reads `secrets/data/<env>/<appStack>/<envVarName>` (`dev` for feature environments).

### Mounted Secrets
Mount Vault secrets as files in the container:
```yaml
secrets:
  mounted:
    - name: certificate
      mountedFileName: cert.pem
      vault:
        path: secrets/data/dev/certs
        property: certificate
      mount:
        path: /app/certs                         # a directory: the file is /app/certs/cert.pem
```

The chart syncs the Vault value into a Kubernetes Secret (an `ExternalSecret`) and mounts it as a directory at `mount.path`, with the value in the file `mountedFileName`. `mount.subPath` has no effect.

### Vault References in Other Fields
Some fields (like test trigger configs) support inline vault references:
```yaml
apikey: vault:DevOps/data/testengine/api#encoded_header
secretId: vault:QA/data/app_auth#SecretId
```

---

## Application Configuration Reference

### Minimal Application Definition
```yaml
applications:
  my-app:                               # lowercase letters, digits, - and _
    deploymentType: deployment          # deployment | statefulset | rollout
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/api
      tag: "1.0.0"                      # usually set in the env file
    ports:
      http: 8080
```

### Common Application Properties

| Property | Description | Default |
|----------|-------------|---------|
| `deploymentType` | `deployment`, `statefulset`, or `rollout` (see [Rollouts](#rollouts)). Without it no workload renders | Required |
| `image.registry` | Container registry | Required |
| `image.repository` | Image repository path | Required |
| `image.tag` | Image tag (typically set per-env) | Required in the merged values |
| `ports.http` | HTTP port the container listens on; used by the Service, probes, routing and test triggers | Required |
| `ports.metrics` | Metrics port (Prometheus scraping, see [ServiceMonitor](#servicemonitor-prometheus)) | Optional |
| `command` | Container command, a list of strings. Only a **single element** of letters, digits and `-_./=` renders correctly: see the warning below | The image's `ENTRYPOINT` |
| `args` | Container arguments, a list of strings. Same single-element limit as `command` | The image's `CMD` |
| `replicas` | Static replica count (ignored when HPA/KEDA active) | Env-dependent default |
| `resources.requests.cpu` | CPU request | `50m` |
| `resources.requests.memory` | Memory request | `512Mi` |
| `resources.limits.cpu` | CPU limit | `2000m` |
| `resources.limits.memory` | Memory limit | `2048Mi` |
| `securityContext` | Container hardening: `readOnlyRootFilesystem` (default `true`; `/tmp` is always writable), `addCapabilities` (all are dropped by default), opt-in `fsGroup` and `seccompProfile` | Hardened |
| `env` | App-specific environment variables (key-value map) | `{}` |
| `labels` | Custom labels | `{}` |
| `annotations` | Custom pod annotations; keys the chart manages (Vault, Istio, OpenTelemetry, gateway) are dropped | `{}` |
| `isFrontend` | Whether this is a frontend application | `false` |
| `staticHostname` | Replaces the default external host with `<staticHostname>.<domain>`; in feature environments it is added only for mc-environment stacks | None |
| `lifecycle.preStopSleepSeconds` | Seconds the container sleeps in its preStop hook; `0` disables the hook | `5` |
| `terminationGracePeriodSeconds` | Pod termination grace period | `10` |
| `affinity.enablePodAntiAffinity` | Required pod anti-affinity outside prod (always on in prod) | `false` |
| `enableDebugMode` | Adds a privileged debug sidecar; not allowed while `migratingToRollouts` is set | `false` |

**Warning: an application's `command` and `args` collapse into one element.** For Deployments, StatefulSets and Rollouts the chart prints both lists inline, so `command: ["/bin/sh", "-c"]` renders as the single string `"/bin/sh -c"`, which the container cannot start, and `args: ["./run.sh", "--port", "8080"]` reaches the process as one argument, `"./run.sh --port 8080"`. The rendered list is read as inline YAML, so other characters break it too: a comma splits an element (`["--hosts=a,b"]` becomes `["--hosts=a", "b"]`), and brackets, braces, `: ` or a leading quote fail the render or change the value. Until the chart is fixed, give each a single element of letters, digits and `-_./=` only (`command: ["./app"]`, `args: ["--verbose"]`), or leave both out and let the image's entrypoint run; anything longer belongs in a script in the image. `jobs[]` and `cronjobs[]` render `args` correctly (see [CronJobs](#cronjobs)).

### Lifecycle and Shutdown

Every application container gets a preStop hook that sleeps `lifecycle.preStopSleepSeconds` (default 5) before Kubernetes sends SIGTERM, so in-flight requests and the Istio sidecar drain while the pod is removed from endpoints. Set it to `0` to turn the hook off. The sleep counts against `terminationGracePeriodSeconds` (default 10), which must also cover the application's shutdown and the sidecar's drain: raise it when the application needs time after SIGTERM.

```yaml
applications:
  api:
    lifecycle:
      preStopSleepSeconds: 10
    terminationGracePeriodSeconds: 31
```

`lifecycle.postStart` and `lifecycle.preStop` (command strings) are accepted by the schema but not rendered.

### Pod Anti-Affinity

In environments whose name starts with `prod`, every application gets required pod anti-affinity: no two of its pods run on the same node. Elsewhere, set `affinity.enablePodAntiAffinity: true` to get the same. Because the rule is required, pods stay Pending when there are fewer schedulable nodes than replicas.

```yaml
applications:
  api:
    affinity:
      enablePodAntiAffinity: true
```

### Networking / Istio
```yaml
applications:
  api:
    networking:
      istio:
        enabled: true                   # default; false renders no VirtualService
        hosts:                          # extra hosts, in addition to the default one
          - "myservice.dev.mycarrier.dev"
        allowedEndpoints:               # paths the gateway lets through (see below)
          - /swagger/*
        redirects: {}
        routes: {}
        responseHeaders: {}
        corsPolicy:
          allowOrigins:
            - exact: "https://app.mycarrier.dev"
          allowMethods: ["GET", "POST"]
          allowHeaders: ["Authorization", "Content-Type"]
          maxAge: "24h"
```

| Value | Default | Effect |
|-------|---------|--------|
| `networking.istio.enabled` | `true` | `false`: no VirtualService for the application |
| `networking.istio.allowedEndpoints` | `[]` | Paths added to the endpoint allowlist: a string (with `*` a prefix match, as in `/api/v1/*`; otherwise an exact match) or `{kind: exact \| prefix \| regex, match: <path>}` |
| `networking.istio.disableDefaultEndpoints` | `false` | `true`: no csharp default entries in the allowlist |
| `networking.istio.allowAllEndpoints` | `false` | Dev and feature environments only: skip the allowlist and route every path |
| `networking.istio.offloadOperatorEnabled` | `true` in dev and feature environments, `false` elsewhere | The offload operator owns the application's routing instead of a chart VirtualService |
| `networking.istio.offloadVSEnabled` | `true` | Feature environments: render the `<fullName>-offload` VirtualService |
| `networking.istio.cloudflareProxied` | `true` | Sets the `external-dns.alpha.kubernetes.io/cloudflare-proxied` annotation on the application's VirtualServices, including the operator-managed one in dev (through the OffloadBase `virtualServiceAnnotations`) |
| `networking.istio.offloadVirtualServiceAnnotations` | `{}` | Dev: extra annotations on the operator-managed VirtualService; a `cloudflare-proxied` key here overrides `cloudflareProxied` |
| `networking.istio.internalEnabled` | `true` | The mesh-internal host described below |
| `networking.istio.enforceAllowlistOnEnvironmentHeader` | `true` | When an allowlist applies, requests with the `environment` header also reach only the allowed paths; `false` (opt-out) lets them reach every path |
| `networking.istio.externalEnabled` | `true` | `false` binds the application's VirtualServices only to `mesh`, drops its public hosts and its `cloudflare-proxied` and `mycarrier.io/gateway` annotations, so only in-cluster callers reach it. `useRootDomain`, `staticHostname`, `networking.istio.hosts` and `networking.istio.legacyHostAliases` then fail the render, and so does a frontend application in a multi-frontend release (the shared VirtualService routes every frontend through the ingress gateway) |

**Endpoint allowlist.** When an application has an allowlist, the gateway answers every other path with a 403. A csharp application has one by default, built from: `/liveness` and `/health` (exact), `/api` (prefix, only when the application's full name contains `api`), and `/swagger` (prefix) in dev and feature environments only. `allowedEndpoints` entries are added after the defaults. A non-csharp application without `allowedEndpoints` has no allowlist. The allowlist is enforced in every environment except plain `dev`, including feature environments (since mycarrier-helm 4.1.0). It also covers requests that carry the `environment` header (the frontend and the API gateway send it on every call): the header route has one match per allowed endpoint. `networking.istio.enforceAllowlistOnEnvironmentHeader: false` (opt-out) lets requests with the header reach every path again, for one application.

**`allowAllEndpoints`** is an escape hatch for dev and feature environments; prefer adding the path to `allowedEndpoints`. Setting it to `true` in any other environment fails the render (an explicit `false` is accepted everywhere), so keep it in the dev values file and out of shared ones. In Layout B, `values.dev.yaml` also serves feature environments that have no file of their own.

**KrakenD `additionalEndpoints`.** With `networking.krakend.enabled: true`, each `networking.krakend.additionalEndpoints[]` entry (endpoints missing from the OpenAPI document, such as liveness) renders with a `method`. `method` defaults to `GET` when the entry omits it. A `method` you set must be one of `GET`, `POST`, `PUT`, `PATCH` or `DELETE` (uppercase, the CRD enum); `values.schema.json` rejects anything else (lowercase, empty, null) at render, and the chart keeps a valid value as written.

When Istio ingress is enabled, the chart also advertises mesh-internal DNS entries per application using the pattern `{appStack}-{application}.{environment}.internal` (not in feature environments). In dev, these support header-based routing to feature namespaces via the `environment` request header.

### Probes
Every application with `ports` gets default probes on its `http` port (or a port named `healthcheck`):

| Probe | `language: csharp` | Other languages |
|-------|--------------------|-----------------|
| Liveness | HTTP GET `/liveness` | TCP socket |
| Readiness | TCP socket | TCP socket |
| Startup | HTTP GET `/health` | TCP socket |

`probes.enableLiveness`, `probes.enableReadiness` and `probes.enableStartup` (all default `true`) turn a probe off. A Rollout's canary health check calls the liveness probe's `httpGet` path (see [Rollouts](#rollouts)). `probes.livenessProbe`, `probes.readinessProbe` and `probes.startupProbe` replace the default with a Kubernetes probe spec:
```yaml
applications:
  api:
    probes:
      enableStartup: false
      livenessProbe:
        httpGet:
          path: /healthz
          port: http
        initialDelaySeconds: 30
        periodSeconds: 10
      readinessProbe:
        httpGet:
          path: /readyz
          port: http
        initialDelaySeconds: 10
        periodSeconds: 10
```

### Service Configuration
```yaml
applications:
  api:
    service:
      type: "ClusterIP"
      ports:
        - name: http
          port: 80
          targetPort: 8080
      disableAffinity: false
      affinityTimeoutSeconds: 600
```

---

## Rollouts

`deploymentType: rollout` deploys the application as an Argo Rollout with a canary strategy. The chart renders the canary itself: the `<fullName>` (stable) and `<fullName>-preview` Services, and Istio weights on every VirtualService route that reaches the application. Canary settings are release-wide, in `global.strategy.canary`, so every Rollout of a release runs the same steps. `updateStrategy.canary` on an application fails to render, and so does `updateStrategy.bluegreen`. A Rollout's replica count and pod template follow the same rules as a Deployment's. A Rollout omits the zero-valued fields that the rollouts controller's typed Update drops, so that Argo CD stays Synced during a canary: `minReadySeconds` renders only when `applications.<app>.minReadySeconds` is above 0 (a Deployment still renders `minReadySeconds: 0`), and `dynamicStableScale` is not rendered (false is Argo Rollouts' default). A stack moves to Rollouts as a whole. In prod, a Rollout whose repository's `deployment-strategy` property is `canary` gets its prod tests from the release's rollout-watch instead of a PostSync hook (see [Test triggers of Rollouts in prod](#test-triggers-of-rollouts-in-prod)).

**The deployment-strategy property turns the steps on.** chart-renderer passes the repository's `deployment-strategy` property on every render as `global.deploymentStrategy`, on either chart: mycarrier-helm reads it directly, and mc-environment forwards its whole `global` map to each environment. Do not set it in a stack's values files. A Rollout (`deploymentType: rollout` without `migratingToRollouts`) runs canary steps only when the value is exactly `canary`. With any other value (`rolling`, empty, unset, or another spelling such as `Canary`) it renders with no steps, no analysis, no barriers or dark stage, no `managedRoutes`, none of the annotations under What the release reads, none of the chart's AnalysisTemplates and, in prod, no `<environment>-<fullName>-alerts` ExternalSecret; in prod it keeps its PostSync test hook. It keeps the `<fullName>` and `<fullName>-preview` Services, the VirtualService and `trafficRouting`, so switching the property moves no traffic: Argo Rollouts scales the new ReplicaSet to full size behind the `-preview` Service at weight 0, then points the stable Service at it. Such a Rollout still needs what the table below lists for every environment, `dev` and `feature<N>`, but not `global.correlationId`, a health path or an alerts service label. Render paths that do not pass the property, such as offloads, render Rollouts without steps until they do. Setting the property back to `rolling` turns the steps off for the next release.

```yaml
global:
  strategy:
    canary:
      preset: standard                  # standard | fast | manual
      # stepsOutsideProd: true          # render the prod steps outside prod, for a test drill (default false;
      #                                 # the 4.7.9 schema refuses it)
      manualTimeout: 40m                # the manual pause's share of the canary budget; the pause has no limit
      # steps: []                       # replaces the preset, verbatim
      # budgetSeconds: 1800             # required with steps, in every environment: their worst-case length, 1 to 5700 s
      analysis:                         # mandatory for every Rollout (see below)
        templates: []                   # extra templates only; health and alerts run unless opted out
        #                               # [tests]: the app's TestEngine suite in each analysis step (see Analysis);
        #                               # needs dark: false until Q54
        # tests:
        #   timeout: 7m                 # poll budget of the tests Job
        #   startupSeconds: 120         # pod start slack; activeDeadlineSeconds is timeout + startupSeconds
        health:
          enabled: true                 # each analysis step calls the liveness probe's HTTP path
          # path: /health               # only when the liveness probe is not HTTP
          #                             # applications.<app>.canaryHealthPath overrides it per application
        alerts:
          enabled: true                 # background analysis, in prod only
          # service: mycarrier          # the service label of the service's Grafana alert rules;
          #                             # default alerts.serviceName, else global.appStack (not the default app), lower-cased
          # dryRun: true                # the alerts metric records and never fails the canary; false at go-live
      # progressDeadlineSeconds: 1200  # a canary that makes no progress for this long aborts; above every barrier
      #                                 # timeout (default 1200 with the dark stage, 600 without it)
      bakeMinutes: 30                   # alert-gate's watch window after promotion, 1 to 100 minutes
      coordinator:
        enabled: true                   # release-wide lockstep; needs global.correlationId where the steps render
        #                               # (prod, or stepsOutsideProd); the pipeline sets it
        # barrierTimeouts: {start: 9m, dark-ready: 9m, dark-passed: 15m, w10: 9m, w25: 9m, w50: 9m}
      dark: true                        # header-gated dark stage: the leader's test suite against the canary at
      #                                 # weight 0 (see Dark stage); false turns it off
      darkReplicas: 2                   # canary pods during the dark stage, at least 2
      # leader: api                     # the application that runs the dark suite; required with 2+ canary Rollouts
```

**Steps in prod only.** A canary Rollout (property `canary`) renders its steps only where `environment.name` is `prod` (Q52, DEVOPS-516). In every other environment (`dev`, `uat`, `qa`, `preprod`, `feature<N>` and any other name), it renders `steps: []`, and Argo Rollouts promotes the new version at once. The preset or explicit `steps`, the barriers, the analysis steps, the pauses, the dark stage, the background `alerts` analysis and `mycarrier.tech/canaryBudgetSeconds` go together. The Rollout keeps the stable and `-preview` Services, the Istio traffic routing, `progressDeadlineSeconds`, `rollbackWindow`, `mycarrier.tech/rolloutGroupSize` and `mycarrier.tech/bakeMinutes`, and the chart's `health` AnalysisTemplate (and `tests`, when listed) still renders, with no step that references it.

- `stepsOutsideProd: true` (default `false`) renders the prod steps in any environment, for a test drill. Set it only for the drill's environment: Layout A in `helm/values.{env}.yaml`, Layout B in the `global` of that environment's `environments[]` entry. Do not set it in the shared `helm/values.yaml`. With it, a canary Rollout renders the same steps as in prod, with the environment's template names, and the same budget. It gives no steps to a Rollout whose property is not `canary`: that Rollout renders the same in every environment, with or without it. The chart's `alerts` check stays prod only; in a drill only a replacement `alerts` entry runs as background analysis.
- The 4.7.9 schema refuses `stepsOutsideProd` ("additional properties not allowed"). A stack can set it only once the deploy-core pin has moved past 4.7.9 to 4.7.10 or later.
- For a canary Rollout, the render-time checks run in every environment, with or without `stepsOutsideProd`, as on 4.7.9: a missing health path, both analysis opt-outs, an extra template that does not render, a barrier timeout at or above `progressDeadlineSeconds`, the leader rule, the leader's `tests-dark` (its `testtrigger.testdefinitions`, see Dark stage), a `darkReplicas` below 2, `budgetSeconds` for an explicit `steps` list, a budget above 5700 s (the leader's `tests-dark` included), a zero `manualTimeout` with the `manual` preset, and the multi-frontend dark stage fail the render outside prod too. The checks of the chart's `tests` template (an application without test definitions, a zero `tests.timeout`, the barrier window and the others under Analysis, `tests`) also run in every environment, except `global.correlationId`, which applies where the steps render. A stack moves to canary as a whole, so the same Rollouts exist in every environment, and the stack sees these failures on its first render, not at its first prod canary.
- Only two checks apply just where the steps render: `global.correlationId` for the coordinator, and the canary pod floor (a minimum of at least 2 replicas, see Dark stage). Outside prod without `stepsOutsideProd`, a render without a correlation id or with 1 replica succeeds. `dev` and `feature<N>` default to 1 replica (see [Default Replica Counts](#default-replica-counts-when-hpa-is-not-active)), so a drill there with `stepsOutsideProd` sets `replicas: 2` (or an autoscaler minimum of 2) on each canary Rollout.

| Preset | Steps (after the dark stage) | Budget with the defaults: leader / follower | With `dark: false` | With the coordinator off |
|--------|-------|-------------------------------|--------------------|--------------------------|
| `standard` (default) | 10%, 25% and 50%, each followed by a 5-minute pause, then 100% | 5343 s / 4770 s | 3330 s | 3570 s |
| `fast` | 25%, then 100% | 3183 s / 2610 s | 1170 s | 1290 s |
| `manual` | 10%, then a pause with no time limit until someone promotes or aborts it, then 100% | 5583 s / 5010 s, with the pause counted as `manualTimeout` (`40m`) | 3570 s | 3690 s |

The budget is `mycarrier.tech/canaryBudgetSeconds` (see What the release reads). The defaults are the coordinator on, the dark stage on (`dark: true`), `analysis.health` at 3 x 30s, barrier timeouts of 9m with `dark-passed` at 15m, and `manualTimeout` 40m. The dark stage adds its `dark-ready` (540 s) and `dark-passed` (900 s) barriers to every Rollout, and the leader's `tests-dark` Job (573 s, as `tests` below) to the leader only; with the coordinator off the dark stage does not render.

With `tests` in `analysis.templates` (which needs `dark: false` until Q54, see Analysis, `tests`) and the default `tests.timeout` (`7m`) and `tests.startupSeconds` (`120`), each analysis step counts the tests Job at its longest, `activeDeadlineSeconds` (540 s) + 33 s for Argo Rollouts to see it end = 573 s, instead of `health` (90 s):

| Preset | Budget with `tests`, `dark: false` and the other defaults | With the coordinator off (one canary Rollout) |
|--------|--------------------------------------|--------------------------|
| `standard` | 4779 s: 2160 s of barriers (`start` and three weight barriers), 900 s of pauses and 3 x 573 s | 5019 s |
| `fast` | 1653 s | 1773 s |
| `manual` | 4053 s, with the pause counted as `manualTimeout` (`40m`) | 4173 s |

`applications.<app>.progressDeadlineSeconds` overrides the deadline for one slow-starting application.

**What the release reads.** A canary Rollout (`deploymentType: rollout` without `migratingToRollouts`, with `global.deploymentStrategy: canary`) carries three annotations that the release's rollout-watch reads. The first two render in every environment; `mycarrier.tech/canaryBudgetSeconds` renders only where the steps render (prod, or `stepsOutsideProd`). A Rollout whose property is not `canary` carries none of them, in any environment:

- `mycarrier.tech/rolloutGroupSize`: the number of such Rollouts in the release.
- `mycarrier.tech/bakeMinutes`: `bakeMinutes` (default `30`), alert-gate's watch window after promotion. rollout-watch puts the smallest value of the release's Rollouts in the `alert.gate` event. Set a longer window for a service with a known slow-burn history. The maximum is `100`: alert-gate's run has a 2-hour deadline (`activeDeadlineSeconds` 7200) and spends about 750 s outside its window, so a longer window would be killed before it ends. A value above `100` or below `1` fails the render, with or without Rollouts.
- `mycarrier.tech/canaryBudgetSeconds`: the worst-case length of the Rollout's canary steps, in whole seconds (Tech Spec D22). rollout-watch times out at the largest value of the release's Rollouts plus 15 minutes, so it never times out a canary that is still inside its steps. The leader runs `tests-dark` and its followers do not, so their values can differ. Outside prod without `stepsOutsideProd` it is absent, but the chart still computes the budget, the same as in prod, and runs its checks.
  - **Preset.** The chart adds up the steps it renders for the Rollout. A pause counts its duration. The `manual` preset's pause counts `manualTimeout` (default `40m`); the pause itself still has no time limit. An analysis step counts its longest template, because its templates run in parallel. A template counts `count` x max(`interval`, `activeDeadlineSeconds`); `activeDeadlineSeconds` counts only for a `job` provider that sets it in `job.spec`. A `job` template also counts the time Argo Rollouts v1.10.0 can take to see a Job end, ceil(sqrt(2 x `activeDeadlineSeconds`)) (33 s at 540 s), and with `count` n of 2 or more at least n x (`activeDeadlineSeconds` + that lag) + (n - 1) x `interval`, because each measurement starts an interval after Argo Rollouts sees the previous Job end. The chart's `health` uses `analysis.health.count` and `interval`. The chart's `tests` and `tests-dark` count their Job's `activeDeadlineSeconds`, which is `analysis.tests.timeout` + `analysis.tests.startupSeconds` (540 s by default), plus that lag: 573 s by default. An `analysisTemplates` entry (an extra template, a replacement `health`, or `tests-dark`) uses its own `count` (default 1; `count: 0` without an `interval` runs once) and `interval` (0 when unset). A barrier counts its timeout. A weight step (and a `setCanaryScale` step) waits until the canary's pods are available, for up to `progressDeadlineSeconds`. With `coordinator.enabled: false`, each weight step above 0 (100 included) counts `progressDeadlineSeconds`. With the coordinator on these waits count 0: with two or more canary Rollouts, a Rollout whose pods start slowly holds its siblings at the next barrier, whose timeout bounds the wait; with one canary Rollout the barriers pass at once, so the budget does not cover these waits, and a canary whose pods start slowly at several steps can outlast rollout-watch's timeout (budget + 15 minutes) while still inside its progress deadlines. Every other step counts 0. The background `alerts` analysis runs next to the steps and does not count. `budgetSeconds` is ignored with a preset.
  - **Explicit steps.** The chart does not add up an explicit `steps` list. Set `budgetSeconds` to its worst-case length by the same rules, from `1` to `5700`. Without it, the render fails, in every environment, also where the steps do not render. Count an indefinite pause (`pause: {}`) as the time a person needs to promote it.
  - **Limits.** A budget above `5700` fails the render, in every environment. rollout-watch's release workflow has `activeDeadlineSeconds` 10800, which covers about 70 minutes before the canary starts, the budget and 15 minutes after it (DEVOPS-319). The defaults fit with the dark stage: `manualTimeout` `40m` is the largest whole 5 minutes that keeps the `manual` leader at or below 5700 s (5583 s), and the `standard` leader is at 5343 s, so a longer `tests.timeout`, `manualTimeout` or barrier timeout soon reaches the limit. With the other defaults, the `standard` preset fits barrier timeouts of up to 10m each with the dark stage (`dark-passed` at its 15m), and up to 18m each with `dark: false`. To lower a budget, lower `manualTimeout`, the barrier timeouts, or the templates' `count` or `interval`; with explicit steps, shorten their pauses and lower `budgetSeconds`. With the `manual` preset, a `manualTimeout` of zero fails the render, and the schema refuses one that is not a duration such as `90s`, `30m` or `1h`. The other presets and explicit steps ignore `manualTimeout`.

In prod, a Rollout that runs canary steps does not run its test trigger as a PostSync hook. rollout-watch starts its prod tests after promotion (see [Test Triggers](#test-triggers)).

**Analysis.** Canary analysis is mandatory for every canary Rollout (property `canary`); a Rollout whose property is not `canary` renders none of it and runs none of its checks. Where the steps render, an analysis step follows each weight. It runs the chart's `health` check and the extra AnalysisTemplates listed in `analysis.templates` (default `[]`), each named `<environment>-<fullName>-<template>`. In prod, the Rollout also runs the chart's `alerts` check as background analysis, from its first weight until promotion. Every listed template must render for each Rollout application, or the render fails: Argo Rollouts resolves them up front and would leave the Rollout InvalidSpec.

- A stack can opt out of one check: `analysis.health.enabled: false` or `analysis.alerts.enabled: false`. With both opted out, `analysis.templates` must list at least one extra template, or every Rollout fails to render, in every environment.
- The opt-out check reads the values, not what renders in the environment. With `health` opted out and `alerts` on, a test drill outside prod (`stepsOutsideProd`) renders with no analysis step, because `alerts` renders in prod only.
- `analysis.templates` lists only extra templates. Listing `health` or `alerts` fails the render, in every environment.
- `analysis.enabled` is deprecated. `true` has no effect. `false` fails the render in every environment, with or without Rollouts.
- An explicit `steps` list renders verbatim, where the steps render, and gets no analysis step from the chart. The background `alerts` analysis, its label check and the opt-out check still apply. It also needs `budgetSeconds`, in every environment (see What the release reads).

- `health` is rendered by the chart and runs in each analysis step unless `analysis.health.enabled` is `false`. When `applications.<app>.canaryHealthPath` or else `analysis.health.path` is set, it calls that path on the application's `http` port (or `healthcheck`). Otherwise it calls the `httpGet` path of the application's liveness probe as the pod renders it (see Probes): `probes.livenessProbe`, or else the default for `global.language`, unless `probes.enableLiveness` is `false`. Readiness and startup probes are not used. A csharp application with default probes uses `/liveness` from its default liveness probe, so it needs no `path`. A non-csharp application with default probes has a TCP liveness probe, so it needs a path. Set `analysis.health.path` when the stack's applications share one health path; set `applications.<app>.canaryHealthPath` for one application, or when the applications' paths differ. The check calls the `-preview` Service port that targets that container port (`ports`, or `service.ports` by `targetPort`), reads a JSON body at `status`, and evaluates `analysis.health.successCondition` (default `result == "Healthy"`). Argo Rollouts up to v1.10.1 counts a 2xx body that is not JSON as healthy without evaluating the condition; argo-rollouts#4770 (merged, not yet released) evaluates the condition on the raw body, so a stack whose health path serves HTML (a frontend's `/`) sets `successCondition: "true"`, which accepts any 2xx answer. A non-2xx answer, a timeout or a connection error is an error, retried after about 10 s; a second error in a row aborts the canary. Tune it with `analysis.health` (`count` 3, `interval` 30s, `consecutiveErrorLimit` 1, 0 aborts on the first error; `successCondition`). The `-preview` Service keeps ClientIP affinity, so the check's calls usually land on one canary pod: it catches a defect of the version, not one that only some pods show. The check calls plain http with no host or headers, so a liveness probe with `scheme: HTTPS`, `host` or `httpHeaders` fails the render while `health` is on; set `canaryHealthPath` instead. An application with no path set and no HTTP liveness probe on a Service port fails the render while `health` is on, in every environment, also where the steps do not render. Set a path, give it an `httpGet` liveness probe, or set `analysis.health.enabled: false`.
- `alerts` is rendered by the chart in prod only, because canaries run only in prod; other environments render no steps, and a test drill there (`stepsOutsideProd`) leaves `alerts` out. (The 4.7.5 breaking entry below describes the earlier prod-and-preprod behaviour.) `analysis.alerts.dryRun` (default `true`) covers only its `alerts` metric: that metric records its results in the AnalysisRun's `dryRunSummary` and never fails the canary until a stack sets `dryRun: false` at go-live (DEVOPS-312 records the conditions). Its `alert-rules` check is always live, whatever `dryRun` is set to, so it can abort the first prod canary (see How it fails). The Rollout runs the template as background analysis from its first weight until promotion, so it also checks during the pauses, where most alert rules' `for` windows (5m) run out. `analysis.alerts.enabled: false` turns the check off.
  - **What it matches.** The matchers alert-gate uses: the service label, the environment (in prod, alerts with no `environment` label match too, because the Service Alerts carry none), and a folder other than Platform. The service label is `analysis.alerts.service`, or else `alerts.serviceName` lower-cased, which is the label of the chart's own alert rules, or else `global.appStack` lower-cased. The default `app` counts as unset, because no alert rule carries it. alert-gate takes the label from the repository name instead (the lower-cased name, or its alias). Where they differ, set `analysis.alerts.service` to the label the service's rules carry: `mc.order` for MC.Order, `mycarrier` for MC.MyCarrier, `curant` for MC.Curant. In prod the render fails when none of the three is set, with preset or explicit `steps`; set one, or set `analysis.alerts.enabled: false`. `global.appStack` defaults to `app`, so a stack that does not set it gets the label `app`; always set it.
  - **How it fails.** `alert-rules` is a Job that runs twice, 30 s apart, when the analysis starts. When either run fails, the canary aborts at its first weight, whatever `dryRun` is set to; a pod that fails without an answer from the script (for example an eviction) is retried once. A run fails when:
    - no alert rule that can fire (not paused, not in error) matches the label: a wrong label, rules that are all paused, or only anomaly rules with no live instance;
    - Grafana rejects the token (401 or 403, for example after a rotation of `ci-alert-gate` or without the Viewer role), answers another 4xx or a redirect, or answers JSON of the wrong shape; or the Vault property is empty;
    - the Job pod cannot read the Secret, or does not start and finish within 360 s.

    A Grafana outage does not fail a run: after three tries, jittered and honouring a 429's `Retry-After` up to 10 s, for a 5xx, a 429, a timeout, a network error (including a pod that cannot reach `grafana.mycarrier.tech`, or a TLS error) or a body that is not JSON, the run logs `SKIPPED` and passes, because an outage says nothing about the release. A `SKIPPED` run did not enforce the check; if it repeats, check Grafana's status and the Job's egress. A Job image that cannot be pulled pauses the canary instead. Fix the cause, or set `analysis.alerts.enabled: false` to deploy without the check. `alerts` calls Grafana's Alertmanager API every `interval` (30s) and fails when a matching alert fires that is not silenced. An alert that already fires when the release starts fails it too (alert-gate ignores such alerts in prod), so silence a standing alert in Grafana before the release. A non-2xx answer, a timeout, a connection error, or JSON that is not a list of alerts is an error: the check tolerates `consecutiveErrorLimit` (4) errors in a row, and one more fails it. Argo Rollouts up to v1.10.1 counts a 2xx answer that is not JSON as a pass. Once live, a failure of `alerts` aborts the canary. To turn the whole check off, set `analysis.alerts.enabled: false` in a release.
  - **Before the first prod canary.** Confirm that the `ci-alert-gate` service account has the Viewer role in Grafana, that the ExternalSecret becomes Ready in the namespace, and that pods in the namespace can pull the Job image. Each of these failures stops the first canary. Also confirm that pods in the namespace can reach `grafana.mycarrier.tech` (for example `curl -sS -o /dev/null -w '%{http_code}' https://grafana.mycarrier.tech` from a pod there). An unreachable Grafana does not stop the canary: it leaves `alert-rules` `SKIPPED`, so check the first `alert-rules` Job log for `SKIPPED`.
  - **What else renders.** Both metrics read the Grafana token from the Secret of an ExternalSecret `<environment>-<fullName>-alerts` (Vault DevOps `grafana/service-accounts/api/tokens`, property `analysis.alerts.tokenKey`, refreshed every 5m). It syncs in wave 8, before the Rollout, and Argo CD waits for it to be Ready: when Vault cannot be read, the sync stops there. Fix the Vault read, or set `analysis.alerts.enabled: false`. The Job's image is `analysis.alerts.image` (Python from Docker Hub, pinned by digest); set it to a mirror where nodes cannot pull from Docker Hub.
- `tests` is rendered by the chart (DEVOPS-515), only for a canary Rollout (repository property `canary`) of a stack that asks for it: list `tests` in `analysis.templates`, or reference `<environment>-<fullName>-tests` in an explicit `steps` list. Nothing renders until a stack lists it, so stacks that do not list it render as before. Like `health` and `alerts`, a Rollout whose property is not `canary` (`rolling` or unset) renders no `tests` template and runs none of its checks, with or without `tests` listed: listing it there has no effect until the property is `canary`. It is the AnalysisTemplate `<environment>-<fullName>-tests`, with one Job metric. The Job sends the application's `testtrigger.testdefinitions` to TestEngine's v1 API, polls the run, and exits 0 only when the run passes. A failing suite fails the AnalysisRun, and the canary aborts (with the coordinator on, the whole release aborts).
  - **What it sends.** The same TestEngine request that the application's PostSync hook sends (one template renders both), with four differences:
    - `ServiceAddress` is the application's `-preview` Service (the canary pods), `http://<fullName>-preview.<namespace>.svc.cluster.local:<port>`, on the `-preview` Service port that reaches the `http` container port (`ports.http`, or with `service.ports` the entry whose `targetPort` is it). When the `-preview` Service exposes no such port, the render fails.
    - A definition's own `serviceAddress` must point at the application's own Service or its `-preview` Service: `<fullName>`, `<fullName>.<namespace>`, `<fullName>.<namespace>.svc` or `<fullName>.<namespace>.svc.cluster.local`, or the same with `<fullName>-preview`, with or without a scheme or user info. The canary run calls the `-preview` address above with the same path, for example `http://<fullName>.<namespace>.svc.cluster.local:8080/api` becomes `http://<fullName>-preview.<namespace>.svc.cluster.local:8080/api`. Leave the port out, or give the `http` Service port; another port (for example `:9090/metrics`) fails the render, because the chart cannot tell which `-preview` port serves it. Any other host (another Service, or a public host such as `https://payment-api.dev.mycarrier.dev`) fails the render, because the canary run must test the canary. The message shows the address without its scheme or user info.
    - `TestEnvironmentVariables` gets `RunKind: canary` and `SlipStep: none`, so the run writes no slip step, posts no check-run and calls no webhook.
    - `Tolerations` is `[]`, so the test pods run on on-demand nodes; a definition's `tolerations` is not used.

    The Job uses the hook's TestEngine URL (from Vault, by the pipeline's Argo Events instance, or `global.testengineWebhookUrl`). Its key is `testtrigger.apikey`, else the shared `vault:DevOps/data/testengine/api#encoded_header`; the hook sends `testtrigger.apikey` as it is, and nothing when it is unset. The key must be a `vault:` reference: a literal key would sit in the AnalysisTemplate and in every AnalysisRun and Job, so it fails the render. Leave `testtrigger.apikey` unset to use the shared key.
  - **What runs.** Each analysis step runs the full suite, in each Rollout of the release, in parallel. The `standard` preset runs it three times, at 10%, 25% and 50%. Choose filters that can run three times against a canary. In prod, rollout-watch also starts the prod tests once after promotion, as before.
  - **Where to set it.** `analysis.templates` is release-wide. With `tests` listed and the property `canary`, every Rollout application of the release needs `testtrigger.testdefinitions` in that environment, or the render fails, in every environment. An application that has no suite can define its own `tests` entry under `analysisTemplates`, which replaces the chart's. Test definitions usually live in `deployment/values.{env}.yaml`, so list `tests` in the shared `helm/values.yaml` only when every environment defines test definitions for every Rollout application. Otherwise set `analysis.templates` in each environment's values: Layout A in `helm/values.{env}.yaml`, Layout B in the `global` of that environment's `environments[]` entry. A list set there replaces the shared list, so repeat any other extra template in it.
  - **Environments.** The template renders in every environment where `tests` is listed, as `health` does, also where the Rollout renders `steps: []`; there no step runs it. `stepsOutsideProd` changes only the Rollout. Its render checks run in every environment, except the `global.correlationId` check, which applies where the steps render.
  - **Render checks.** With `tests` listed and the property `canary`, the render fails when:
    - a Rollout application has no `testtrigger.testdefinitions`;
    - `analysis.tests.timeout` is zero, or `analysis.tests.startupSeconds` is not a whole number from 30 to 600;
    - a definition's `serviceAddress` is not on the application's own Service or its `-preview` Service, or names a port other than the `http` Service port, or the `-preview` Service exposes no `http` port;
    - `testtrigger.apikey` is not a `vault:` reference;
    - in prod, a filter's first `TestCategory` starts with `preprod` (see Prod filters);
    - the Rollout has managed routes: `dark: true` (the default) with the coordinator on and a preset (the dark stage renders only then), or a `setHeaderRoute` or `setMirrorRoute` step in explicit `steps` (see Dark stage below);
    - `coordinator.enabled` is `false` and the release has more than one canary Rollout (see Lockstep);
    - `global.correlationId` is empty where the steps render (prod, or `stepsOutsideProd`): the request sends it as `CorrelationId`, and TestEngine answers 422 without it. The pipeline sets it on every render;
    - with more than one canary Rollout, one can wait at a barrier for another for the barrier's timeout or longer (see Barrier window).
  - **Before the first canary with `tests`.** Do these before any real stack lists `tests`:
    - Run R1 on testengine-dev: a dev canary Rollout whose suite fails must abort, and one whose suite passes must pass with exactly one request to TestEngine. This shows the Job reaches TestEngine from an app namespace (NetworkPolicy, DNS and egress) without an Istio sidecar; a Job that cannot connect fails closed and aborts every release that lists `tests`.
    - TestEngine must run with `RUN_KINDS_ENABLED=true`. testengine-dev does. The prod TestEngine turns it on in the DEVOPS-321 pilot; keep `tests` off prod stacks until then. Before it, each prod canary that runs `tests` fails at its first analysis step: the Job sends no request and fails with a message that names `RUN_KINDS_ENABLED`.
    - Mirror the Job image to ACR and point `analysis.tests.image` at the mirror (the ACR mirror is still open). An image that cannot be pulled stalls the canary (see How it fails).
    - Pods in the namespace must pull the Job image and the Vault webhook's init image, and reach the TestEngine URL.
  - **Prod filters.** In prod, TestEngine refuses a canary run when a filter's first `TestCategory` starts with `preprod` (in any case; TestEngine reads the text before the first `&`, without `TestCategory=`). Such a filter fails the render where the request's `EnvironmentName` (the namespace) contains `prod` and not `preprod`. A filter that TestEngine reads from Vault (`filters: vault:...`) is not known at render time; TestEngine then answers 422, and the canary fails at its first analysis step.
  - **How it fails.** The Job first reads TestEngine's `/v1/capabilities`. A 404, or `run_kinds_enabled` false, ends it with no request sent. Then it sends one request. A 425 means TestEngine dispatched nothing, and the Job sends the same request again. A 422 (`run kinds disabled` included), any other 4xx and a 5xx fail without a retry. A request with no answer also fails without a retry, because it may have started a run. When `tests.timeout` is spent before a request, the Job sends none and says so. Every member must echo `run_kind` canary and `slip_step` none. The Job then reads the run every 10 s. `passed` passes. `failed` fails. `no_results` or `infra_failed` starts the request once more, as a new run, which must pass; with less than 60 s of `tests.timeout` left, the Job skips that resubmit and fails, and its `FAIL:` line says so. A 404 for the run is retried for 60 s after the request, then fails. A 5xx fails (a 503 means TestEngine's run status store is down). A read with no answer is retried. Each call to TestEngine also ends by `tests.timeout`, the connection, the status line, the headers and the body together; when `tests.timeout` runs out, the Job fails. The pod's termination message holds the Job's last lines, with the `FAIL:` reason; it names error types, never the URL's host or the key. A TestEngine outage therefore aborts a healthy canary.
    - A Job whose image, or the Vault webhook's init image, cannot be pulled (`ErrImagePull`, `ImagePullBackOff`, `InvalidImageName`) does not fail the run. Argo Rollouts v1.10.0 records the measurement as Inconclusive, and with `inconclusiveLimit: 0` (TestEngine's caller contract, rule 13; it stays) the Rollout pauses at its canary weight, still serving production traffic, with the suite never run. With more than one canary Rollout, the siblings' next barrier times out and canary-coordinator's cascade aborts the paused Rollout, about 9 minutes later. With one canary Rollout nothing aborts it until rollout-watch's timeout at `mycarrier.tech/canaryBudgetSeconds` + 15 minutes (about 93 minutes on the `standard` preset); rollout-watch then publishes `prod.rollback`, and gitops-rollback reverts the release, which may have been fine. Mirror the image to ACR to avoid this.
  - **Timing.** `analysis.tests.timeout` (default `7m`; a duration such as `90s`, `7m` or `1h`; zero fails the render) is the Job's poll budget: the whole run, the one resubmit included. `analysis.tests.startupSeconds` (default `120`, from `30` to `600`) is the slack for the pod to start. The Job's `activeDeadlineSeconds` is the timeout + `startupSeconds` (540 s by default), and the canary budget counts it for each analysis step (see the table above).
    - Kubernetes counts `activeDeadlineSeconds` from the Job's creation, Pending included: scheduling (with `tolerations: []`, maybe an on-demand node scale-up), the image pull and the Vault injection. The script's own budget starts only when it starts, and the pod cannot read its own start time. A pod that stays Pending past `startupSeconds` ends `DeadlineExceeded`: the Job condition shows it, there is no `FAIL:` line, and a TestEngine run already started is left running. Raise `startupSeconds` where pods start slowly; it adds to the budget and to the barrier window.
  - **Barrier window.** In each analysis step, each canary Rollout of the release runs its own templates in parallel; after the steps up to the next barrier, canary-coordinator holds the barrier until the whole group reaches it. So Rollout A waits there for Rollout B for B's longest run of all the analysis steps since the previous barrier minus A's shortest run of them (the pauses and weights between them are the same for both). With the coordinator on and `tests` listed, or with the dark stage running the leader's `tests-dark`, the render fails when the worst such pair of different Rollouts reaches the barrier's timeout (`w10`, `w25`, `w50` and `dark-passed`, or any barrier of explicit `steps` that follows an analysis step):
    - Each Rollout's step uses its own templates, also its `analysisTemplates` replacements (`health`, `tests`) and extra templates. A step's longest run is its longest template: `count` x max(`interval`, `activeDeadlineSeconds`), as in the budget, plus, for a Job, the lag ceil(sqrt(2 x `activeDeadlineSeconds`)), the time Argo Rollouts v1.10.0 can take to see a Job end. A Job with `count` n of 2 or more can run n x (`activeDeadlineSeconds` + lag) + (n - 1) x `interval`, because each measurement starts an interval after the previous Job is seen to end. Its shortest run is its templates' largest (`count` - 1) x `interval`: Argo Rollouts takes the first measurement at once, and a Job can end at once. Several analysis steps between two barriers add up. The dark stage's `tests-dark` runs on the leader only, so at `dark-passed` only the leader's run counts, and a follower's own `tests-dark` entry is ignored. With the defaults the leader's `tests-dark` takes up to 573 s, below `dark-passed`'s 15m (900 s); a `dark-passed` of 9m (540 s), the default before the dark stage was on, fails the render with two or more canary Rollouts.
    - With the defaults, two canary Rollouts give 540 + 33 - 60 = 513 s (the tests Job's 540 s, the 33 s detection lag, the other Rollout's `health` at 2 x 30 s), below 540 s. A Rollout whose step can end at once (`health` off, or a `health` replacement with `count: 1`) can wait 573 s, which fails: lower `tests.timeout` (for example to `6m`) or raise the weight barriers. A sibling with a longer `health` replacement or its own longer `tests` adds its longer run.
    - A release with one canary Rollout has no barrier wait: canary-coordinator passes the barrier at once for a group of one, so the check never fails it, and its `tests.timeout` is bound only by the budget.
    - The spread of pod readiness between the Rollouts is not counted, so keep headroom below the barrier's timeout.
    - To give the tests more time, raise `coordinator.barrierTimeouts` `w10`, `w25` and `w50`, keep each below `progressDeadlineSeconds`, and keep the budget at or below 5700 s. A barrier in explicit `steps` whose `timeout` is missing or not in the `90s`, `9m` or `1h` form is not checked.
  - **Lockstep.** TestEngine's DeployVerifier checks every Rollout of the release's correlation group, and each must be in flight. With `coordinator.enabled: false` each Rollout runs its own steps, so a sibling that already promoted (or has not started) would fail the run after part of the release shipped: `tests` with the coordinator off fails the render when the release has more than one canary Rollout. With the coordinator on, each run's DeployVerifier also needs every sibling Rollout's canary to have an available pod within its window of about 60 s, so a slow-starting sibling can fail the run. This is raised with TestEngine's owners.
  - **Job.** `backoffLimit: 0`, `restartPolicy: Never`, `tolerations: []`, no Istio sidecar, and the chart's pod and container security contexts. The image is `analysis.tests.image` (Python from Docker Hub, pinned by digest, the same default as `alerts.image`); set it to a mirror where nodes cannot pull from Docker Hub. The URL and the key reach the pod as `vault:` environment values, as for the hook.
  - **Dark stage.** `tests` fails the render on a Rollout with managed routes: `dark: true` (the default) with the coordinator on and a preset (with `coordinator.enabled: false` or an explicit `steps` list the dark stage does not render, and `dark: true` adds no route), or a `setHeaderRoute` or `setMirrorRoute` step in explicit `steps`. TestEngine's DeployVerifier fails a canary run of such a Rollout that sends no `X-MyCarrier-Canary` header, and `tests` runs at the weight steps, after the dark stage has removed its header route, so every `tests` run would fail. The dark stage already runs the suite against the canary once, at weight 0 (`tests-dark`, see Dark stage under Lockstep and the dark stage). To run `tests` at the weight steps instead, set `dark: false` with it, until Q54 (a DeployVerifier check of header-less canary runs per Rollout) is resolved; the render message says the same.
  - **Rollback.** Remove `tests` from `analysis.templates`. The next render drops the template, and the analysis steps no longer run it.
  - **Chart version.** 4.7.11 renders no `tests` template: listing `tests` fails the render of a canary Rollout, and its schema refuses `analysis.tests` ("additional properties not allowed"). Set them only once the deploy-core pin has moved past 4.7.11, to the release after 4.7.11.
- `compare` is not built yet.
- `applications.<app>.analysisTemplates` render under the same names, and one named `health`, `alerts` or `tests` replaces the chart's. A replacement `alerts` renders in every environment, not only prod, and runs as background analysis where the steps render (prod, or `stepsOutsideProd`): set `count: 0` and an `interval` on it so it runs until promotion (with a `count` it stops after `count` measurements and checks none of the later weights). Any other entry that an analysis step references must keep `count` above 0 when it sets an `interval`: `count: 0` runs indefinitely, which Argo Rollouts allows only in background analysis, so the render fails. Its provider is exactly one of `web`, the chart's shorthand, which checks `result == "Healthy"` on the `-preview` Service's `/health` by default, on the Service port that reaches the `http` container port (`url`, `statusEndpoint` with or without `url`, `successCondition`, `jsonPath`, `timeoutSeconds`), or `job`, an Argo Rollouts job provider passed through as written. Other metric providers are not supported. An entry takes `name`, `count`, `failureLimit`, `interval` and `consecutiveErrorLimit`; an unknown key fails the render. The `job.container` shorthand fails to render.

**Lockstep and the dark stage.** `coordinator.enabled` (default `true`) turns on release-wide lockstep through the canary-coordinator step plugin. The controller rejects steps for a plugin it doesn't have, so set `coordinator.enabled: false` where the plugin is not on the cluster. With `coordinator.enabled: false`, each Rollout of a release runs its own steps: one can be at 50% while another is at 10%, or abort while another promotes. With it on:

- `global.correlationId` must be set where the steps render (prod, or `stepsOutsideProd`), or every Rollout fails to render there. The pipeline sets it on every render. The plugin finds a release's Rollouts by that label.
- A preset starts with a `start` barrier and gets a barrier after each weight's analysis and pause; the dark stage adds `dark-ready` and `dark-passed`. Every barrier timeout (`coordinator.barrierTimeouts`: 9m each, `dark-passed` 15m) must stay below `progressDeadlineSeconds` (default 1200 where the dark stage renders, 600 otherwise), or the render fails: Argo Rollouts counts the wait at a barrier toward the deadline. A stack or application that sets `progressDeadlineSeconds` at or below 900 therefore fails with the dark stage on: raise it above 900, or remove it to get 1200. With `tests` listed, the barrier after each analysis step must also cover the tests Job's barrier window, and `dark-passed` covers the leader's `tests-dark` (see Analysis, Barrier window).
- `dark` (default `true`) adds the header-gated dark stage to a preset (see Dark stage below). With `coordinator.enabled: false`, or with an explicit `steps` list, it does not render, and `dark` has no effect.
- The leader is `global.strategy.canary.leader`. It must name an application of the release in every environment where it is set (a misspelled name fails the render), and where the dark stage runs (coordinator on, `dark: true` and a preset, in every environment, also where the steps do not render) it must be an application with `deploymentType: rollout` and without `migratingToRollouts`; with more than one such application the render fails until it is set, and a release with one defaults to it. A leader set in shared values is fine where that application is still a Deployment or migrating, as long as the coordinator or the dark stage is off there; an application defined only in one environment's values file needs the leader set in that same file. Set it to an application that serves the release's traffic.

**Dark stage.** With the coordinator on and a preset, `dark: true` (the default since the release after 4.7.12, DEVOPS-326) runs the leader's test suite against the release's canaries at weight 0, before any customer HTTP request reaches them through the routes (queue-driven work in canary pods is not gated, see What stays exposed). Rollouts whose property is not `canary`, Deployments and StatefulSets render as before. Where the steps render (prod, or `stepsOutsideProd`), each canary Rollout of the release, after the `start` barrier:

1. scales its canary to `darkReplicas` pods (default 2; the schema and the render refuse fewer: with one pod a single restart leaves the canary with no available pod, and Argo Rollouts removes the header route in the middle of the suite);
2. adds the `canary-header` route, which sends a request carrying `X-MyCarrier-Canary: <global.correlationId, lower-cased>` to the canary, above every other route of its VirtualService; the weights stay 100/0;
3. waits at `dark-ready` for the whole release;
4. on the leader only, runs `<environment>-<fullName>-tests-dark`;
5. waits at `dark-passed` (15m) for the leader's suite; a failing suite aborts the leader and, through the coordinator, every Rollout of the release;
6. removes the header route;
7. wraps the first weight W: `setCanaryScale {weight: W}`, `setWeight W`, `setCanaryScale {matchTrafficWeight: true}`. The canary is sized for W% (at least 2 pods) before traffic moves, the dark-tested pods stay up, and from there the canary follows the weight.

- **`tests-dark`.** The chart renders `<environment>-<fullName>-tests-dark` for the leader only. It is the `tests` Job (see Analysis, `tests`: the same request, Job, timeout, image and failure handling) with two differences: `ServiceAddress` is the leader's stable Service, `http://<fullName>.<namespace>.svc.cluster.local:<port>` (a definition's own `serviceAddress` follows the `tests` rules, with the stable Service in place of `-preview`), and `TestEnvironmentVariables.RequestHeaders` is `{"X-MyCarrier-Canary": "<global.correlationId, lower-cased>"}`, so the test pods' requests take the header route to the canary. `RunKind` is `canary` and `SlipStep` is `none`. Like `tests`, it renders in every environment; only where the steps render does a step run it.
- **The leader needs test definitions.** The leader (see the leader rule above) must have `testtrigger.testdefinitions` in every environment where it is a canary Rollout, also where the steps do not render, or the render fails. The other ways out are its own `tests-dark` entry under `analysisTemplates`, which replaces the chart's, or `dark: false`. Test definitions usually live in `deployment/values.{env}.yaml`: give the leader definitions in each environment's file, or set `dark: false` in the environments that have none (Layout A in `helm/values.{env}.yaml`, Layout B in the `global` of that environment's `environments[]` entry). Followers need none.
- **TestEngine.** The prod TestEngine must run with `RUN_KINDS_ENABLED=true`, which the DEVOPS-321 pilot turns on. Until then the leader's `tests-dark` sends no request and fails with a message that names `RUN_KINDS_ENABLED` and `dark: false`, and the release aborts at the dark stage. testengine-dev runs with it on.
- **`tests` at the weight steps.** `tests` in `analysis.templates` fails the render while the dark stage is on; set `dark: false` with it until Q54 is resolved (see Analysis, `tests`).
- **Timing.** `dark-passed` defaults to 15m so that the leader's suite (573 s with the default `tests.timeout` and `startupSeconds`) fits in the followers' wait; with two or more canary Rollouts the render fails when it does not (see Analysis, Barrier window). `progressDeadlineSeconds` defaults to 1200 on canary Rollouts that render the dark stage (coordinator on, `dark: true` and a preset), in every environment, above every barrier timeout; it stays 600 with `dark: false`, where the default barrier timeouts (9m) sit below it, and with an explicit `steps` list, whose own barrier timeouts are checked against it, with `coordinator.enabled: false`, where it counts in the budget for each weight step, and on Rollouts whose property is not `canary`. `manualTimeout` defaults to 40m so that the `manual` leader fits the 5700 s budget limit (see the budget table).
- **Canary pod floor.** Every canary Rollout renders `minPodsPerReplicaSet: 2` (other Rollouts keep 1), in every environment and with `dark: false` too: Argo Rollouts sizes the canary max(ceil(weight x replicas / 100), 2) pods at each weight, never more than the Rollout's replicas. Where the steps render, a canary Rollout whose minimum is below 2 fails the render: `autoscaling.minReplicas` with the HPA, `keda.idleReplicaCount` with KEDA when it is set (KEDA scales the Rollout to it while its triggers are idle, and Argo Rollouts never sizes the canary above the Rollout's replicas, so the canary drops to 0 pods; remove it), else `keda.minReplicaCount`, else `replicas`; with the top-level `scaling` value and neither autoscaler the minimum counts as 1 (the Rollout renders no replicas, and Argo Rollouts runs 1). Prod defaults to 2. `dev` and `feature<N>` default to 1, so a drill there with `stepsOutsideProd` sets `replicas: 2` or an autoscaler minimum of 2.
- **Canary-to-canary routes.** Where the steps render, the coordinator is on and the steps move in lock-step (a preset, or an explicit `steps` list with a canary-coordinator barrier between every two `setWeight` steps), a canary pod of the release that calls another application of the release reaches that application's canary, during the dark stage and at every weight, so the leader's one dark run reaches every canary of the release. The Rollout labels its canary pods `mycarrier.tech/rollout-role: canary` and its stable pods `stable` (`canaryMetadata` and `stableMetadata`), and its VirtualService gets a `<route>-canary-source` route right before each route that has the `-preview` destination and no `fault` or `redirect`. The source route has the original's matches (one match when the original has none), each also requiring, through `sourceLabels`, a caller whose pod is labelled `mycarrier.tech/rollout-role: canary` and carries the release's `mycarrier.tech/correlationId` label as the pod renders it (the id's own case, cut to 63 characters). Its matches carry no `gateways`: the chart removes the `gateways` of every match it copies, because Istio skips `sourceLabels` on a match that sets `gateways`, so a source route with `gateways: [mesh]` would take every in-mesh caller to the canary. An ingress gateway's pod is never a canary pod of the release, so it never takes a source route. It sends the request to the original's `-preview` destination and keeps every other field of the original. A match whose own `gateways` leave out `mesh` (an ingress-only custom route under `networking.istio.routes`) is left out of the source route, and a route with no other match gets none, because an in-mesh caller never matches it. Blocked paths (the `-forbidden` route's 403), redirects, ingress-only matches and routes to other hosts answer a canary caller as they answer a stable one. Argo Rollouts does not manage these routes, and Argo CD keeps them in sync from git. They also render with `dark: false`, and not with the coordinator off, with an explicit `steps` list that lacks a canary-coordinator barrier between two `setWeight` steps, where the steps do not render, on Rollouts whose property is not `canary`, on Deployments or StatefulSets, or in the shared multi-frontend VirtualService. They need the coordinator's barriers between weights for load proportionality: with them the release's Rollouts move through the same weights in lock-step; without them a caller can be at 50% while its callee is at 10%, and the source routes would send the caller canary's whole share to a callee canary sized for 10%, so with the coordinator off, or an explicit `steps` list without those barriers, canary callers reach stable. A preset has a barrier after each weight; an explicit `steps` list gets the routes only when it has a canary-coordinator barrier between every two `setWeight` steps, as a preset does.
- **Source routes match on source labels only.** mycarrier-helm 4.7.13 rendered each source route match with `gateways: [mesh]`. Istio ignores `sourceLabels` on such a match, so from the moment a Rollout's `-preview` Service switched to the canary, every in-mesh caller, stable pods and pods outside the release included, reached that canary, whatever the weight. The release after 4.7.13 renders the matches with `sourceLabels` and no `gateways`. This is a fix, not a breaking change: nothing to set.
- **Load on a callee's canary.** At weight W, a callee's canary receives about W x (2 - W) of the traffic its callers in the release send it: the caller canary's share W through the source route, plus W of the caller stable's share by weight. Its pods are sized for W (at least 2), so it carries about 1.9 times its weight's share at 10%, 1.75 times at 25% and 1.5 times at 50%. The factor compounds down a call chain (A calls B calls C), an HPA that averages over all pods does not correct it, and at small replica counts the 2-pod floor absorbs it. The chart does not size for it; the DEVOPS-321 pilot watches canary pod CPU and latency against stable on callees that take most of their traffic from a sibling.
- **Multi-frontend.** A frontend Rollout in a multi-frontend release fails to render while the dark stage is on, in every environment: the header route would also go into the shared `<primary>-multifrontend` VirtualService, where it matches every path. Set `dark: false` for such a release.
- **What stays exposed.** A call that leaves the mesh (the public host, the ingress gateway, KrakenD) reaches the callee's stable pods, also from a canary pod. The `canary-header` route has no gateway restriction, so during the dark stage a public request that carries the release's correlation id in `X-MyCarrier-Canary` reaches the canary through ingress (an accepted risk). When one Rollout of the release aborts, for up to about 30 s (`abortScaleDownDelaySeconds`) the other Rollouts' canary pods that call it reach its aborted canary pods or its stable pods, then its stable pods: Argo Rollouts points its `-preview` Service back at stable, after pointing it at the aborted canary while that still has available pods. Every canary Rollout runs `darkReplicas` pods through the whole dark window, and the dark stage gates header-tagged HTTP traffic only: a canary Rollout that consumes a queue (a KEDA or Service Bus worker) does real work from those pods before the suite has passed, and its HTTP calls to the release's other canary Rollouts reach their canaries, still untested, through the source routes.
- **Rollback.** `dark: false` turns the dark stage off and leaves the canary pod floor and the canary-to-canary routes on; they go only with the chart version.


| Environment | What a Rollout needs |
|-------------|----------------------|
| Every environment | Istio left on (`networking.istio.enabled`, `istioDisabled`, `service.istioDisabled`), no `service.aliases`, no custom route whose `destination` is the application's own Service, and no two routes with the same name that reach it |
| `feature<N>` | `networking.istio.offloadOperatorEnabled: false` and `networking.istio.offloadVSEnabled: false` (on the primary frontend too, in a multi-frontend release) |
| `dev` | `networking.istio.offloadOperatorEnabled: false`, which deletes the application's dev VirtualService until Argo CD self-heals — try Rollouts in a feature environment instead |

The chart fails the render when one of these is missing.

**Migrations.** A database migration runs in one of two ways. A migrator that runs to completion and exits goes in `jobs` with `timing: pre-deploy`: Argo CD runs the Job as a PreSync hook (or, with `runAsHook: false`, as a plain wave-0 resource that runs once per release), ahead of the workloads (sync wave 10), and waits for it to complete, so the migration finishes before any Deployment, StatefulSet or Rollout of the release is updated, and a failed Job fails the sync; it has no port and gets no canary steps. A long-running migrator application, which runs the migration when it starts and keeps running (like a worker), is an entry under `applications`; with `deploymentType: rollout` it takes part in the canary like any other Rollout, so give it an HTTP port and a health path for the health check (see Analysis), and set `networking.istio.externalEnabled: false` so that only in-cluster callers reach the pod that holds the database credentials. It gives no start order: it syncs in wave 10 with every Deployment, StatefulSet and Rollout, so their new pods start alongside it and can serve before the migration finishes. With the coordinator on (the default) the release moves in lockstep and an abort stops all of it; with `coordinator.enabled: false` each Rollout runs its own steps, so a migrator Rollout that aborts does not stop the others from promoting. The default readiness probe is a TCP check that passes once the port opens, so it does not catch a migration that fails while the process keeps running. Use it only when the migrator's readiness waits for its migration and every other application's readiness waits for the schema version it needs (`probes.readinessProbe`): keep the port, startup and liveness probes answering while the migration runs, and set `applications.<app>.progressDeadlineSeconds` above the longest migration on every Rollout whose readiness waits for it, or that Rollout aborts. With the coordinator on, a Rollout whose schema is already in place (its readiness does not wait) reaches the next barrier first and waits there for the migrator; that wait counts toward its own progress deadline and is capped by `coordinator.barrierTimeouts` (9m by default, `dark-passed` 15m), so a longer migration aborts the whole release. Raise the barrier timeouts above the longest migration, and `applications.<app>.progressDeadlineSeconds` above them on every Rollout of the release, not only the ones that wait (the chart fails the render when a barrier timeout reaches a Rollout's deadline); a longer deadline also delays the abort of a stuck canary pod, so keep it as low as the migration allows. Each barrier timeout also counts in the canary budget, which must stay at or below 5700 s (see What the release reads): the `standard` preset fits barrier timeouts of up to 10m each with the dark stage (`dark-passed` at its 15m), and up to 18m each with `dark: false`. Otherwise use the pre-deploy job. Either way, a migration must stay compatible with the previous version, whose pods keep running against the migrated schema, so an abort or a revert needs no database rollback. Applications with `migration` in the name are left out of automatic HPA (see [HPA](#hpa-horizontal-pod-autoscaler)).

### Switching between Deployment and Rollout

Never change `deploymentType` in one release: Argo CD prunes the old workload before any new pod is ready, which is an outage. Switch in two releases, in either direction, with `migratingToRollouts`:

| Direction | Release 1 | Release 2 |
|-----------|-----------|-----------|
| Deployment → Rollout | `deploymentType: rollout` and `migratingToRollouts: true` | Remove `migratingToRollouts`: the Rollout gets its own pod template, and, when the repository's `deployment-strategy` property is `canary`, the canary from `global.strategy.canary` (its steps in prod only; elsewhere it promotes at once); Argo CD prunes the Deployment |
| Rollout → Deployment | `deploymentType: deployment` and `migratingToRollouts: true` | Remove `migratingToRollouts`: Argo CD prunes the Rollout |

In release 1 the chart renders both workloads: the Rollout borrows the Deployment's pod template (`workloadRef` with `scaleDown: never`) and a bare canary, both sets of pods serve behind the existing Services, and the HPA/KEDA autoscaler targets the workload `deploymentType` names.

Before release 1:
- The application must sync without app-level `Replace=true`. mc-environment 0.3.0 and later sync without it; feature environments from the legacy offload generator (`offloads.yaml`) still set it.
- The autoscaler must already be on. Turning HPA/KEDA on removes `replicas` from the manifest, so the workload drops to 1 pod until the autoscaler scales it; do that in an earlier release.

Before release 2:
- The incoming workload must have at least as many ready pods as the outgoing one, because release 2 prunes every outgoing pod at once. With HPA/KEDA, set the autoscaler minimum in release 1 to the outgoing workload's current pod count, and restore it in release 2.
- On the way in, wait until the Rollout's `availableReplicas` equals `spec.replicas`: until then the stable Service also selects release 2's canary pods.

`enableDebugMode` fails to render while `migratingToRollouts` is set: turn it off for both releases.

```yaml
# helm/values.yaml
global:
  appStack: myservice
  language: csharp
  strategy:
    canary:
      preset: standard                  # used from release 2, in prod; release 1 runs no canary steps

# helm/values.prod.yaml
environment:
  name: prod

# helm/deployment/values.yaml
applications:
  api:
    # Every environment reads this file. Dev and feature<N> values files must also set
    # networking.istio.offloadOperatorEnabled: false for api (see the table above), or keep
    # deploymentType: deployment here and make the switch in helm/deployment/values.prod.yaml.
    deploymentType: rollout             # release 1 of the switch to a Rollout
    migratingToRollouts: true           # remove in release 2
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/api
    ports:
      http: 8080

# helm/deployment/values.prod.yaml
applications:
  api:
    image:
      tag: release-v1.0.0
```

---

## Autoscaling

### HPA (Horizontal Pod Autoscaler)

HPA creation follows a strict precedence hierarchy:

1. **KEDA override**: If KEDA renders (`keda.enabled: true`, outside feature environments) → no HPA (KEDA wins)
2. **Per-app explicit**: `autoscaling.enabled: true` → always creates HPA
3. **Per-app force**: `autoscaling.forceAutoscaling: true` → creates HPA (even for migrations)
4. **Per-app force false**: `autoscaling.forceAutoscaling: false` → explicitly disables HPA
5. **Global override**: `global.forceAutoscaling: false` → blocks all automatic scaling
6. **Global force or automatic**: `global.forceAutoscaling: true`, or any environment other than `dev`, `preprod` and `feature<N>` (prod, qa, uat, …) → HPA for non-migration apps
7. **Otherwise**: no HPA

**Migration app protection**: Apps with "migration" in their name are excluded from step 6. Use `autoscaling.enabled: true` or `autoscaling.forceAutoscaling: true` to override.

**Default HPA values** (when HPA is created):
- `minReplicas`: `replicas`, or 2 when `replicas` is not set
- `maxReplicas`: `minReplicas` × 3
- `targetCPUUtilizationPercentage`: 80
- `targetMemoryUtilizationPercentage`: 80 (both metrics are always set)

```yaml
applications:
  api:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
      targetMemoryUtilizationPercentage: 80  # default
```

### Default Replica Counts (when HPA is NOT active)

| Environment | Default Replicas |
|-------------|------------------|
| `feature<N>` | 1 |
| `dev` | 1 |
| `preprod` | 2 |
| Any other environment (prod, qa, uat, …: migration apps, or HPA turned off) | 2 |

`replicas` overrides the default. When HPA **is** active, the `replicas` field is omitted from the Deployment and HPA manages scaling.

A canary Rollout (repository property `canary`) needs a minimum of at least 2 pods (`replicas`, or the HPA's `minReplicas` or KEDA's `minReplicaCount`, and no `keda.idleReplicaCount`) wherever its canary steps render, or the render fails (see [Rollouts](#rollouts), Dark stage, Canary pod floor). Prod's defaults meet it; a canary drill in `dev` or `feature<N>` sets 2.

### KEDA (Event-Driven Autoscaling)

KEDA scales based on Azure Service Bus message count. **HPA and KEDA are mutually exclusive per application.** Wherever KEDA renders (`keda.enabled: true` outside feature environments), no HPA is created regardless of any HPA settings.

KEDA does not render in feature environments (`feature<N>`): there the application gets no ScaledObject, and the HPA rules above apply as if KEDA were off. `autoscaling.enabled: true` (or a force setting) still creates an HPA; otherwise the application runs its static replica count.

A ScaledObject uses either the flat fields below (one trigger) or `keda.triggers` (a list, multiple triggers) — never both. See [Multiple Triggers](#multiple-triggers).

#### Queue-Based Scaling
```yaml
applications:
  worker:
    keda:
      enabled: true
      type: "queue"
      queueName: "my-queue-name"
      # clusterAuthRef auto-resolves: servicebus-connectionstring-<env>
      messageCount: 500                 # messages per replica threshold (default)
      pollingInterval: 30               # seconds between checks (default)
      cooldownPeriod: 300               # seconds before scale-down (default)
      minReplicaCount: 2                # default
      maxReplicaCount: 50               # default
```

#### Topic-Based Scaling
```yaml
applications:
  worker:
    keda:
      enabled: true
      type: "topic"
      topicName: "my-topic"
      subscriptionName: "my-subscription"
```

#### Scale-to-Zero
```yaml
applications:
  batch-worker:
    keda:
      enabled: true
      type: "queue"
      queueName: "batch-jobs"
      idleReplicaCount: 0               # scale to zero when idle
      minReplicaCount: 1
      activationMessageCount: 1         # messages needed to activate from zero
```

On a canary Rollout (repository property `canary`), `idleReplicaCount` fails the render wherever the canary steps render (prod, or `stepsOutsideProd`): KEDA scales the Rollout to it while its triggers are idle, and the canary would drop to 0 pods (see [Rollouts](#rollouts), Dark stage, Canary pod floor).

#### Multiple Triggers
A single ScaledObject can scale off more than one trigger — for example, a worker that drains a primary topic subscription and also needs to react to a dead-letter queue. Use `keda.triggers` (a list) instead of the flat `type`/`queueName`/`topicName`/`subscriptionName`/`messageCount`/`activationMessageCount` fields. The flat fields and `keda.triggers` are **mutually exclusive** — one application uses one shape or the other, never both.

```yaml
applications:
  order-worker:
    keda:
      enabled: true
      minReplicaCount: 6
      maxReplicaCount: 50
      triggers:
        - type: topic
          topicName: topic-name
          subscriptionName: subscription
          messageCount: 200
        - type: topic
          topicName: topic-name2
          subscriptionName: subscription2
          messageCount: 200
          activationMessageCount: 1          # optional, per trigger
          clusterAuthRef: other-cluster-auth # optional, per-trigger override
        - type: queue
          queueName: dead-letter-replay
          messageCount: 50
```

KEDA computes a desired replica count independently for each trigger, then scales the workload to the **maximum** of those results, clamped by the shared `minReplicaCount`/`maxReplicaCount`.

`minReplicaCount`, `maxReplicaCount`, `pollingInterval`, `cooldownPeriod`, `idleReplicaCount`, and `advanced` are always ScaledObject-level — set them once under `keda`, never inside a `triggers` item.

#### KEDA ClusterAuthRef Convention
The `clusterAuthRef` defaults automatically based on environment — no manual config needed:

| Environment | Value |
|-------------|-------|
| dev | `servicebus-connectionstring-dev` |
| preprod | `servicebus-connectionstring-preprod` |
| prod | `servicebus-connectionstring-prod` |
| any other environment | `servicebus-connectionstring-<environment name>` |

Set `keda.clusterAuthRef` to override the convention for every trigger, or set `clusterAuthRef` on one item in `keda.triggers` to override just that trigger. Each level falls back to the one above: trigger `clusterAuthRef` → `keda.clusterAuthRef` → `servicebus-connectionstring-<env>`.

#### KEDA Scaling Formula
```
desiredReplicas = ceil(activeMessageCount / messageCount)
```
Result is clamped between `minReplicaCount` and `maxReplicaCount`. With `keda.triggers`, this formula runs once per trigger and the maximum result across all triggers is used.

#### Advanced KEDA Scaling Policies
```yaml
    keda:
      enabled: true
      type: "queue"
      queueName: "orders"
      advanced:
        horizontalPodAutoscalerConfig:
          behavior:
            scaleDown:
              stabilizationWindowSeconds: 300
              policies:
                - type: Percent
                  value: 25
                  periodSeconds: 60
            scaleUp:
              policies:
                - type: Pods
                  value: 4
                  periodSeconds: 60
```

---

## Test Triggers

Test triggers configure ArgoCD **PostSync** hooks that call the TestEngine API to run automated tests after deployment. They are defined per-application in `deployment/values.{env}.yaml`.

```yaml
applications:
  api:
    testtrigger:
      activeDeadlineSeconds: "300"
      ttlSecondsAfterFinished: "3600"
      apikey: vault:DevOps/data/testengine/api#encoded_header
      enableV1: true
      testdefinitions:
        - containerImage: testing/myorg/myservice/tests
          containerTag: 1.0.0
          filters: ["TestCategory=CoreAPI"]
          name: apitests
          secretId: vault:QA/data/app_auth#SecretId
```

The trigger Job's pod carries the application's labels, except `app.kubernetes.io/name` and `app`, which are `<fullName>-trigger`. This keeps the pod from matching the application's Service and PDB selectors, and from being counted by its HPA.

### Test triggers of Rollouts in prod

A PostSync hook can fire at the start of a canary sync, after the last promote or after an abort, so it can test the wrong version. In prod, the chart therefore renders no hook Job for an application with `deploymentType: rollout` (without `migratingToRollouts`) while `global.deploymentStrategy` is `canary`. The release's rollout-watch starts the prod tests after the canary is promoted:

- With `testtrigger.enableV1: true` (the default), the chart renders the ConfigMap `<fullName>-prod-tests` in the application's namespace, labelled `mycarrier.tech/correlationId`. Its key `request.json` holds the TestEngine v1 request the hook would send (the same template renders both). rollout-watch posts it to TestEngine's v1 trigger once the release is promoted.
- With `enableV1: false`, the render fails: rollout-watch posts only v1 requests, so nothing would start the application's prod tests. Leave `enableV1` unset or `true` on every prod canary Rollout that has test definitions.
- rollout-watch posts with the shared key and its own TestEngine URL. `testtrigger.apikey` must be `vault:DevOps/data/testengine/api#encoded_header` or unset, or the render fails. `global.testengineWebhookUrl` must not be set in prod, or the render fails. Both rules apply only where the ConfigMap renders.
- The ConfigMap follows the repository's `deployment-strategy` property, which chart-renderer passes as `global.deploymentStrategy`. Only the canary release path (`deployment-strategy: canary`) runs rollout-watch, and only then does the chart render the ConfigMap in place of the hook.
- Other environments, Deployments, StatefulSets, applications with `migratingToRollouts` and Rollouts whose property is not `canary` keep the PostSync hook, unchanged.

### Test definitions in canary analysis

With `tests` in `global.strategy.canary.analysis.templates`, each analysis step of a canary Rollout (repository property `canary`, which chart-renderer passes as `global.deploymentStrategy`) also runs the application's test definitions against its `-preview` Service, and a failing suite aborts the canary (see [Rollouts](#rollouts), Analysis, `tests`). A Rollout whose property is not `canary` ignores `tests`. The hook and the prod-tests ConfigMap stay as they are. Every Rollout application of the release then needs `testdefinitions` in each environment where `tests` is listed. The canary run calls the `-preview` Service: a definition's `serviceAddress` must point at the application's own Service (or its `-preview` Service), with no port or the `http` Service port, and the run keeps its path; any other host or port fails the render. The run uses no `tolerations`, and `apikey` must be a `vault:` reference or unset. `tests` fails the render while the dark stage is on (the default), so a stack that lists it sets `dark: false` in the same place until Q54 is resolved; the dark stage instead runs the leader's test definitions once, at weight 0, against its stable Service with the canary header (`tests-dark`, see Rollouts, Dark stage), and then the leader needs `testdefinitions` in every environment. This example lists `tests` only in preprod, where the test definitions are, and turns the dark stage off there. With the property `canary`, preprod renders the template, and its Rollout runs no steps unless `stepsOutsideProd` is set; with any other property value, nothing of it renders. The property does not go in these files: chart-renderer passes it.

```yaml
# helm/values.yaml
global:
  appStack: myservice
  language: csharp
  # deploymentStrategy: canary      # not set here: chart-renderer passes the repository's deployment-strategy property

# helm/values.preprod.yaml
environment:
  name: preprod
global:
  strategy:
    canary:
      dark: false                       # tests needs the dark stage off until Q54; in dev and prod (dark stage on)
      #                                 # the leader (api) needs test definitions too, or dark: false there
      analysis:
        templates: [tests]              # the app's TestEngine suite in each analysis step (property canary only)
        tests:
          timeout: 7m                   # poll budget; the Job's activeDeadlineSeconds adds startupSeconds (120)

# helm/deployment/values.yaml
applications:
  api:
    deploymentType: rollout
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/api
    ports:
      http: 8080

# helm/deployment/values.preprod.yaml
applications:
  api:
    image:
      tag: release-v1.0.0
    testtrigger:
      apikey: vault:DevOps/data/testengine/api#encoded_header
      testdefinitions:
        - name: apitests
          containerImage: testing/myorg/myservice/tests
          containerTag: 1.0.0
          secretId: vault:QA/data/app_auth#SecretId
          filters: ["TestCategory=CoreAPI"]
```

### Test Trigger Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `activeDeadlineSeconds` | Max trigger job runtime in seconds | `"300"` |
| `ttlSecondsAfterFinished` | Job cleanup delay in seconds | `"3600"` |
| `apikey` | TestEngine API key (vault ref) | Required |
| `enableV1` | `true`: one request with every test definition to TestEngine's v1 API; `false`: one request per test definition to the legacy API, which is retired | `true` |
| `backoffLimit` | Retry count on failure | `0` |
| `resources` | Resource requests/limits for the trigger job pod | `100m`/`128Mi` requests, `500m`/`256Mi` limits |
| `testdefinitions[].containerImage` | Test container image | Required |
| `testdefinitions[].containerTag` | Test container tag | Required |
| `testdefinitions[].filters` | Test category filters: a list of strings or one string | `[]` (runs all) |
| `testdefinitions[].name` | Test name identifier | Required |
| `testdefinitions[].secretId` | Auth secret (vault ref) | Required |
| `testdefinitions[].serviceAddress` | Override target service address. With canary `tests`, it must point at the application's own Service (or its `-preview` Service), with no port or the `http` Service port: the canary run keeps its path on the `-preview` Service, and another host or port fails the render | Auto: `http://<fullname>.<ns>.svc.cluster.local:<ports.http>` |
| `testdefinitions[].additionalEnvVars` | Extra env vars for test container | `""` (format: `key1=value1;key2=value2`) |
| `testdefinitions[].resultsApiKey` | autotest-results-api key, as `AUTOTEST_RESULTS_API_KEY` on the test container: `vault:DevOps/data/autotestresults_api/api#key`, the key the results API reads. Must be a `vault:` reference: a literal value fails the render. Set together with `resultsApiUrl` | Not set |
| `testdefinitions[].resultsApiUrl` | autotest-results-api base URL, as `AUTOTEST_RESULTS_API_URL` on the test container: `vault:QA/data/autotestresults_api#url`, or an `https` URL under `mycarrier.tech` with no user info (the schema refuses anything else). Set together with `resultsApiKey`: one without the other fails the render. No default | Not set |
| `testdefinitions[].podResources` | Resource requests/limits for the test pod | `250m`/`1Gi` requests, `2000m`/`4Gi` limits |
| `testdefinitions[].hardenedSecurityContext` | Run the test pod non-root with a read-only root filesystem | `true` |

The chart picks the TestEngine URL itself (from Vault, by `enableV1` and the pipeline's Argo Events instance); there is no URL value to set. The hook never fails the sync: when a call to TestEngine fails, the trigger pod logs an `ERROR:` line with the HTTP status and still exits 0. The Job is deleted when it finishes, so if tests do not appear in TestEngine, check the trigger pod's log during the sync.

---

## CronJobs

```yaml
cronjobs:
  - name: nightly-cleanup
    schedule: "0 2 * * *"              # cron expression (required)
    timeZone: "America/New_York"       # optional timezone
    concurrencyPolicy: "Forbid"        # Allow | Forbid | Replace — set it: when omitted, Kubernetes allows overlapping runs
    suspend: false                     # temporarily disable the cronjob
    successfulJobsHistoryLimit: 3      # default 3
    failedJobsHistoryLimit: 1          # default 1
    startingDeadlineSeconds: 300
    activeDeadlineSeconds: 900
    backoffLimit: 2                    # default 0
    restartPolicy: "OnFailure"         # Never | OnFailure (default: Never)
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/cleanup
      tag: "1.0.0"
    command: ["/bin/sh"]               # one element: put everything else in args
    args: ["-c", "./cleanup.sh"]
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    env:                               # a map, like applications.<app>.env
      CLEANUP_DAYS: "90"
```

`command` renders correctly only with a single element; a multi-element `command` collapses into one string. In Layout B, CronJobs go in `environments[].cronjobs`.

A CronJob syncs in wave 10 with the workloads, after the pre-deploy jobs, so a schedule that fires during a release never runs the new image against the old schema. `jobs` with `timing: pre-deploy` are Argo CD PreSync hooks (they run on every sync, before anything else of the release is applied, so a ConfigMap or Secret the job reads through `configmap`, `useSecret`, `configMapName` or `secretName` must come from outside the release or be a PreSync hook with a lower wave: one from `extraObjects` is applied after the job, so the job reads the previous release's values, and on a first deploy it fails and blocks the sync; `secrets.mounted` is fine) and `timing: post-deploy` are PostSync hooks; `order` sorts jobs of the same timing. `runAsHook: false` (opt-out) keeps a job with `timing` a plain resource: it syncs in wave 0, ahead of the workloads, and runs once per release, when its manifest changes, not on every sync. Without `timing` a Job syncs in wave 0, ahead of the workloads. On a Rollout a PostSync hook can fire before promotion or after an abort, so do not use a post-deploy job to check a canary release.

---

## Alerts

mycarrier-helm renders a stack's Grafana alerting from `alerts:`: one alert rule group with the standard rules for the stack's language plus any additional rules, two contact points (general and Sev1) and a notification route. The management cluster applies them; application clusters do not. Alerts are off by default (`alerts.enabled: false`).

`alerts:` belongs to the stack, next to `secrets:`. Put the shared settings (`serviceName`, `displayName`, overrides, additional rules) in `helm/values.yaml`, and `alerts.enabled: true` only in the values file of the environment that alerts — prod. The queries read production telemetry and the resource names do not include the environment, so never enable alerts in more than one environment.

| Layout | Shared settings | `alerts.enabled: true` |
|--------|-----------------|------------------------|
| A (mycarrier-helm) | Top level of `helm/values.yaml` | Top level of `helm/values.prod.yaml` |
| B (mc-environment) | Top level of `helm/values.yaml` | Top level of `helm/deployment/values.prod.yaml`, next to `environments:` — never inside an `environments[]` entry, where the schema rejects it |

mc-environment passes `alerts` to every entry, so a values file that enables alerts must hold a single `environments` entry: the pipeline fails the render when more than one entry renders alerts.

```yaml
# helm/values.yaml
global:
  appStack: invoice
  language: csharp
alerts:
  serviceName: MC.Invoice
  displayName: Invoice
  standard:
    serverErrorRatio:
      threshold: 10
  filters:
    excludedPaths:
      - /api/v1/customer-health

# helm/values.prod.yaml
environment:
  name: prod
alerts:
  enabled: true

# helm/deployment/values.yaml
applications:
  api:
    deploymentType: deployment
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/invoice/api
    ports:
      http: 8080

# helm/deployment/values.prod.yaml
applications:
  api:
    image:
      tag: release-v1.0.0
```

The same stack with mc-environment:

```yaml
# helm/values.yaml
global:
  appStack: invoice
  language: csharp
alerts:
  serviceName: MC.Invoice
  displayName: Invoice

# helm/deployment/values.prod.yaml
environments:
  - name: prod
    applications:
      api:
        deploymentType: deployment
        image:
          registry: mycarrieracr.azurecr.io
          repository: appstack/invoice/api
          tag: release-v1.0.0
        ports:
          http: 8080
alerts:
  enabled: true
```

| Value | Default | Purpose |
|-------|---------|---------|
| `alerts.enabled` | `false` | Render the alerts (prod values file only) |
| `alerts.serviceName` | — | Required. HyperDX `ServiceName` prefix the queries match (`MC.Invoice` matches `MC.Invoice%`); lowercased, it is the route's `service` label |
| `alerts.displayName` | — | Required, letters and digits only. Names the resources (`invoice-alerts`, `invoice`, `invoice-sev1`), the contact points (`Invoice`, `Invoice Sev1`) and the rule uids |
| `alerts.interval` | `60s` | Rule group evaluation interval |
| `alerts.paused` | `false` | Pauses every standard and compact rule that does not set its own `paused` |
| `alerts.filters.excludedPaths` | `[]` | Paths left out of the alerts on the service's own HTTP responses (`serverErrorRatio`, `clientErrorRatio`, `serverErrorCount`, `http503Returned`): `url.path` values, or `http.route` values for nodejs |
| `alerts.standard.<key>` | Language defaults | Overrides of one standard alert (below) |
| `alerts.additional.<name>` | — | Additional rules (below) |
| `alerts.contactPoints.secretName` | `squadcast-webhooks` | Secret in `monitoring` holding the Squadcast webhook URLs |
| `alerts.contactPoints.secretKey` | `serviceName` lowercased | Key of the general webhook; the Sev1 contact point uses `<secretKey>-sev1` |
| `alerts.routing.routes` | `[]` | Extra child routes under the stack's notification route, after the Sev1 route |

The Squadcast webhooks must exist in Vault under the keys `<serviceName lowercased>` and `<serviceName lowercased>-sev1`, unless `alerts.contactPoints.secretKey` names other keys. The schema rejects unknown keys under `alerts`, except inside an additional rule.

### Standard alerts

`global.language` selects the standard alerts and their defaults:

| Key | Default title | Fires when | csharp | nodejs |
|-----|---------------|------------|--------|--------|
| `serverErrorRatio` | `[Sev1] <displayName> Server HTTP Errors > 30% in 5m` | 5xx responses exceed `threshold` percent of non-error responses | on | on |
| `clientErrorRatio` | `[Sev2] <displayName> Client HTTP Errors > 30% in 5m` | 4xx responses exceed `threshold` percent of non-error responses | on | on |
| `serverErrorCount` | `[Sev3] <displayName> HTTP Errors > 5 in 5m` | More than `threshold` 5xx responses | on | on |
| `http503Returned` | `[Sev1] <displayName> HTTP 503 Service Unavailable in 5m` | The service returned more than `threshold` 503s outside `probePaths` (default threshold 0: any 503) | on | off |
| `http503Received` | `[Sev2] <displayName> Dependency HTTP 503 in 5m` | The service received more than `threshold` 503s from dependencies outside `excludedHosts` (default threshold 0) | on | off |
| `nonHttpErrors` | `[Sev3] <displayName> Non HTTP Errors > 5 in 5m` | More than `threshold` error log lines outside the `apiServiceSuffix` service (default `Api`) | on | on, paused |

`python` and `go` stacks have no standard alerts: use `alerts.additional`. The render fails when `alerts.standard` is set for a language without standard alerts, and when alerts are enabled with no rule at all. There is no availability alert for any language: availability alerts come from Hyperping.

`alerts.standard.<key>` overrides that alert's defaults: `enabled`, `severity` (`sev1`, `sev2`, `sev3`), `threshold`, `for`, `title`, `paused`, `noDataState`, `execErrState`, and the alert's own `probePaths`, `excludedHosts` or `apiServiceSuffix`. An override replaces the default, including `false`, `0` and an empty list. Severity sets the `severity` label (`sev1` routes to the Sev1 contact point) and, unless `title` is set, the title's `[SevN]` prefix. Rule uids never change with severity or title, so Grafana keeps the rule's state, silences and history.

### Additional rules

`alerts.additional` is a map keyed by rule name. The compact form builds a ClickHouse rule like the standard ones; `title`, `severity` and `sql` are required:

```yaml
alerts:
  additional:
    smc3ParseErrors:
      title: "[Sev3] MC.Invoice.InboundIntegration.Worker SMC3 Parse Errors"
      severity: sev3
      sql: |
        SELECT COUNT(1)
        FROM hyperdx.prod_otel_logs
        WHERE ServiceName = 'MC.Invoice.InboundIntegration.Worker'
          AND SeverityText = 'Error'
          AND Timestamp > now() - INTERVAL 1 MINUTE
      condition:
        threshold: 1
        reducer: min
      for: 0m
      annotations:
        description: More than 1 SMC3 document parse error in the last minute.
```

Compact defaults: `uid` `<displayName lowercased>_<key in snake_case>`, `alertType` `<key in snake_case>`, `timeRange` 300 (seconds), `condition.type` `gt`, `condition.reducer` `last`, `for` `5m`, `noDataState` `OK`, `execErrState` `KeepLast`, `paused` `alerts.paused`. `labels` and `annotations` merge over the defaults.

The raw form, `alerts.additional.<name>.rule`, passes a Grafana `AlertRule` through unchanged; `uid`, `title`, `condition`, `data`, `for`, `noDataState` and `execErrState` are required. `enabled: false` on either form leaves the rule out. Rule uids must be unique and at most 40 characters of `[A-Za-z0-9_-]`; the render fails otherwise.

---

## OpenTelemetry

The chart configures OpenTelemetry for every container: `OTEL_*` environment variables that export to the node's collector, with `OTEL_SERVICE_NAME` set to `global.appStack`.

```yaml
disableOtelAutoinstrumentation: true   # true to disable, false to enable
```

| Value | Default | Effect |
|-------|---------|--------|
| `manualOtelConfig` | `false` | `true`: the chart injects nothing OpenTelemetry-related; supply your own `OTEL_*` values through `env` |
| `disableOtelAutoinstrumentation` | `true` (mc-environment entries: `false`) | `false`: the OpenTelemetry Operator auto-instruments `nodejs` and `python` applications. `csharp` and `go` get the `OTEL_*` settings only |

---

## ServiceMonitor (Prometheus)

A ServiceMonitor is per application. It scrapes the Service port named `metrics` at `/metrics`, so the application needs `ports.metrics` (or a `service.ports` entry named `metrics`):

```yaml
applications:
  api:
    ports:
      http: 8080
      metrics: 9090
    serviceMonitor:
      enabled: true                     # creates a Prometheus ServiceMonitor resource
      interval: 30s                     # default
```

---

## ArgoCD Integration

The chart uses ArgoCD sync waves and options for GitOps workflows:
- Sync waves order creation: VirtualServices `0`, Services `5`, workloads (Deployment, StatefulSet, Rollout) `10`, autoscalers (HPA, ScaledObject) `11`; mounted-secret `ExternalSecret`s run as `PreSync` hooks
- `SkipDryRunOnMissingResource=true` handles CRDs
- Test triggers run as `PostSync` hooks, except for Rollouts in prod that run canary steps, whose prod tests the release starts after promotion (see [Test triggers of Rollouts in prod](#test-triggers-of-rollouts-in-prod))
- Offloads use `ApplicationSet` generators for feature environments
- mc-environment's generated Applications sync with server-side apply and without `Replace=true` (since mc-environment 0.3.0), and ignore the Service and VirtualService fields Argo Rollouts manages

---

## Modifying Helm Configuration — Decision Guide

**First, identify the chart layout** (see [Identifying the Chart Layout](#identifying-the-chart-layout) above). Then use the correct column in the [Layout Comparison table](#layout-comparison--decision-guide).

### Quick Reference for Layout A (mycarrier-helm direct)

| Change Type | File to Edit |
|-------------|-------------|
| Add/remove a dependency (mongodb, redis, etc.) | `helm/values.yaml` → `global.dependencies` |
| Change appStack or language | `helm/values.yaml` → `global.appStack`, `global.language` |
| Add/change a global env var for all envs | `helm/values.yaml` → `global.env` |
| Add/change an env-specific URL or secret | `helm/values.{env}.yaml` → `global.env` or `secrets` |
| Add a new application/service | `helm/deployment/values.yaml` → `applications` |
| Change image tag for a deployment | `helm/deployment/values.{env}.yaml` → `applications.<app>.image.tag` |
| Add networking/ingress for an app in one env | `helm/deployment/values.{env}.yaml` → `applications.<app>.networking` |
| Add/modify test triggers | `helm/deployment/values.{env}.yaml` → `applications.<app>.testtrigger` |
| Configure HPA autoscaling | `helm/deployment/values.{env}.yaml` → `applications.<app>.autoscaling` |
| Configure KEDA autoscaling | `helm/deployment/values.{env}.yaml` → `applications.<app>.keda` |
| Add app-specific env var for one env | `helm/deployment/values.{env}.yaml` → `applications.<app>.env` |
| Add app-specific env var for all envs | `helm/deployment/values.yaml` → `applications.<app>.env` |
| Add a CronJob | `helm/values.yaml` or `helm/values.{env}.yaml` → `cronjobs` |
| Configure alerts | `helm/values.yaml` → `alerts`; `helm/values.prod.yaml` → `alerts.enabled: true` |

### Quick Reference for Layout B (mc-environment wrapper)

| Change Type | File to Edit |
|-------------|-------------|
| Add/remove a dependency | `helm/values.yaml` → `global.dependencies` |
| Change appStack or language | `helm/values.yaml` → `global.appStack`, `global.language` |
| Add/change a global env var for all envs | `helm/values.yaml` → `global.env` |
| Add/change an env-specific URL or secret | `helm/deployment/values.{env}.yaml` → `environments[].global.env` or `environments[].secrets` |
| Add a new application/service | Each `environments[]` entry → `applications` |
| Change image tag for a deployment | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.image.tag` |
| Add networking/ingress for an app | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.networking` |
| Add/modify test triggers | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.testtrigger` |
| Configure autoscaling (HPA/KEDA) | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.autoscaling` or `keda` |
| Add a feature environment | New `helm/deployment/values.feature<N>.yaml` with its `environments[]` entry |
| Configure alerts | `helm/values.yaml` → `alerts`; `helm/deployment/values.prod.yaml` → top-level `alerts.enabled: true` |

### Deployment Pipeline
1. Changes are committed to the repository
2. CI/CD renders the merged values into the GitOps repository: the manifests for mycarrier-helm; an ApplicationSet per environment entry, plus the stack's alert resources, for mc-environment
3. ArgoCD deploys the rendered manifests to the target Kubernetes cluster (for mc-environment, each generated Application renders mycarrier-helm itself)
4. ArgoCD PostSync hooks run test triggers (if configured); for a canary Rollout in prod (property `canary`), the release starts them after the canary is promoted

---

## YAML Formatting Rules

- **Indentation**: 2 spaces (no tabs)
- **Strings**: Quote strings that contain special YAML characters or could be misinterpreted (e.g., `'dev:myservice:'`)
- **Booleans**: Use `true`/`false` (lowercase, unquoted)
- **Numbers in string context**: Quote when the value must remain a string (e.g., `"300"` for activeDeadlineSeconds)
- **Ordering**: Keep keys in the same order as existing files for consistency
- **Empty values**: Use `{}` for empty maps, `[]` for empty lists

---

## Validation Checklist

When reviewing or creating helm value changes:

1. **Environment consistency** — If adding an env var or secret to one environment, verify whether it should exist in all environments
2. **Secret paths** — Vault paths follow pattern `secrets/{env}/shared/{secret-name}` or `secrets/{env}/{appstack}/{secret-name}`
3. **Image tags** — All applications in a deployment file should typically use the same image tag (except prod which may use release tags like `release-v1.x.x`)
4. **POSIX env var names** — No hyphens, no dots, start with letter or underscore
5. **RedisKeyPrefix isolation** — Must include environment prefix: `'{env}:{appstack}:'`
6. **In-cluster vs external URLs** — Use cluster-internal URLs when the target service is in the same cluster
7. **Migration app naming** — Apps with "migration" in the name are excluded from automatic HPA
8. **Test trigger filters** — Must match environment-specific test categories
9. **No secrets in values** — All sensitive values must use Vault references
10. **HPA/KEDA mutual exclusivity** — Never configure both for the same application
11. **KEDA trigger shape** — Never mix the flat KEDA fields with `keda.triggers` for the same application
12. **Key names** — mycarrier-helm's schema rejects wrong types and invalid enum values, but not unknown or misspelled keys at the root or under `applications.<app>`: those render without error and do nothing. Check every key against this document (unknown keys are rejected only under `alerts` outside additional rules, and at the root and in `environments[]` entries of mc-environment)
13. **Layout B entries** — Each `helm/deployment/values.{env}.yaml` carries the environment's complete entry; nothing is merged from another file's entries
14. **Alerts** — `alerts.enabled: true` in exactly one environment's values file (prod), the shared settings in `helm/values.yaml`
15. **`allowAllEndpoints`** — Only in dev values (dev and feature environments); anywhere else the render fails
16. **Deployment ⇄ Rollout** — Never change `deploymentType` in one release; switch with `migratingToRollouts` over two releases
17. **Prod canary Rollout test triggers** — For a prod Rollout whose repository's `deployment-strategy` property is `canary`: `enableV1: true`, `apikey` unset or `vault:DevOps/data/testengine/api#encoded_header`, and no `global.testengineWebhookUrl`
18. **Canary steps outside prod** — Canary Rollouts (property `canary`) run their steps in prod only; `global.strategy.canary.stepsOutsideProd: true` only in the values of a test drill's environment, never in the shared `helm/values.yaml`
19. **Canary dark stage and pod floor** — For a stack whose repository property is `canary`: wherever the canary steps render (prod, or `stepsOutsideProd`; with the coordinator off or explicit `steps` too), each canary Rollout's minimum replicas is at least 2 (`autoscaling.minReplicas` with the HPA; with KEDA, `keda.minReplicaCount` and no `keda.idleReplicaCount`; else `replicas`, which counts as 1 with the top-level `scaling` value and no autoscaler). Where the dark stage renders (coordinator on, `dark: true`, a preset; every environment): `global.strategy.canary.leader` set when the release has two or more canary Rollouts; the leader has `testtrigger.testdefinitions` in every environment (or `dark: false` there); `tests` in `analysis.templates` only with `dark: false`; no `progressDeadlineSeconds` at or below 900; and `dark: false` for a multi-frontend release

---

## Breaking changes

Newest first. Each entry names the chart version, what broke, and what a stack's values must change.

### mycarrier-helm, the release after 4.7.12

The header-gated dark stage is on by default, the canary keeps at least 2 pods, and a release's canary pods call each other's canaries (DEVOPS-326). Only canary Rollouts change: `deploymentType: rollout` without `migratingToRollouts`, in a repository whose `deployment-strategy` property is `canary`. Deployments, StatefulSets, migrating Rollouts and Rollouts whose property is not `canary` render unchanged. No stack renders a canary Rollout today. See Rollouts, Dark stage.

- `global.strategy.canary.dark` defaults to `true` (was `false`), and `darkReplicas` to `2` (was `1`; below 2 now fails, in the schema and the render). With the coordinator on and a preset, every canary Rollout runs the dark stage where its steps render, and the leader runs the chart's new `<environment>-<fullName>-tests-dark` AnalysisTemplate: the `tests` Job sent to the leader's stable Service with `X-MyCarrier-Canary: <global.correlationId, lower-cased>`. The header route's value is now lower-cased too. To keep the earlier steps, set `dark: false`.
- With the dark stage on, in every environment, the render fails when: the release has two or more canary Rollouts and no `global.strategy.canary.leader`; the leader has no `testtrigger.testdefinitions` (and no `tests-dark` entry of its own under `analysisTemplates`); `tests` is in `analysis.templates` (until Q54); a frontend Rollout is in a multi-frontend release; or a barrier timeout reaches `progressDeadlineSeconds`, which now includes a stack's or an application's own `progressDeadlineSeconds` at or below 900 against `dark-passed`'s 15m. Add the leader and its test definitions, raise or remove `progressDeadlineSeconds`, or set `dark: false`.
- With the dark stage on and two or more canary Rollouts, the barrier window (see Analysis, Barrier window) is now checked at every barrier after an analysis step, `w10`, `w25` and `w50` included, in every environment, also without `tests` in `analysis.templates` (before, only with `tests` listed). A Rollout with a long analysis step, such as a `health` replacement or an extra template that runs a Job, can make a sibling wait at the barrier for its timeout or longer, and the render fails. For example, a `health` replacement Job with `count: 1` and `activeDeadlineSeconds: 600` can run 635 s at `w10`, and a sibling with the chart's `health` can end after 60 s: a 575 s wait against the 9m (540 s) barrier. Shorten that template's `count`, `interval` or `activeDeadlineSeconds`, raise `coordinator.barrierTimeouts` `w10`, `w25` and `w50` (each below `progressDeadlineSeconds`, the budget at or below 5700 s), or set `dark: false`.
- The prod TestEngine runs with `RUN_KINDS_ENABLED=false` until the DEVOPS-321 pilot. Until then a prod canary with the dark stage on fails at `tests-dark` and aborts; set `dark: false` for a prod canary before the pilot.
- Defaults that changed: `coordinator.barrierTimeouts.dark-passed` 15m (was 9m); `progressDeadlineSeconds` 1200 (was 600) on a canary Rollout that renders the dark stage (coordinator on, `dark: true` and a preset), in every environment (600 with `dark: false`, with an explicit `steps` list, with the coordinator off and on other Rollouts); `manualTimeout` 40m (was 1h). The budgets with the defaults are now, leader / follower: `standard` 5343 s / 4770 s, `fast` 3183 s / 2610 s, `manual` 5583 s / 5010 s (with `dark: false`: 3330 s, 1170 s and 3570 s; with the coordinator off: 3570 s, 1290 s and 3690 s). A stack that sets a barrier timeout or `tests.timeout` above its default, or `manualTimeout` above 40m (the old default and example value `1h` included: the `manual` leader then counts 6783 s), can now pass 5700 s and fail: lower it, or set `dark: false`.
- Every canary Rollout renders `minPodsPerReplicaSet: 2` (was 1), in every environment, with or without the dark stage. Where the steps render (prod, or `stepsOutsideProd`), a canary Rollout whose minimum (`autoscaling.minReplicas`, `keda.idleReplicaCount` when set, else `keda.minReplicaCount`, else `replicas`; 1 with the top-level `scaling` value and no autoscaler) is below 2 fails the render. Set it to 2 or more (remove `keda.idleReplicaCount`); a drill in `dev` or `feature<N>`, which default to 1 replica, sets `replicas: 2`.
- Where the steps render, the coordinator is on and the steps move in lock-step (a preset, or an explicit `steps` list with a canary-coordinator barrier between every two `setWeight` steps), canary Rollouts render `canaryMetadata`/`stableMetadata` labels (`mycarrier.tech/rollout-role`), and their VirtualServices a `<route>-canary-source` route before each route with the `-preview` destination, no `fault` or `redirect` and a match the mesh can reach, matched on the caller's canary label and correlation id inside the mesh, so a release's canary pods reach each other's canaries. Calls that leave the mesh still reach stable pods. Nothing to set.

### mycarrier-helm, the release after 4.7.11

`mycarrier.tech/canaryBudgetSeconds` now counts a `job` analysis template at its longest (DEVOPS-515): Argo Rollouts v1.10.0 can take ceil(sqrt(2 x `activeDeadlineSeconds`)) seconds to see a Job end, and it starts the next measurement only an interval after that. Only canary Rollouts (repository property `canary`) with a `job` template under `applications.<app>.analysisTemplates` (an extra template, a replacement `health` or `tests`, or `tests-dark`) change; no stack runs a canary Rollout today.

- A `job` template with `count` 1 now counts `activeDeadlineSeconds` + ceil(sqrt(2 x `activeDeadlineSeconds`)), for example 600 + 35 = 635 s.
- A `job` template with `count` n of 2 or more now counts at least n x (`activeDeadlineSeconds` + ceil(sqrt(2 x `activeDeadlineSeconds`))) + (n - 1) x `interval`. A `standard`-preset stack with a `smoke` Job of `count: 2`, `interval: 1m` and `activeDeadlineSeconds: 400` goes from 5460 s to 5814 s.
- A budget above 5700 s fails the render, so a stack near the cap can now fail. Lower that template's `count`, `interval` or `activeDeadlineSeconds`, or lower `coordinator.barrierTimeouts` or `manualTimeout`. An explicit `steps` list states its own `budgetSeconds`: recount it by the same rules.

### mycarrier-helm, the release after 4.7.10

A Rollout runs canary steps only when the repository's `deployment-strategy` property is `canary` (DEVOPS-310). chart-renderer passes the property as `global.deploymentStrategy`; mc-environment forwards it. Deployment and StatefulSet applications, and migrating Rollouts, render unchanged.

- A Rollout (`deploymentType: rollout` without `migratingToRollouts`) in a repository whose property is `rolling` or unset, or rendered by a path that does not pass it (offloads), now renders without canary steps, in every environment: no steps (not even `steps: []`), analysis, barriers, dark stage, `managedRoutes`, chart AnalysisTemplates, prod `<environment>-<fullName>-alerts` ExternalSecret or `mycarrier.tech/rolloutGroupSize`, `bakeMinutes` and `canaryBudgetSeconds` annotations, and `stepsOutsideProd` does not change that. It keeps the same Services, VirtualService and `trafficRouting`, and in prod its PostSync test hook instead of the `<fullName>-prod-tests` ConfigMap. To keep the canary, set the repository's `deployment-strategy` property to `canary`; its steps then render as on 4.7.10 (in prod, or with `stepsOutsideProd`). No values change.

### mycarrier-helm 4.7.10

Canary steps render only in prod (Q52, DEVOPS-516). Prod renders unchanged, and Deployment and StatefulSet applications render unchanged.

- Outside prod, a canary Rollout (`deploymentType: rollout` without `migratingToRollouts`; since the release after 4.7.10, also with the property `canary`) renders `steps: []`, and Argo Rollouts promotes the new version at once. It renders no barriers, analysis steps, pauses, dark stage, background analysis or `mycarrier.tech/canaryBudgetSeconds`, with a preset or with explicit `steps`. The Services, the Istio traffic routing, `rollbackWindow`, `mycarrier.tech/rolloutGroupSize`, `mycarrier.tech/bakeMinutes` and the chart's `health` AnalysisTemplate stay. To run the steps outside prod for a test drill, set `global.strategy.canary.stepsOutsideProd: true` (new, default `false`) in that environment's values only. The 4.7.9 schema refuses the key ("additional properties not allowed"), so set it only once the deploy-core pin has moved past 4.7.9 to 4.7.10 or later.
- A replacement `alerts` entry under `applications.<app>.analysisTemplates` no longer runs as background analysis outside prod. Set `stepsOutsideProd: true` where it must run. The chart's own `alerts` check stays prod only.
- Outside prod without `stepsOutsideProd`, `global.correlationId` for the coordinator is no longer required. Nothing to change. Every other render check still fails the render in every environment, as on 4.7.9: the health path, the analysis opt-outs, extra templates, barrier timeouts, the leader rule with the leader's `tests-dark`, `budgetSeconds` for explicit `steps`, the budget limit and `manualTimeout`.

### mycarrier-helm 4.7.9

Canary analysis is mandatory for every Rollout, and Rollouts carry the contract the release's rollout-watch reads (DEVOPS-312, DEVOPS-319). Deployment and StatefulSet applications render unchanged, except for the `testtrigger.enableV1` default (last item) and where the first two items below, the `bakeMinutes` cap or the prod test-trigger rules fail the whole render.

- `global.strategy.canary.analysis.enabled` is deprecated. `false` fails the render in every environment, with or without Rollouts. `true` has no effect. Remove it. To leave out one check, set `analysis.health.enabled: false` or `analysis.alerts.enabled: false`.
- `analysis.templates` now lists only extra templates, and defaults to `[]` (4.7.5 to 4.7.8 defaulted to `[health, alerts]`). Listing `health` or `alerts` fails the render in every environment. Remove them: both run unless opted out.
- With `analysis.health.enabled: false`, `analysis.alerts.enabled: false` and no extra template in `analysis.templates`, every Rollout fails to render, in every environment, with preset or explicit `steps`. Keep one check on, or list an extra template.
- Every Rollout runs the chart's `health` check in each analysis step. Its path now comes from the liveness probe only: `canaryHealthPath`, else `analysis.health.path`, else the `httpGet` path of `probes.livenessProbe` or of the default liveness probe. Readiness and startup probes are no longer used. A Rollout whose liveness probe is not HTTP fails to render; this includes every non-csharp application with default probes. Set `applications.<app>.canaryHealthPath` or `analysis.health.path`, give the application an `httpGet` liveness probe, or set `analysis.health.enabled: false`.
- csharp applications with default probes: the health check now calls `/liveness` (the default liveness probe) instead of `/health` (the default startup probe). Nothing to set. To keep `/health`, set `canaryHealthPath: /health`.
- In prod, every Rollout runs the chart's `alerts` check as background analysis. Its service label is `analysis.alerts.service`, else `alerts.serviceName` lower-cased, else `global.appStack` lower-cased (new; the default `app` counts as unset). With none of them set, the render fails in prod: set one, or set `analysis.alerts.enabled: false`. `dryRun` stays `true`, but `alert-rules` is always live: the first prod canary aborts when no alert rule that can fire carries the label. Check the label against the service's Grafana alert rules before the first prod release, and see Rollouts, Analysis, Before the first prod canary.
- `coordinator.enabled` defaults to `true` (was `false`). Every preset now starts with a `start` barrier and gets a barrier after each weight. `global.correlationId` is now required for every Rollout; the pipeline sets it. Set `coordinator.enabled: false` to render without it, or where the canary-coordinator plugin is not on the cluster.
- `dark` defaults to `false` (was `true`) until the chart renders `tests-dark` (DEVOPS-326). To keep the dark stage, set `dark: true`. The leader's `tests-dark` step now renders whenever the dark stage does (before, it needed `analysis.enabled`), so a `tests-dark` AnalysisTemplate must render for the leader.
- Every Rollout that runs canary steps carries `mycarrier.tech/bakeMinutes` from `bakeMinutes` (default `30`), in every environment. `bakeMinutes` above `100` now fails every render, with or without Rollouts. Set it to `100` or less.
- Every Rollout that runs canary steps carries `mycarrier.tech/canaryBudgetSeconds`, the worst-case length of its steps, in every environment. An explicit `steps` list now needs `budgetSeconds`, or the Rollout fails to render. Set it to the steps' worst-case length in seconds, from `1` to `5700`. With a preset, the chart computes the budget and ignores `budgetSeconds`.
- A canary budget above 5700 s now fails the render. The `manual` preset with `dark: true` adds up to at least 5850 s with the defaults, and the `standard` preset fails with barrier timeouts of 19m each. Lower `manualTimeout`, the barrier timeouts, or the analysis templates' `count` or `interval`.
- The `manual` preset's pause now counts as `manualTimeout` (new, default `1h`) in the budget; the pause itself still has no time limit. With the `manual` preset, a zero `manualTimeout` fails the render, and the schema refuses a value that is not a duration such as `90s`, `30m` or `1h`. Set it to the time a person needs to promote or abort the canary.
- In prod, a Rollout (without `migratingToRollouts`) whose repository's `deployment-strategy` property is `canary` no longer renders its `<fullName>-trigger` PostSync hook Job. With `testtrigger.enableV1: true`, it renders the ConfigMap `<fullName>-prod-tests` instead, and the release's rollout-watch starts its prod tests after promotion. With `enableV1: false`, the render fails: remove it. A prod Rollout whose property is not `canary` keeps its PostSync hook.
- In prod, a Rollout whose test trigger has `enableV1: true` fails to render when `testtrigger.apikey` is set to a key other than `vault:DevOps/data/testengine/api#encoded_header`, or when `global.testengineWebhookUrl` is set. Remove the key or set the shared one, and remove `global.testengineWebhookUrl`.
- `testtrigger.enableV1` now defaults to `true`, because TestEngine's legacy API is retired. A test trigger that did not set it now sends one request with every test definition to TestEngine's v1 API, instead of one request per definition to the legacy API. No values change is needed; `enableV1: false` keeps the legacy API, but a Rollout in prod whose repository's `deployment-strategy` property is `canary` fails to render with it.

### mycarrier-helm 4.7.7

Not breaking; recorded because it changes 4.7.6's behaviour.

- The chart's `alerts` template renders in prod only; 4.7.5 and 4.7.6 also rendered it in preprod. Canaries run only in prod, and a preprod canary is a test drill that no longer needs a service label or rules labelled `environment: preprod`.

### mycarrier-helm 4.7.6

Not breaking; recorded because it changes 4.7.5's behaviour.

- `alert-rules` now passes and logs `SKIPPED` on a Grafana outage (5xx, 429, timeout, network or TLS error, a body that is not JSON); 4xx, redirects, an empty token and a JSON answer of the wrong shape still fail. Either of its two runs failing now fails the check (it was both), and the Job retries a failed pod once.

### mycarrier-helm 4.7.5

Rollouts with `analysis.enabled` in prod and preprod; other environments and other applications render unchanged.

- `global.strategy.canary.analysis.templates` defaults to `[health, alerts]` (was `[health]`). In prod and preprod, `alerts` needs the service label of the service's Grafana alert rules: set `global.strategy.canary.analysis.alerts.service` (the lower-cased repository name, or its alias, such as `mycarrier` for MC.MyCarrier), or `alerts.serviceName`. Otherwise the render fails. To keep the previous behaviour, set `templates: [health]`.
- `alerts` runs as background analysis. `analysis.alerts.dryRun` (default `true`) covers only its firing-alerts metric, which fails no canary until a stack sets `dryRun: false`. Its `alert-rules` check is always live, whatever `dryRun` is set to: the canary aborts at the first weight when no alert rule that can fire matches the label (in preprod only rules labelled `environment: preprod` count), and also when the check cannot run: a Grafana error after retries, a rejected token (401 or 403), an empty Vault property, or a Job pod that cannot reach Grafana or finish within 180 s. An image that cannot be pulled pauses the canary. Fix the cause, or set `templates: [health]`. It adds an ExternalSecret in sync wave 8: when Vault cannot be read, the sync stops there.
- An `applications.<app>.analysisTemplates` entry named `alerts` (as the 4.7.4 entry suggested) no longer runs in each analysis step: it runs as background analysis from the first weight, in every environment. Set `count: 0` and an `interval` on it so it runs until promotion; with a `count` (default 1) it stops early.
- An explicit `count: 0` on an `applications.<app>.analysisTemplates` entry is now kept (it rendered as 1). With an `interval`, on an entry that an analysis step references, the render fails, because Argo Rollouts would leave the Rollout InvalidSpec; set a `count` above 0.
- Once `dryRun` is false, an alert that already fires when the release starts fails the canary. See Rollouts, Analysis.

### mycarrier-helm 4.7.4

Rollouts with `analysis.enabled`, and `applications.<app>.analysisTemplates`; other applications render unchanged.

- `global.strategy.canary.analysis.templates` defaults to `[health]` (was `[health, compare, alerts]`), and every listed template must render for each Rollout application, or the render fails. The chart renders `health`; remove `compare` and `alerts`, or define them under `applications.<app>.analysisTemplates`.
- The chart's `health` template calls `applications.<app>.canaryHealthPath` or else `global.strategy.canary.analysis.health.path` on the `http` port when one is set, and otherwise the path of the application's first HTTP probe (readiness, startup, then liveness, after the `global.language` defaults). An application with neither on a `-preview` Service port, such as a non-csharp application with default TCP probes, fails the render while `health` is listed. Set `canaryHealthPath` or `analysis.health.path`, add an `httpGet` probe under `probes`, or remove `health` from the list.
- With `coordinator.enabled`, `dark` (default `true`) and `analysis.enabled`, the leader fails to render until a `tests-dark` AnalysisTemplate renders for it (before, its Rollout went InvalidSpec); the chart does not render one yet. Set `dark: false`, or define `tests-dark` under `applications.<app>.analysisTemplates`.
- An `applications.<app>.analysisTemplates` entry with a key outside `name`, `count`, `failureLimit`, `interval`, `consecutiveErrorLimit` and `provider`, or a provider other than `web` or `job`, fails the render.
- `applications.<app>.analysisTemplates` no longer accepts the `job.container` shorthand, and no longer injects `RELEASE_ID`, `RELEASE_DEFINITION_NAME` or `BRANCH_NAME`. Canary tests run through TestEngine; give a full Argo Rollouts provider instead. The `web` shorthand now puts `successCondition` at metric level (it never applied before), calls `http://<fullName>-preview.<namespace>.svc.cluster.local:<Service port of http>/health` by default, and applies `statusEndpoint` without `url` too.

### mycarrier-helm 4.7.3

- With the coordinator and the dark stage on, a release with more than one `deploymentType: rollout` application fails to render until `global.strategy.canary.leader` names the application that runs the dark-stage suite (an application with `deploymentType: rollout` and without `migratingToRollouts`). Before, the first name in sort order was the leader. A leader that is set must name an application of the release, in every environment. A release with one Rollout application needs no change.
- `jobs` with `timing` are now real Argo CD hooks: the hook, sync-wave and hook-delete-policy annotations render on the Job's metadata instead of its pod template, where Argo CD ignored them. A `pre-deploy` job is a PreSync hook; a `post-deploy` job is a PostSync hook and now runs after the workloads instead of alongside the pre-deploy jobs. A hook runs on every sync operation (manual, self-heal, each retry), not only when its manifest changes, and Argo CD waits for it: make the job idempotent and safe to re-run, and keep `activeDeadlineSeconds` as short as the job allows, because a hung PreSync job holds the sync for that long. A ConfigMap or Secret the job reads from `extraObjects` is applied after a PreSync job (see CronJobs). To keep a job as it was (a plain wave-0 resource that runs once per manifest change), set `runAsHook: false` on it.
- `argocd.argoproj.io/hook`, `sync-wave` or `hook-delete-policy` under the `annotations` of a job with `timing` (unless `runAsHook: false`), or `argocd.argoproj.io/sync-wave` under `cronjobs[].annotations`, fails the render. Use `timing` and `order`.
- CronJobs sync in wave 10 with the workloads instead of wave 0.
- The endpoint allowlist now also applies to requests that carry the `environment` header (the frontend and the API gateway send it on every call); before, the header route reached every path. A prod audit of 7 days of traces found no served request outside its application's allowlist apart from calls that already failed. An application that needs a path outside its allowlist adds it to `networking.istio.allowedEndpoints`, or sets `networking.istio.enforceAllowlistOnEnvironmentHeader: false`.

### mycarrier-helm 4.7.0

Rollouts with `global.strategy.canary.coordinator.enabled` only.

- The header-gated dark stage (`dark`, default `true`) renders with the coordinator on. Set `dark: false` to keep the 4.6.0 steps. A frontend Rollout in a multi-frontend release fails to render unless `dark: false`.
- `coordinator.barrierTimeouts` default to 9m (were 10m, 15m and 30m), and a barrier timeout at or above `progressDeadlineSeconds` fails the render. Raise `progressDeadlineSeconds` for a longer barrier.

### mycarrier-helm 4.6.0

- An application whose name contains `migration` with `deploymentType: rollout` fails to render. Run the migrator through `jobs` with `timing: pre-deploy`. (4.7.3 lifts this for a long-running migrator application.)
- With `global.strategy.canary.coordinator.enabled`, `global.correlationId` is required.

### mycarrier-helm 4.5.0

Rollouts only; Deployment and StatefulSet applications render unchanged.

- `applications.<app>.updateStrategy.canary` fails to render on a Rollout. Remove it and set `global.strategy.canary`
  (`preset` or `steps`, `analysis`, `progressDeadlineSeconds`) instead; the chart renders the Services and the Istio
  routing.
- A Rollout fails to render with Istio off, with `service.aliases`, with a custom route whose `destination` is its own
  Service, or with two routes of the same name that reach it (for example a custom route key `canary`).
- In feature environments every Rollout needs `networking.istio.offloadVSEnabled: false`, on the primary frontend too
  in a multi-frontend release.
- AnalysisTemplates from `applications.<app>.analysisTemplates` are named `<environment>-<fullName>-<name>`.

### mycarrier-helm 4.4.0

- `updateStrategy.bluegreen` is removed and fails to render. Use `updateStrategy.canary` with
  `deploymentType: rollout`.
- `deploymentType: rollout` fails to render where the offload operator is on (the default in dev and feature
  environments). Set `networking.istio.offloadOperatorEnabled: false` there, and in feature environments with Istio
  traffic routing also `networking.istio.offloadVSEnabled: false`.
- `enableDebugMode` fails to render while `migratingToRollouts` is true. Turn it off for both releases of a switch
  between Deployment and Rollout.

### mycarrier-helm 4.2.0

- `networking.istio.allowAllEndpoints: true` fails to render outside dev and feature environments. Remove it from
  preprod, prod and every other environment's values (an explicit `false` is accepted) and list the paths in
  `networking.istio.allowedEndpoints` instead.

### mycarrier-helm 4.1.0

- Feature environments enforce the endpoint allowlist, as preprod and prod do: an application with one (every csharp
  application by default, and any application that sets `networking.istio.allowedEndpoints`) answers 403 there for
  every other path. The csharp defaults are `/liveness` and `/health` (exact), `/api` (prefix, only when the
  application's full name contains `api`) and `/swagger` (prefix). Add every other path the application serves on
  feature environments to `networking.istio.allowedEndpoints`, or set `networking.istio.allowAllEndpoints: true` in
  the dev or feature values.
