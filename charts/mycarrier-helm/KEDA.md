# KEDA Autoscaler Configuration Guide

This document covers KEDA (Kubernetes Event-Driven Autoscaling) for Azure Service Bus in the MyCarrier Helm chart.

## Overview

KEDA enables event-driven autoscaling based on Azure Service Bus message count. Unlike HPA (which scales on CPU/memory), KEDA scales your application based on the number of messages waiting to be processed in a queue or topic subscription.

> **Note:** HPA and KEDA are mutually exclusive per application. When `keda.enabled` is true, HPA is not created regardless of any HPA or environment settings. See [HPA.md](HPA.md) for CPU/memory-based autoscaling.

## How It Works

When KEDA is enabled for an application, the chart creates two resources:

1. **TriggerAuthentication** - References a Kubernetes Secret containing the Azure Service Bus connection string
2. **ScaledObject** - Configures the scaling trigger, target workload, and scaling parameters

KEDA polls Azure Service Bus at a configurable interval and scales the workload based on the number of pending messages relative to the `messageCount` threshold.

## How Replicas Are Calculated

KEDA uses the **active message count** from Azure Service Bus (queue length or topic subscription backlog) to determine the desired number of replicas. The formula is:

```
desiredReplicas = ceil( activeMessageCount / messageCount )
```

The result is then clamped between `minReplicaCount` and `maxReplicaCount`. If `idleReplicaCount` is set and there are zero active messages, KEDA scales to that value instead.

### Scaling Formula Walkthrough

Given the defaults (`messageCount: "500"`, `minReplicaCount: 2`, `maxReplicaCount: 50`):

| Active Messages | Calculation | Raw Result | Clamped Result | Reason |
|-----------------|-------------|-----------|----------------|--------|
| 0 | 0 / 500 | 0 | 2 | Clamped to `minReplicaCount` |
| 100 | 100 / 500 | 1 | 2 | Clamped to `minReplicaCount` |
| 500 | 500 / 500 | 1 | 2 | Clamped to `minReplicaCount` |
| 1,000 | 1000 / 500 | 2 | 2 | Matches `minReplicaCount` |
| 5,000 | 5000 / 500 | 10 | 10 | Within range |
| 10,000 | 10000 / 500 | 20 | 20 | Within range |
| 25,000 | 25000 / 500 | 50 | 50 | Matches `maxReplicaCount` |
| 100,000 | 100000 / 500 | 200 | 50 | Clamped to `maxReplicaCount` |

### With Scale-to-Zero

When `idleReplicaCount: 0` is set, KEDA introduces a two-phase activation:

1. **Idle state** (0 active messages): Scaled to `idleReplicaCount` (0 replicas)
2. **Activation** (active messages >= `activationMessageCount`): Scales from 0 to at least `minReplicaCount`
3. **Active scaling**: Normal formula applies (`ceil(activeMessages / messageCount)`)

| Active Messages | `idleReplicaCount: 0`, `activationMessageCount: "1"` | Result |
|-----------------|-------------------------------------------------------|--------|
| 0 | Below activation threshold | **0** (idle) |
| 1 | Meets activation threshold | **2** (jumps to `minReplicaCount`) |
| 5,000 | Normal scaling: 5000 / 500 = 10 | **10** |

### Choosing the Right `messageCount`

The `messageCount` value represents **how many messages one replica can handle** during a polling interval. To choose the right value:

- **Too low** (e.g., `"1"`): Aggressive scaling, many replicas created quickly. Useful for latency-sensitive workloads.
- **Too high** (e.g., `"10000"`): Conservative scaling, fewer replicas. Useful for batch processing where throughput per pod is high.
- **Right-sized**: Estimate how many messages one pod processes per `pollingInterval` (default 30s). If a pod processes ~500 messages in 30 seconds, `messageCount: "500"` keeps the backlog stable.

## Authentication

KEDA authenticates to Azure Service Bus using a **connection string** stored in a Kubernetes Secret. The chart provides two options for supplying this secret:

### Option A: Reference an Existing Kubernetes Secret

Point to a secret that already exists in the namespace (created manually, by another operator, etc.):

```yaml
connectionStringSecret:
  name: "servicebus-secret"      # Name of the Kubernetes Secret
  key: "connection-string"       # Key within the secret
```

```bash
# Example: Creating the secret manually
kubectl create secret generic servicebus-secret \
  --from-literal=connection-string="Endpoint=sb://my-namespace.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=..."
```

**Resources created:** TriggerAuthentication + ScaledObject (2 resources)

### Option B: Auto-Create from Vault via External Secrets Operator

