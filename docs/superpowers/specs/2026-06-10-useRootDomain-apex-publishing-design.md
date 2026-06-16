# Design: `useRootDomain` — publish an application at the apex domain

**Date:** 2026-06-10
**Chart:** `charts/mycarrier-helm`
**Status:** Approved (pending spec review)

## Problem

Today every application is published under a hostname label:

- Default external host: `<hostname>.<domainPrefix>.<domain>` — e.g. `app-foo.api.mycarriertms.com`
- `staticHostname: custom` → `custom.<domain>` (skips the prefix) — e.g. `custom.mycarriertms.com`

There is no way to publish an application at the **bare apex domain** — `<domain>` itself
(`mycarriertms.com` in prod, `mycarrier.dev` in dev/preprod). Some applications (e.g. a
marketing site) need to be served at the root.

## Solution overview

Add a per-application boolean **`useRootDomain`**. When true, the application's *external*
host becomes the bare apex domain returned by `helm.domain`, with no hostname label. It is
the apex analogue of `staticHostname`.

### Semantics

- **Type:** boolean, per application. Default absent / `false`.
- **Environment scope:** effective only in **non-feature environments** (dev, preprod, prod).
  In feature environments (`hasPrefix "feature" environment.name`) the flag is ignored and the
  application keeps its normal feature hostname. Gate: `not $isFeatureEnv`.
- **Effect:** replaces the generated *external* host with `{{ $domain }}`. Internal hosts
  (`<fullName>`, `<fullName>.<namespace>.svc`, `.svc.cluster.local`, and
  `<baseFullName>.<metaenv>.internal`) are left unchanged.
- **Mutual exclusion:** `useRootDomain` and `staticHostname` cannot both be set on the same
  application. If both are truthy the render **fails** with a clear message:
  `app "<name>": set either useRootDomain or staticHostname, not both`.

### Domain resolution note (existing behaviour, not changed here)

`helm.domain` resolves prod-prefixed environments to `mycarriertms.com` and everything else
(including dev and preprod) to `mycarrier.dev`, unless `environment.domainOverride` is set.
Consequently an app using `useRootDomain` in **both** dev and preprod resolves to the same
`mycarrier.dev` apex record. This is pre-existing domain behaviour; the feature does not change
it. Teams needing distinct apexes per environment use `domainOverride`.

## Affected surfaces

Because apex publishing is non-feature only, and the offload VirtualServices only render in
feature environments, apex never reaches the offload paths. Only three host-generation surfaces
change:

| File | Surface | Change |
|---|---|---|
| `templates/_spec_virtualservice.tpl` | single-app backend main VS | In the non-feature host branch, select host as: **apex** → `staticHostname` → default generated host |
| `templates/_spec_frontend_virtualservice.tpl` | multifrontend main VS | Add an apex branch for the primary app, parallel to the existing `staticHostname` branch (the `not $isFeatureEnv` block) |
| `templates/offloadBase.yaml` | OffloadBase CRD (the dev / offload-operator path) | Add an apex branch parallel to the `staticHostname` branch |

### Why each, by environment

- **dev:** `offloadOperatorEnabled` defaults true, so the backend main VS is suppressed and the
  **OffloadBase CRD** emits the host — apex handled there.
- **preprod / prod:** `offloadOperatorEnabled` is false, so the **backend main VS** emits the
  host — apex handled there.
- **frontend (any non-feature env):** the **multifrontend main VS** emits the primary app host —
  apex handled there.

### Redirect-authority gating

Both spec files gate the `<namespace>-` prefix on redirect authorities with
`and (not (contains "prod" $namespace)) (not staticHostname)`. `useRootDomain` is added to that
condition so a fixed apex host suppresses the namespace prefix the same way `staticHostname`
does, keeping the two options symmetric. (`_spec_virtualservice.tpl` ~lines 65/68;
`_spec_frontend_virtualservice.tpl` ~lines 160/163.)

### Validation helper

A new named template, **`helm.assertExternalHostConfig`**, takes an application's values and
calls `fail` when both `useRootDomain` and `staticHostname` are truthy. It is included once per
application by each of the three surfaces. Three call sites justify a shared helper over inline
duplication (DRY); a single helper also keeps the error message consistent.

## Schema & documentation

- `values.schema.json`: add `useRootDomain` to the application properties as
  `oneOf: [ {type: boolean, description: ...}, {type: null} ]`, mirroring the `staticHostname`
  entry.
- `values.yaml`: document `useRootDomain` next to `staticHostname` (field list comment and the
  property itself), noting it is non-feature-only and mutually exclusive with `staticHostname`.

## Testing (helm-unittest, written test-first)

New cases across the existing suites:

1. **Backend, prod** — `useRootDomain: true` → `spec.hosts` contains `mycarriertms.com`, does
   **not** contain `<appstack-app>.api.mycarriertms.com`; internal hosts still present.
2. **OffloadBase, dev** — `useRootDomain: true`, `offloadOperatorEnabled: true` →
   `spec.hosts` contains `mycarrier.dev`, not the generated `<appstack-app>...` host.
3. **Feature env** — `useRootDomain: true` → flag ignored: normal feature hostname present, apex
   absent; `hasDocuments` unchanged.
4. **Multifrontend, prod** — primary app `useRootDomain: true` → apex host present on the
   multifrontend VS.
5. **Conflict** — `useRootDomain: true` + `staticHostname: foo` → `failedTemplate` with
   `errorMessage` matching the both-set message.
6. **Redirect** (optional/secondary) — `useRootDomain: true` with a redirect → redirect authority
   has no `<namespace>-` prefix.

## Out of scope (YAGNI)

- Apex in feature environments.
- Apex on the offload VirtualServices (never rendered in non-feature envs).
- A string form / per-app apex override (covered by existing `environment.domainOverride`).
- Any external-DNS / cloudflare-proxied annotation changes (existing annotation logic applies
  unchanged to whatever host is emitted).
