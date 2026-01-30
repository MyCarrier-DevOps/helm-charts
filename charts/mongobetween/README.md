# mongobetween Helm Chart

A Helm chart for deploying [mongobetween](https://github.com/coinbase/mongobetween) - a lightweight MongoDB connection proxy with distributed cursor/transaction caching via Dragonfly.

## Features

- **High Performance**: Pre-configured for 10,000+ ops/sec without scaling
- **Distributed Caching**: Dragonfly (Redis-compatible) for cursor and transaction state
- **Autoscaling**: Supports both standard Kubernetes HPA and KEDA custom metrics
- **Istio Integration**: Traffic interception via ServiceEntry and VirtualService
- **OpenTelemetry**: Built-in metrics for observability

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- (Optional) Dragonfly Operator for distributed caching
- (Optional) KEDA for custom metric autoscaling
- (Optional) Istio for traffic interception

## Installation

### Basic Installation

```bash
helm install mongobetween ./charts/mongobetween \
  --namespace mongobetween \
  --create-namespace \
  --set mongodb.uri="mongodb+srv://user:pass@cluster.mongodb.net/db"
```

### With Istio Traffic Interception

```bash
helm install mongobetween ./charts/mongobetween \
  --namespace mongobetween \
  --create-namespace \
  --set mongodb.uri="mongodb+srv://user:pass@cluster.mongodb.net/db" \
  --set istio.enabled=true \
  --set istio.interceptHost="preprod.hpp8s.mongodb.net" \
  --set istio.targetNamespace="dev"
```

### With KEDA Autoscaling

```bash
helm install mongobetween ./charts/mongobetween \
  --namespace mongobetween \
  --create-namespace \
  --set mongodb.uri="mongodb+srv://user:pass@cluster.mongodb.net/db" \
  --set autoscaling.keda.enabled=true
```

## Configuration

### Core Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas (before autoscaling) | `2` |
| `image.repository` | mongobetween image repository | `ghcr.io/mycarrier-devops/mongobetween` |
| `image.tag` | Image tag | `latest` |
| `mongodb.uri` | MongoDB connection URI | `""` (required) |
| `mongodb.ping` | Ping MongoDB on startup | `true` |

### Pool Tuning (for 10k ops/sec)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `poolTuning.minPoolSize` | Minimum backend connections | `50` |
| `poolTuning.maxPoolSize` | Maximum backend connections | `500` |
| `poolTuning.maxConnecting` | Max concurrent connection establishments | `8` |
| `poolTuning.maxIdleTimeMS` | Connection idle timeout (ms) | `300000` |

### Dragonfly Cache

| Parameter | Description | Default |
|-----------|-------------|---------|
| `dragonfly.enabled` | Enable Dragonfly for distributed caching | `true` |
| `dragonfly.replicas` | Number of Dragonfly replicas | `2` |
| `dragonfly.resources.requests.memory` | Dragonfly memory request | `512Mi` |
| `dragonfly.resources.limits.memory` | Dragonfly memory limit | `1Gi` |

### Autoscaling

| Parameter | Description | Default |
|-----------|-------------|---------|
| `autoscaling.enabled` | Enable standard HPA | `true` |
| `autoscaling.minReplicas` | Minimum replicas | `2` |
| `autoscaling.maxReplicas` | Maximum replicas | `20` |
| `autoscaling.targetCPUUtilizationPercentage` | CPU threshold | `70` |
| `autoscaling.targetMemoryUtilizationPercentage` | Memory threshold | `80` |
| `autoscaling.keda.enabled` | Enable KEDA autoscaling | `false` |
| `autoscaling.keda.saturationThreshold` | Saturation metric threshold | `10` |

### Istio Traffic Interception

| Parameter | Description | Default |
|-----------|-------------|---------|
| `istio.enabled` | Enable Istio integration | `false` |
| `istio.interceptHost` | MongoDB host to intercept | `""` |
| `istio.interceptPort` | MongoDB port to intercept | `27017` |
| `istio.targetNamespace` | Namespace to apply interception | `""` |
| `istio.tlsMode` | TLS mode for upstream | `SIMPLE` |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Target Namespace                               │
│  ┌─────────────┐                                                        │
│  │  App Pods   │──── mongodb+srv://preprod.hpp8s.mongodb.net ────┐     │
│  └─────────────┘                                                  │     │
└───────────────────────────────────────────────────────────────────│─────┘
                                                                    │
                    Istio VirtualService intercepts                 │
                                                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        mongobetween Namespace                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      mongobetween Deployment                     │   │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐    │   │
│  │  │ Pod 1     │  │ Pod 2     │  │ Pod 3     │  │ Pod N     │    │   │
│  │  │           │  │           │  │           │  │ (HPA/KEDA)│    │   │
│  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘    │   │
│  │        │              │              │              │           │   │
│  │        └──────────────┴──────────────┴──────────────┘           │   │
│  │                              │                                   │   │
│  │                     Distributed Cache                            │   │
│  │                              │                                   │   │
│  │                    ┌─────────▼─────────┐                        │   │
│  │                    │    Dragonfly      │                        │   │
│  │                    │  (cursor/txn)     │                        │   │
│  │                    └───────────────────┘                        │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                        ┌───────────────────┐
                        │  MongoDB Atlas    │
                        │  (actual backend) │
                        └───────────────────┘
```

## Metrics

mongobetween exports OpenTelemetry metrics:

| Metric | Description |
|--------|-------------|
| `mongobetween_saturation` | Pool utilization (0-100%) - primary scaling metric |
| `mongobetween_concurrent_operations` | Current in-flight operations |
| `mongobetween_operations_total` | Total operations processed |
| `mongobetween_round_trip_duration` | MongoDB round-trip latency |
| `mongobetween_pool_checked_out_connections` | Connections in use |

## Scaling Recommendations

Based on empirical testing:

- **10% saturation**: 36% latency degradation (acceptable)
- **20% saturation**: 120% latency degradation (scale point)
- **70% saturation**: 541% latency degradation (too late)

**Recommendation**: Scale at 10% saturation to maintain low latency.