The chart generates an `ExternalSecret` that syncs the connection string from Vault into a Kubernetes Secret automatically. No pre-existing secret needed.

```yaml
connectionStringSecret:
  vault:
    path: "secrets/data/dev/servicebus"    # Vault secret path
    property: "connectionString"           # Property within the Vault secret
    # secretStoreName: "vault-backend"     # Optional: ClusterSecretStore name (default: "vault-backend")
    # refreshInterval: "15m"              # Optional: How often ESO polls Vault (default: "15m")
```

The chart creates an `ExternalSecret` (named `<fullName>-keda-servicebus-es`) that:
1. Reads from the ClusterSecretStore (default: `vault-backend`, configurable via `vault.secretStoreName`)
2. Syncs into a K8s Secret named `<fullName>-keda-servicebus`
3. The TriggerAuthentication automatically references this generated secret

**Resources created:** ExternalSecret + TriggerAuthentication + ScaledObject (3 resources)

> **Note:** This uses the same External Secrets Operator and `vault-backend` ClusterSecretStore as the chart's existing `secrets.mounted` feature.

## Configuration

### Queue-Based Scaling

Scale based on messages in an Azure Service Bus queue:

```yaml
applications:
  order-processor:
    deploymentType: deployment
    image:
      registry: "myregistry.example.com"
      repository: "mycarrier/order-processor"
      tag: "1.0.0"
    keda:
      enabled: true
      type: "queue"
      queueName: "orders"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
```

### Topic-Based Scaling

Scale based on messages in an Azure Service Bus topic subscription:

```yaml
applications:
  notification-worker:
    deploymentType: deployment
    image:
      registry: "myregistry.example.com"
      repository: "mycarrier/notification-worker"
      tag: "1.0.0"
    keda:
      enabled: true
      type: "topic"
      topicName: "notifications"
      subscriptionName: "email-sender"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
```

### Configuration Reference

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `enabled` | Yes | `false` | Enable KEDA autoscaling |
| `type` | Yes | - | `"queue"` or `"topic"` |
| `queueName` | When type=queue | - | Azure Service Bus queue name |
| `topicName` | When type=topic | - | Azure Service Bus topic name |
| `subscriptionName` | When type=topic | - | Azure Service Bus subscription name |
| `connectionStringSecret.name` | Option A | - | Existing Kubernetes Secret name |
| `connectionStringSecret.key` | Option A | - | Key within the existing Secret |
| `connectionStringSecret.vault.path` | Option B | - | Vault secret path (auto-creates K8s secret via ESO) |
| `connectionStringSecret.vault.property` | Option B | - | Property within the Vault secret |
| `connectionStringSecret.vault.secretStoreName` | No | `"vault-backend"` | ClusterSecretStore name for ESO |
| `connectionStringSecret.vault.refreshInterval` | No | `"15m"` | How often ESO polls Vault for secret changes |
| `messageCount` | No | `"500"` | Target messages per replica to trigger scaling |
| `activationMessageCount` | No | - | Message threshold to activate the scaler (scale from idle) |
| `pollingInterval` | No | `30` | How often KEDA checks the trigger source (seconds) |
| `cooldownPeriod` | No | `300` | Wait time after last trigger before scaling down (seconds) |
| `minReplicaCount` | No | `2` | Minimum number of replicas |
| `maxReplicaCount` | No | `50` | Maximum number of replicas |
| `idleReplicaCount` | No | - | Replicas when idle (set to `0` for scale-to-zero) |
| `advanced` | No | - | Advanced KEDA scaling policies |

## Examples

### Example 1: Basic Queue Consumer

Minimal configuration with all defaults:

```yaml
applications:
  queue-worker:
    keda:
      enabled: true
      type: "queue"
      queueName: "tasks"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
```

**Result:**
- Scales between 2-50 replicas
- Triggers when queue has more than 500 messages per replica
- Polls every 30 seconds
- Scales down after 300 seconds of inactivity

### Example 2: Queue Consumer with Vault

Connection string auto-synced from Vault — no pre-existing K8s secret needed:

```yaml
applications:
  queue-worker:
    keda:
      enabled: true
      type: "queue"
      queueName: "tasks"
      connectionStringSecret:
        vault:
          path: "secrets/data/prod/servicebus"
          property: "connectionString"
```

**Result:**
- Creates an `ExternalSecret` that syncs from Vault into a K8s Secret
- TriggerAuthentication automatically references the generated secret
- Same scaling behavior as Example 1

### Example 3: High-Throughput Topic Consumer

Custom parameters for a high-volume workload:

