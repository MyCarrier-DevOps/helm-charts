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
1. Root-level `global` from `helm/values.yaml`, with `environments[].global` merged over it
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
| `applications`, `jobs`, `cronjobs`, `secrets`, `infrastructure`, `extraObjects` | Passed to mycarrier-helm unchanged | — |
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
| `networking.istio.internalEnabled` | `true` | The mesh-internal host described below |

**Endpoint allowlist.** When an application has an allowlist, the gateway answers every other path with a 403. A csharp application has one by default, built from: `/liveness` and `/health` (exact), `/api` (prefix, only when the application's full name contains `api`), and `/swagger` (prefix) in dev and feature environments only. `allowedEndpoints` entries are added after the defaults. A non-csharp application without `allowedEndpoints` has no allowlist. The allowlist is enforced in every environment except plain `dev`, including feature environments (since mycarrier-helm 4.1.0).

**`allowAllEndpoints`** is an escape hatch for dev and feature environments; prefer adding the path to `allowedEndpoints`. Setting it to `true` in any other environment fails the render (an explicit `false` is accepted everywhere), so keep it in the dev values file and out of shared ones. In Layout B, `values.dev.yaml` also serves feature environments that have no file of their own.

When Istio ingress is enabled, the chart also advertises mesh-internal DNS entries per application using the pattern `{appStack}-{application}.{environment}.internal` (not in feature environments). In dev, these support header-based routing to feature namespaces via the `environment` request header.

### Probes
Every application with `ports` gets default probes on its `http` port (or a port named `healthcheck`):

| Probe | `language: csharp` | Other languages |
|-------|--------------------|-----------------|
| Liveness | HTTP GET `/liveness` | TCP socket |
| Readiness | TCP socket | TCP socket |
| Startup | HTTP GET `/health` | TCP socket |

`probes.enableLiveness`, `probes.enableReadiness` and `probes.enableStartup` (all default `true`) turn a probe off. `probes.livenessProbe`, `probes.readinessProbe` and `probes.startupProbe` replace the default with a Kubernetes probe spec:
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

`deploymentType: rollout` deploys the application as an Argo Rollout with a canary strategy, plus a `<fullName>-preview` Service next to the `<fullName>` Service. `updateStrategy.canary` is passed to the Rollout unchanged as its canary strategy (Argo Rollouts fields such as `steps`); without it the Rollout gets `canary: {maxUnavailable: 0}`. Canary is the only strategy: `updateStrategy.bluegreen` fails to render. A Rollout's replica count and pod template follow the same rules as a Deployment's.

| Environment | What a Rollout needs |
|-------------|----------------------|
| prod, preprod and other non-dev environments | Nothing more |
| `feature<N>` | `networking.istio.offloadOperatorEnabled: false`; with `updateStrategy.canary.trafficRouting.istio`, also `networking.istio.offloadVSEnabled: false` |
| `dev` | `networking.istio.offloadOperatorEnabled: false`, which deletes the application's dev VirtualService until Argo CD self-heals — try Rollouts in a feature environment instead |

The chart fails the render when one of these is missing.

### Switching between Deployment and Rollout

Never change `deploymentType` in one release: Argo CD prunes the old workload before any new pod is ready, which is an outage. Switch in two releases, in either direction, with `migratingToRollouts`:

| Direction | Release 1 | Release 2 |
|-----------|-----------|-----------|
| Deployment → Rollout | `deploymentType: rollout` and `migratingToRollouts: true` | Remove `migratingToRollouts`: the Rollout gets its own pod template and `updateStrategy.canary`; Argo CD prunes the Deployment |
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
    updateStrategy:
      canary:                           # used from release 2
        steps:
          - setWeight: 25
          - pause: {duration: 10m}
          - setWeight: 50
          - pause: {duration: 10m}

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

### Test Trigger Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `activeDeadlineSeconds` | Max trigger job runtime in seconds | `"300"` |
| `ttlSecondsAfterFinished` | Job cleanup delay in seconds | `"3600"` |
| `apikey` | TestEngine API key (vault ref) | Required |
| `enableV1` | `true`: one request with every test definition to TestEngine's v1 API; `false`: one request per test definition to the legacy API | `false` |
| `backoffLimit` | Retry count on failure | `0` |
| `resources` | Resource requests/limits for the trigger job pod | `100m`/`128Mi` requests, `500m`/`256Mi` limits |
| `testdefinitions[].containerImage` | Test container image | Required |
| `testdefinitions[].containerTag` | Test container tag | Required |
| `testdefinitions[].filters` | Test category filters: a list of strings or one string | `[]` (runs all) |
| `testdefinitions[].name` | Test name identifier | Required |
| `testdefinitions[].secretId` | Auth secret (vault ref) | Required |
| `testdefinitions[].serviceAddress` | Override target service address | Auto: `http://<fullname>.<ns>.svc.cluster.local:<ports.http>` |
| `testdefinitions[].additionalEnvVars` | Extra env vars for test container | `""` (format: `key1=value1;key2=value2`) |
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
- Test triggers run as `PostSync` hooks
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
4. ArgoCD PostSync hooks run test triggers (if configured)

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

---

## Breaking changes

Newest first. Each entry names the chart version, what broke, and what a stack's values must change.

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
