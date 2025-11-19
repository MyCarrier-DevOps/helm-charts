# MyCarrier Helm Chart

A Helm chart for deploying MyCarrier applications to Kubernetes.

## Overview

This Helm chart provides a standardized approach for deploying MyCarrier applications and services to Kubernetes environments. It supports various deployment types (standard deployments, statefulsets, and Argo Rollouts), secret management through Vault, metrics collection, and advanced networking with Istio.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Istio 1.9+ (for networking features)
- Vault (for secrets management)
- Argo CD (for GitOps deployments)
- OpenTelemetry Operator (for observability)

## Installing the Chart

To install the chart with the release name `mycarrier-app`:

```bash
helm install mycarrier-app . -f values.yaml
```

For environment-specific installations:

```bash
# Development environment
helm install mycarrier-app . -f values.yaml -f values-dev.yaml

# Production environment
helm install mycarrier-app . -f values.yaml -f values-prod.yaml
```

To upgrade an existing release:

```bash
helm upgrade mycarrier-app . -f values.yaml
```

To uninstall a release:

```bash
helm uninstall mycarrier-app
```

## Chart Structure

```
mycarrier/
├── Chart.yaml              # Chart metadata
├── Chart.lock              # Dependency lock file (auto-generated)
├── values.yaml             # Default values
├── values.schema.json      # JSON Schema for validation
├── README.md               # This documentation file
├── templates/              # Kubernetes resource templates
│   ├── _helpers.tpl        # Named template definitions
│   ├── _environment.tpl    # Environment-specific template functions
│   ├── _labels.tpl         # Labeling template functions
│   ├── _lifecycle.tpl      # Container lifecycle configurations
│   ├── _networking.tpl     # Networking template functions
│   ├── _otel.tpl           # OpenTelemetry integration helpers
│   ├── _probes.tpl         # Health/readiness probe configurations
│   ├── _toleration.tpl     # Node tolerations for pods
│   ├── _spec_job.tpl       # Job spec template definitions
│   ├── _spec_cronjob.tpl   # CronJob spec template definitions
│   ├── deployment.yaml     # Standard deployment template
│   ├── service.yaml        # Service template
│   ├── statefulset.yaml    # StatefulSet template
│   ├── jobs.yaml           # Job template
│   ├── cronjob.yaml        # CronJob template
│   ├── offloads.yaml       # ApplicationSet generator for offloads
│   ├── extraObjects.yaml   # Template for custom Kubernetes objects
│   └── tests/              # Helm test templates
│       └── test-*.yaml     # Test resources
└── charts/                 # Packaged dependencies (auto-generated)
```

## Naming Conventions

This chart follows these naming conventions:

### Resources

- **Kubernetes Resources**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **Deployment/StatefulSet**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **Service**: `{{ include "helm.fullname" . }}-{{ .appName }}`
- **ConfigMap**: `{{ include "helm.fullname" . }}-{{ .appName }}-config`
- **Secret**: `{{ include "helm.fullname" . }}-{{ .appName }}-secrets`
- **VirtualService**: `{{ include "helm.fullname" . }}-{{ .appName }}`

### Template Files

- Helper templates start with underscore: `_helpers.tpl`
- Resource templates are named for the resource they create: `deployment.yaml`
- Conditional resources include the condition in the filename: `istio-gateway.yaml`

### Labels and Annotations

Standard labels applied to all resources:

```yaml
labels:
  app.kubernetes.io/name: {{ include "helm.fullname" . }}
  app.kubernetes.io/instance: {{ include "helm.instance" . }}
  app.kubernetes.io/part-of: {{ .Values.global.appStack }}
  app.kubernetes.io/component: {{ .appName }}
  app: {{ include "helm.fullname" . }}
  mycarrier.tech/environment: {{ .Values.environment.name }}
  mycarrier.tech/envscaling: {{ include "helm.envScaling" . }}
  mycarrier.tech/envType: {{ include "helm.envType" . }}
  mycarrier.tech/service-namespace: {{ include "helm.namespace" . }}
  mycarrier.tech/reference: {{ .Values.global.branchlabel }}
```

