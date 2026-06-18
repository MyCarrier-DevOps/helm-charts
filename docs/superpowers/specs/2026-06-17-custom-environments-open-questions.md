# Custom environments: open questions & future work

**Date:** 2026-06-17
**Chart:** `charts/mycarrier-helm`
**Status:** Open — collects loose ends from the `environment.tier` work; not scheduled.
**Related:**
- `2026-06-17-environment-tier-preprod-design.md` (shipped — preprod-tier support)
- `2026-06-17-environment-tier-prod-research.md` (tabled — prod-tier plan & open questions)

## Context

`environment.tier` lets a non-standard namespace (e.g. `demo`, `prod-acme`) adopt an existing
behavioral tier (`dev|preprod|prod`) for secrets/auth/scaling/routing while keeping its own
identity (name/namespace/hostnames). The preprod cut is implemented and backward-compatible. This
doc tracks the remaining design questions and improvements for **custom environments** across both
the preprod and prod tiers, so they aren't lost.

---

## 1. Future improvement: overridable `_lang.tpl` environment variables

### Problem

The language helpers in [`_lang.tpl`](../../../charts/mycarrier-helm/templates/_lang.tpl)
(`helm.lang.vars.csharp`, plus the empty `helm.lang.vars.js`) inject a fixed set of env vars
computed from the tier — `AuthEnvironment`, `Auth_Environment`, `Auth_*_BaseUrl`,
`MongoConnection_<tier>`, `ServiceBusNamespace`, `SplitIo_ApiKey`, the `Strivacity*` family,
`KeyVault_IsActive`, etc. There is **no first-class way to override these** via `global.env` /
`application.env`. The behavior splits two ways, neither acceptable:

1. **Keys the C# block "owns" are silently dropped.**
   [`helm.application.env`](../../../charts/mycarrier-helm/templates/_environment.tpl) strips a
   fixed set from both env sources for C# apps: `KeyVault_IsActive`, `KeyVault_SplitIoProxyApiKey`,
   `KeyVault_SplitIoProxyUrl`, and (when `dependencies.redis`) `KeyVault_RedisConnection` /
   `Auth_KeyVault_RedisConnection`. A user value for any of these is discarded — `lang.vars` wins,
   no signal.
2. **Every other lang var produces a duplicate.**
   `AuthEnvironment`, `Auth_*_BaseUrl`, `MongoConnection_*`, … are not stripped, so a user value for
   the same key renders a second `env` entry. In the deployment/rollout/statefulset specs the user
   value is emitted *after* `helm.lang.vars`
   ([`_spec_deployment.tpl:142-147`](../../../charts/mycarrier-helm/templates/_spec_deployment.tpl)),
   so the effective value depends on Kubernetes' duplicate-env resolution — fragile and noisy.

### Why it matters: self-contained environments

This is the missing piece for deploying an environment with its **own crossplane resources and
vault secret trees** instead of sharing the tier's. The isolation story is only half-built today:

- **Crossplane resource names** are already overridable — `servicebus.yaml` / `resourcegroup.yaml`
  use `<instance>.name | default <tier-default>`.
- **Individual vault secrets** are already overridable — `secrets.individual[].path` wins over the
  tier-derived fallback.
- **But the `_lang.tpl` vars that *reference* those services are not** — `ServiceBusNamespace`,
  `MongoConnection_<tier>`, Redis/Elastic/auth endpoints are hardcoded to the tier. So an env can
  provision its own ServiceBus yet its app still connects to the *shared* tier ServiceBus.

Closing this gap is a prerequisite for the **"isolated" posture** in the prod research doc (Q1).

### Goal

Make `global.env` / `application.env` an **authoritative override** for any `_lang.tpl`-injected
key: user value wins, exactly once, no duplicate, no silent drop. Precedence (highest last):
`lang.vars` (tier defaults) → individual vault secrets → `application.env` (over `global.env`).

### Proposed solution

- **Option A (preferred) — lang.vars skips user-defined keys.** Compute the merged user-env key set
  once; `helm.lang.vars.*` does not emit any key in that set. The special-case `KeyVault_*`
  stripping in `helm.application.env` is removed and becomes a natural consequence. Smallest blast
  radius, preserves the current emission structure.
- **Option B — assemble one merged dict, emit once.** Build `lang.vars` as a dict, merge `vault` +
  `application.env` on top, dedupe, emit a single `env` block. Cleaner but a larger refactor of
  `_spec_deployment.tpl` / `_spec_rollout.tpl` / `_spec_statefulset.tpl` / `_spec_job.tpl`.

### Considerations / risks

- C# re-injection: if a user overrides a `KeyVault_*` key, lang.vars must *skip* it rather than
  re-inject; verify nothing downstream assumes the lang.vars value is always present.
