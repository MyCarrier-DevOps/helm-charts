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

## Target Files
- These instructions apply specifically to Helm YAML files with pattern `helm/**/*.yaml`

---

## Identifying the Chart Layout

### How to detect which chart the repository uses

| Signal | **mycarrier-helm** (direct) | **mc-environment** (wrapper) |
|--------|----------------------------|------------------------------|
| `helm/deployment/values.yaml` root key | `applications:` | `environments:` |
| `helm/values.{env}.yaml` exists at root level | ✅ Yes | ❌ No (env config is inside `environments[]`) |
| `helm/deployment/values.{env}.yaml` root key | `applications:` | `environments:` |
| `helm/values.yaml` has `mycarrierChartVersion:` | ❌ No | Optional (may or may not be present) |

**Quick check**: Look at `helm/deployment/values.yaml`. If the root key is `applications:`, it's **mycarrier-helm**. If the root key is `environments:`, it's **mc-environment**. This is the most reliable signal — do not rely on the presence of `mycarrierChartVersion`.

---

## Layout A: mycarrier-helm (Direct)

Used when the repository deploys directly via ArgoCD without an ApplicationSet wrapper.

### File Structure

| File | Purpose | What belongs here |
|------|---------|-------------------|
| `/helm/values.yaml` | **Base values** — global settings, appStack, language, dependencies | `global.appStack`, `global.language`, `global.dependencies`, `serviceMonitor` |
| `/helm/values.{env}.yaml` | **Environment overrides** — env-specific URLs, secrets, Redis key prefixes | `global.env.*`, `environment.name`, `secrets`, `disableOtelAutoinstrumentation` |
| `/helm/deployment/values.yaml` | **Application definitions** — all deployable services (image, ports, securityContext) | `applications.*` with `image`, `ports`, `deploymentType`, `securityContext` |
| `/helm/deployment/values.{env}.yaml` | **Per-env deployment overrides** — image tags, networking, test triggers, app-level env vars | `applications.*.image.tag`, `applications.*.networking`, `applications.*.testtrigger`, `applications.*.env` |

Environments: `dev`, `preprod`, `prod` (and `feature-*` for offload branches).

### Merge Order (lowest → highest precedence)

```
helm/values.yaml                    ← global base
helm/values.{env}.yaml              ← environment overrides
helm/deployment/values.yaml         ← application base definitions
helm/deployment/values.{env}.yaml   ← environment-specific app overrides
```

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
| `/helm/values.yaml` | **Base values** — `global` (appStack, language, dependencies), optionally `mycarrierChartVersion` | `global.*`, optionally `mycarrierChartVersion` |
| `/helm/deployment/values.yaml` | **Base environment definition** — default/template environment entry | `environments: [{ name, global, environment, applications, secrets, ... }]` |
| `/helm/deployment/values.{env}.yaml` | **Per-env overrides** — full environment entry with env-specific config | `environments: [{ name, global, environment, applications, secrets, ... }]` |

**No `helm/values.{env}.yaml` files at root level** — all environment-specific config lives inside `environments[]` entries in the deployment files.

### Values Merge Logic

The mc-environment chart layers values for each environment entry:
1. Root-level `global` from `helm/values.yaml` (base for all environments)
2. `environments[].global` overrides (per-environment global overrides)
3. `environments[].applications`, `environments[].secrets`, etc. (per-environment app config)

The merged result is serialized into each ArgoCD `Application.spec.source.helm.values`.

### Optional: Chart Version Pin

Some mc-environment repositories pin the mycarrier-helm chart version in `helm/values.yaml`. When present, it controls the chart version used by all generated ArgoCD Applications. When absent, the chart version is managed by CI/CD.

```yaml
mycarrierChartVersion: "3.0.44"  # Pins the version of mycarrier-helm used by all generated Applications
```

### Example (Layout B)

