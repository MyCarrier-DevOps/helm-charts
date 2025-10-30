# Autoscaling Configuration Guide

This document provides a comprehensive guide to autoscaling behavior in the MyCarrier Helm chart, including the decision logic, configuration hierarchy, and detailed examples.

## Overview

The chart provides intelligent autoscaling with multiple configuration levels:
- **Automatic production autoscaling** for non-migration apps
- **Global force autoscaling** to enable HPA in any environment
- **Per-application autoscaling** for fine-grained control
- **Migration app protection** to prevent unintended scaling of migrations
- **Override mechanism** to explicitly disable autoscaling

## Configuration Hierarchy

Autoscaling is determined by checking configurations in this order (highest precedence first):

1. **Per-app explicit enable**: `applications.<app>.autoscaling.enabled`
2. **Per-app force**: `applications.<app>.autoscaling.forceAutoscaling`
3. **Global override**: `global.forceAutoscaling: false` (blocks automatic scaling)
4. **Global force**: `global.forceAutoscaling: true`
5. **Automatic prod scaling**: `envScaling=1` (production environments)

## Configuration Options

### Global Level

```yaml
global:
  forceAutoscaling: true | false | not set
```

- **`true`**: Forces HPA creation for all non-migration apps in any environment
- **`false`**: Acts as an **override** - disables all automatic scaling (including prod)
- **not set** (default): Allows automatic production scaling for non-migration apps

### Application Level

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
- **`enabled: false`**: Does not create HPA unless overridden by force flags or automatic scaling
- **`forceAutoscaling: true`**: Creates HPA even for migration apps
- **`forceAutoscaling: false`**: Explicitly disables HPA for this app

## Decision Matrix

### Standard Applications (Non-Migration)

| Environment | envScaling | global.force | app.enabled | app.force | HPA? | Reason |
|-------------|------------|--------------|-------------|-----------|------|--------|
| dev | 0 | not set | not set | not set | No | No triggers active |
| dev | 0 | not set | true | - | Yes | Explicit enable |
| dev | 0 | true | not set | not set | Yes | Global force |
| dev | 0 | false | not set | not set | No | Global override |
| dev | 0 | false | true | - | Yes | Explicit enable overrides override |
| dev | 0 | false | not set | true | Yes | App force overrides override |
| preprod | 0 | not set | not set | not set | No | No triggers active |
| preprod | 0 | true | not set | not set | Yes | Global force |
| preprod | 0 | false | not set | not set | No | Global override |
| feature-x | 0 | not set | not set | not set | No | No triggers active |
| feature-x | 0 | true | not set | not set | Yes | Global force |
| feature-x | 0 | false | not set | not set | No | Global override |
| **prod** | 1 | not set | not set | not set | **Yes** | **Auto-scale in prod** |
| prod | 1 | not set | not set | false | **No** | **App force=false blocks auto-scale** |
| prod | 1 | not set | true | - | Yes | Explicit enable wins |
| prod | 1 | false | not set | not set | **No** | **override disables prod auto-scale** |
| prod | 1 | false | true | - | Yes | Explicit enable overrides override |
| prod | 1 | false | not set | true | Yes | App force overrides override |
| prod | 1 | false | not set | false | No | App force=false + override |
| prod | 1 | true | not set | not set | Yes | Global force + prod |
| prod | 1 | true | not set | false | No | App force=false blocks global force |

### Migration Applications (name contains "migration")

| Environment | envScaling | global.force | app.enabled | app.force | HPA? | Reason |
|-------------|------------|--------------|-------------|-----------|------|--------|
| prod | 1 | not set | not set | not set | **No** | **Migrations excluded from auto-scale** |
| prod | 1 | not set | not set | false | No | App force=false blocks (already no HPA) |
| prod | 1 | not set | true | - | Yes | Explicit enable works |
| prod | 1 | **true** | not set | not set | **No** | **Global force excluded for migrations** |
| prod | 1 | true | not set | **true** | Yes | **App force works for migrations** |
| prod | 1 | true | not set | false | No | App force=false blocks global force |
| prod | 1 | false | not set | not set | No | override active |
| prod | 1 | false | true | - | Yes | Explicit enable overrides override |
| prod | 1 | false | not set | true | Yes | App force overrides override |
| prod | 1 | false | not set | false | No | App force=false + override |

## HPA Creation Logic

### Pseudocode