```yaml
applications:
  event-processor:
    keda:
      enabled: true
      type: "topic"
      topicName: "events"
      subscriptionName: "event-processor"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
      messageCount: "20"
      pollingInterval: 10
      cooldownPeriod: 120
      minReplicaCount: 3
      maxReplicaCount: 50
```

**Result:**
- Scales between 3-50 replicas
- Triggers when subscription has more than 20 messages per replica
- Polls every 10 seconds for faster reaction
- Scales down after 120 seconds of inactivity

### Example 4: Scale-to-Zero Worker

For workloads that should scale to zero when idle:

```yaml
applications:
  batch-processor:
    keda:
      enabled: true
      type: "queue"
      queueName: "batch-jobs"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
      idleReplicaCount: 0
      minReplicaCount: 1
      activationMessageCount: "1"
```

**Result:**
- Scales to 0 replicas when queue is empty
- Activates (scales from 0 to 1) when at least 1 message appears
- Scales between 1-50 replicas when active

### Example 5: Advanced Scaling Policies

Fine-tune scale-down behavior to prevent flapping:

```yaml
applications:
  order-worker:
    keda:
      enabled: true
      type: "queue"
      queueName: "orders"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
      minReplicaCount: 2
      maxReplicaCount: 20
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

**Result:**
- Scales down at most 25% of pods per minute
- Waits 300 seconds of stable metrics before scaling down
- Scales up at most 4 pods per minute

### Example 6: KEDA with Rollout Deployment

KEDA works with all deployment types:

```yaml
applications:
  message-handler:
    deploymentType: rollout
    keda:
      enabled: true
      type: "topic"
      topicName: "messages"
      subscriptionName: "handler"
      connectionStringSecret:
        name: "servicebus-secret"
        key: "connection-string"
```

**Result:**
- ScaledObject targets the Argo Rollout (apiVersion: argoproj.io/v1alpha1)

## HPA and KEDA Mutual Exclusivity

KEDA takes precedence over HPA at the earliest point in the decision logic. When `keda.enabled` is true:

- `autoscaling.enabled: true` is ignored (no HPA created)
- Automatic production scaling is bypassed (no HPA created)
- `global.forceAutoscaling: true` does not create an HPA
- `autoscaling.forceAutoscaling: true` does not create an HPA

The `replicas` field is omitted from the Deployment/StatefulSet/Rollout spec, allowing KEDA to manage the replica count.

| Configuration | HPA Created? | KEDA Created? |
|---------------|-------------|---------------|
| `keda.enabled: true` only | No | Yes |
| `keda.enabled: true` + `autoscaling.enabled: true` | No | Yes |
| `keda.enabled: true` + prod auto-scaling | No | Yes |
| `keda.enabled: false` + `autoscaling.enabled: true` | Yes | No |
| Neither enabled | Depends on env/global settings | No |

## Troubleshooting

### Issue: KEDA not scaling

**Possible causes:**
1. Secret does not exist in the namespace (or ExternalSecret failed to sync)
2. Connection string is invalid or expired
3. Queue/topic name is misspelled
4. `pollingInterval` is too high to notice short bursts

**Solutions:**
- Verify the secret: `kubectl get secret <name> -n <namespace>`
- If using Vault: check ExternalSecret status: `kubectl describe externalsecret <fullName>-keda-servicebus-es`
- Check KEDA operator logs: `kubectl logs -n keda -l app=keda-operator`
- Verify the ScaledObject: `kubectl describe scaledobject <name>`

### Issue: HPA still being created alongside KEDA

**Possible cause:** KEDA is not enabled at the application level.

**Solution:** Ensure `keda.enabled: true` is set on the specific application, not just the other keda fields.

### Issue: Pods not scaling to zero

**Possible causes:**
1. `idleReplicaCount` is not set (defaults to `minReplicaCount`)
2. There are still messages in the queue/subscription

**Solution:** Set `idleReplicaCount: 0` explicitly and verify the queue is empty.

## Related Files

- [templates/keda-scaledobject.yaml](templates/keda-scaledobject.yaml) - ScaledObject and TriggerAuthentication templates
- [templates/_spec_keda.tpl](templates/_spec_keda.tpl) - KEDA spec helpers
- [templates/_helpers.tpl](templates/_helpers.tpl) - `helm.kedaCondition` and `helm.hpaCondition`
- [templates/_defaults.tpl](templates/_defaults.tpl) - KEDA default values
- [templates/_spec_deployment.tpl](templates/_spec_deployment.tpl) - Deployment replicas logic
- [templates/_spec_rollout.tpl](templates/_spec_rollout.tpl) - Rollout replicas logic
- [HPA.md](HPA.md) - HPA autoscaler documentation
- [REPLICAS.md](REPLICAS.md) - Replica defaults documentation
