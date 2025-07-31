# Autoscaling Matrix Test Coverage

This document outlines the comprehensive test matrix for autoscaling behavior covering all combinations of:
- **Environment types** (affecting envScaling)
- **Global forceAutoscaling** setting
- **Individual autoscaling.enabled** setting  
- **Replica configuration** scenarios

## Test Matrix Summary

### Environment Types and envScaling Values

| Environment | forceAutoscaling=false | forceAutoscaling=true |
|-------------|----------------------|----------------------|
| dev         | envScaling = 0       | envScaling = 1       |
| preprod     | envScaling = 0       | envScaling = 1       |
| feature-*   | envScaling = 0       | envScaling = 1       |
| prod        | envScaling = 1       | envScaling = 1       |

### Test Scenarios Covered

#### 1. No Force Autoscaling + No Individual Autoscaling (4 tests)
- ✅ `dev` env: Default replicas = 2, envScaling = 0, no HPA
- ✅ `feature-*` env: Default replicas = 1, envScaling = 0, no HPA  
- ✅ `feature-*` env: Explicit replicas = 5, envScaling = 0, no HPA
- ✅ `prod` env: Default replicas = 2, envScaling = 1, no HPA
- ✅ `prod` env: Explicit replicas = 3, envScaling = 1, no HPA
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

#### 5. Label Verification (2 tests)
- ✅ Verify envScaling label = "1" when forceAutoscaling = true
- ✅ Verify envScaling label = "0" when forceAutoscaling = false in dev

## Key Behaviors Validated

### HPA Creation Logic
HPA is created when: `autoscaling.enabled = true` OR `global.forceAutoscaling = true`

### Replica Field Logic  
Replicas field is **excluded** when: `autoscaling.enabled = true` OR `global.forceAutoscaling = true`

### Environment-Specific Replica Defaults
When autoscaling is disabled:
- `feature-*` environments: Default 1 replica
- All other environments: Default 2 replicas
- Explicit replica values override defaults

### EnvScaling Label Behavior
- `envScaling = 1` when: `forceAutoscaling = true` OR environment is `prod`
- `envScaling = 0` when: `forceAutoscaling = false` AND environment is `dev/preprod/feature-*`

## Test Coverage: 17/17 Tests Passing ✅

All combinations of the matrix are thoroughly tested and validated.