```python
def should_create_hpa(app_name, app_config, global_config, env_scaling):
    # 1. Explicit enable always wins
    if app_config.autoscaling.enabled == true:
        return True

    # 2. App-level force (works even for migrations)
    if app_config.autoscaling.forceAutoscaling == true:
        return True

    # 3. App-level forceAutoscaling false explicitly disables HPA
    if app_config.autoscaling.forceAutoscaling == false:
        return False

    # 4. Global override blocks automatic scaling
    if global_config.forceAutoscaling == false:
        return False

    # 5. Global force (but NOT for migrations)
    if global_config.forceAutoscaling == true:
        if is_migration_app(app_name):
            return False  # Migrations excluded from global force
        else:
            return True

    # 6. Automatic production scaling (but NOT for migrations)
    if env_scaling == "1":  # Production environment
        if is_migration_app(app_name):
            return False  # Migrations excluded from auto-scaling
        else:
            return True  # Auto-scale in prod

    # 7. Default: no HPA
    return False

def is_migration_app(app_name):
    return "migration" in app_name.lower()
```

### Template Implementation

The logic is implemented in:
- `templates/autoscaler.yaml` - HPA creation condition
- `templates/_spec_deployment.tpl` - Replicas field omission
- `templates/_spec_rollout.tpl` - Replicas field omission

## Examples

### Example 1: Default Production Behavior

```yaml
environment:
  name: "prod"

applications:
  api:
    # No autoscaling config needed
```

**Result:**
- envScaling: 1
- HPA: Created automatically
- minReplicas: 2 (default)
- maxReplicas: 10 (default)

### Example 2: Disable Production Autoscaling (override)

```yaml
global:
  forceAutoscaling: false  # override to disable prod auto-scaling

environment:
  name: "prod"

applications:
  api:
    replicas: 3
```

**Result:**
- envScaling: 1
- HPA: NOT created (override active)
- Deployment replicas: 3

### Example 3: Force Autoscaling in Dev

```yaml
global:
  forceAutoscaling: true  # Force HPA in all environments

environment:
  name: "dev"

applications:
  api:
    autoscaling:
      minReplicas: 1
      maxReplicas: 5
```

**Result:**
- envScaling: 1 (forced)
- HPA: Created
- Scales: 1-5 replicas

### Example 4: Migration App in Production

```yaml
environment:
  name: "prod"

applications:
  db-migration:
    # Migration apps don't auto-scale
    replicas: 1
```

**Result:**
- envScaling: 1
- HPA: NOT created (migration app excluded)
- Deployment replicas: 1

### Example 5: Override Migration Exception with App Force

```yaml
environment:
  name: "prod"

applications:
  db-migration:
    autoscaling:
      forceAutoscaling: true  # App-level force works for migrations
      minReplicas: 1
      maxReplicas: 3
```

**Result:**
- envScaling: 1
- HPA: Created (app-level force)
- Scales: 1-3 replicas

### Example 6: Global Force Does NOT Affect Migrations

```yaml
global:
  forceAutoscaling: true  # Global force active

environment:
  name: "prod"

applications:
  api:
    # Regular app - gets HPA

  db-migration:
    # Migration app - does NOT get HPA from global force
    replicas: 1
```

**Result:**
- `api`: HPA created (global force)
- `db-migration`: HPA NOT created (migrations excluded from global force)

### Example 7: Explicit Enable Always Wins

```yaml
global:
  forceAutoscaling: false  # override active

environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: true  # Explicit enable overrides override
      minReplicas: 2
      maxReplicas: 10
```

**Result:**
- HPA: Created (explicit enable has highest precedence)
- override does not apply

### Example 8: Mixed Configuration

```yaml
global:
  forceAutoscaling: false  # override for most apps

environment:
  name: "prod"

applications:
  api:
    # No HPA (override blocks prod auto-scaling)
    replicas: 3

  worker:
    autoscaling:
      forceAutoscaling: true  # App-level force overrides override
      minReplicas: 2
      maxReplicas: 8

  frontend:
    autoscaling:
      enabled: true  # Explicit enable overrides override
      minReplicas: 3
      maxReplicas: 12

  db-migration:
    # No HPA (migration + override)
    replicas: 1
```

**Result:**
- `api`: No HPA, 3 replicas
- `worker`: HPA created (app force overrides override)
- `frontend`: HPA created (explicit enable overrides override)
- `db-migration`: No HPA, 1 replica

## Default HPA Values

When HPA is created, these defaults apply (defined in `_spec_hpa.tpl`):

```yaml
minReplicas: 2
maxReplicas: 10
targetCPUUtilizationPercentage: 80
```

Override these per application:

```yaml
applications:
  api:
    autoscaling:
      minReplicas: 3
      maxReplicas: 20
      targetCPUUtilizationPercentage: 70
      targetMemoryUtilizationPercentage: 80  # Optional
```

## Migration App Detection

An application is considered a "migration app" if its name contains "migration" (case-insensitive):

**Migration Apps:**
- `db-migration`
- `schema-migration`
- `data-migration-worker`
- `migration-service`

**Not Migration Apps:**
- `api`
- `worker`
- `migrate-service` (does not contain "migration")

## envScaling Behavior

The `envScaling` label determines environment behavior:

