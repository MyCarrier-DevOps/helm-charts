# Design: `environment.tier` — preprod-class environments

**Date:** 2026-06-17
**Chart:** `charts/mycarrier-helm` (+ `charts/mc-environment` docs only)
**Status:** Proposed — ready for implementation

## Problem

The chart conflates two concepts into a single string, `environment.name`:

1. **Identity** — the namespace and hostnames for this deployment
   (`helm.namespace` = the env name; hosts derive from it).
2. **Behavioral tier** — which secrets / auth / scaling / routing profile to use.

The tier is derived *implicitly* from the name in `helm.metaEnvironment`
([`_environment.tpl`](../../../charts/mycarrier-helm/templates/_environment.tpl)), with only
two mappings: `feature*` → `dev`, and everything else → its literal name. `qa`/`uat` are not
separate deployments — they exist only as header values folded into the preprod profile
(`^(preprod|uat|qa)$` at `_environment.tpl:84`).

There is **no allowlist or `fail`** blocking a new env name. But a name the chart does not
recognise (e.g. `demo`) matches none of the `dev`/`preprod`/`prod` branches and silently
renders a broken hybrid:

| Behaviour | `preprod` | `demo` today | Source |
|---|---|---|---|
| Vault path prefix | `…/preprod/…` | `…/demo/…` ❌ (tree doesn't exist) | `_lang.tpl`, `_vault.tpl:32` |
| C# `Auth_*_BaseUrl` / `Auth_Environment` | PreProd values | **none emitted** ❌ | `_lang.tpl:19` |
| ServiceBus connection (KEDA) | `…-preprod` | `…-demo` ❌ | `_spec_keda.tpl:36` |
| VirtualService routing | simple catch-all | complex header-match ❌ | `_spec_virtualservice.tpl:168` |
| HPA / autoscaling | off | **on** ❌ | `_helpers.tpl:148` |

Goal: let an operator declare a **new namespace** (e.g. `demo`) that behaves exactly like the
**preprod tier** — same secrets, auth, scaling and routing — while keeping its own
namespace and hostnames. Per product decision, a preprod-tier env **shares preprod's secrets and
backing services** (exactly as `qa`/`uat` do today).

## Solution

Introduce an explicit, optional `environment.tier` field and a single helper,
`helm.environmentTier`, that is the **behavioral discriminator**. Identity stays on
`helm.metaEnvironment` (unchanged). Behavioral call sites switch from `metaEnvironment` to
`environmentTier`.

### The backward-compatibility rule (the crux)

```
helm.environmentTier = environment.tier   (validated dev|preprod|prod)   IF set
                       ELSE helm.metaEnvironment      ← today's value
```

Because an unset tier makes `environmentTier == metaEnvironment`, **every existing environment
renders byte-identical**. The new behaviour is strictly opt-in. No `fail` is introduced for an
unset or unrecognised *name* (that would change current behaviour); validation fires **only when
`tier` is explicitly set**.

### Usage

```yaml
# mc-environment environments[] entry, or mycarrier-helm values
environment:
  name: demo
  tier: preprod        # dev | preprod | prod   (optional)
```

### Behaviour for `demo` with `tier: preprod`

| Concern | Resolves to | Driver |
|---|---|---|
| Namespace | `demo` | `helm.namespace` (identity — unchanged) |
| Hostnames / `.internal` / domain.prefix | `demo`-based | `helm.metaEnvironment` (identity — unchanged) |
| `environment` header value | exact `demo` (not the preprod regex) | `helm.environmentHeaderValue` (identity — unchanged) |
| Vault paths, ServiceBus, Elastic, auth URLs | `…/preprod/…`, PreProd | `helm.environmentTier` |
| VirtualService routing mode | simple catch-all | `helm.environmentTier` via `isSimpleEnvironment` |
| Autoscaling | off | `helm.environmentTier` via `envScaling` |
| Replicas default | 2 (already, non-dev/feature) | unchanged |
| Domain TLD | `mycarrier.dev` (non-prod) | `helm.domain` (`hasPrefix "prod"` false — unchanged) |

## Implementation

### 1. New helper — `charts/mycarrier-helm/templates/_environment.tpl`

```gotemplate
{{- define "helm.environmentTier" -}}
{{- $tier := "" -}}
{{- if and .Values .Values.environment .Values.environment.tier -}}
{{- $tier = .Values.environment.tier -}}
{{- end -}}
{{- if $tier -}}
{{- if not (has $tier (list "dev" "preprod" "prod")) -}}
{{- fail (printf "environment.tier %q is invalid; must be one of dev, preprod, prod" $tier) -}}
{{- end -}}
{{- $tier -}}
{{- else -}}
{{- include "helm.metaEnvironment" . -}}
{{- end -}}
{{- end -}}
```

### 2. Behavioral substitutions (`metaEnvironment` → `environmentTier`)

Each is a like-for-like swap of the discriminator; output is identical when `tier` is unset.

| File | Site | Change |
|---|---|---|
| `_environment.tpl` | `isSimpleEnvironment` (`eq $metaenv "prod"`/`"preprod"`) | use `environmentTier` |
| `_lang.tpl` | `helm.lang.vars.csharp` + `helm.lang.vars.js`: the `eq $metaenv …` auth blocks **and** every `{{ $metaenv }}` in vault paths / ServiceBus / Elastic URL | bind `$metaenv := include "helm.environmentTier" .` |
| `_vault.tpl` | individual-secret path prefix (`:32`) | bind tier and use it for the path |
| `_spec_keda.tpl` | `servicebus-connectionstring-<metaEnv>` (`:36`) | use `environmentTier` |
| `_helpers.tpl` | `helm.envScaling` no-autoscale set (`:148`) | `has (include "helm.environmentTier" .) (list "dev" "preprod")` (drops the separate `hasPrefix "feature"` clause — `environmentTier` already maps feature→dev) |
| `_helpers.crossplane.tpl` | `resourceGroup.defaultName` (`:108`), `servicebus.name` (`:120-121`) | use `environmentTier` so a preprod-tier env that declares infra points at the shared `inf-preprod*` (consistent with "share preprod"). Only fires if the env declares `infrastructure.*`. |

**Left on `metaEnvironment` (identity — do NOT change):** `helm.namespace`, `helm.fullname`,
hosts and the `.<env>.internal` ServiceEntry, `helm.domain` / `helm.domain.prefix`,
`helm.environmentHeaderValue` / `…IsRegex` (so `demo`'s header is exact `demo`, not the preprod
regex), and the `_spec_*virtualservice` host construction.

### 3. `charts/mc-environment` — no template change

[`appset.yaml:24-27`](../../../charts/mc-environment/templates/appset.yaml) deep-copies the whole
`environment` block, so `tier` rides through automatically. Add a commented `tier:` to
`example.yaml` / `values.yaml` only.

### 4. Values documentation

- `charts/mycarrier-helm/values.yaml`: document `environment.tier` (optional, `dev|preprod|prod`,
  default = derived from name).
- `charts/mycarrier-helm/README.md`: short "environment tiers" section.

## Testing

helm-unittest, `charts/mycarrier-helm`.

**Backward-compatibility guard (must be zero-diff):** `helm template` the chart for
`environment.name` ∈ {`dev`, `preprod`, `prod`, `feature20`} **without** `tier`, before and after
the change; assert byte-identical output. (Snapshot or `diff` in CI.)

**New suite `tests/environment_tier_test.yaml`:**

1. `name: demo`, `tier: preprod`, csharp → a deployment env var `Auth_Environment: PreProd` and a
   vault path containing `secrets/data/preprod/`.
2. Same → KEDA `clusterAuthRef` / lang var ServiceBus references `…-preprod` / `inf-preprod-…`.
3. Same → VirtualService default route is a **catch-all** (no `match:` block) — proves
   `isSimpleEnvironment` flipped via tier.
4. Same → namespace is `demo` and the primary host is `demo`-prefixed (identity unchanged), and the
   `environment` header value is exact `demo` (not the `^(preprod|uat|qa)$` regex).
5. Same → no HPA rendered (envScaling 0) for an app without explicit autoscaling.
6. `name: demo` with **no** `tier` → matches current behaviour (complex routing, HPA on) — pins BC.
7. `tier: bogus` → render fails with the validation message.

## Out of scope (this plan)

- **prod-tier / customer environments** — separate doc:
  `2026-06-17-environment-tier-prod-research.md` (tabled, open questions).
- `environment.domainPrefix` override — prod-plan scope (preprod uses the env-name prefix already).
- Removing the `qa`/`uat` preprod regex or migrating them to first-class envs.
- Per-env *isolated* secrets/infra (preprod decision is "share preprod").
