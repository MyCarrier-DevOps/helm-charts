# Design: consolidated OpenTelemetry injection block and controls

**Date:** 2026-07-24
**Chart:** `charts/mycarrier-helm` (affected versions verified: 3.3.9, 3.3.10)
**Target version:** 3.4.0
**Status:** Approved — not yet implemented

## Problem

The chart's OpenTelemetry wiring is spread across two env helpers invoked in different orders by
each workload type, with a flag that governs none of it. Everything below was verified by rendering
`helm template`, not by reading templates.

### 1. `disableOtelAutoinstrumentation` is inert in both directions

Single root cause: `| default` applied to a boolean. Sprig's `default` treats boolean `false` as
empty, so `default true false` returns `true`.

- `_otel.tpl:14` — `and (has $language $languageList) (not .Values.disableOtelAutoinstrumentation | default true)`.
  Go template pipes bind the whole preceding command, so this parses as `default true (not X)`,
  truthy for every `X`. The operator annotations render unconditionally — stuck **on**.
- `_otel.tpl:86` — `not (.Values.disableOtelAutoinstrumentation | default true)`. Already
  parenthesized, but `default true false` is still `true`, so `not` yields false. `NODE_OPTIONS`
  renders for no value of the flag — stuck **off**.

Measured with `global.language: nodejs`:

| `disableOtelAutoinstrumentation` | otel annotations | `NODE_OPTIONS` |
| --- | --- | --- |
| `true`  | 3 rendered | absent |
| `false` | 3 rendered | absent |
| unset   | 3 rendered | absent |

The stuck-**off** half means the original ticket's acceptance criterion 2 (annotations *and*
`NODE_OPTIONS` render when the flag is `false`) also fails today.

### 2. No control over the `OTEL_*` env block

The block is injected into every container and initContainer of every workload type with no flag
governing it.

### 3. A consumer-supplied `OTEL_EXPORTER_OTLP_ENDPOINT` behaves four different ways

| context | user-supplied endpoint | mechanism |
| --- | --- | --- |
| deployment / rollout / statefulset main container | **discarded** | omit list in `helm.application.env` (`_environment.tpl:143`) |
| deployment / rollout initContainers | **discarded** | inline omit list (`_spec_deployment.tpl:97`, `_spec_rollout.tpl:107`) |
| statefulset initContainers | **duplicated**, user wins | no omit list; user env renders after the block |
| job / cronjob | **duplicated**, user wins | no omit list; user env renders after the block |

Three duplicated hardcoded omit lists, and two workload types that emit a duplicate env name and
rely on kubelet's last-occurrence-wins.

### 4. Jobs and cronjobs never receive the language block

`_spec_job.tpl:55` and `_spec_cronjob.tpl:71` guard it with `hasKey $ "helm.otel.language"`. `$` is
the root context, so this is always false. Jobs and cronjobs get the generic block but never
`OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` / `OTEL_SERVICE_NAME`.

### 5. Two YAML indentation bugs in `args` and env-map rendering

`{{ toYaml X | indent N | trim }}` is correct only when `N` equals the literal column of `{{` —
`indent` pads every line, `trim` strips only the first, and the literal indentation re-supplies it.
A mismatch misaligns every line after the first. A sweep of all templates found five real
mismatches in two classes:

- **initContainer `args`** — `_spec_deployment.tpl:91`, `_spec_rollout.tpl:101`,
  `_spec_statefulset.tpl:53` (`col=10 indent=8`). Any initContainer with more than one arg renders
  invalid YAML and fails the render outright.
- **job / cronjob env map values** — `_spec_job.tpl:62` (`col=12 indent=10`),
  `_spec_cronjob.tpl:78` (`col=16 indent=14`). This one fails *silently*: it emits structurally
  valid YAML in which `secretKeyRef` is a sibling of `valueFrom` rather than nested under it, so
  `valueFrom` is null and `secretKeyRef` is an unknown field on `EnvVar`:

  ```yaml
  - name: "FROM_SECRET"
    valueFrom:
    secretKeyRef:
      key: my-key
      name: my-secret
  ```

  `helm template` succeeds and CI passes, so every job/cronjob env var using `valueFrom` is silently
  null in the cluster.

Five sweep hits were triaged as non-bugs: `_spec_deployment.tpl:166,180,189` are preceded by a
`{{ if }}` that emits nothing, so the effective column equals the literal indentation;
`_helpers.tpl:255` is a single-line scalar; `_spec_triggertestengine.tpl:101` is
whitespace-insensitive JSON inside a shell command.