## Coding Style & Best Practices

### YAML Formatting

- Indentation: 2 spaces
- Line length: ≤ 80 characters when possible
- Use `|` for multi-line strings that need newlines preserved
- Use `>` for multi-line strings that can be folded

### Templates

- Use helper functions in `_helpers.tpl` for reusable logic
- Document each helper function with comments
- Use Sprig functions consistently and appropriately
- Prefer named templates over duplicated logic
- Include comments for complex template logic
- Use consistently formatted whitespace in templates

### Conditional Logic

```yaml
{{- if .Values.feature.enabled }}
# Resource inclusion for enabled feature
{{- end }}
```

### Iteration

```yaml
{{- range $appName, $app := .Values.applications }}
# Resource for each application
{{- end }}
```

## Values Structure

This chart uses a structured approach to values, organized by application. The following sections outline the key configuration areas:

### Global Settings

```yaml
global:
  appStack: "app"           # Application stack name
  language: "nodejs"        # Programming language (csharp, nodejs, java, python, nginx)
  gitbranch: ""             # Git branch name (for feature branches)
  branchlabel: ""           # Label for branch
  forceAutoscaling: false   # Force autoscaling regardless of environment
```

### Environment Settings

```yaml
environment:
  name: "dev"               # Environment name (dev, preprod, prod, feature-*)
  dependencyenv: "dev"      # Environment name for dependencies
  domainOverride:
    enabled: false          # Whether to override default domain
    domain: "example.com"   # Domain to use when override is enabled
```

### Application Definitions

The chart supports multiple applications within a single release:

```yaml
applications:
  example-api:
    isFrontend: false                      # Whether this is a frontend application
    forceOffload: false                    # Whether to force offloading
    staticHostname: "api.example.com"      # Optional static hostname
    labels: {}                             # Custom labels
    annotations: {}                        # Custom annotations
    deploymentType: "deployment"           # Type: deployment, statefulset, or rollout
    version: "1.0.0"                       # Application version
    image:
      registry: "myregistry.example.com"   # Docker registry
      repository: "mycarrier/example-api"  # Docker image repository
      tag: "1.0.0"                         # Docker image tag
      pullPolicy: "IfNotPresent"           # Image pull policy
      pullSecrets: []                      # Image pull secrets
    replicas: 1                        # Number of replicas
    ports:
      http: 8080                           # HTTP port
      metrics: 9090                        # Metrics port
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
    autoscaling:
      enabled: false
      minReplicas: 1
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
      targetMemoryUtilizationPercentage: 80
    nodeSelector: {}
    tolerations: []
    affinity: {}
    service:
      type: "ClusterIP"
      ports:
        - name: http
          port: 80
          targetPort: 8080
      annotations: {}
      disableAffinity: false
      affinityTimeoutSeconds: 600
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
    env: []                                # Environment variables (key-value pairs)
    volumes: []
    volumeMounts: []
    lifecycle:
      postStart: "echo postStartTest"
      preStop: "pkill dotnet"  # Varies based on language
    networking:
      ingress:
        type: "istio"
      istio:
        enabled: true
        hosts: []
        redirects: {}
        routes: {}
        responseHeaders: {}
        corsPolicy: {}
    serviceAccount:
      create: false
```

### Autoscaling Configuration

The chart provides intelligent autoscaling with multiple configuration levels. See [AUTOSCALING.md](AUTOSCALING.md) for comprehensive documentation.

#### Configuration Options

**Global Level:**
```yaml
global:
  forceAutoscaling: true | false | not set
```

- **`not set`** (default): Allows automatic production autoscaling for non-migration apps
- **`false`**: Disables all automatic autoscaling (override mechanism)
- **`true`**: Forces HPA creation for all non-migration apps in any environment

**Application Level:**
```yaml
applications:
  <app-name>:
    autoscaling:
      enabled: true | false
      forceAutoscaling: true | false
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 80
```

