# Design: custom (non-standard) environment names

**Date:** 2026-06-17
**Chart:** `charts/mycarrier-helm` (+ `charts/mc-environment` example)
**Status:** Implemented

## Problem

`environment.name` was constrained by a `values.schema.json` regex
(`^(dev|preprod|prod|qa|uat|feature.+)$`), so any other name (e.g. `demo`) was rejected at render
time. We need to deploy additional preprod-grade environments beyond `qa`/`uat`.

## How environments are actually deployed

`mc-environment` holds a list of `environments[]`; its `appset.yaml` generates one ApplicationSet
per entry whose `source` is the `mycarrier-helm` chart, passing that entry's values through
(`helm.values: {{ .Values | toYaml }}`). So each environment — including `qa`/`uat` — is its **own
namespace/deployment**.

Crucially, these environments run with **`global.language: nodejs`**. The chart's language helper
([`_lang.tpl`](../../../charts/mycarrier-helm/templates/_lang.tpl)) only injects its env-var block
when `language == "csharp"`, so for nodejs it injects **nothing**. That is why `qa.yaml`/`uat.yaml`
configure everything **explicitly** — ~140 `global.env` entries pointing at `*.preprod.mycarrier.dev`
/ `*-preprod` KeyVault refs, `secrets.individual` pathed under `secrets/preprod/…`,
`dependencyenv: preprod`, autoscaling disabled per-app — with genuinely env-specific deviations
interleaved (qa SQL, `SplitIo*-qa`, qa function URLs, `RedisKeyPrefix: qa:`).

So the chart provides no environment-specific automation for these envs; the values do. The **only**
thing standing between today's setup and a new `demo` environment was the schema name regex.

## Decision

Relax the `environment.name` schema pattern to a **DNS-1123 label**
(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`). A non-standard name is treated as a **generic environment**:
its own namespace and hostnames, no special chart behavior, configured explicitly via
`global.env` / `application.env` / `secrets` — exactly the way `qa`/`uat` are configured today.

No new behavioral abstraction is introduced. Deploying `demo` is identical in shape to deploying a
bare `qa`: same structural behavior (the verified render diff between a bare nodejs `qa` and `demo`
differs only in identity — namespace/hosts/labels), config supplied by the env author.

## Changes

- `charts/mycarrier-helm/values.schema.json` — `environment.name` pattern relaxed to a DNS-1123
  label; description updated.
- `charts/mycarrier-helm/values.yaml`, `README.md` — `environment.name` doc updated.
- `charts/mycarrier-helm/Chart.yaml` — version bump (additive capability).
- `charts/mc-environment/example.yaml` — added a `demo` environment configured the qa/uat way.
- `charts/mycarrier-helm/tests/custom_environment_name_test.yaml` — asserts a custom name renders
  and namespaces correctly, that user-provided env passes through, and that an invalid name (not a
  DNS-1123 label) is still rejected.

No template logic changed: identity (namespace/hostnames/`environment` header) stays keyed on
`environment.name`; structural behavior (routing mode via `isSimpleEnvironment`, autoscaling via
`envScaling`) follows the existing name-based rules — a custom name behaves like any non
dev/preprod/prod name (i.e. like a bare `qa`).

## Alternative considered and rejected: a behavioral "tier"

An `environment.tier` abstraction was prototyped (commit `4b75372`, reverted) to let a new namespace
adopt an existing tier's secrets/auth/scaling/routing automatically. It was **not adopted** because:

- These environments are **nodejs**, so the tier's main lever (`_lang.tpl` csharp defaults) is a
  no-op — the values supply everything regardless.
- For apps that don't already override them, tier defaults would have *changed* behavior
  (simple vs. complex routing, autoscaling default), i.e. introduced new behavior rather than
  matching qa/uat.
- It added surface area (a new field, validation, template branches) for no benefit in the actual
  nodejs + user-provided-values workflow.

## Future considerations (only if the workflow changes)

- **Reducing per-env `global.env` boilerplate.** A tier-style abstraction could derive the shared
  preprod values, but it would first require **overridable `_lang.tpl` env vars** — today a user
  value for a key the C# block emits either duplicates (most keys) or is silently stripped
  (`KeyVault_*`). Without that, a tier can't be layered cleanly over the existing explicit configs.
  Relevant only if these environments move to `language: csharp`.
- **prod-grade custom environments** (e.g. `prod-acme`): the `prod-` name prefix already satisfies
  the chart's `hasPrefix "prod"` identity checks (prod TLD, affinity, `api` host prefix). Per-customer
  isolation of secrets/infra would build on the override work above.