```yaml
# helm/values.yaml
mycarrierChartVersion: "3.0.44"     # ← optional, some repos omit this
global:
  appStack: myservice
  language: csharp
  dependencies:                      # optional — omit if no infra dependencies needed
    mongodb: true
    redis: true
  env:
    LOG_LEVEL: info

# helm/deployment/values.yaml (base environment template)
environments:
  - name: dev
    global:
      env:
        RedisKeyPrefix: 'dev:myservice:'
        ServiceBusNamespace: "inf-dev-servicebus.servicebus.windows.net"
    environment:
      dependencyenv: dev
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
    environment:
      dependencyenv: prod
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

Each `environments[]` entry supports these additional fields beyond standard mycarrier-helm values:

| Property | Description | Default |
|----------|-------------|---------|
| `name` | Environment name (required) | — |
| `releaseName` | Override ArgoCD Application/release name | Auto-generated |
| `applicationName` | Explicit ArgoCD Application name | Auto-generated |
| `destinationNamespace` | Target Kubernetes namespace | Auto from env name |
| `helm.parameters` | Additional Helm `--set` parameters | `[]` |
| `helm.valueFiles` | Additional Helm value files to include | `[]` |
| `helm.version` | Override chart version for this env | `mycarrierChartVersion` |
| `annotations` | ArgoCD Application annotations | `{}` |
| `labels` | ArgoCD Application labels | `{}` |
| `syncPolicy` | ArgoCD sync policy overrides | Default sync policy |
| `infrastructure` | Azure infrastructure resources (Crossplane) | `{}` |

### mc-environment: Feature Environments

Feature environments are defined as additional entries in the `environments[]` array (e.g., `feature13`, `feature14`). They typically duplicate the dev config with the environment name changed:

```yaml
environments:
  # ... dev entry ...
  - name: feature13
    global:
      env:
        RedisKeyPrefix: 'feature13:myservice:'
    environment:
      dependencyenv: dev       # share dev dependencies
    applications:
      api:
        image:
          tag: "1.0.0-feature"
    # ... secrets usually shared with dev ...
```

---

## Layout Comparison — Decision Guide

| Change Type | Layout A (mycarrier-helm) | Layout B (mc-environment) |
|-------------|--------------------------|---------------------------|
| Add global env var for all envs | `helm/values.yaml` → `global.env` | `helm/values.yaml` → `global.env` |
| Add env-specific URL | `helm/values.{env}.yaml` → `global.env` | `helm/deployment/values.{env}.yaml` → `environments[].global.env` |
| Add a new application | `helm/deployment/values.yaml` → `applications` | `helm/deployment/values.yaml` → `environments[].applications` (each env) |
| Change image tag | `helm/deployment/values.{env}.yaml` → `applications.<app>.image.tag` | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.image.tag` |
| Add a secret | `helm/values.{env}.yaml` → `secrets` | `helm/deployment/values.{env}.yaml` → `environments[].secrets` |
| Add test triggers | `helm/deployment/values.{env}.yaml` → `applications.<app>.testtrigger` | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.testtrigger` |
| Change chart version | N/A (managed by CI/CD) | `helm/values.yaml` → `mycarrierChartVersion` |
| Add a feature environment | Handled via offload mechanism | Add new entry to `environments[]` |

---

## Global Configuration (Both Layouts)

The `global` block in `helm/values.yaml` is shared across both chart layouts. The following sections document `mycarrier-helm` values. In **Layout A**, these are set at root level. In **Layout B**, application/secret/environment values are nested inside `environments[]` entries but the same schema applies.

```yaml
# helm/values.yaml — global base (same shape for both layouts)
global:
  appStack: "myservice"              # Application stack name — used in resource naming
  language: "csharp"                 # Programming language: csharp | nodejs | java | python | nginx
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
  forceAutoscaling: false            # Optional — force HPA creation in all environments
  env: {}                            # Global env vars shared by all applications

environment:
  name: "dev"                        # Environment name: dev | preprod | prod | feature-*
  dependencyenv: "dev"               # Environment name for dependency resolution
  domainOverride:
    enabled: false
    domain: "example.com"

serviceMonitor: {}                   # Prometheus ServiceMonitor (set enabled: true to create)
disableOtelAutoinstrumentation: true # OpenTelemetry auto-instrumentation toggle
```

### Supported Dependencies
Set to `true` in `global.dependencies` to enable Vault secret injection and infrastructure wiring for: `mongodb`, `redis`, `azureservicebus`, `elasticsearch`, `postgres`, `sqlserver`, `clickhouse`, `redpanda`, `loadsure`, `chargify`.

---

## Domain Conventions

- **Dev/PreProd**: Services are hosted under `mycarrier.dev` domain
- **Prod**: Services are hosted under `mycarriertms.com` domain

## Service URL Patterns

Microservices follow predictable URL patterns based on environment:

### External URLs

| Environment | Pattern | Example |
|-------------|---------|---------|
| Dev | `https://{service}-{component}.dev.mycarrier.dev` | `https://address-api.dev.mycarrier.dev` |
| PreProd | `https://{service}-{component}.preprod.mycarrier.dev` | `https://address-api.preprod.mycarrier.dev` |
| Prod | `https://{service}-{component}.api.mycarriertms.com` | `https://address-api.api.mycarriertms.com` |

- Dev/PreProd URLs contain the environment name segment
- Prod URLs use `api` instead of an environment name

### In-Cluster (Kubernetes Internal) URLs
For inter-service communication within the same cluster:
Pattern: `http://{service}-{component}.{env}.svc.cluster.local`