- **`enabled: true`**: Always creates HPA (highest precedence)
- **`forceAutoscaling: true`**: Creates HPA even for migration apps, overrides global settings

#### HPA Creation Logic

A HorizontalPodAutoscaler (HPA) is created when:

1. `autoscaling.enabled: true` (highest precedence), OR
2. `autoscaling.forceAutoscaling: true` (app-level force), OR
3. UNLESS `global.forceAutoscaling: false` (override blocks auto-scaling), THEN:
   - `global.forceAutoscaling: true` AND app is NOT a migration app, OR
   - Environment is production (envScaling=1) AND app is NOT a migration app

**Migration App Protection:** Apps with "migration" in their name are excluded from global force and automatic production autoscaling. Use app-level `autoscaling.enabled` or `autoscaling.forceAutoscaling` to enable HPA for migrations.

When autoscaling is **enabled**:
- A HorizontalPodAutoscaler (HPA) resource is created
- The `replicas` field is removed from the Deployment to allow HPA control
- The HPA manages scaling based on CPU/memory utilization
- **Default HPA values** (if not explicitly set):
  - `minReplicas`: **2**
  - `maxReplicas`: **10**
  - `targetCPUUtilizationPercentage`: **80**

When autoscaling is **disabled**:
- No HPA resource is created
- The `replicas` field is set on the Deployment with environment-specific defaults:
  - Feature environments (`feature-*`): Default 1 replica
  - Other environments (dev, preprod): Default 2 replicas
  - Production with migration apps: Default 2 replicas

#### Example Configuration

**Example 1: Default Production (Auto-scaling)**

```yaml
environment:
  name: "prod"              # Production environment (envScaling=1)

applications:
  api:
    # HPA automatically created in production
    # No autoscaling config needed
    autoscaling:
      minReplicas: 2        # Optional: customize min/max
      maxReplicas: 10

  db-migration:
    # Migration apps excluded from auto-scaling
    replicas: 1             # Uses static replicas
```

**Example 2: Disable Production Auto-scaling (Override)**

```yaml
global:
  forceAutoscaling: false   # Override: disable auto-scaling

environment:
  name: "prod"

applications:
  api:
    replicas: 3             # Uses static replicas (no HPA)
```

**Example 3: Force Autoscaling in Dev**

```yaml
global:
  forceAutoscaling: true    # Force HPA in any environment

environment:
  name: "dev"

applications:
  api:
    autoscaling:
      minReplicas: 1
      maxReplicas: 5

  db-migration:
    # Global force does NOT apply to migrations
    replicas: 1
```

**Example 4: App-level Override**

```yaml
global:
  forceAutoscaling: false   # Override global

environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: true         # Explicit enable overrides global
      minReplicas: 3
      maxReplicas: 15

  worker:
    replicas: 2             # Static replicas
```

For more examples and use cases, see [AUTOSCALING.md](AUTOSCALING.md).

### Networking Configuration

```yaml
networking:
  ingress:
    type: "istio"                          # Type: istio, nginx, or none
  istio:
    enabled: true
    hosts:
      - host: "api.example.com"
        paths:
          - path: "/"
            pathType: "Prefix"
    gateways:
      - "istio-system/ingressgateway"
    redirects: {}
    routes: {}
    responseHeaders: {}
    corsPolicy:
      allowOrigins:
        - exact: "https://example.com"
      allowMethods:
        - "GET"
        - "POST"
      allowHeaders:
        - "Authorization"
        - "Content-Type"
      maxAge: "24h"
```

### Secrets Management

The chart integrates with Vault for secrets management:

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"           # Path to secrets in Vault for bulk retrieval
  individual:                              # Individual environment variables from Vault
    - envVarName: "DB_PASSWORD"
      path: "secrets/data/dev/db"
      keyName: "password"
  mounted:                                 # File-mounted secrets from Vault
    - name: "certificate"
      mountedFileName: "cert.pem"
      vault:
        path: "secrets/data/dev/certs"
        property: "certificate"
      mount:
        path: /app/certs
        subPath: cert.pem