### Net effect

On `mycarrier-frontend` (dev and uat): pods receive the full injected block pointing at
`http://$(OTEL_HOST_IP):4317`, the consumer's endpoint never arrives, and
`disableOtelAutoinstrumentation: true` does nothing. Because the frontend entrypoint serves its
container env as a public `app.settings.json`, browsers receive an unreachable cluster-internal
endpoint plus node IP, pod name, pod UID, and namespace.

## Scope corrections from the original ticket

- The ticket proposed widening `disableOtelAutoinstrumentation` to govern the env block. That is
  wrong: the flag names the OTel Operator's
  [automatic instrumentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)
  feature and must keep meaning exactly that. The env block gets a separate control.
- The `language:` pod label from `helm.otel.labels` is **not** an OTel artifact. `language` is a
  chart input (`global.language` / `application.language`) driving language-specific defaults; the
  label is descriptive metadata that merely happens to be defined in `_otel.tpl`. Untouched.
- Jobs and cronjobs are explicitly in scope. Behavior must be consistent across all deployed
  resources; a partial fix reproduces the inconsistency this work exists to remove.

## How the chart wires OTel

Six helpers in `_otel.tpl`, consumed by ~20 call sites across `_spec_deployment.tpl`,
`_spec_rollout.tpl`, `_spec_statefulset.tpl`, `_spec_job.tpl`, `_spec_cronjob.tpl`, and
`analysistemplate.yaml`. No other template injects `OTEL_*`.

Three structural facts that shape the design, all verified:

- **The spec templates' `$` and `.` are the same merged dict.** `deployment.yaml` builds
  `$appContext := merge (dict "appName" … "application" $appValues "ctx" …) $`; `jobs.yaml` and
  `cronjob.yaml` build `merge (dict "job" . …) $` / `merge (dict "cronjob" . …) $`. So `$` inside
  each spec helper carries `Values`, `Chart`, `Release` *and* the workload's own dict. Every env
  source is reachable from a single helper with no call-site plumbing.
- **`volumeMounts` and `volumes` always contain `tmp-dir`** in every workload, so suppressing the
  `otel-log` entries cannot produce an empty YAML list.
- **initContainer `env` is scalar-only per `values.schema.json`** (`got object, want string`), so
  deployment/rollout's `value: "{{ $value }}"` rendering is correct and statefulset's map-handling
  branch is unreachable. Not a defect; no change.

## Design

### 1. One consolidated env block: `helm.otel.env`

`helm.otel.envVars` and `helm.otel.language` are merged into a single `helm.otel.env` helper that
emits the complete OTel env contribution as one contiguous block with a fixed internal order. Both
old helpers are removed; they are internal, with no consumer outside this chart.

This is a correctness requirement, not tidiness. The block depends on Kubernetes `$(VAR)`
expansion, which only resolves variables defined **earlier in the same env list**:
`OTEL_EXPORTER_OTLP_ENDPOINT` references `$(OTEL_HOST_IP)`, and `OTEL_RESOURCE_ATTRIBUTES`
references five `OTEL_RESOURCE_ATTRIBUTES_*` vars. Splitting OTel across two helpers whose relative
order varies per workload is what allowed that contract to become accidental. One block with a
fixed order makes it structural.

Emission order within the block:

1. field-ref vars — `K8S_NODE_NAME`, `OTEL_RESOURCE_ATTRIBUTES_NODE_NAME`,
   `OTEL_RESOURCE_ATTRIBUTES_POD_NAME`, `OTEL_RESOURCE_ATTRIBUTES_POD_NAMESPACE`, `POD_NAME`,
   `OTEL_RESOURCE_ATTRIBUTES_POD_UID`, `OTEL_RESOURCE_ATTRIBUTES_POD_IP`, `OTEL_HOST_IP`
2. `OTEL_EXPORTER_OTLP_PROTOCOL`, then `OTEL_EXPORTER_OTLP_ENDPOINT` (skipped when the consumer
   supplies one — see 4)
3. `OTEL_RESOURCE_ATTRIBUTES`
4. language-independent exporter vars — `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`,
   `OTEL_LOGS_EXPORTER`, `OTEL_SERVICE_NAME`
5. language-specific vars — for nodejs, `OTEL_NODE_RESOURCE_DETECTORS`, then `NODE_OPTIONS` when
   auto-instrumentation is enabled