### envScaling = 0 (Development Mode)
- Environments: `dev`, `preprod`, `feature-*`
- Condition: When `global.forceAutoscaling != true`
- Behavior: No automatic HPA creation

### envScaling = 1 (Production Mode)
- Environments: `prod` OR any environment when `global.forceAutoscaling == true`
- Behavior: Automatic HPA creation for non-migration apps

## Use Cases

### Use Case 1: Standard Production Deployment
**Goal:** Auto-scale all apps in production, keep migrations static

```yaml
environment:
  name: "prod"
# No global.forceAutoscaling needed - prod auto-scales by default
```

### Use Case 2: Cost-Optimized Production
**Goal:** Disable autoscaling in production to control costs

```yaml
global:
  forceAutoscaling: false  # override

environment:
  name: "prod"

applications:
  api:
    replicas: 2  # Static replicas
```

### Use Case 3: Development with Autoscaling
**Goal:** Test autoscaling in development environment

```yaml
global:
  forceAutoscaling: true  # Enable HPA in dev

environment:
  name: "dev"
```

### Use Case 4: Selective Autoscaling
**Goal:** Only specific apps autoscale, others stay static

```yaml
global:
  forceAutoscaling: false  # Disable auto-scaling

environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: true  # Only this app gets HPA
      minReplicas: 3
      maxReplicas: 15

  worker:
    replicas: 2  # Static

  db-migration:
    replicas: 1  # Static
```

### Use Case 5: Scale Migration in Production
**Goal:** Unusual case where migration needs to scale

```yaml
environment:
  name: "prod"

applications:
  data-migration-worker:
    autoscaling:
      forceAutoscaling: true  # App-level force for migration
      minReplicas: 1
      maxReplicas: 5
```

## Troubleshooting

### Issue: HPA not created in production
**Possible Causes:**
1. App is a migration app (contains "migration" in name)
2. `global.forceAutoscaling: false` is set (override)
3. `autoscaling.enabled: false` is explicitly set

**Solutions:**
- For migrations: Set `autoscaling.forceAutoscaling: true` at app level
- Remove `global.forceAutoscaling: false` or set `autoscaling.enabled: true`

### Issue: Unwanted HPA in development
**Possible Causes:**
1. `global.forceAutoscaling: true` is set
2. `autoscaling.enabled: true` is set at app level

**Solutions:**
- Set `global.forceAutoscaling: false`
- Remove `autoscaling.enabled: true` from app config

### Issue: Migration app auto-scaling in production
**Possible Causes:**
1. `autoscaling.enabled: true` set for migration app
2. `autoscaling.forceAutoscaling: true` set for migration app

**Solutions:**
- This is working as designed if explicitly configured
- Remove explicit autoscaling config if unintended

### Issue: Cannot disable autoscaling in production
**Solution:**
Set the override: `global.forceAutoscaling: false`

### Issue: Want to scale only one app in production
**Solution:**
```yaml
global:
  forceAutoscaling: false  # Disable auto-scaling

applications:
  api:
    autoscaling:
      enabled: true  # Only this app scales
```

## Best Practices

### Production Environments
1. **Default behavior is good**: Let prod auto-scale by default
2. **Use override sparingly**: Only use `forceAutoscaling: false` when you truly need static replicas
3. **Monitor HPA metrics**: Ensure minReplicas and maxReplicas are appropriate

### Migration Apps
1. **Keep static by default**: Migrations should have predictable resource usage
2. **Use explicit replicas**: Set `replicas: 1` for one-time migrations
3. **App-level force for special cases**: Use `autoscaling.forceAutoscaling: true` only when needed

### Development/Staging
1. **Keep autoscaling disabled**: Save costs in non-prod environments
2. **Test autoscaling selectively**: Use `autoscaling.enabled: true` on specific apps when testing
3. **Use global force for load testing**: Set `global.forceAutoscaling: true` temporarily

### Cost Optimization
1. **Feature branches**: Keep replicas low (default is 1)
2. **Dev environments**: Use override if needed: `forceAutoscaling: false`
3. **Right-size defaults**: Adjust `minReplicas` per app instead of global force

## Related Files

- [templates/autoscaler.yaml](templates/autoscaler.yaml) - HPA resource template
- [templates/_spec_hpa.tpl](templates/_spec_hpa.tpl) - HPA spec with defaults
- [templates/_spec_deployment.tpl](templates/_spec_deployment.tpl) - Deployment replicas logic
- [templates/_spec_rollout.tpl](templates/_spec_rollout.tpl) - Rollout replicas logic
- [templates/_context.tpl](templates/_context.tpl) - Default forceAutoscaling value
- [REPLICAS.md](REPLICAS.md) - Replica defaults documentation
- [AUTOSCALING_TEST_MATRIX.md](AUTOSCALING_TEST_MATRIX.md) - Test coverage
- [README.md](README.md#autoscaling-configuration) - Quick reference
