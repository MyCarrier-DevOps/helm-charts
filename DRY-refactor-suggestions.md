## DRY Violations in Proposed Helm Template Changes

### Summary of DRY Violations

1. **Repeated Endpoint Name Generation**
   - Name formatting logic (replacing `/`, `*`, special characters) is duplicated for each endpoint type (exact, prefix, regex).

2. **Multiple Conditional Blocks for Endpoint Types**
   - Similar blocks for `exact`, `prefix`, and `regex` endpoint rendering, each handling match and name logic separately.

3. **Redundant Helper Usage**
   - Helper templates for path and name processing are called in multiple places with minor variations rather than centralized.

4. **Repeated Route Block**
   - The majority of the route YAML structure is repeated for different endpoint types, with only small changes in the rendered name/match.

5. **Deduplication Logic**
   - Deduplication keys and value assignments are handled separately for string and dict endpoints, resulting in similar code blocks.

---

### Refactoring Suggestions

To address these DRY violations, consider the following refactor:

#### 1. Centralize Endpoint Name Generation

```gotmpl
{{/* Centralized endpoint name generation for all kinds */}}
{{- define "helm.renderEndpointName" -}}
{{- if eq .kind "regex" -}}
  {{- include "helm.processRegexEndpointName" .match -}}
{{- else -}}
  {{- include "helm.processEndpointName" .match -}}
{{- end -}}
{{- end -}}
```

#### 2. Centralize Endpoint Match Rendering

```gotmpl
{{/* Centralized endpoint match rendering for all kinds */}}
{{- define "helm.renderEndpointMatch" -}}
uri:
  {{- if eq .kind "prefix" -}}
    prefix: {{ include "helm.processPrefixPath" .match }}
  {{- else if eq .kind "regex" -}}
    regex: {{ .match }}
  {{- else -}}
    exact: {{ .match }}
  {{- end -}}
{{- end -}}
```

#### 3. Centralize Endpoint Rule Block

```gotmpl
{{/* Centralized HTTP rule rendering for a single endpoint */}}
{{- define "helm.renderEndpointRule" -}}
- name: {{ $.fullName }}-allowed-{{ include "helm.renderEndpointName" . }}
  match:
    - {{ include "helm.renderEndpointMatch" . | indent 6 | trim }}
  route:
    - destination:
        host: {{ $.fullName }}
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 100
    {{- if eq $.application.deploymentType "rollout" }}
    - destination:
        host: {{ $.fullName }}-preview
        port:
          number: {{ default 8080 (dig "ports" "http" nil $.application) }}
      weight: 0
    {{- end }}
  {{- with $.application.networking.istio.corsPolicy }}
  corsPolicy:
    {{ toYaml . | indent 4 | trim }}
  {{- end }}
  timeout: {{ default "151s" (dig "service" "timeout" "151s" $.application) }}
  retries:
    retryOn: {{ default "5xx,reset" (dig "service" "retryOn" "5xx,reset" $.application) }}
    attempts: {{ default 3 (dig "service" "attempts" 3 $.application) }}
    perTryTimeout: {{ default "50s" (dig "service" "perTryTimeout" "50s" $.application) }}
{{- end -}}
```

#### 4. DRY Rendering Loop for All Endpoint Rules

After deduplication, simply loop and call the above centralized template:

```gotmpl
{{- range $unique }}
  {{- include "helm.renderEndpointRule" (dict "kind" .kind "match" .match "fullName" $fullName "application" $.application) }}
{{- end }}
```

#### 5. Forbidden Rule Stays Separate

The forbidden rule is unique and can remain a separate block.

---

**Net effect:**
- All endpoint name and match processing is centralized.
- The HTTP rule block is generated via a single template.
- The main loop is lean: deduplicate endpoints, then render using one reusable template.
- Maintenance and readability improve; DRY principle is restored.
