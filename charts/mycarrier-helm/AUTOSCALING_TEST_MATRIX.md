# Autoscaling Matrix Test Coverage

This document outlines the comprehensive test matrix for autoscaling behavior covering all combinations of:
- **Environment types** (affecting envScaling)
- **Global forceAutoscaling** setting
- **Individual autoscaling.enabled** setting
- **Replica configuration** scenarios
- **Migration app exception** (apps with "migration" in name)

## Test Matrix Summary

### Environment Types and envScaling Values

| Environment | forceAutoscaling=false | forceAutoscaling=true |
|-------------|----------------------|----------------------|
| dev         | envScaling = 0       | envScaling = 1       |
| preprod     | envScaling = 0       | envScaling = 1       |
| feature-*   | envScaling = 0       | envScaling = 1       |
| prod        | envScaling = 1       | envScaling = 1       |

### Test Scenarios Covered

#### 1. No Force Autoscaling + No Individual Autoscaling (6 tests)
- ✅ `dev` env: Default replicas = 2, envScaling = 0, no HPA
- ✅ `feature-*` env: Default replicas = 1, envScaling = 0, no HPA
- ✅ `feature-*` env: Explicit replicas = 5, envScaling = 0, no HPA
- ✅ `prod` env: Default replicas, envScaling = 1, **HPA auto-created** for non-migration apps
- ✅ `prod` env: Explicit replicas, envScaling = 1, **HPA auto-created** for non-migration apps
- ✅ `prod` env: Explicit replicas = 0/1, envScaling = 1, **HPA auto-created** for non-migration apps
- ✅ `preprod` env: Default replicas = 2, envScaling = 0, no HPA

#### 2. No Force Autoscaling + Individual Autoscaling Enabled (3 tests)
- ✅ `dev` env: envScaling = 0, HPA created, no replicas field
- ✅ `feature-*` env: envScaling = 0, HPA created, no replicas field
- ✅ `prod` env: envScaling = 1, HPA created, no replicas field

#### 3. Force Autoscaling + Individual Autoscaling Disabled (3 tests)
- ✅ `dev` env: envScaling = 1, HPA created, no replicas field
- ✅ `feature-*` env: envScaling = 1, HPA created, no replicas field (explicit replicas ignored)
- ✅ `prod` env: envScaling = 1, HPA created, no replicas field

#### 4. Force Autoscaling + Individual Autoscaling Enabled (3 tests)
- ✅ `dev` env: envScaling = 1, HPA created, no replicas field
- ✅ `feature-*` env: envScaling = 1, HPA created, no replicas field
- ✅ `prod` env: envScaling = 1, HPA created, no replicas field

#### 5. Migration App Exception (5 tests)
- ✅ `prod` env: Migration app with "migration" in name should NOT auto-scale
- ✅ `prod` env: Migration app with "migration" suffix should NOT auto-scale
- ✅ `prod` env: Migration app with "migration" in middle should NOT auto-scale
- ✅ `prod` env: Migration app with explicit `autoscaling.enabled=true` should still create HPA
- ✅ `prod` env: Migration app with `forceAutoscaling=true` should create HPA

#### 6. Label Verification (2 tests)
- ✅ Verify envScaling label = "1" when forceAutoscaling = true
- ✅ Verify envScaling label = "0" when forceAutoscaling = false in dev

## Key Behaviors Validated

### HPA Creation Logic
HPA is created when **ANY** of the following conditions are met:
- `autoscaling.enabled = true`, OR
- `global.forceAutoscaling = true`, OR
- `envScaling = 1` (production environment) AND app name does NOT contain "migration"

### HPA Default Values
When HPA is created, these defaults are used (defined in `_spec_hpa.tpl`):
- `minReplicas`: **2** (if not explicitly set)
- `maxReplicas`: **10** (if not explicitly set)
- `targetCPUUtilizationPercentage`: **80** (if not explicitly set)

### Migration App Exception
Applications with "migration" in their name are excluded from automatic production autoscaling to ensure predictable behavior for migration tasks. This exception can be overridden by:
- Setting `autoscaling.enabled = true` for the specific migration app, OR
- Setting `global.forceAutoscaling = true` globally

### Replica Field Logic
Replicas field is **excluded** when HPA is created (see HPA Creation Logic above)

### Environment-Specific Replica Defaults
When autoscaling is disabled:
- `feature-*` environments: Default 1 replica
- All other environments: Default 2 replicas
- Explicit replica values override defaults

### EnvScaling Label Behavior
- `envScaling = 1` when: `forceAutoscaling = true` OR environment is `prod`
- `envScaling = 0` when: `forceAutoscaling = false` AND environment is `dev/preprod/feature-*`

## Test Coverage Summary

Total test scenarios: **24 tests**
- No Force + No Individual Autoscaling: 6 tests
- No Force + Individual Autoscaling Enabled: 3 tests
- Force Autoscaling + Individual Disabled: 3 tests
- Force Autoscaling + Individual Enabled: 3 tests
- Migration App Exception: 5 tests
- Label Verification: 2 tests
- Explicit replica edge cases: 2 tests

All combinations of the matrix are thoroughly tested and validated. ✅

## Examples

### Automatic Production Autoscaling (New Behavior)
In production environments (`envScaling=1`):
```yaml
environment:
  name: "prod"

applications:
  api:
    autoscaling:
      enabled: false  # HPA still created automatically in prod
      minReplicas: 2
      maxReplicas: 10
```
Result: HPA is created because environment is production

### Migration App Exception
```yaml
environment:
  name: "prod"

applications:
  db-migration:
    autoscaling:
      enabled: false  # No HPA created - migration app excluded
      minReplicas: 1
```
Result: No HPA created because app name contains "migration"

### Override Migration Exception
```yaml
environment:
  name: "prod"

applications:
  db-migration:
    autoscaling:
      enabled: true  # Explicitly enable autoscaling
      minReplicas: 1
      maxReplicas: 3
```
Result: HPA is created because `autoscaling.enabled=true` overrides the migration exception
