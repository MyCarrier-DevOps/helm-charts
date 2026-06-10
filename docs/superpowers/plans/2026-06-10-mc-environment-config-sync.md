# mc-environment Config-Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `mc-environment` faithfully represent mycarrier-helm's configuration surface — pass the `environment` and `global` blocks through (fixing dropped `dependencyenv`/`domainOverride`/`namespaceOverride` and per-env `global` overrides) and replace the drift-prone local `infrastructure` schema copy with a remote `$ref`.

**Architecture:** `mc-environment/templates/appset.yaml` builds an ArgoCD `ApplicationSet` per environment whose `Values` block feeds the `mycarrier-helm` chart. Stop hand-building the `environment` and `global` sub-blocks; emit them with `toYaml` (injecting `name`, merging per-env `global`, preserving `appStack` lowercasing). In `mc-environment/values.schema.json`, complete `mycarrierEnvironmentOverride` and repoint the local `infrastructure` definition to mycarrier-helm's published schema.

**Tech Stack:** Helm (Go templates + Sprig), helm-unittest, JSON Schema (draft-07).

**Conventions:**
- Run mc-environment tests from `charts/mc-environment`: `helm unittest -f 'tests/appset_test.yaml' .`
- Run mycarrier-helm tests from `charts/mycarrier-helm`: `helm unittest -f 'tests/virtualservice_test.yaml' .`
- Remote schema base URL (already used in this file):
  `https://raw.githubusercontent.com/MyCarrier-DevOps/helm-charts/refs/heads/main/charts/mycarrier-helm/values.schema.json`
- Commit attribution: author/committer is the user only; no `Co-Authored-By`, no AI mentions.

---

## File Structure

- `charts/mc-environment/templates/appset.yaml` — **modify**: `global` block (lines ~20-37) and `environment` block (lines ~38-40).
- `charts/mc-environment/values.schema.json` — **modify**: `mycarrierEnvironmentOverride` (lines ~110-123, add `namespaceOverride`); `infrastructure` definition (lines ~313-321, repoint to remote).
- `charts/mc-environment/tests/fixtures/environment-overrides.yaml` — **create**: fixture with a per-env `environment` block + an app with `staticHostname`.
- `charts/mc-environment/tests/appset_test.yaml` — **modify**: add forwarding / merge / schema tests.
- `charts/mycarrier-helm/tests/virtualservice_test.yaml` — **modify**: add the staticHostname + domainOverride combination test.

---

## Task 0: Probe remote-`$ref` enforcement (gating spike)

**Why:** The schema repoint in Task 4 only works if Helm actually fetches and enforces remote `$ref`s. `environments[].enableVaultCA` is already a remote `$ref` to mycarrier-helm's `enableVaultCA` (a `boolean`/`null` `oneOf`), so we can probe enforcement with **no code change**.

**Files:** none (investigation only).

- [ ] **Step 1: Write a probe values file**

```bash
cat > /tmp/mc-probe.yaml <<'EOF'
global:
  appStack: carriers
environments:
  - name: dev
    enableVaultCA: "not-a-boolean"
EOF
```

- [ ] **Step 2: Render and observe**

Run (from `charts/mc-environment`): `helm template . -f /tmp/mc-probe.yaml >/dev/null; echo "rc=$?"`

- **If it FAILS** with a schema error about `enableVaultCA` (string vs boolean): remote `$ref`s ARE enforced. Proceed with Task 4 as written (remote repoint).
- **If it SUCCEEDS** (`rc=0`): remote `$ref`s are NOT enforced by Helm's validator. Do **Task 4 (fallback)** instead of Task 4, and note in the commit that infrastructure stays a local copy with a targeted patch.

- [ ] **Step 3: Record the outcome**

Write the result (enforced / not enforced) into the Task 4 commit message so the decision is traceable. No commit for this task.

---

## Task 1: Pass the `environment` block through (appset.yaml)

**Files:**
- Create: `charts/mc-environment/tests/fixtures/environment-overrides.yaml`
- Modify: `charts/mc-environment/templates/appset.yaml:38-40`
- Test: `charts/mc-environment/tests/appset_test.yaml`

- [ ] **Step 1: Create the fixture**

Create `charts/mc-environment/tests/fixtures/environment-overrides.yaml`:

```yaml
global:
  appStack: carriers
  gitbranch: main
  language: nodejs
environments:
  - name: dev
    environment:
      dependencyenv: dev
      namespaceOverride: platform-dev
      domainOverride:
        enabled: true
        domain: example.dev
    applications:
      shipments-api:
        staticHostname: api
        image:
          registry: ghcr.io
          repository: mycarrier/shipments-api
          tag: "1.12.3"
```