```

### Environment Variables Configuration

The chart supports configuring environment variables at different scopes to provide maximum flexibility. Environment variables can be set at the global level (affecting all applications), per-application level, or using combinations for fine-grained control.

#### Global Environment Variables (All Components, All Environments)

Set environment variables that apply to all applications across all environments:

```yaml
global:
  env:
    LOG_LEVEL: "info"
    APP_VERSION: "1.0.0"
    FEATURE_FLAG_SERVICE_URL: "https://features.mycarrier.com"

applications:
  api:
    # Application-specific configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
  worker:
    # Application-specific configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
```

#### Component-Specific Variables

Set environment variables for specific applications that apply across all environments:

```yaml
applications:
  api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    env:
      API_RATE_LIMIT: "1000"
      API_TIMEOUT: "30s"
      ENABLE_METRICS: "true"
  
  worker:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
    env:
      WORKER_CONCURRENCY: "10"
      QUEUE_NAME: "background-jobs"
      WORKER_TIMEOUT: "300s"
```

#### Combined Approach Example

A comprehensive example showing how global and application-specific environment variables work together:

```yaml
global:
  # Global variables for all applications
  env:
    COMPANY_NAME: "MyCarrier"
    ENVIRONMENT: "dev"
    LOG_LEVEL: "warn"

environment:
  name: "prod"

applications:
  api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    env:
      # Application-specific variables
      API_PORT: "8080"
      API_WORKERS: "10"
      # Override global variable for this specific application
      LOG_LEVEL: "info"  # Always info for API, regardless of environment
    
  worker:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/worker"
      tag: "1.0.0"
    env:
      # Application-specific variables
      WORKER_TYPE: "background"
      QUEUE_WORKERS: "20"
      # This application inherits the global LOG_LEVEL setting
```

## Minimal Configuration Examples

The following examples demonstrate the minimal configuration required for different types of objects within the chart.

### Minimal Application

```yaml
global:
  appStack: "api"
  language: "nodejs"

environment:
  name: "dev"

applications:
  example-api:
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
```

### Minimal Service Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    service:
      type: "ClusterIP"
      ports:
        - name: http
          port: 80
          targetPort: 8080
```

### Minimal Deployment Configuration

```yaml
applications:
  example-api:
    deploymentType: "deployment"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

### Minimal StatefulSet Configuration

```yaml
applications:
  example-database:
    deploymentType: "statefulset"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/database"
      tag: "1.0.0"
    ports:
      http: 5432
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "1Gi"
```

### Minimal Istio/Networking Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    networking:
      ingress:
        type: "istio"
      istio:
        enabled: true
        hosts:
          - "api.mycarrier.dev"
```

#### Internal mesh hostnames

When Istio ingress is enabled, the chart also advertises mesh-internal DNS entries for every application using the pattern `{{ appStack }}-{{ application }}.{{ environment }}.internal`. These names allow workloads in any namespace to target a stable service address for each environment:

- `*.dev.internal` accepts an optional `environment` request header. If a feature namespace exists with a matching header value (for example `feature-my-branch`), traffic is routed to that namespace. When the feature workload is absent, the request automatically falls back to the `dev` deployment.
- `*.preprod.internal` and `*.prod.internal` always resolve to the pre-production and production services respectively, providing consistent URLs for cross-environment smoke tests.

Every Istio-enabled application receives a matching `ServiceEntry` so that these internal hostnames are resolvable within the mesh. Feature namespaces are included, which means preview workloads can expose `*.dev.internal` endpoints for collaborative testing without additional DNS changes.

Set the `environment` header to the desired feature namespace when calling the `dev` endpoint to exercise preview deployments without touching DNS records.

### Minimal Secret Configuration

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"
  individual:
    - envVarName: "DB_PASSWORD"
      path: "secrets/data/dev/db"
      keyName: "password"
