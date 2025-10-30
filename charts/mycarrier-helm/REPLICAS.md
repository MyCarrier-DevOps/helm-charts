# Replica Configuration and Default Values

This document explains how replica counts are determined in the MyCarrier Helm chart across different environments and configurations.

## Overview

The chart automatically manages replica counts based on:
- **Environment type** (dev, preprod, prod, feature*)
- **envScaling value** (0 or 1)
- **Autoscaling configuration** (per-app and global levels)
- **Application name** (migration apps are special-cased)
- **Explicit replica values** (user-defined overrides)

For comprehensive autoscaling logic and examples, see [AUTOSCALING.md](AUTOSCALING.md).

## envScaling Determination

The `envScaling` label is a key factor in determining behavior:

### envScaling = 0
When the environment is in "development mode":
- Environment is `dev`, `preprod`, or `feature-*`
- **AND** `global.forceAutoscaling` is NOT `true`

### envScaling = 1
When the environment is in "production mode":
- Environment is `prod`, **OR**
- `global.forceAutoscaling` is `true` (any environment)

**Note:** envScaling determines whether automatic HPA creation happens, but can be overridden by `global.forceAutoscaling: false`.

## Default Replica Values Matrix

### Standard Applications (Non-Migration)

| Environment | envScaling | forceAutoscaling | autoscaling.enabled | Explicit replicas | Result | HPA Created? |
|-------------|------------|------------------|---------------------|-------------------|---------|--------------|
| **dev** | 0 | false | false | Not set | replicas: **2** | No |
| **dev** | 0 | false | false | 3 | replicas: **3** | No |
| **dev** | 1 | true | false | Not set | *No replicas field* | Yes |
| **preprod** | 0 | false | false | Not set | replicas: **2** | No |
| **preprod** | 0 | false | false | 5 | replicas: **5** | No |
| **preprod** | 1 | true | false | Not set | *No replicas field* | Yes |
| **feature-xyz** | 0 | false | false | Not set | replicas: **1** | No |
| **feature-xyz** | 0 | false | false | 3 | replicas: **3** | No |
| **feature-xyz** | 1 | true | false | Not set | *No replicas field* | Yes |
| **prod** | 1 | false | false | Not set | *No replicas field* | Yes (auto) |
| **prod** | 1 | false | false | 2 | *No replicas field* | Yes (auto) |
| **prod** | 1 | false | true | Not set | *No replicas field* | Yes |

### Migration Applications (apps with "migration" in name)

Migration apps are **excluded from automatic production autoscaling** to ensure predictable behavior for migration tasks.

| Environment | envScaling | forceAutoscaling | autoscaling.enabled | Explicit replicas | Result | HPA Created? |
|-------------|------------|------------------|---------------------|-------------------|---------|--------------|
| **prod** | 1 | false | false | Not set | replicas: **2** | No |
| **prod** | 1 | false | false | 1 | replicas: **1** | No |
| **prod** | 1 | false | true | Not set | *No replicas field* | Yes |
| **prod** | 1 | true | false | Not set | *No replicas field* | Yes |

## Default Values Summary

When autoscaling is **NOT** active (no HPA created):

| Environment Type | Default Replicas |
|------------------|------------------|
| `feature-*` | **1** |
| `dev` | **2** |
| `preprod` | **2** |
| `prod` (migration apps only) | **2** |

When autoscaling **IS** active (HPA created):
- The `replicas` field is **omitted** from the deployment
- HPA manages scaling between `minReplicas` and `maxReplicas`
- Initial pod count starts at `minReplicas`
- **Default HPA values** (defined in `_spec_hpa.tpl`):
  - `minReplicas`: **2**
  - `maxReplicas`: **10**
  - `targetCPUUtilizationPercentage`: **80**

## Template Logic Reference

### Deployment Template Logic

The logic in `_spec_deployment.tpl` follows this decision tree:

```
Is autoscaling active? (autoscaling.enabled OR forceAutoscaling OR (envScaling=1 AND NOT migration app))
├─ YES: Omit replicas field (HPA will manage)
└─ NO: Set replicas field
    ├─ envScaling = 0?
    │   ├─ YES: Is feature-* environment?
    │   │   ├─ YES: Use explicit replicas OR default to 1
    │   │   └─ NO: Use explicit replicas OR default to 2
    │   └─ NO: (envScaling = 1)
    │       ├─ Is feature-* environment?
    │       │   └─ YES: Use explicit replicas OR default to 1
    │       └─ NO: Use explicit replicas OR default to 2
```

### Helper Template: helm.envScaling

Located in `_helpers.tpl`:

```yaml
{{- define "helm.envScaling" -}}
{{- $envName := .Values.environment.name -}}
{{- $forceAutoscaling := .Values.global.forceAutoscaling -}}
{{- $envList := list "dev" "preprod" -}}
{{- if and (or (has $envName $envList) (hasPrefix "feature" $envName)) (not $forceAutoscaling) -}}
  0
{{- else -}}
  1
{{- end -}}
{{- end -}}
```