- [ ] **Step 2: Write the failing test**

Append to `charts/mc-environment/tests/appset_test.yaml` (under `tests:`):

```yaml
  - it: forwards the environment block (dependencyenv, namespaceOverride, domainOverride)
    values:
      - fixtures/environment-overrides.yaml
    documentSelector:
      path: metadata.name
      value: carriers-dev
    asserts:
      - equal:
          path: spec.generators[0].list.elements[0].Values.environment.name
          value: dev
      - equal:
          path: spec.generators[0].list.elements[0].Values.environment.dependencyenv
          value: dev
      - equal:
          path: spec.generators[0].list.elements[0].Values.environment.namespaceOverride
          value: platform-dev
      - equal:
          path: spec.generators[0].list.elements[0].Values.environment.domainOverride.enabled
          value: true
      - equal:
          path: spec.generators[0].list.elements[0].Values.environment.domainOverride.domain
          value: example.dev
      # explicit spec ask: an app staticHostname AND an overridden domain both pass through
      - equal:
          path: spec.generators[0].list.elements[0].Values.applications.shipments-api.staticHostname
          value: api
```

- [ ] **Step 3: Run the test, verify it FAILS**

Run (from `charts/mc-environment`): `helm unittest -f 'tests/appset_test.yaml' .`
Expected: FAIL — `environment.dependencyenv` renders empty and `environment.domainOverride`/`namespaceOverride` are absent under the current hand-built block. (The `staticHostname` assertion already passes, since `applications` is a remote `$ref` passed through via `toYaml`; the suite still fails overall on the environment assertions, which is the RED we need.)

- [ ] **Step 4: Implement the pass-through**

In `charts/mc-environment/templates/appset.yaml`, replace these three lines:

```gotemplate
                environment:
                  name: {{ $env.name }}
                  dependencyenv: {{ $env.dependencyenv | default "" }}
```

with:

```gotemplate
                environment:
                  {{- $envBlock := deepCopy ($env.environment | default dict) }}
                  {{- $_ := set $envBlock "name" $env.name }}
                  {{- $envBlock | toYaml | nindent 18 }}
```

- [ ] **Step 5: Run the test, verify it PASSES**

Run (from `charts/mc-environment`): `helm unittest -f 'tests/appset_test.yaml' .`
Expected: PASS, and all pre-existing tests still PASS (the `environment.name` assertions in the existing suite remain satisfied because `name` is injected).

- [ ] **Step 6: Commit**

```bash
git add charts/mc-environment/templates/appset.yaml charts/mc-environment/tests/appset_test.yaml charts/mc-environment/tests/fixtures/environment-overrides.yaml
git commit -m "fix(mc-environment): pass environment block through to mycarrier-helm

Emit the whole environment block via toYaml with name injected, so
dependencyenv, namespaceOverride and domainOverride reach mycarrier-helm
instead of being dropped by the hand-built block."
```

---

## Task 2: Merge and pass the `global` block through (appset.yaml)

**Files:**
- Modify: `charts/mc-environment/templates/appset.yaml:20-37`
- Test: `charts/mc-environment/tests/appset_test.yaml`

- [ ] **Step 1: Write the failing test (per-env global override)**

Append to `charts/mc-environment/tests/appset_test.yaml`:

```yaml
  - it: merges per-environment global overrides over the base global
    set:
      global.appStack: Carriers
      global.gitbranch: main
      global.dependencies.redis: false
      environments:
        - name: dev
          global:
            gitbranch: dev
            dependencies:
              redis: true
    documentSelector:
      path: metadata.name
      value: carriers-dev
    asserts:
      # per-env override wins
      - equal:
          path: spec.generators[0].list.elements[0].Values.global.gitbranch
          value: dev
      - equal:
          path: spec.generators[0].list.elements[0].Values.global.dependencies.redis
          value: true
      # appStack is forced lowercase
      - equal:
          path: spec.generators[0].list.elements[0].Values.global.appStack
          value: carriers
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run (from `charts/mc-environment`): `helm unittest -f 'tests/appset_test.yaml' .`
Expected: FAIL — the current block reads `gitbranch`/`dependencies` from base `$.Values.global` only, so the per-env `gitbranch: dev` and `dependencies.redis: true` overrides are ignored.

- [ ] **Step 3: Implement merged pass-through**

In `charts/mc-environment/templates/appset.yaml`, replace this block:

```gotemplate
                global:
                  appStack: {{ $.Values.global.appStack | lower }}
                  gitbranch: {{ $.Values.global.gitbranch }}
                  branchlabel: {{ $.Values.global.branchlabel }}
                  language: {{ $.Values.global.language }}
                  v2migration: {{ $.Values.global.v2migration }}
                  correlationId: {{ $.Values.global.correlationId | quote }}
                  commitDeployed: {{ $.Values.global.commitDeployed | quote }}
                  {{- $mergedEnv := deepCopy ($.Values.global.env | default dict) }}
                  {{- if $env.global }}{{- if $env.global.env }}{{- $mergedEnv = mustMergeOverwrite $mergedEnv $env.global.env }}{{- end }}{{- end }}
                  {{- if $mergedEnv }}
                  env:
                    {{- $mergedEnv | toYaml | nindent 20 }}
                  {{- end }}
                  {{ with $.Values.global.dependencies }}
                  dependencies:
                    {{- toYaml . | nindent 20 }}
                  {{ end }}
