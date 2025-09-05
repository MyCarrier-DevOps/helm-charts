# Multi-Frontend Deployment Guide

This document explains how to deploy multiple frontend applications using a single Virtual Service with path-based routing.

## Overview

The multi-frontend capability allows you to deploy multiple frontend applications under a single domain with different path prefixes:

- `/` → Primary frontend application
- `/ui/welcome` → Welcome portal
- `/ui/admin` → Admin portal  
- `/ui/customer` → Customer portal

## Configuration

### Required Parameters

```yaml
applications:
  app-name:
    isFrontend: true              # Marks this as a frontend app
    isPrimary: true|false         # One app must be primary (handles root path)
    routePrefix: "/path"          # URL path prefix for this app
```

### Example Configuration

See `examples/values-multifrontend.yaml` for a complete example.

## How It Works

### Virtual Service Generation

The multi-frontend system creates a single Virtual Service that:

1. **Collects all frontend applications** marked with `isFrontend: true`
2. **Identifies the primary application** with `isPrimary: true`
3. **Creates path-based routing rules** ordered by specificity
4. **Handles environment-specific routing** for feature branches
5. **Preserves existing functionality** like redirects and custom routes

### Routing Priority

Routes are processed in this order:

1. Environment header matching (for non-feature environments)
2. Specific path prefixes (most specific first)
3. Custom routes from existing configuration
4. Domain redirects
5. Default/root route (primary application)

### Feature Branch Support

For feature branches, an additional "offload" Virtual Service is created to handle the feature-specific hostname routing.

## Backward Compatibility

The multi-frontend Virtual Service is only created when:
- Multiple applications have `isFrontend: true`
- At least one application has `isPrimary: true`

**Important Notes:**
- Single frontend apps use the standard `virtualService.yaml` template only
- When multi-frontend conditions are met, both `virtualService.yaml` and `frontendVirtualService.yaml` run simultaneously
- Individual VirtualServices handle app-to-app routing; multi-frontend VirtualServices handle coordinated path-based routing
- Only one app should have `isPrimary: true` (handles root path `/`)

Existing single-application deployments continue to work without changes.

## Template Files

This feature uses these templates:
- `templates/virtualService.yaml` - Creates individual VirtualServices for each app (always runs)
- `templates/frontendVirtualService.yaml` - Creates coordinating multi-frontend VirtualServices (conditional)
- `templates/_spec_multifrontend_virtualservice.tpl` - Virtual Service spec logic for multi-frontend
- `templates/_helpers_frontend.tpl` - Frontend-specific helper functions