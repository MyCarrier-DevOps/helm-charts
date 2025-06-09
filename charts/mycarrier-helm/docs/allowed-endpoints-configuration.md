# Allowed Endpoints Configuration

The `allowedEndpoints` configuration supports both legacy and new formats for maximum flexibility.

## New Format (Recommended)

The new format provides explicit control over the type of URI matching:

```yaml
applications:
  myapp:
    networking:
      istio:
        enabled: true
        allowedEndpoints:
          # Exact matches
          - kind: "exact"
            match: "/robots.txt"
          - kind: "exact"
            match: "/health"
          
          # Prefix matches  
          - kind: "prefix"
            match: "/api/"
          - kind: "prefix"
            match: "/docs/"
          
          # Regex matches (RE2 syntax)
          - kind: "regex"
            match: "/webhook/(dwolla|plaid|stripe)"
          - kind: "regex"
            match: "/api/v[12]/users"
          - kind: "regex"
            match: "^/(health|ready|status)$"
```

## Legacy Format (Still Supported)

The legacy format continues to work for backward compatibility:

```yaml
applications:
  myapp:
    networking:
      istio:
        enabled: true
        allowedEndpoints:
          - "/exact/path"        # Exact match
          - "/prefix/path/*"     # Prefix match (removes * and after)
```

## Match Types

### Exact Match (`kind: "exact"`)
- Matches the URI exactly as specified
- Case-sensitive
- Use for specific endpoints like `/health`, `/robots.txt`

### Prefix Match (`kind: "prefix"`)
- Matches URIs that start with the specified prefix
- Case-sensitive
- Use for API paths like `/api/`, `/docs/`

### Regex Match (`kind: "regex"`)
- Uses RE2 regex syntax for complex pattern matching
- Supports advanced patterns like version matching, parameter validation
- Examples:
  - `/api/v[12]/users` - Match API versions 1 or 2
  - `/users/\\d+` - Match numeric user IDs
  - `(?i)/admin` - Case-insensitive matching
  - `^/(health|ready|status)$` - Multiple exact endpoints

## How It Works

1. **Allowed Endpoints**: Each endpoint in the list creates an HTTP route that allows traffic
2. **Forbidden Rule**: A catch-all rule at the end returns 403 for any non-allowed endpoints
3. **Rule Order**: Istio processes rules in order, so allowed endpoints are checked first

## Migration Guide

To migrate from legacy to new format:

**Before (Legacy):**
```yaml
allowedEndpoints:
  - "/api/users"
  - "/docs/*"
```

**After (New):**
```yaml
allowedEndpoints:
  - kind: "exact"
    match: "/api/users"
  - kind: "prefix"  
    match: "/docs/"
```

## Common Patterns

### API Versioning
```yaml
- kind: "regex"
  match: "/api/v[12]/"
```

### User IDs
```yaml
- kind: "regex"
  match: "/users/\\d+"
```

### Multiple Health Endpoints
```yaml
- kind: "regex"
  match: "^/(health|healthz|ready|live)$"
```

### Webhooks with Multiple Providers
```yaml
- kind: "regex"
  match: "/webhook/(stripe|dwolla|plaid|quickbooks)"
```

## Security Considerations

1. **Regex Performance**: Complex regex patterns can impact performance
2. **ReDoS Protection**: Avoid catastrophic backtracking patterns
3. **Validation**: Test regex patterns thoroughly
4. **Principle of Least Privilege**: Only allow necessary endpoints

## Testing

Use `helm template` to verify your configuration generates the expected Istio VirtualService:

```bash
helm template myapp . -f values.yaml --show-only templates/virtualService.yaml
```