```

with:

```gotemplate
                global:
                  {{- $g := mustMergeOverwrite (deepCopy $.Values.global) ($env.global | default dict) }}
                  {{- $_ := set $g "appStack" (lower ($g.appStack | default "")) }}
                  {{- $g | toYaml | nindent 18 }}
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run (from `charts/mc-environment`): `helm unittest -f 'tests/appset_test.yaml' .`
Expected: PASS. Pre-existing global tests still PASS:
- "forwards dev environment configuration" (`global.dependencies.redis: true`, `global.env.LOG_LEVEL: info`, `global.correlationId: test-corr-id-123`, `global.commitDeployed: abc1234`) — all present via the merged base global.
- "forwards empty correlationId and commitDeployed when not set" — values.yaml defaults both to `""`, so the merged map still emits `correlationId: ""` / `commitDeployed: ""`.

- [ ] **Step 5: Commit**

```bash
git add charts/mc-environment/templates/appset.yaml charts/mc-environment/tests/appset_test.yaml
git commit -m "fix(mc-environment): merge per-env global overrides into the global block

Deep-merge base global with the environment's global override and emit via
toYaml (forcing appStack lowercase), so per-env gitbranch/dependencies/env
overrides take effect instead of being silently dropped."
```

---

## Task 3: Add `namespaceOverride` to the environment-override schema

**Files:**
- Modify: `charts/mc-environment/values.schema.json:119-122`
- Test: `charts/mc-environment/tests/appset_test.yaml` (reuses `environment-overrides.yaml`, which already sets `namespaceOverride`)

- [ ] **Step 1: Write the failing test (schema rejects namespaceOverride today)**

The `environment-overrides.yaml` fixture sets `environment.namespaceOverride`, but `mycarrierEnvironmentOverride` does not declare it. Confirm the current schema rejects it:

Run (from `charts/mc-environment`): `helm template . -f tests/fixtures/environment-overrides.yaml >/dev/null; echo "rc=$?"`
Expected: FAIL (`rc` non-zero) with a schema error: additional property `namespaceOverride` not allowed under the environment block.

> Note: if Task 0 found remote `$ref`s are NOT enforced, this step may unexpectedly pass. In that case skip to Step 2 (the schema addition is still correct and harmless) and treat Step 4 as a render smoke-test only.

- [ ] **Step 2: Add the property**

In `charts/mc-environment/values.schema.json`, inside `mycarrierEnvironmentOverride.properties`, replace:

```json
        "domainOverride": {
          "$ref": "https://raw.githubusercontent.com/MyCarrier-DevOps/helm-charts/refs/heads/main/charts/mycarrier-helm/values.schema.json#/properties/environment/properties/domainOverride"
        }
      }
```

with:

```json
        "domainOverride": {
          "$ref": "https://raw.githubusercontent.com/MyCarrier-DevOps/helm-charts/refs/heads/main/charts/mycarrier-helm/values.schema.json#/properties/environment/properties/domainOverride"
        },
        "namespaceOverride": {
          "$ref": "https://raw.githubusercontent.com/MyCarrier-DevOps/helm-charts/refs/heads/main/charts/mycarrier-helm/values.schema.json#/properties/environment/properties/namespaceOverride"
        }
      }
```

- [ ] **Step 3: Validate the JSON is well-formed**

