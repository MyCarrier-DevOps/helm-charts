# Research: `environment.tier` — prod-class / customer environments

**Date:** 2026-06-17
**Chart:** `charts/mycarrier-helm`
**Status:** Tabled — research & open questions (do **not** implement yet)
**Depends on:** `2026-06-17-environment-tier-preprod-design.md` (the `helm.environmentTier`
helper and BC rule defined there are reused verbatim here).
**See also:** `2026-06-17-custom-environments-open-questions.md` — cross-tier open questions and the
overridable-lang-vars improvement (§1) that the isolated-infra posture below depends on.

## Goal

Allow fresh **prod-tier** environments — e.g. a per-customer production environment in its own
namespace `prod-acme` — that behave like prod for secrets/auth/scaling/infra, while keeping a
distinct namespace and hostnames. Operator declares:

```yaml
environment:
  name: prod-acme          # convention: prod-<customer>
  tier: prod
  # domainPrefix: api       # proposed override; default "api" (see below)
  # domainOverride: { enabled: true, domain: acme.com }   # existing, per-customer TLD
```

## Why prod is harder than preprod

Prod is special-cased by **two different mechanisms**, where preprod is only special-cased by
`metaEnvironment`:

- **Exact-match behaviour** — `eq $metaenv "prod"` (secrets/auth/elastic/infra). These are fixed by
  the same `metaEnvironment` → `environmentTier` swaps as the preprod plan.
- **Name-prefix identity** — `hasPrefix "prod" $name` / `contains "prod" $namespace`
  (domain TLD, pod affinity, host-prefix omission, `domain.prefix → api`). These are **not**
  touched by the tier swap.

### The naming-convention insight

If the namespace is `prod-acme`, every name-prefix identity check already evaluates correctly —
**no change needed**:

| Branch | `prod-acme` → | Want | Action |
|---|---|---|---|
| `_helpers.tpl:13/16` domain TLD | `mycarriertms.com` | prod TLD | none |
| `_helpers.tpl:56` `domain.prefix` | `api` | `api` (default) | none (+ optional override) |
| `_affinity.tpl:2` pod affinity | prod affinity | prod affinity | none |
| `_spec_virtualservice.tpl:68/71`, `_spec_frontend_virtualservice.tpl:164/167` host prefix (`contains "prod" $namespace`) | omits `prod-acme-` (clean hosts) | clean | none |
| `_lang.tpl:35/72/195`, `_helpers.crossplane.tpl:121` (`eq $metaenv "prod"`) | non-prod ❌ | prod | **tier swap** (same as preprod plan) |

So, **given the `prod-` naming convention, prod-tier needs essentially the same behavioral swaps as
the preprod plan plus one optional override** — *not* a separate refactor of the name-prefix
branches.

### `domain.prefix` must NOT become tier-based

True prod returns `api` (→ `api.mycarriertms.com`). If `domain.prefix` were keyed on *tier*,
every prod-tier customer would collapse onto `api.<domain>` and collide. It must stay
**name/identity-based**. Decision so far: keep current logic (`hasPrefix "prod" name ? api :
metaenv`) and add an optional `environment.domainPrefix` override (default `api` for prod-named
envs), letting each customer differentiate via `domainOverride` (their own TLD) rather than via the
prefix.

## Proposed surface (pending answers)

- Reuse `helm.environmentTier` + BC rule from the preprod plan (unchanged).
- Add `environment.domainPrefix` override in `helm.domain.prefix`
  ([`_helpers.tpl:47`](../../../charts/mycarrier-helm/templates/_helpers.tpl)); default behaviour
  unchanged when unset.
- `prod-<customer>` namespace is a **hard convention** for the identity checks to work; needs a
  documented guard (see Q4).

## Open questions