- Redis-conditional keys (`KeyVault_RedisConnection` / `Auth_KeyVault_RedisConnection`) must keep
  their `dependencies.redis` condition so a user value isn't dropped when redis is off.
- Keep `ComputedEnvironmentName`, OTEL, `ActiveOffloads` non-overridable (stay in `omitKeys`).
- User override values run through `tpl` — ensure template references still resolve.
- Backward compatibility: no-override renders must be byte-identical (full unit suite is the guard).

---

## 2. Open questions — preprod-tier custom environments (e.g. `demo`)

- **P1 · `ComputedEnvironmentName` value.** A preprod-tier `demo` reports
  `ComputedEnvironmentName: demo`, whereas real `preprod` reports `uat`
  ([`_spec_deployment.tpl:11`](../../../charts/mycarrier-helm/templates/_spec_deployment.tpl)). If
  app logic switches on this value (config/feature selection), `demo` won't match the `uat` path.
  Decide: custom envs report their own name (identity, current) or the tier's computed value?
  Needs app-team input.
- **P2 · DNS + TLS for the per-env subdomain.** `demo` publishes hosts like
  `<appstack>-<app>.demo.mycarrier.dev` (domain.prefix = env name). Requires a wildcard record +
  cert for `*.demo.mycarrier.dev`, or per-host external-dns + cert-manager. Confirm the provisioning
  path, or mandate `environment.domainOverride` for custom envs.
- **P3 · Vault policy scope.** Pods auth to Vault with the cluster-wide `appcluster` role
  (`clusterauth` path, azure — [`_vault.tpl`](../../../charts/mycarrier-helm/templates/_vault.tpl)).
  Reading `secrets/data/preprod/*` from the `demo` namespace works only if that role's policy is
  namespace-agnostic (true for preprod today). Confirm, else demo secret reads fail at runtime.
- **P4 · Shared backing-service data risk.** Secrets resolve to preprod, so `demo` reads/writes
  preprod's Mongo/Redis/ServiceBus/Elastic — intended (matches qa/uat) but demo traffic mutates
  preprod data. Record as accepted; revisit for any custom env that must not touch preprod data
  (→ isolated posture, §1).
- **P5 · KEDA ClusterTriggerAuthentication.** KEDA references the cluster-scoped
  `ClusterTriggerAuthentication` named `servicebus-connectionstring-preprod`
  ([`_spec_keda.tpl:80`](../../../charts/mycarrier-helm/templates/_spec_keda.tpl)). A preprod-tier
  demo reuses it (points at preprod's ServiceBus). An isolated env needs its own — the chart only
  exposes `clusterAuthRef` selection, not creation.

---

## 3. Open questions — prod-tier custom environments (e.g. `prod-acme`)

Detailed in `2026-06-17-environment-tier-prod-research.md`. Cross-referenced here:

- **PR1 · Shared vs isolated infra/secrets default** (prod doc Q1) — gated on §1 above for true
  isolation.
- **PR2 · Naming-convention enforcement** (prod doc Q4) — `prod-` prefix carries prod identity;
  `fail` vs move domain-TLD/affinity to tier as a safety net.
- **PR3 · Host collision across multiple prod envs** (prod doc Q5) — rely on per-customer
  `domainOverride`; consider a render-time guard.
- **PR4 · `ComputedEnvironmentName`** (prod doc Q2) — same question as P1 for prod.
- **PR5 · Blast radius / governance** (prod doc Q7) — who may set `tier: prod`, review gates.

---

## 4. Cross-cutting open questions (both tiers)

- **X1 · Overridable lang vars** — §1; the isolation enabler.
- **X2 · Crossplane ServiceBus resource group.** A ServiceBus's `resourceGroupName` always uses the
  tier-default RG
  ([`crossplane/azure/servicebus/servicebus.yaml:46`](../../../charts/mycarrier-helm/templates/crossplane/azure/servicebus/servicebus.yaml)),
  so even a named ServiceBus lands in the shared RG — blocks fully-isolated infra.
- **X3 · Observability / labels.** `mycarrier.tech/environment` and `mycarrier.tech/envType` labels
  carry the literal env name (`demo`) while behavior is tier-based. Confirm downstream
  dashboards/alerts/cost-attribution that filter by environment handle custom names (no hardcoded
  env allowlists).
- **X4 · `environment.dependencyenv` defaulting.** Clarify how custom envs should set
  `dependencyenv` (the example pins `demo` → `preprod`); consider defaulting it from the tier when
  unset for custom envs.

## Out of scope

- Changing tier-derived *defaults* (they are correct defaults).
- Overriding chart-managed keys (`ComputedEnvironmentName`, OTEL, `ActiveOffloads`).
- Environment lifecycle/TTL/cleanup automation (not a chart concern).