## Examples

### Example 1: Development Environment (envScaling=0)

```yaml
global:
  forceAutoscaling: false

environment:
  name: "dev"

applications:
  api:
    # No explicit replicas or autoscaling config
```

**Result:**
- envScaling: **0**
- HPA: **Not created**
- Deployment replicas: **2** (default)

### Example 2: Feature Environment (envScaling=0)

```yaml
global:
  forceAutoscaling: false

environment:
  name: "feature-login-redesign"

applications:
  frontend:
    # No explicit replicas or autoscaling config
```

**Result:**
- envScaling: **0**
- HPA: **Not created**
- Deployment replicas: **1** (feature default)

### Example 3: Production Environment (envScaling=1, Auto-HPA)

```yaml
global:
  forceAutoscaling: false

environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: false  # Still gets HPA due to automatic production autoscaling
      minReplicas: 2
      maxReplicas: 10
```

**Result:**
- envScaling: **1**
- HPA: **Created automatically** (production environment)
- Deployment replicas: **Omitted** (HPA manages scaling)
- Initial pods: **2** (minReplicas)

### Example 4: Production Migration App (envScaling=1, No Auto-HPA)

```yaml
global:
  forceAutoscaling: false

environment:
  name: "prod"

applications:
  db-migration:
    # No explicit replicas or autoscaling config
```

**Result:**
- envScaling: **1**
- HPA: **Not created** (migration app excluded)
- Deployment replicas: **2** (default)

### Example 5: Force Autoscaling in Dev (envScaling=1)

```yaml
global:
  forceAutoscaling: true  # Forces envScaling=1 in all environments

environment:
  name: "dev"

applications:
  api:
    autoscaling:
      enabled: false  # Overridden by forceAutoscaling
      minReplicas: 1
      maxReplicas: 5
```

**Result:**
- envScaling: **1** (forced)
- HPA: **Created** (global force)
- Deployment replicas: **Omitted** (HPA manages scaling)
- Initial pods: **1** (minReplicas)

### Example 6: Explicit Replica Override

```yaml
global:
  forceAutoscaling: false

environment:
  name: "dev"

applications:
  worker:
    replicas: 5  # Explicit override
```

**Result:**
- envScaling: **0**
- HPA: **Not created**
- Deployment replicas: **5** (explicit value used)

### Example 7: Migration App with Explicit Autoscaling

```yaml
global:
  forceAutoscaling: false

environment:
  name: "prod"

applications:
  db-migration:
    autoscaling:
      enabled: true  # Explicitly enable autoscaling
      minReplicas: 1
      maxReplicas: 3
```

**Result:**
- envScaling: **1**
- HPA: **Created** (explicitly enabled)
- Deployment replicas: **Omitted** (HPA manages scaling)
- Initial pods: **1** (minReplicas)

## Best Practices

### 1. Feature Environments
- Default of 1 replica is cost-effective for testing
- Override with explicit `replicas` if you need more

### 2. Development/Staging Environments
- Default of 2 replicas provides basic redundancy
- Consider explicit autoscaling for load testing

### 3. Production Environments
- Automatic HPA creation ensures scalability
- Migration apps are excluded - use explicit config if needed
- Always configure appropriate `minReplicas` and `maxReplicas`

### 4. Migration Apps
- Excluded from automatic production autoscaling by default
- Use explicit `autoscaling.enabled: true` if scaling is needed
- Consider using `replicas: 1` for one-time migrations

### 5. Cost Optimization
- Use `forceAutoscaling: false` in non-prod environments
- Feature branches automatically default to 1 replica
- Explicitly set `replicas: 0` to completely disable deployments

## Troubleshooting

### Issue: Too many replicas in feature environment
**Cause:** Explicit replicas set or autoscaling enabled
**Solution:** Remove explicit `replicas` field to use default of 1

### Issue: Migration not scaling in production
**Cause:** Migration apps are excluded from auto-scaling
**Solution:** Set `autoscaling.enabled: true` explicitly for the migration app

### Issue: Pods not scaling in production
**Cause:** HPA might not be created
**Solution:** Check that environment is `prod` or `forceAutoscaling: true`

### Issue: Dev environment using too many resources
**Cause:** Default is 2 replicas per app
**Solution:** Set explicit `replicas: 1` or use feature branch naming

## Related Files

- [autoscaler.yaml](templates/autoscaler.yaml) - HPA template with auto-creation logic
- [_spec_deployment.tpl](templates/_spec_deployment.tpl) - Deployment replica logic
- [_spec_rollout.tpl](templates/_spec_rollout.tpl) - Rollout replica logic
- [_helpers.tpl](templates/_helpers.tpl) - envScaling helper function
- [AUTOSCALING_TEST_MATRIX.md](AUTOSCALING_TEST_MATRIX.md) - Comprehensive test coverage
- [README.md](README.md#autoscaling-configuration) - Main autoscaling documentation