Run (from `charts/mc-environment`): `python3 -m json.tool values.schema.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 4: Render the fixture, verify it now validates**

Run (from `charts/mc-environment`): `helm template . -f tests/fixtures/environment-overrides.yaml >/dev/null; echo "rc=$?"`
Expected: `rc=0`. Then re-run the suite: `helm unittest -f 'tests/appset_test.yaml' .` → PASS.

- [ ] **Step 5: Commit**

```bash
git add charts/mc-environment/values.schema.json
git commit -m "feat(mc-environment): allow environment.namespaceOverride in schema

Add namespaceOverride to mycarrierEnvironmentOverride via remote \$ref to
mycarrier-helm, matching the other environment properties."
```

---

## Task 4: Repoint the local `infrastructure` schema to mycarrier-helm (remote)

**Precondition:** Task 0 found remote `$ref`s ARE enforced. If NOT, do **Task 4 (fallback)** below instead.

**Files:**
- Modify: `charts/mc-environment/values.schema.json:313-321`
- Test: `charts/mc-environment/tests/appset_test.yaml`

- [ ] **Step 1: Write the failing test (a field mycarrier-helm permits but the local copy rejects)**

mycarrier-helm's storage account allows additional properties; the local copy sets `additionalProperties: false`. Append to `charts/mc-environment/tests/appset_test.yaml`:

```yaml
  - it: accepts storage-account fields that mycarrier-helm permits
    set:
      global.appStack: carriers
      environments:
        - name: dev
          infrastructure:
            azure:
              storage:
                accounts:
                  - name: shipmentsdata
                    sku: Standard_LRS
                    newStorageAccount:
                      name: shipmentsdata
    documentSelector:
      path: metadata.name
      value: carriers-dev
    asserts:
      - equal:
          path: spec.generators[0].list.elements[0].Values.infrastructure.azure.storage.accounts[0].sku
          value: Standard_LRS
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run (from `charts/mc-environment`): `helm unittest -f 'tests/appset_test.yaml' .`
Expected: FAIL — schema error: additional property `sku` not allowed on the storage account (local `additionalProperties: false`).

- [ ] **Step 3: Repoint the definition to the remote schema**

In `charts/mc-environment/values.schema.json`, replace:

```json
    "infrastructure": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "azure": {
          "$ref": "#/definitions/infrastructureAzure"
        }
      }
    },
```

with:

```json
    "infrastructure": {
      "$ref": "https://raw.githubusercontent.com/MyCarrier-DevOps/helm-charts/refs/heads/main/charts/mycarrier-helm/values.schema.json#/properties/infrastructure"
    },
```

> The `infrastructureAzure*` definitions become unreferenced (dead) but are harmless. Leave them; a separate cleanup PR can remove them to avoid a large diff here.

- [ ] **Step 4: Validate JSON + run tests**

Run (from `charts/mc-environment`):
```bash
python3 -m json.tool values.schema.json >/dev/null && echo OK
helm unittest -f 'tests/appset_test.yaml' .
```
Expected: `OK`; suite PASSES (the `sku` test now passes; the existing `newStorageAccount.name`/`containers` assertions still pass because the remote schema is a superset).

- [ ] **Step 5: Commit**

```bash
git add charts/mc-environment/values.schema.json charts/mc-environment/tests/appset_test.yaml
git commit -m "feat(mc-environment): validate infrastructure against mycarrier-helm schema

Repoint the local infrastructure definition to mycarrier-helm's published
schema (remote \$ref), so any field mycarrier-helm accepts (e.g. storage sku)
validates here and stays in sync. Remote-\$ref enforcement confirmed in Task 0."
```

---

## Task 4 (fallback): Targeted local infrastructure patch

**Use only if Task 0 found remote `$ref`s are NOT enforced.** Keeping a local copy that's actually enforced is better than a remote ref that's silently ignored.

**Files:**
- Modify: `charts/mc-environment/values.schema.json` — `infrastructureAzureStorageAccount` definition (the storage-account object).

- [ ] **Step 1: Write the failing test**

Use the exact same test from Task 4 Step 1 ("accepts storage-account fields that mycarrier-helm permits").

- [ ] **Step 2: Run the test, verify it FAILS** (same as Task 4 Step 2).

- [ ] **Step 3: Open the storage account to additional properties**

In `charts/mc-environment/values.schema.json`, find the `infrastructureAzureStorageAccount` definition and change its `"additionalProperties": false` to `"additionalProperties": true` (mycarrier-helm permits extra storage-account fields). Make the same change to `infrastructureAzureNewStorageAccount` if the offending field nests there.

- [ ] **Step 4: Validate JSON + run tests** (same commands as Task 4 Step 4). Expected PASS.

- [ ] **Step 5: Commit**

