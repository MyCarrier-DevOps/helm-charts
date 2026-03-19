# Crossplane Infrastructure Guide

Configure Azure infrastructure resources managed through Crossplane in the mycarrier-helm chart.

## Quick Start

A Service Bus with a topic and subscription, using all defaults:

```yaml
infrastructure:
  azure:
    servicebus:
      - topics:
          - name: "orders"
            subscriptions:
              - name: "processor"
```

This produces 3 Crossplane resources (ServiceBusNamespace, Topic, Subscription) with auto-generated names, `Standard` SKU, `Observe` management policy, and `default` provider config. Location must be set either per-resource or via `infrastructure.azure.defaults.location`.

## Global Defaults

`infrastructure.azure.defaults` is a top-level configuration block in your values that sets shared defaults for **all** Crossplane resources (resource groups and service bus). These are not per-resource settings — they apply globally and eliminate repetition when multiple resources share the same location or provider.

```yaml
infrastructure:
  azure:
    defaults:
      location: "East US"            # Used by any resource that doesn't set its own location
      providerConfigRef: "default"   # Used by any resource that doesn't set its own providerConfigRef
    resourceGroup: [...]              # These inherit from defaults above
    servicebus: [...]                 # These inherit from defaults above
```

Per-resource values always take precedence over `defaults`.

## Defaults Reference

| Field | Default | Applies To |
|-------|---------|------------|
| `name` | `inf-{env}` | Resource Group |
| `name` | `inf-{env}-servicebus` | Service Bus |
| `sku` | `Standard` | Service Bus |
| `location` | From `defaults.location` | Resource Group, Service Bus |
| `providerConfigRef` | `"default"` | Resource Group, Service Bus (+ all children) |
| `managementPolicies` | `["Observe"]` | All Crossplane resources |
| `resourceGroupName` | `rg-{appStack}-{env}` | Service Bus |
| `maxDeliveryCount` | `10` | Subscription |
| `namespace` (K8s) | `environment.name` | All resources |

`{env}` in default names uses `metaEnvironment`: all `feature-*` environments map to `dev`, all others use their actual name.

### Per-Environment Defaults

For an app with `global.appStack: myapp`:

| Resource | dev / feature-* | preprod | prod |
|----------|----------------|---------|------|
| Resource Group name | `inf-dev` | `inf-preprod` | `inf-prod` |
| Service Bus name | `inf-dev-servicebus` | `inf-preprod-servicebus` | `inf-prod-servicebus` |
| Service Bus RG | `rg-myapp-dev` | `rg-myapp-preprod` | `rg-myapp-prod` |
| Storage account | `stmyappdev` | `stmyapppreprod` | `stmyappprod` |
| K8s namespace | `dev` (or `feature42`) | `preprod` | `prod` |

## Resource Groups

### Minimal

```yaml
resourceGroup:
  - {}    # name: inf-dev, location from defaults, Observe policy
```

### Explicit

```yaml
resourceGroup:
  - name: "rg-custom"
    location: "West Europe"
    providerConfigRef: "my-provider"
    managementPolicies: ["Create", "Update", "LateInitialize", "Observe"]
    tags:
      environment: "dev"
```

## Service Bus

### Minimal

```yaml
servicebus:
  - topics:
      - name: "orders"
        subscriptions:
          - name: "processor"
```

### Full Example

```yaml
servicebus:
  - name: "custom-servicebus"
    location: "East US"
    sku: "Premium"
    capacity: 2
    providerConfigRef: "my-provider"       # Inherited by topics, subscriptions, rules
    resourceGroupName: "rg-app-dev"
    managementPolicies: ["Create", "Update", "LateInitialize", "Observe"]
    tags:
      environment: "dev"
    topics:
      - name: "orders"
        maxSizeInMegabytes: 2048
        requiresDuplicateDetection: true
        defaultMessageTtl: "P14D"
        supportOrdering: true
        subscriptions:
          - name: "order-processor"
            maxDeliveryCount: 5
            lockDuration: "PT5M"
            deadLetteringOnMessageExpiration: true
            rules:
              - name: "high-priority"
                filterType: "SqlFilter"
                sqlFilter: "priority = 'high'"
              - name: "json-only"
                filterType: "CorrelationFilter"
                correlationFilter:
                  contentType: "application/json"
          - name: "order-archive"
            maxDeliveryCount: 1
            forwardDeadLetteredMessagesTo: "dlq-topic"
```

### ProviderConfigRef Inheritance

Set `providerConfigRef` once on the servicebus entry. All child resources (topics, subscriptions, rules) inherit it automatically.

## Storage Accounts

Storage uses Crossplane Compositions (Claims). `providerConfigRef` and `managementPolicies` are configured on the Composition, not here.

### New Account

```yaml
storage:
  accounts:
    - newStorageAccount:
        location: "East US"
```

Name auto-generates as `st{appStack}{env}` (e.g., `stmyappdev`). Resource group defaults to `rg-{appStack}-{env}`.

### Existing Account

```yaml
storage:
  accounts:
    - existingStorageAccount:
        name: "mystorageaccount"
      existingResourceGroup:
        name: "my-existing-rg"
      containers:
        - name: "uploads"
          accessType: "private"
```

## Management Policies

All resources default to `["Observe"]` (read-only import). The `Delete` policy is **blocked** to prevent accidental infrastructure deletion.

| Policy | Description |
|--------|-------------|
| `Observe` | Read-only import of existing resources (default) |
| `Create` | Allow creating new resources |
| `Update` | Allow updating existing resources |
| `LateInitialize` | Fill in unset fields from the live resource |

To fully manage a resource:

```yaml
managementPolicies: ["Create", "Update", "LateInitialize", "Observe"]
```

## Naming Conventions

Crossplane resource metadata names follow `{env}-{appStack}-{name}`, sanitized for RFC 1123 (lowercase, max 63 chars).

| Resource | Default Name | K8s Metadata Name |
|----------|-------------|-------------------|
| Resource Group | `inf-{env}` | `{env}-{appStack}-inf-{env}` |
| Service Bus | `inf-{env}-servicebus` | `{env}-{appStack}-inf-{env}-servicebus` |
| Topic | _(required)_ | `{env}-{appStack}-{sbName}-{topicName}` |
| Subscription | _(required)_ | `{env}-{appStack}-{topicName}-{subName}` |
| Rule | _(required)_ | `{env}-{appStack}-{ruleName}` |
| Storage | `st{appStack}{env}` | `{env}-{appStack}-st{appStack}{env}` |

Names exceeding 63 characters are truncated to 54 characters with an 8-character hash suffix.

## Kubernetes Namespace

All Crossplane resources deploy to the namespace matching `environment.name` (e.g., `dev`, `preprod`, `prod`), consistent with all other chart resources. `environment.namespaceOverride` takes precedence if set. Override per-resource with the `namespace` field.

## Labels

Service Bus resources include relationship labels used by Crossplane's label selectors to link child resources to parents:

- `servicebus.mycarrier.io/namespace` — Service Bus namespace name
- `servicebus.mycarrier.io/topic` — Full topic resource name
- `servicebus.mycarrier.io/subscription` — Full subscription resource name

All resources also include standard Helm labels (`app.kubernetes.io/*`, `mycarrier.tech/*`).