```

### Minimal CronJob Configuration

```yaml
cronjobs:
  - name: backup-job
    schedule: "0 2 * * *"  # Run daily at 2 AM
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
```

### Minimal OpenTelemetry Configuration

To enable OpenTelemetry for a Node.js application:

```yaml
global:
  language: "nodejs"
  appStack: "api"

disableOtelAutoinstrumentation: false  # Enables OpenTelemetry auto-instrumentation
```

### Minimal Tolerations Configuration

```yaml
applications:
  example-api:
    # ...other configurations...
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "api"
        effect: "NoSchedule"
```

## Template Usage Guide

### Helper Functions

These are the main helper functions in the templates:

#### Basic Naming and Context

```
{{- define "helm.fullname" -}}
{{- $ctx := fromJson (include "helm.default-context" .) -}}
{{- $envName := $ctx.defaults.environmentName -}}
{{- $appStack := $ctx.defaults.appStack -}}
{{- $appName := .appName | default "" -}}
# ... additional logic ...
{{- end }}
```

Used for generating consistent resource names across environments.

#### Labels

```
{{- define "helm.labels.standard" -}}
app.kubernetes.io/name: {{ include "helm.fullname" . | trunc 63 }}
app.kubernetes.io/instance: {{ $instance | trunc 63 }}
app.kubernetes.io/part-of: {{ $appStack }}
app.kubernetes.io/component: {{ $appName }}
# ... additional labels ...
{{- end -}}
```

Used for applying consistent labels to resources.

#### Probes

```
{{- define "helm.defaultReadinessProbe" -}}
{{- if (ne (.Values.global.language | lower) "csharp" ) }}
{{- if (dig "ports" (dict) .application) }}
readinessProbe:
  tcpSocket:
    port: {{- (or (index .application.ports "http") (index .application.ports "healthcheck")) | toString | indent 1 }}
  # ... probe configuration ...
{{- end }}
{{- end }}
{{- end -}}
```

Used for configuring health, readiness, and liveness probes.

### Example: Using Helper Templates

Here's how to use these helper functions in templates:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "helm.fullname" . }}-{{ $appName }}
  annotations:
    argocd.argoproj.io/sync-wave: "10"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  labels:
    {{- include "helm.labels.standard" . | nindent 4 }}
spec:
  replicas: {{ $app.replicas }}
  selector:
    matchLabels:
      {{- include "helm.labels.selector" . | nindent 6 }}
  template:
    metadata:
      annotations:
        {{- include "helm.annotations.istio" . | nindent 8 }}
        {{- include "helm.otel.annotations" . | nindent 8 }}
      labels:
        {{- include "helm.labels.selector" . | nindent 8 }}
        {{- include "helm.otel.labels" . | nindent 8 }}
    spec:
      {{- include "helm.podDefaultToleration" . | nindent 6 }}
      containers:
        - name: {{ $appName }}
          image: "{{ .image.registry }}/{{ .image.repository }}:{{ .image.tag }}"
          {{- include "helm.defaultReadinessProbe" . | nindent 10 }}
          {{- include "helm.defaultLivenessProbe" . | nindent 10 }}
          env:
            {{- include "helm.otel.envVars" . | nindent 12 }}
            {{- include "helm.otel.language" . | nindent 12 }}
          resources:
            {{- include "helm.resources" . | nindent 12 }}
```

## Common Use Cases

### Deploying a Basic Node.js Application

```yaml
global:
  appStack: "app"
  language: "nodejs"

environment:
  name: "dev"

applications:
  api:
    deploymentType: "deployment"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/api"
      tag: "1.0.0"
    ports:
      http: 8080
      metrics: 9090
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

### Configuring Vault Secrets

```yaml
secrets:
  bulk:
    path: "secrets/data/dev/app"
  individual:
    - envVarName: DB_PASSWORD
      path: secrets/data/dev/app/db
      keyName: password
  mounted:
    - name: certificate
      mountedFileName: cert.pem
      vault:
        path: secrets/data/dev/app/certs
        property: certificate
      mount:
        path: /app/certs
        subPath: cert.pem