```bash
git add charts/mc-environment/values.schema.json charts/mc-environment/tests/appset_test.yaml
git commit -m "fix(mc-environment): align storage-account schema with mycarrier-helm

Helm does not enforce remote \$refs (confirmed in Task 0), so patch the local
infrastructure copy to permit the extra storage-account fields mycarrier-helm
accepts instead of repointing to a remote schema that would be ignored."
```

---

## Task 5: Prove staticHostname + domainOverride combine (mycarrier-helm)

**Files:**
- Test: `charts/mycarrier-helm/tests/virtualservice_test.yaml`

- [ ] **Step 1: Write the test**

Append to `charts/mycarrier-helm/tests/virtualservice_test.yaml` (under `tests:`):

```yaml
  - it: should combine staticHostname with an overridden domain
    set:
      environment.name: "prod"
      environment.domainOverride.enabled: true
      environment.domainOverride.domain: "custom.com"
      applications.combo-api.deploymentType: deployment
      applications.combo-api.isFrontend: false
      applications.combo-api.staticHostname: "foo"
      applications.combo-api.image.registry: "myregistry.example.com"
      applications.combo-api.image.repository: "mycarrier/combo-api"
      applications.combo-api.image.tag: "1.0.0"
      applications.combo-api.ports.http: 8080
      applications.combo-api.networking.ingress.type: "istio"
      applications.combo-api.networking.istio.enabled: true
      applications.combo-api.networking.istio.offloadOperatorEnabled: false
    asserts:
      - isKind:
          of: VirtualService
      # staticHostname (foo) joined to the overridden domain (custom.com)
      - contains:
          path: spec.hosts
          content: foo.custom.com
```

- [ ] **Step 2: Run the test, verify it PASSES**

Run (from `charts/mycarrier-helm`): `helm unittest -f 'tests/virtualservice_test.yaml' .`
Expected: PASS. (`helm.domain` short-circuits to `domainOverride.domain` when enabled; the non-feature `staticHostname` branch emits `foo.custom.com`.) This is an existing-behavior characterization test — it documents the combination works end-to-end.

- [ ] **Step 3: Commit**

```bash
git add charts/mycarrier-helm/tests/virtualservice_test.yaml
git commit -m "test(virtualservice): cover staticHostname combined with domainOverride"
```

---

## Task 6: Full regression + finish

**Files:** none (verification).

- [ ] **Step 1: Run both chart suites**

```bash
( cd charts/mc-environment && helm unittest . )
( cd charts/mycarrier-helm && helm unittest . )
```
Expected: all suites PASS in both charts.

- [ ] **Step 2: Render the original example to confirm the reported gap is closed**

Run (from `charts/mc-environment`): `helm template . -f tests/fixtures/environment-overrides.yaml >/dev/null; echo "rc=$?"`
Expected: `rc=0`, and the rendered `Values.environment` contains `dependencyenv`, `namespaceOverride`, and `domainOverride`.

- [ ] **Step 3: Use the finishing-a-development-branch skill** to decide how to integrate (PR vs merge) — do not push or open a PR without explicit user direction.

---

## Self-Review

**Spec coverage:**
- environment pass-through + inject name → Task 1. ✓
- global merged pass-through (appStack lower, correlationId/commitDeployed defaults) → Task 2 (defaults come from values.yaml; verified in Step 4). ✓
- schema: namespaceOverride → Task 3; infrastructure remote `$ref` → Task 4 (+ fallback). ✓
- remote-`$ref` enforcement unknown → Task 0 gate + Task 4 fallback. ✓
- tests: domainOverride/namespaceOverride/dependencyenv forwarding → Task 1; per-env global merge → Task 2; staticHostname + domainOverride pass-through → fixture (`environment-overrides.yaml` sets both) asserted in Task 1 + the mycarrier-helm combination → Task 5; previously-rejected infra field → Task 4. ✓
- exclusion of `isEnvironmentDeploy=false`-only config → no such config is touched. ✓

**Placeholder scan:** none — every step has exact paths, code, commands, expected output.

**Type/name consistency:** template var names (`$envBlock`, `$g`) are self-contained per task; remote URL string identical across Tasks 3 and 4; fixture filename `environment-overrides.yaml` consistent across Tasks 1, 3, 6.

**staticHostname+domainOverride pass-through:** covered non-optionally in Task 1 Step 2 — the fixture sets both an app `staticHostname: api` and `environment.domainOverride`, and the test asserts both reach the generated `Values`. The mycarrier-helm side (that they combine into `foo.custom.com`) is Task 5.