Every field-ref var precedes every var that interpolates it, so the expansion contract holds by
construction.

### 2. Placement: one call site per container, block before user env

Each container and initContainer gets exactly one `{{ include "helm.otel.env" $ }}`, positioned
immediately after `helm.lang.vars` and **before** the workload's user env
(`helm.application.env` / `.job.env` / `.cronjob.env` / initContainer `.env`).

Four of the five workload types already order it this way; only deployment's main container
currently trails it, so this is the minimum-churn choice. It also means user values can reference
chart-provided vars such as `$(OTEL_HOST_IP)`, and user env takes last-occurrence precedence for
anything the block emits — with skip-inject (below) as the primary guarantee, so correctness never
depends on that precedence.

`vault` and `ComputedEnvironmentName` placement is left as-is per workload; normalizing those is
unrelated churn.

### 3. Two predicate helpers as the single source of truth

- `helm.otel.chartManaged` → `"true"` unless `manualOtelConfig` is truthy
- `helm.otel.autoinstrumentation.enabled` → `"true"` only when `helm.otel.chartManaged` **and**
  `disableOtelAutoinstrumentation` is explicitly `false`

Both replace `| default` with an explicit `kindIs "invalid"` null test, so an explicit `false` means
false and only *unset* falls back to the documented default. Every OTel decision reads from these
two, so the `default`-on-a-boolean foot-gun exists in exactly two places and is correct in both.
Each returns `"true"` or `""`, consumed as `{{- if include "helm.otel.chartManaged" . }}`.

Gating, applied at the helper definitions so all call sites and all workload types are covered
without per-site edits:

| helper | gate |
| --- | --- |
| `helm.otel.env` | `helm.otel.chartManaged` |
| `NODE_OPTIONS` within `helm.otel.env` | `helm.otel.autoinstrumentation.enabled` |
| `helm.otel.annotations` | `helm.otel.autoinstrumentation.enabled` |
| `helm.otel.volumes`, `helm.otel.volumeMounts` | `helm.otel.chartManaged` |
| `helm.otel.labels` | none — unchanged |

### 4. New value: `manualOtelConfig`

Top-level, default `false`, matching the placement of `disableOtelAutoinstrumentation`. No
per-application variant; no current consumer needs one.

```yaml
## @param manualOtelConfig Take over OpenTelemetry configuration from the chart.
##   false (default) — chart injects the standard OTEL_* env block, otel-log volume,
##                     and (when enabled) operator auto-instrumentation.
##   true            — chart injects nothing OTel-related; supply your own OTEL_*
##                     via global.env / application.env.
manualOtelConfig: false
```

`manualOtelConfig: true` suppresses every OTel variable and artifact from every layer: the whole
`helm.otel.env` block, the operator annotations, and the `otel-log` volume and mount. It overrides
`disableOtelAutoinstrumentation` — a workload whose OTel config the chart does not manage must not
receive operator injection either.

The two flags have **opposite** defaults, deliberately. Documented explicitly in `values.yaml` and
the README table so no reader assumes they track each other:

| key | default | meaning of default | opt- |
| --- | --- | --- | --- |
| `manualOtelConfig` | `false` | chart manages OTel config | **out** |
| `disableOtelAutoinstrumentation` | `true` | operator auto-instrumentation off | **in** |

### 5. Endpoint override: uniform skip-inject

`helm.otel.env` resolves a consumer-supplied `OTEL_EXPORTER_OTLP_ENDPOINT` from whichever env
source the current context exposes, most specific first:

1. `.job.env` (job context)
2. `.cronjob.env` (cronjob context)
3. `.application.env` (app context)
4. `.Values.global.env`

Contexts are mutually exclusive — a context carries `.job` xor `.cronjob` xor `.application` — so
one helper covers all five workload types. When a value is found the block omits its own endpoint
entirely; otherwise it emits `http://$(OTEL_HOST_IP):4317` as today.

`OTEL_EXPORTER_OTLP_ENDPOINT` is removed from all three omit lists (`_environment.tpl:143`,
`_spec_deployment.tpl:97`, `_spec_rollout.tpl:107`) so the consumer's value flows through.

Result: exactly one effective occurrence in all five workload types and in initContainers,
replacing today's four divergent behaviors, with no reliance on kubelet last-occurrence-wins. When
no override is set this mechanism contributes **no** change to rendered output — the endpoint fix is
inert for consumers who do not use it, so any diff observed in the no-regression check is
attributable to §2 or §6, never to this.