```

### Advanced StatefulSet Configuration

```yaml
applications:
  database:
    deploymentType: "statefulset"
    replicas: 3
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        partition: 0
    podManagementPolicy: "OrderedReady"
    persistentVolumes:
      - name: data
        mountPath: /data
        size: 10Gi
        storageClass: "standard"
        accessModes:
          - ReadWriteOnce
```

### Using Offloads

For development environments, the chart supports "offloading" certain applications to separate Argo CD ApplicationSets:

```yaml
applications:
  example-api:
    isFrontend: false
    forceOffload: true  # Force this application to be offloaded
    # ... other app configuration ...
```

### Running Scheduled Jobs with CronJobs

The chart supports Kubernetes CronJobs for running scheduled tasks such as backups, cleanup operations, or periodic data processing:

#### Basic CronJob Example

```yaml
cronjobs:
  - name: nightly-backup
    schedule: "0 2 * * *"  # Run daily at 2 AM UTC
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
    command: ["/bin/sh", "-c"]
    args: ["./backup.sh"]
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

#### Advanced CronJob with All Features

```yaml
cronjobs:
  - name: data-cleanup
    schedule: "0 3 * * 0"  # Run weekly on Sunday at 3 AM
    timeZone: "America/New_York"  # Use specific timezone
    concurrencyPolicy: "Forbid"  # Don't allow concurrent runs
    suspend: false  # Set to true to temporarily disable
    successfulJobsHistoryLimit: 5  # Keep last 5 successful jobs
    failedJobsHistoryLimit: 3  # Keep last 3 failed jobs
    startingDeadlineSeconds: 300  # Start within 5 minutes of scheduled time
    activeDeadlineSeconds: 900  # Kill job if it runs longer than 15 minutes
    backoffLimit: 2  # Retry up to 2 times on failure
    restartPolicy: "OnFailure"  # Restart container on failure

    # Custom labels and annotations
    labels:
      team: "data-engineering"
      job-type: "cleanup"
    annotations:
      app.mycarrier.tech/description: "Weekly data cleanup job"

    # Container configuration
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/data-cleanup"
      tag: "2.0.0"
    imagePullPolicy: "Always"
    imagePullSecret: "custom-pull-secret"

    # Command and arguments
    command: ["/usr/local/bin/python"]
    args: ["-m", "myapp.jobs.cleanup", "--mode=weekly"]

    # Environment variables
    env:
      - name: CLEANUP_THRESHOLD_DAYS
        value: "90"
      - name: DRY_RUN
        value: "false"

    # Use ConfigMap and Secrets
    configMapName: "cleanup-config"
    secretName: "cleanup-secrets"

    # Resource limits
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "2000m"
        memory: "2Gi"

    # Volume mounts
    volumes:
      - name: temp-data
        mountPath: /tmp/cleanup
        kind: emptyDir
```

#### Multiple CronJobs Example

```yaml
cronjobs:
  # Daily backup job
  - name: database-backup
    schedule: "0 1 * * *"  # Daily at 1 AM
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/backup"
      tag: "1.0.0"
    env:
      - name: BACKUP_TYPE
        value: "full"

  # Hourly cache cleanup
  - name: cache-cleanup
    schedule: "0 * * * *"  # Every hour
    concurrencyPolicy: "Replace"  # Replace running job if new one starts
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/cache-cleanup"
      tag: "1.0.0"

  # Weekly report generation
  - name: weekly-report
    schedule: "0 9 * * 1"  # Monday at 9 AM
    timeZone: "America/New_York"
    image:
      registry: "mycarrieracr.azurecr.io"
      repository: "app/reports"
      tag: "1.0.0"
    resources:
      requests:
        cpu: "1000m"
        memory: "1Gi"
      limits:
        cpu: "2000m"
        memory: "4Gi"
```

#### CronJob Configuration Options