1. **Shared vs isolated backing services / secrets (biggest).**
   `tier: prod` makes vault paths resolve to the shared `secrets/data/prod/…` tree, ServiceBus to
   `inf-prod-servicebus-prem`, Elastic to the prod cluster, and crossplane defaults to `inf-prod`.
   For a *customer* prod env this may be wrong — you may want **isolation** (`inf-prod-acme`, a
   customer-specific vault tree, customer DB). Per-env overrides exist (`infrastructure.azure.*`,
   `secrets.individual` explicit paths, `global.env`), so both are achievable — but **what is the
   default posture for prod-tier?** Options:
   - (a) tier-driven shared (consistent with preprod decision), overrides for isolation; or
   - (b) namespace-driven isolated by default (`inf-<namespace>`), explicit opt-in to share.
   This single answer decides whether crossplane/vault defaults key on `environmentTier` (shared) or
   `helm.namespace` (isolated).

   **Prerequisite for the isolated posture:** crossplane resource names and `secrets.individual`
   paths are already overridable, but the `_lang.tpl` env vars that *reference* backing services
   (`ServiceBusNamespace`, `MongoConnection_<tier>`, Redis/Elastic/auth endpoints) are hardcoded to
   the tier and currently cannot be overridden. A genuinely self-contained env needs those
   overridable — see `2026-06-17-custom-environments-open-questions.md` (§1). Also note the related gap where a
   ServiceBus's `resourceGroupName` always uses the tier-default resource group
   (`crossplane/azure/servicebus/servicebus.yaml`).

2. **`ComputedEnvironmentName`** ([`_spec_deployment.tpl:11`](../../../charts/mycarrier-helm/templates/_spec_deployment.tpl)).
   Today `preprod → uat`, else literal name. What should an app *see* for `prod-acme`? `prod`
   (tier), `prod-acme` (literal), or a customer slug? App-visible — needs product input.

3. **DNS / TLS.** Each customer prod env needs a wildcard + cert for its `domainOverride` domain
   (e.g. `*.acme.com` or `api.acme.com`). Infra outside these charts; confirm provisioning path
   (external-dns / Cloudflare / cert-manager).

4. **Naming-convention enforcement.** The design relies on the `prod-` namespace prefix to satisfy
   the identity checks. If someone sets `tier: prod` on a namespace **not** prefixed `prod-`
   (e.g. `acme`), they silently get the wrong domain (`mycarrier.dev`), no prod affinity, and
   prefixed hosts. Mitigations to decide:
   - (a) `fail` when `tier == prod` and `not (hasPrefix "prod" namespace)`; or
   - (b) move the domain-TLD + affinity checks to *tier* as a safety net (safe — they don't collide,
     unlike `domain.prefix`), while leaving `domain.prefix` name-based. Option (b) decouples the
     convention from correctness for everything except the prefix.

5. **Host collision across multiple prod envs.** Two customer prod envs sharing `appStack` +
   `api` prefix collide unless their `domainOverride` TLDs differ. Confirm every customer env
   carries a distinct `domainOverride`, and consider a render-time guard.

6. **`environment` header value for prod-tier.** Stays identity/name-based → exact `prod-acme`.
   With `isSimpleEnvironment` true (via tier), the VS also emits a catch-all default route. Confirm
   the header-match route on `prod-acme` is desired (it mirrors how true `prod` matches `prod`).

7. **Blast radius / governance.** A prod-tier env reading prod secrets is a production-grade
   credential surface. If Q1 lands on "shared", define approval/guardrails (who can set
   `tier: prod`, review gates) before enabling.

## Recommendation (tentative, pending Q1 + Q4)

- Implement the **preprod plan first** (it stands alone and is fully BC).
- For prod, lean toward **Q1(a) shared default + explicit isolation overrides** *only if* product
  confirms customer envs are meant to share prod data; otherwise **Q1(b) isolated default**.
- Adopt **Q4(b)** (tier-drives domain-TLD + affinity, name-drives prefix) so correctness doesn't
  hinge on operators remembering the `prod-` convention, while preserving the no-collision property
  of a name-based `domain.prefix`.

## Out of scope until tabled questions are answered

- Any template change for prod-tier (this is research only).
- Multi-prod ingress/gateway topology, customer onboarding automation, secret-tree provisioning.