Examples:
- `http://address-api.preprod.svc.cluster.local`
- `http://shipment-api.prod.svc.cluster.local`

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
| All apps, all envs | `helm/values.yaml` → `global.env` | Every container in every environment |
| All apps, one env | `helm/values.{env}.yaml` → `global.env` | Every container in that environment |
| One app, all envs | `helm/deployment/values.yaml` → `applications.<app>.env` | Only that application |
| One app, one env | `helm/deployment/values.{env}.yaml` → `applications.<app>.env` | Only that application in that environment |

App-level `env` overrides `global.env` for the same key.

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
      path: secrets/dev/shared/my-secret-name
```

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
        path: /app/certs
        subPath: cert.pem
```

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
  my-app:
    deploymentType: deployment          # deployment | statefulset | rollout
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/api
    ports:
      http: 8080
```

### Common Application Properties

| Property | Description | Default |
|----------|-------------|---------|
| `deploymentType` | `deployment`, `statefulset`, or `rollout` | Required |
| `image.registry` | Container registry | Required |
| `image.repository` | Image repository path | Required |
| `image.tag` | Image tag (typically set per-env) | Required in env files |
| `ports.http` | HTTP port the container listens on | Required |
| `ports.metrics` | Metrics port (Prometheus scraping) | Optional |
| `replicas` | Static replica count (ignored when HPA/KEDA active) | Env-dependent default |
| `resources.requests.cpu` | CPU request | Chart default |
| `resources.requests.memory` | Memory request | Chart default |
| `resources.limits.cpu` | CPU limit | Chart default |
| `resources.limits.memory` | Memory limit | Chart default |
| `securityContext` | Pod security context | `{}` |
| `env` | App-specific environment variables (key-value map) | `{}` |
| `labels` | Custom labels | `{}` |
| `annotations` | Custom annotations | `{}` |
| `isFrontend` | Whether this is a frontend application | `false` |
| `forceOffload` | Force offloading to separate ArgoCD ApplicationSet | `false` |
| `staticHostname` | Static hostname for feature envs (requires `isEnvironmentDeploy: true`) | None |
| `lifecycle.postStart` | Post-start hook command | `"echo postStartTest"` |
| `lifecycle.preStop` | Pre-stop hook command | Varies by language |

### Networking / Istio
```yaml
applications:
  api:
    networking:
      ingress:
        type: "istio"                   # istio | nginx | none
      istio:
        enabled: true
        hosts:
          - "myservice-api.dev.mycarrier.dev"
        allowedEndpoints:               # restrict which paths are exposed
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

When Istio ingress is enabled, the chart also advertises mesh-internal DNS entries per application using the pattern `{appStack}-{application}.{environment}.internal`. In dev, these support header-based routing to feature namespaces via the `environment` request header.

### Probes
C# applications (`language: csharp`) do **not** get default readiness/liveness probes from the chart. Non-C# applications get a default TCP socket probe. Configure custom probes explicitly when needed:
```yaml
applications:
  api:
    probes:
      liveness:
        enabled: true
        path: "/healthz"
        port: "http"
        initialDelaySeconds: 30
        periodSeconds: 10
      readiness:
        enabled: true
        path: "/readyz"
        port: "http"
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

## Autoscaling

### HPA (Horizontal Pod Autoscaler)

HPA creation follows a strict precedence hierarchy:

1. **KEDA override**: If `keda.enabled: true` → no HPA (KEDA wins)
2. **Per-app explicit**: `autoscaling.enabled: true` → always creates HPA
3. **Per-app force**: `autoscaling.forceAutoscaling: true` → creates HPA (even for migrations)
4. **Per-app force false**: `autoscaling.forceAutoscaling: false` → explicitly disables HPA
5. **Global override**: `global.forceAutoscaling: false` → blocks all auto-scaling
6. **Global force**: `global.forceAutoscaling: true` → HPA for non-migration apps in any env
7. **Auto prod**: Production environment (envScaling=1) → HPA for non-migration apps

**Migration app protection**: Apps with "migration" in their name are excluded from automatic production and global-force HPA. Use `autoscaling.enabled: true` or `autoscaling.forceAutoscaling: true` to override.

**Default HPA values** (when HPA is created):
- `minReplicas`: 2
- `maxReplicas`: 10
- `targetCPUUtilizationPercentage`: 80

```yaml
applications:
  api:
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
      targetMemoryUtilizationPercentage: 80  # optional