| Field | Description | Default |
|-------|-------------|---------|
| `name` | Name of the CronJob (required) | - |
| `schedule` | Cron schedule expression (required) | - |
| `timeZone` | Timezone for the schedule | System timezone |
| `concurrencyPolicy` | How to handle concurrent executions: `Allow`, `Forbid`, or `Replace` | `Forbid` |
| `suspend` | Suspend all executions | `false` |
| `successfulJobsHistoryLimit` | Number of successful jobs to keep | `3` |
| `failedJobsHistoryLimit` | Number of failed jobs to keep | `1` |
| `startingDeadlineSeconds` | Deadline for starting if missed schedule | None |
| `activeDeadlineSeconds` | Maximum job execution time | None |
| `backoffLimit` | Number of retries before marking job as failed | `0` |
| `restartPolicy` | Pod restart policy: `Never` or `OnFailure` | `Never` |
| `image` | Container image configuration (required) | - |
| `imagePullPolicy` | Image pull policy | `IfNotPresent` |
| `imagePullSecret` | Image pull secret name | `imagepull` |
| `command` | Container command override | None |
| `args` | Container arguments | None |
| `env` | Environment variables array | `[]` |
| `configMapName` | ConfigMap to load as environment variables | None |
| `secretName` | Secret to load as environment variables | None |
| `resources` | CPU and memory resource limits | Defaults set |
| `volumes` | Volume mounts configuration | `[]` |

#### Cron Schedule Examples

- `"*/5 * * * *"` - Every 5 minutes
- `"0 * * * *"` - Every hour
- `"0 0 * * *"` - Daily at midnight
- `"0 2 * * *"` - Daily at 2 AM
- `"0 0 * * 0"` - Weekly on Sunday
- `"0 0 1 * *"` - Monthly on the 1st
- `"0 9 * * 1-5"` - Weekdays at 9 AM

## ArgoCD Integration

The chart includes ArgoCD sync waves and options for better GitOps workflows:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Controls the order of resource creation
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

## OpenTelemetry Integration

The chart provides built-in OpenTelemetry configuration for supported languages:

```yaml
global:
  language: "nodejs"  # Supported values: nodejs, java, python, csharp

disableOtelAutoinstrumentation: false  # Set to true to disable auto-instrumentation
```

This includes:
- Auto-injected OpenTelemetry collector
- Language-specific instrumentation
- Standardized metrics and traces

## Troubleshooting

### Common Issues

1. **Pod Fails to Start**: Check resource constraints, image availability, and Vault connectivity
   ```bash
   kubectl describe pod -l app.kubernetes.io/instance=mycarrier-app
   ```

2. **Service Unavailable**: Verify service and endpoint configurations
   ```bash
   kubectl get svc,ep -l app.kubernetes.io/instance=mycarrier-app
   ```

3. **Istio Routing Problems**: Check VirtualService and Gateway resources
   ```bash
   kubectl get virtualservice,gateway -l app.kubernetes.io/instance=mycarrier-app
   ```

## Contributing

When contributing to this chart, please follow the coding standards defined in the chart's documentation.

### Contribution Workflow

1. Create a feature branch from `main`
2. Make changes to the chart
3. Update documentation
4. Run tests
5. Submit a pull request

## Parameters

### Global Settings

| Name                                  | Description                                                                            | Value    |
| ------------------------------------- | -------------------------------------------------------------------------------------- | -------- |
| `global.appStack`                     | Application stack name, used for naming resources and grouping applications            | `app`    |
| `global.gitbranch`                    | Name of the git branch (used for feature branches)                                     | `""`     |
| `global.branchlabel`                  | Label for the branch, used for reference label                                         | `""`     |
| `global.language`                     | Default programming language for applications (can be overridden at application level) | `csharp` |
| `global.v2migration`                  | Flag to indicate if we are migrating to v2 (enables certain ArgoCD sync options)       | `false`  |
| `global.commitDeployed`               | Label for the deployed commit (used for tracking deployments)                          | `""`     |
| `global.env`                          | Global environment variables shared across all applications                            | `{}`     |
| `global.dependencies`                 | Dependency flags to control infrastructure resources                                   |          |
| `global.dependencies.mongodb`         | Enable MongoDB dependency                                                              | `false`  |
| `global.dependencies.elasticsearch`   | Enable Elasticsearch dependency                                                        | `false`  |
| `global.dependencies.redis`           | Enable Redis dependency                                                                | `false`  |
| `global.dependencies.postgres`        | Enable PostgreSQL dependency                                                           | `false`  |
| `global.dependencies.sqlserver`       | Enable SQL Server dependency                                                           | `false`  |
| `global.dependencies.clickhouse`      | Enable ClickHouse dependency                                                           | `false`  |
| `global.dependencies.azureservicebus` | Enable Azure Service Bus dependency                                                    | `false`  |
| `global.dependencies.redpanda`        | Enable Redpanda dependency                                                             | `false`  |
| `global.dependencies.loadsure`        | Enable Loadsure dependency                                                             | `false`  |
| `global.dependencies.chargify`        | Enable Chargify dependency                                                             | `false`  |

