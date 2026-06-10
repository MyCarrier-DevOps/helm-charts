# Design: `helm.whitelabelHost` template helper

**Date:** 2026-06-10
**Chart:** `charts/mycarrier-helm`
**Status:** Approved (pending spec review)

## Problem

Whitelabel deployments need VirtualService hosts of the form `<label>.<domain>` in the
long-lived environments and `<label>.<env>.<domain>` in ephemeral ones, **without hardcoding the
domain** (it varies by environment and by `environment.domainOverride`).

Values-sourced `networking.istio.hosts` entries are already run through `tpl . $` in every
VirtualService-generation path, so template expressions in host values are evaluated against the
root context `$`. Two facts follow:

- `{{ $domain }}` does **not** work in a host value — `$domain` is a local variable inside the
  VirtualService templates, not part of the `tpl` root context.
- `{{ include "helm.domain" $ }}` **does** work, because named templates are globally available
  and `helm.domain` honors `environment.domainOverride`.

So an author can already write the full conditional today:

```yaml
hosts:
  - 'estes{{ if not (has .Values.environment.name (list "prod" "preprod" "dev")) }}.{{ .Values.environment.name }}{{ end }}.{{ include "helm.domain" $ }}'
```

This is verbose and error-prone to repeat across apps/labels. The goal is a clean, reusable
helper that encapsulates the env-infix-skip + domain logic.

## Solution

Add a named template `helm.whitelabelHost` that authors call inside `networking.istio.hosts`.

### Usage

```yaml
networking:
  istio:
    hosts:
      - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
```

### Behavior

`<domain>` is the result of `helm.domain` (so `environment.domainOverride` is honored). The
`.<env>` infix is omitted **only** for `prod`, `preprod`, and `dev`; every other environment
(`qa`, `uat`, `feature*`, …) includes it.

| `environment.name` | result |
|---|---|
| `prod` / `preprod` / `dev` | `estes.<domain>` |
| `qa` | `estes.qa.<domain>` |
| `uat` | `estes.uat.<domain>` |
| `feature20` | `estes.feature20.<domain>` |
| `feature20` + `domainOverride{enabled:true, domain: integratedtm.dev}` | `estes.feature20.integratedtm.dev` |

### Implementation

One `define` block in `charts/mycarrier-helm/templates/_helpers.tpl`, next to `helm.domain`:

```gotemplate
{{- define "helm.whitelabelHost" -}}
{{- $label := required "whitelabelHost requires a label" .label -}}
{{- $ctx := .ctx -}}
{{- $env := $ctx.Values.environment.name -}}
{{- $domain := include "helm.domain" $ctx -}}
{{- if has $env (list "prod" "preprod" "dev") -}}
{{- printf "%s.%s" $label $domain -}}
{{- else -}}
{{- printf "%s.%s.%s" $label $env $domain -}}
{{- end -}}
{{- end -}}
```

- **Inputs:** a dict with `label` (the whitelabel prefix, required) and `ctx` (the root `$`).
- `ctx` gives access to `.Values.environment.name` and lets the helper call `helm.domain`.
- `required` produces a clear render error if `label` is missing/empty.
- The skip-set `(list "prod" "preprod" "dev")` is fixed (the long-lived shared environments).

### Why no template-path changes are needed

`networking.istio.hosts` entries are already passed through `tpl . $` in all five host paths
(single-app main VS, single-app offload VS, multifrontend main VS, multifrontend offload VS,
OffloadBase CRD). Because the helper is invoked from within a host string via `include`, it works
in every one of those paths automatically. The only code added is the helper definition.

## Testing

helm-unittest, `charts/mycarrier-helm`. A dedicated suite (`tests/whitelabel_host_test.yaml`)
asserts the rendered `spec.hosts` of a single-app VirtualService contains the expected host for an
app whose `networking.istio.hosts` uses the helper with label `estes`:

1. `environment.name: dev` → `spec.hosts` contains `estes.mycarrier.dev` (no infix).
2. `environment.name: prod` → contains `estes.mycarriertms.com` (no infix).
3. `environment.name: preprod` → contains `estes.mycarrier.dev` (no infix).
4. `environment.name: feature20` → contains `estes.feature20.mycarrier.dev` (infix).
5. `environment.name: qa` → contains `estes.qa.mycarrier.dev` (infix — pins the skip-set boundary).
6. `environment.name: feature20` + `domainOverride{enabled:true, domain: integratedtm.dev}` →
   contains `estes.feature20.integratedtm.dev` (override honored).

(Each test sets a non-frontend deployment app with istio enabled and `offloadOperatorEnabled:
false` so the single-app VirtualService renders; the host assertion uses `contains` on
`spec.hosts`.)

## Documentation

- A short example in the istio/hosts section of `charts/mycarrier-helm/README.md`, including the
  note that `{{ $domain }}` does not resolve in host values but `{{ include "helm.domain" $ }}`
  and `helm.whitelabelHost` do.
- A commented example on `networking.istio.hosts` in `charts/mycarrier-helm/values.yaml`.

## Out of scope (YAGNI)

- A structured `whitelabelHosts:` values field (decision: helper-in-hosts, not a new field).
- A per-call domain-override parameter (covered by `environment.domainOverride` via `helm.domain`).
- Configurable skip-set (fixed to prod/preprod/dev).
- Changes to any VirtualService template (hosts are already `tpl`-evaluated).
