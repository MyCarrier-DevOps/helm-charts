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
│   ├── deployment.yaml     # Standard deployment template
│   ├── service.yaml        # Service template
│   ├── statefulset.yaml    # StatefulSet template
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
    replicaCount: 1                        # Number of replicas
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
    env: []
    envFrom: []
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
  replicas: {{ $app.replicaCount }}
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
    replicaCount: 3
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

## License

This chart is licensed under the Apache 2.0 License - see the LICENSE file for details.