### Environment Settings

| Name                                 | Description                                                                                                     | Value         |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `environment.name`                   | Environment name (dev, preprod, prod, or feature-*)                                                             | `dev`         |
| `environment.dependencyenv`          | Environment name for dependencies                                                                               | `dev`         |
| `environment.domainOverride`         | Domain override configuration                                                                                   |               |
| `environment.domainOverride.enabled` | Whether to override the default domain (default domains: mycarrier.dev for non-prod, mycarriertms.com for prod) | `false`       |
| `environment.domainOverride.domain`  | Domain to use when override is enabled                                                                          | `example.com` |

### Platform Settings

| Name                             | Description                                                                            | Value        |
| -------------------------------- | -------------------------------------------------------------------------------------- | ------------ |
| `enableVaultCA`                  | Enable Vault CA certificate download during pod startup                                | `false`      |
| `disableOtelAutoinstrumentation` | Disable OpenTelemetry automatic instrumentation (set to false to enable)               | `true`       |
| `tolerations`                    | Default tolerations for all applications                                               | `[]`         |
| `deployment`                     | Deployment folder name (should match the subfolder containing the specific deployment) | `deployment` |

### Applications

| Name           | Description                                                          | Value |
| -------------- | -------------------------------------------------------------------- | ----- |
| `applications` | Map of application definitions where the key is the application name | `{}`  |

### Kubernetes Jobs

| Name   | Description                    | Value |
| ------ | ------------------------------ | ----- |
| `jobs` | List of Kubernetes Jobs to run | `[]`  |

### Kubernetes CronJobs

| Name       | Description                        | Value |
| ---------- | ---------------------------------- | ----- |
| `cronjobs` | List of Kubernetes CronJobs to run | `[]`  |

### Secrets Management

| Name                 | Description                                    | Value |
| -------------------- | ---------------------------------------------- | ----- |
| `secrets`            | Secret configuration                           |       |
| `secrets.bulk`       | Bulk secret retrieval from a single Vault path | `{}`  |
| `secrets.individual` | Individual environment variables from Vault    | `[]`  |
| `secrets.mounted`    | File-mounted secrets from Vault                | `[]`  |

### Infrastructure Resources

| Name                                    | Description                                | Value |
| --------------------------------------- | ------------------------------------------ | ----- |
| `infrastructure`                        | Infrastructure configuration               |       |
| `infrastructure.azure`                  | Azure infrastructure resources             |       |
| `infrastructure.azure.resourceGroup`    | Azure Resource Group configurations        | `[]`  |
| `infrastructure.azure.storage`          | Azure Storage configuration                |       |
| `infrastructure.azure.storage.accounts` | Azure storage account configurations       | `[]`  |
| `infrastructure.azure.servicebus`       | Azure Service Bus namespace configurations | `[]`  |

### Deployment Settings

| Name                  | Description                                                                            | Value   |
| --------------------- | -------------------------------------------------------------------------------------- | ------- |
| `isEnvironmentDeploy` | Whether this is an environment-level deployment (affects resource naming and behavior) | `false` |

## License

This chart is licensed under the Apache 2.0 License - see the LICENSE file for details.