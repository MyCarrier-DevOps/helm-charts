# Design: sync mc-environment to mycarrier-helm's configuration surface

**Date:** 2026-06-10
**Charts:** `charts/mc-environment` (primary), `charts/mycarrier-helm` (one combination test)
**Status:** Approved (pending spec review)

## Problem

`mc-environment` generates one ArgoCD `ApplicationSet` per environment; each carries a `Values`
block that is fed to the `mycarrier-helm` chart. Most sections (`applications`, `jobs`,
`secrets`, `infrastructure`, `extraObjects`) are passed through with `toYaml`, but two blocks are
**hand-built field-by-field** — `environment` and `global` — and the JSON schema keeps **local
copies** of several mycarrier-helm sections. Both patterns drift from mycarrier-helm and silently
drop or reject valid configuration.

Confirmed against the current chart (HEAD):

- **`environment.dependencyenv`** is read from `$env.dependencyenv`, but the documented/schema
  input nests it under `$env.environment.dependencyenv`. Result: it renders **empty** — silently
  dropped.
- **`environment.domainOverride`** (and children `enabled`, `domain`) is **not emitted at all**.
- **`environment.namespaceOverride`** is not emitted and is **absent from the schema's
  `mycarrierEnvironmentOverride` definition**.
- **`global`** is hand-built and only merges `global.env` per environment; per-environment
  overrides of `global.gitbranch`, `global.dependencies`, etc. are **ignored** (e.g.
  `example.yaml` sets a per-env `global.gitbranch`/`dependencies` that never take effect).
- **Schema local copies drift:** the local `infrastructure` definition rejects valid mycarrier-helm
  fields (e.g. storage `sku`, which mycarrier-helm allows), and `applications` is also a local copy
  — so a new mycarrier-helm application field (e.g. the proposed `useRootDomain`) would fail
  mc-environment validation until manually added.

mycarrier-helm's authoritative `environment` surface: `name`, `namespaceOverride`,
`dependencyenv`, `domainOverride{enabled,domain}`.

## Solution overview

Stop hand-maintaining partial copies. Pass structured blocks through, and reference
mycarrier-helm's published schema instead of copying it.

### Part 1 — `environment` block (appset.yaml): pass-through + inject name

```gotemplate
environment:
  {{- $e := deepCopy ($env.environment | default dict) }}
  {{- $_ := set $e "name" $env.name }}
  {{- $e | toYaml | nindent 18 }}
```

- `name` comes from the top-level `$env.name` (canonical; also used for metadata/namespace) and is
  injected/overwritten onto the environment block.
- Everything else (`dependencyenv`, `namespaceOverride`, `domainOverride{...}`, and any future
  mycarrier-helm environment field) flows through untouched.
- Absent `$env.environment` defaults to an empty dict, yielding just `{name: <env>}`.

### Part 2 — `global` block (appset.yaml): merged pass-through, preserving contracts

- Deep-merge base `$.Values.global` with per-env `$env.global`
  (`mustMergeOverwrite (deepCopy base) override`), so per-env overrides of `gitbranch`,
  `dependencies`, `env`, etc. take effect. Fixes the silent per-env override drop.
- Preserve the two behaviours the current template guarantees:
  - force `appStack` to lowercase after the merge;
  - default `correlationId` and `commitDeployed` to `""` when unset (keeps the existing
    "empty when not set" contract / test).
- Emit the merged map with `toYaml`.

### Part 3 — schema sync (values.schema.json)

- Add `namespaceOverride` to `mycarrierEnvironmentOverride` as a remote `$ref` into
  mycarrier-helm's published schema, matching the existing per-field `$ref` pattern there.
- Replace the drift-prone **local** `infrastructure` and `applications` definitions with remote
  `$ref`s into mycarrier-helm's `values.schema.json` (`#/properties/infrastructure`,
  `#/properties/applications`). This auto-syncs `sku` and every future field, including
  `useRootDomain`.

### Exclusions (per scope decision)

`mc-environment` always sets `isEnvironmentDeploy: true`. Configuration that is only meaningful
when `isEnvironmentDeploy=false` is intentionally **not** represented.

## Risks / tradeoffs

- **Schema pins to `main`.** Remote `$ref`s resolve against mycarrier-helm's schema on `main`, not
  the `mycarrierChartVersion` actually deployed. This extends an existing pattern in this chart
  (`global` already uses remote `$ref`s), so it is not a new dependency, but validation can diverge
  from the deployed chart version if `main` moves ahead. Accepted by decision.
- **Network at template time.** Remote `$ref` resolution assumes the schema URL is reachable when
  Helm validates values. The existing `global` ref suggests this works, but it is **unverified** —
  the implementation must first prove Helm actually resolves and enforces a remote `$ref` (e.g.
  feed input that violates the remote schema and confirm validation fails). If Helm silently
  ignores remote refs, fall back to the targeted-local-patch approach for that section.
- **Output changes.** `global`/`environment` rendered output changes shape (merged global, new
  environment fields). Existing snapshot tests will be re-recorded intentionally; behavioural
  assertions are added/updated.

## Testing

Written test-first where practical; existing `appset_test.yaml` and snapshots kept green
(snapshots re-recorded only where output legitimately changes).

**mc-environment (`tests/appset_test.yaml`):**
1. `environment.domainOverride{enabled,domain}` provided on input → present in the generated
   `Values.environment.domainOverride`.
2. `environment.namespaceOverride` and `environment.dependencyenv` → forwarded correctly (the
   dependencyenv regression).
3. **staticHostname + domainOverride pass-through** (explicit ask): an app with
   `applications.<app>.staticHostname` and an env with `environment.domainOverride` →
   the generated `Values` contains both intact.
4. Per-env `global` override (e.g. `global.gitbranch`, `global.dependencies`) overrides the base.
5. `correlationId`/`commitDeployed` still default to `""` when unset.
6. A previously-rejected `infrastructure` field (storage `sku`) now passes schema validation.

**mycarrier-helm (combination, proves the real outcome):**
7. `applications.<app>.staticHostname: foo` + `environment.domainOverride{enabled: true,
   domain: custom.com}` → VirtualService host `foo.custom.com`.

## Out of scope (YAGNI)

- Pinning schema `$ref`s to a release tag (decision: track `main`).
- Reworking how `applications`/`jobs`/`secrets` are passed through (already `toYaml`).
- Any `isEnvironmentDeploy=false`-only configuration.
