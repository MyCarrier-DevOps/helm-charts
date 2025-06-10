# Application Naming Constraints

## Error: "Additional property [app-name] is not allowed"

If you see this error when deploying your Helm chart, it means your application name violates the naming constraints.

### Valid Application Names

Application names **must contain only**:
- Lowercase letters (`a-z`)
- Numbers (`0-9`) 
- Underscores (`_`)
- Dashes (`-`)

### Invalid Characters

Application names **cannot contain**:
- Uppercase letters (`A-Z`)
- Spaces (` `)
- Special characters (`@`, `#`, `$`, `%`, etc.)
- Periods (`.`)
- Forward slashes (`/`)

### Examples

✅ **Valid Names:**
```yaml
applications:
  my-app:           # lowercase with dash
  user_service:     # lowercase with underscore  
  api-v2:          # lowercase with dash and number
  worker123:       # lowercase with numbers
```

❌ **Invalid Names:**
```yaml
applications:
  My-App:          # Contains uppercase letters
  user.service:    # Contains period
  api/v2:          # Contains forward slash
  worker@123:      # Contains special character
```

### How to Fix

1. Convert uppercase letters to lowercase
2. Replace spaces with dashes or underscores
3. Remove or replace special characters with allowed characters

**Before:**
```yaml
applications:
  User-Service-API:
```

**After:**
```yaml
applications:
  user-service-api:
```
