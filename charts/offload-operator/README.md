# Offload Operator Helm Chart

Deploys the offload-operator, which reconciles `OffloadBase` and `OffloadRoute` CRDs into consolidated Istio VirtualServices for feature-environment offload routing.

## Configuration

| Parameter | Description | Default |
|---|---|---|
| `image.repository` | Container image repository | `ghcr.io/mycarrier-devops/offload-operator` |
| `image.tag` | Container image tag | See `values.yaml` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `replicaCount` | Number of operator replicas | `1` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `10m` |
| `resources.requests.memory` | Memory request | `64Mi` |
| `leaderElection.enabled` | Enable leader election | `true` |
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name override | `""` |
| `nodeSelector` | Node selector | `{}` |
| `tolerations` | Tolerations | `[]` |
| `affinity` | Affinity rules | `{}` |