```

### Default Replica Counts (when HPA is NOT active)

| Environment | Default Replicas |
|-------------|------------------|
| `feature-*` | 1 |
| `dev` | 2 |
| `preprod` | 2 |
| `prod` (migration apps only) | 2 |

When HPA **is** active, the `replicas` field is omitted from the Deployment and HPA manages scaling.

### KEDA (Event-Driven Autoscaling)

KEDA scales based on Azure Service Bus message count. **HPA and KEDA are mutually exclusive per application.** When `keda.enabled` is true, HPA is never created regardless of any HPA settings.

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
| dev / feature | `servicebus-connectionstring-dev` |
| preprod | `servicebus-connectionstring-preprod` |
| prod | `servicebus-connectionstring-prod` |

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
      webhook_url: vault:DevOps/data/testengine/api#url
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
| `activeDeadlineSeconds` | Max job runtime in seconds | `"300"` |
| `ttlSecondsAfterFinished` | Job cleanup delay in seconds | `"3600"` |
| `apikey` | TestEngine API key (vault ref) | Required |
| `webhook_url` | TestEngine webhook URL (vault ref) | Required |
| `backoffLimit` | Retry count on failure | `0` |
| `resources` | Resource requests/limits for the job pod | Chart defaults |
| `testdefinitions[].containerImage` | Test container image | Required |
| `testdefinitions[].containerTag` | Test container tag | Required |
| `testdefinitions[].filters` | Test category filters (array of strings) | `[]` (runs all) |
| `testdefinitions[].name` | Test name identifier | Required |
| `testdefinitions[].secretId` | Auth secret (vault ref) | Required |
| `testdefinitions[].serviceAddress` | Override target service address | Auto: `<fullname>.<ns>.svc.cluster.local:<port>` |
| `testdefinitions[].additionalEnvVars` | Extra env vars for test container | `""` (format: `key1=value1;key2=value2`) |

---

## CronJobs

```yaml
cronjobs:
  - name: nightly-cleanup
    schedule: "0 2 * * *"              # cron expression (required)
    timeZone: "America/New_York"       # optional timezone
    concurrencyPolicy: "Forbid"        # Allow | Forbid | Replace (default: Forbid)
    suspend: false                     # temporarily disable the cronjob
    successfulJobsHistoryLimit: 3
    failedJobsHistoryLimit: 1
    startingDeadlineSeconds: 300
    activeDeadlineSeconds: 900
    backoffLimit: 2
    restartPolicy: "OnFailure"         # Never | OnFailure (default: Never)
    image:
      registry: mycarrieracr.azurecr.io
      repository: appstack/myservice/cleanup
      tag: "1.0.0"
    command: ["/bin/sh", "-c"]
    args: ["./cleanup.sh"]
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    env:
      - name: CLEANUP_DAYS
        value: "90"
```

---

## OpenTelemetry

```yaml
disableOtelAutoinstrumentation: true   # true to disable, false to enable
```

When set to `false`, the chart auto-injects OTel collector annotations and language-specific instrumentation based on `global.language`. Supported languages: `csharp`, `nodejs`, `java`, `python`.

---

## ServiceMonitor (Prometheus)

```yaml
serviceMonitor:
  enabled: true                         # creates a Prometheus ServiceMonitor resource
```

---

## ArgoCD Integration

The chart uses ArgoCD sync waves and options for GitOps workflows:
- Resources get `argocd.argoproj.io/sync-wave: "10"` for ordered creation
- `SkipDryRunOnMissingResource=true` handles CRDs
- Test triggers run as `PostSync` hooks
- Offloads use `ApplicationSet` generators for feature environments

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

### Quick Reference for Layout B (mc-environment wrapper)

| Change Type | File to Edit |
|-------------|-------------|
| Add/remove a dependency | `helm/values.yaml` → `global.dependencies` |
| Change appStack or language | `helm/values.yaml` → `global.appStack`, `global.language` |
| Pin mycarrier-helm chart version | `helm/values.yaml` → `mycarrierChartVersion` |
| Add/change a global env var for all envs | `helm/values.yaml` → `global.env` |
| Add/change an env-specific URL or secret | `helm/deployment/values.{env}.yaml` → `environments[].global.env` or `environments[].secrets` |
| Add a new application/service | Each `environments[]` entry → `applications` |
| Change image tag for a deployment | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.image.tag` |
| Add networking/ingress for an app | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.networking` |
| Add/modify test triggers | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.testtrigger` |
| Configure autoscaling (HPA/KEDA) | `helm/deployment/values.{env}.yaml` → `environments[].applications.<app>.autoscaling` or `keda` |
| Add a feature environment | Add new entry to `environments[]` in appropriate deployment file |
| Override ArgoCD sync policy | `helm/deployment/values.{env}.yaml` → `environments[].syncPolicy` |

### Deployment Pipeline
1. Changes are committed to the repository
2. CI/CD renders Helm templates using the merged values
3. ArgoCD deploys the rendered manifests to the target Kubernetes cluster
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