Rejected alternative: keep the omit lists off and rely on ordering so the user's value wins. That
leaves a duplicate env name in the spec — which the ticket explicitly warns against — and makes
correctness implicit in template ordering.

**This is a hard prerequisite for `manualOtelConfig`, not merely adjacent.** With
`manualOtelConfig: true` the chart injects no endpoint, so the consumer must supply one; while the
omit lists strip that key, such workloads would have no endpoint at all.

Resulting consumer matrix:

| consumer wants | config |
| --- | --- |
| chart-managed OTel, node-local collector | default — nothing to set |
| chart-managed OTel, different endpoint | `global.env.OTEL_EXPORTER_OTLP_ENDPOINT` |
| full control, no injected pod metadata | `manualOtelConfig: true` + own `OTEL_*` vars |

### 6. Jobs and cronjobs receive the same block

The always-false `hasKey $ "helm.otel.language"` guards at `_spec_job.tpl:55` and
`_spec_cronjob.tpl:71` are removed. With the consolidated helper there is a single include and
nothing to guard, so jobs and cronjobs receive exactly the same block as every other workload.

Consequence to state in the PR: jobs and cronjobs gain `OTEL_TRACES_EXPORTER`,
`OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER`, `OTEL_SERVICE_NAME`, and for nodejs
`OTEL_NODE_RESOURCE_DETECTORS`. They already received the endpoint and resource attributes, so this
completes a partial configuration rather than introducing telemetry from nothing.

### 7. Indentation fixes

Replace the mismatched `indent N | trim` with `nindent` at the correct column:

- `_spec_deployment.tpl:91`, `_spec_rollout.tpl:101`, `_spec_statefulset.tpl:53` — initContainer
  `args`
- `_spec_job.tpl:62`, `_spec_cronjob.tpl:78` — env map values

## Testing

New `tests/otel_test.yaml` (helm-unittest 1.1.0, already a chart dev dependency wired into
`.github/workflows/unit-tests.yaml`), asserting across **all five workload types**:

- `disableOtelAutoinstrumentation` × `true` / `false` / unset with `global.language: nodejs` —
  annotations and `NODE_OPTIONS` present only for explicit `false`
- `manualOtelConfig: true` — no `OTEL_*` env var, no `opentelemetry.io` annotation, no `otel-log`
  volume or mount
- `manualOtelConfig: true` — the `language` pod label still renders
- endpoint override from `global.env`, `application.env`, `.job.env`, `.cronjob.env` — user value
  resolves and appears exactly once, with no duplicate env name
- no override — the injected default still renders, for csharp and nodejs
- block ordering — every field-ref var precedes the var interpolating it
- jobs and cronjobs receive the exporter vars

Extend existing suites for the indentation fixes, since these are silent-failure bugs that had no
coverage:

- initContainer with multi-element `args` renders valid YAML (deployment, rollout, statefulset)
- job and cronjob env value given as `{valueFrom: {secretKeyRef: …}}` renders `secretKeyRef`
  **nested under** `valueFrom`

No-regression check, run manually and recorded in the PR: `helm template` a representative csharp
backend values file before and after, and diff. Expected differences limited to the deployment
main-container env ordering change from §2 and the job/cronjob additions from §6; no change to any
var's value.

## Documentation

`values.yaml` (parameter comment including the opposite-defaults note), `values.schema.json`
(boolean-or-null, matching the shape of the `disableOtelAutoinstrumentation` entry), and the README
parameter table plus both OTel prose sections.

## Release

**3.4.0** — minor. One new opt-out value; everything else restores documented or plainly intended
behavior. Nothing that currently works stops working, and no consumer-facing contract changes.

State in the PR body: nodejs/java/python workloads setting `disableOtelAutoinstrumentation: true`
lose operator sidecar injection they had not asked for; those setting an explicit `false` gain
`NODE_OPTIONS`; jobs and cronjobs gain the four exporter vars; job/cronjob `valueFrom` env vars go
from silently null to functional.

Downstream consumers pin the chart through their ArgoCD / `mc-environment` config (e.g.
`MC.MyCarrier.Frontend` at `targetRevision: 3.3.9`) and must bump to pick this up.

## Note carried to the PR

The OTel Operator normally sets `NODE_OPTIONS` itself when it injects. Since the chart's copy has
never rendered, making it render may result in the variable being set twice — harmless (same value,
last wins), but worth watching the first time a workload enables auto-instrumentation.
