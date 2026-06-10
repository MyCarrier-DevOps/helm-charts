# helm.whitelabelHost Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `helm.whitelabelHost` named template to mycarrier-helm that builds a whitelabel VirtualService host (`<label>.<domain>`, with a `.<env>` infix outside prod/preprod/dev) using the environment-resolved domain, callable from `networking.istio.hosts`.

**Architecture:** `networking.istio.hosts` entries are already evaluated via `tpl . $` in every VirtualService path, so adding the helper requires NO template-path changes — only the helper definition plus tests and docs. The helper takes `{label, ctx}` where `ctx` is the root `$`, derives the domain from `helm.domain` (honoring `environment.domainOverride`), and conditionally inserts the env infix.

**Tech Stack:** Helm (Go templates + Sprig), helm-unittest.

**Conventions:**
- Run mycarrier-helm tests from `charts/mycarrier-helm`: `helm unittest -f 'tests/<file>' .`
- Work on branch `feat/mc-environment-config-sync` (already checked out). Do NOT touch `main`.
- Commit attribution: the repo's git user only; no `Co-Authored-By`, no AI mentions.

---

## File Structure

- `charts/mycarrier-helm/templates/_helpers.tpl` — **modify**: add the `helm.whitelabelHost` define (next to `helm.domain`, near the top).
- `charts/mycarrier-helm/tests/whitelabel_host_test.yaml` — **create**: the helper's test suite (targets `virtualService.yaml`).
- `charts/mycarrier-helm/README.md` — **modify**: add a usage example in the istio hosts documentation.
- `charts/mycarrier-helm/values.yaml` — **modify**: add a commented example on `networking.istio.hosts`.

---

## Task 1: Add the `helm.whitelabelHost` helper (TDD)

**Files:**
- Create: `charts/mycarrier-helm/tests/whitelabel_host_test.yaml`
- Modify: `charts/mycarrier-helm/templates/_helpers.tpl`

- [ ] **Step 1: Write the failing test suite.** Create `charts/mycarrier-helm/tests/whitelabel_host_test.yaml`:

```yaml
suite: whitelabel host helper tests
templates:
  - virtualService.yaml
tests:
  - it: omits the env infix in dev
    set:
      environment.name: "dev"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - isKind:
          of: VirtualService
      - contains:
          path: spec.hosts
          content: estes.mycarrier.dev

  - it: omits the env infix in prod (prod domain)
    set:
      environment.name: "prod"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.mycarriertms.com

  - it: omits the env infix in preprod
    set:
      environment.name: "preprod"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.mycarrier.dev

  - it: includes the env infix in a feature environment
    set:
      environment.name: "feature20"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.feature20.mycarrier.dev

  - it: includes the env infix in qa (skip-set boundary)
    set:
      environment.name: "qa"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.qa.mycarrier.dev

  - it: honors domainOverride on the infix branch
    set:
      environment.name: "feature20"
      environment.domainOverride.enabled: true
      environment.domainOverride.domain: "integratedtm.dev"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.feature20.integratedtm.dev

  - it: honors domainOverride on the no-infix branch
    set:
      environment.name: "dev"
      environment.domainOverride.enabled: true
      environment.domainOverride.domain: "integratedtm.dev"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      - contains:
          path: spec.hosts
          content: estes.integratedtm.dev

  - it: coexists with staticHostname under a domainOverride
    set:
      environment.name: "dev"
      environment.domainOverride.enabled: true
      environment.domainOverride.domain: "integratedtm.dev"
      applications.wl-api.deploymentType: deployment
      applications.wl-api.isFrontend: false
      applications.wl-api.staticHostname: "api"
      applications.wl-api.image.registry: "r"
      applications.wl-api.image.repository: "mycarrier/wl-api"
      applications.wl-api.image.tag: "1.0.0"
      applications.wl-api.ports.http: 8080
      applications.wl-api.networking.ingress.type: "istio"
      applications.wl-api.networking.istio.enabled: true
      applications.wl-api.networking.istio.offloadOperatorEnabled: false
      applications.wl-api.networking.istio.hosts:
        - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
    asserts:
      # static host uses the overridden domain
      - contains:
          path: spec.hosts
          content: api.integratedtm.dev
      # whitelabel helper host also present, also on the overridden domain (dev = no infix)
      - contains:
          path: spec.hosts
          content: estes.integratedtm.dev
```

- [ ] **Step 2: Run the suite, confirm it FAILS for the right reason.**

Run (from `charts/mycarrier-helm`): `helm unittest -f 'tests/whitelabel_host_test.yaml' .`
Expected: FAIL/ERROR — the template `helm.whitelabelHost` is not defined, so `tpl` errors while rendering the host (e.g. `template ... helm.whitelabelHost ... not defined`). If it PASSES, STOP and report BLOCKED (the helper may already exist).

- [ ] **Step 3: Add the helper.** In `charts/mycarrier-helm/templates/_helpers.tpl`, add this block immediately AFTER the closing `{{- end -}}` of the `helm.domain` definition (the `helm.domain` define is near the top of the file, lines ~1-18):

```gotemplate

{{- define "helm.whitelabelHost" -}}
{{- $label := required "helm.whitelabelHost requires a label" .label -}}
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

- [ ] **Step 4: Run the suite, confirm all 8 tests PASS.**

Run (from `charts/mycarrier-helm`): `helm unittest -f 'tests/whitelabel_host_test.yaml' .`
Expected: PASS, 8/8.

- [ ] **Step 5: Run the full chart suite to confirm no regressions.**

Run (from `charts/mycarrier-helm`): `helm unittest .`
Expected: all suites pass.

- [ ] **Step 6: Commit.**

```bash
git add charts/mycarrier-helm/templates/_helpers.tpl charts/mycarrier-helm/tests/whitelabel_host_test.yaml
git commit -m "feat(virtualservice): add helm.whitelabelHost template helper

Build a whitelabel host (<label>.<domain>, with a .<env> infix outside
prod/preprod/dev) from the environment-resolved domain, callable from
networking.istio.hosts. Honors environment.domainOverride."
```

---

## Task 2: Document the helper

**Files:**
- Modify: `charts/mycarrier-helm/README.md`
- Modify: `charts/mycarrier-helm/values.yaml`

- [ ] **Step 1: Locate the istio hosts documentation in `charts/mycarrier-helm/README.md`.**

Run: `grep -n "networking.istio.hosts\|istio:" charts/mycarrier-helm/README.md | head`
Identify the section that documents `networking.istio.hosts` (custom VirtualService hosts). If no such section exists, add the example under the nearest Istio/VirtualService heading.

- [ ] **Step 2: Add this documentation block** in that section (verbatim):

````markdown
#### Whitelabel hosts

Use the `helm.whitelabelHost` helper to publish a label on the environment's domain without
hardcoding it. It renders `<label>.<domain>` in `prod`/`preprod`/`dev` and `<label>.<env>.<domain>`
in every other environment (`qa`, `uat`, `feature*`). The domain follows
`environment.domainOverride`.

```yaml
networking:
  istio:
    hosts:
      - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
```

| environment | rendered host |
|---|---|
| `prod` | `estes.mycarriertms.com` |
| `dev` / `preprod` | `estes.mycarrier.dev` |
| `feature20` | `estes.feature20.mycarrier.dev` |
| `feature20` + `domainOverride: integratedtm.dev` | `estes.feature20.integratedtm.dev` |

> Note: `{{ $domain }}` does **not** resolve inside a host value (it is a template-internal
> variable). Use `{{ include "helm.domain" $ }}` or the `helm.whitelabelHost` helper instead.
````

- [ ] **Step 3: Add a commented example to `charts/mycarrier-helm/values.yaml`.**

Run: `grep -n "hosts:" charts/mycarrier-helm/values.yaml | head` to find the `networking.istio.hosts` key (or its documentation comment). Immediately adjacent to it, add this comment (match the file's existing comment indentation):

```yaml
        # Whitelabel hosts can use the helm.whitelabelHost helper to derive the domain:
        #   hosts:
        #     - '{{ include "helm.whitelabelHost" (dict "label" "estes" "ctx" $) }}'
        # Renders estes.<domain> in prod/preprod/dev and estes.<env>.<domain> elsewhere.
```

If `networking.istio.hosts` is not present in `values.yaml`, add the comment under the existing `networking.istio` documentation block instead. Do not add a live (uncommented) `hosts` value.

- [ ] **Step 4: Sanity-check the chart still templates and tests pass.**

Run (from `charts/mycarrier-helm`):
```bash
helm template . >/dev/null && echo "template OK"
helm unittest -f 'tests/whitelabel_host_test.yaml' .
```
Expected: `template OK`; suite 8/8 (docs changes must not affect rendering).

- [ ] **Step 5: Commit.**

```bash
git add charts/mycarrier-helm/README.md charts/mycarrier-helm/values.yaml
git commit -m "docs(virtualservice): document helm.whitelabelHost usage"
```

---

## Task 3: Bump chart version

**Files:**
- Modify: `charts/mycarrier-helm/Chart.yaml`

- [ ] **Step 1: Read the current version.**

Run: `grep -n '^version:' charts/mycarrier-helm/Chart.yaml`

- [ ] **Step 2: Bump the minor version** (new backward-compatible feature). Edit `charts/mycarrier-helm/Chart.yaml` `version:` from `3.2.0` to `3.3.0`. If the current version is not `3.2.0`, bump the minor component of whatever the current version is (e.g. `X.Y.Z` → `X.(Y+1).0`) and note the actual values in the commit.

- [ ] **Step 3: Commit.**

```bash
git add charts/mycarrier-helm/Chart.yaml
git commit -m "chore(mycarrier-helm): bump chart version for whitelabelHost helper"
```

---

## Self-Review

**Spec coverage:**
- Helper definition (label + ctx, helm.domain, skip-set prod/preprod/dev, required label) → Task 1 Step 3. ✓
- No template-path changes (hosts already tpl'd) → reflected: only `_helpers.tpl` touched. ✓
- All 8 spec test cases (dev, prod, preprod, feature20, qa, override+infix, override+no-infix, override+staticHostname) → Task 1 Step 1 has all 8. ✓
- Docs (README + values.yaml, incl. the `$domain` note) → Task 2. ✓
- Chart version bump (consistent with how other features in this repo ship, e.g. the tpl-interpolation feature bumped the chart) → Task 3. ✓

**Placeholder scan:** none — all test code, the helper, and doc blocks are provided in full. Task 2 doc-insertion points are located by `grep` because exact README/values line numbers are not known in advance; the content to insert is fully specified.

**Type/name consistency:** helper name `helm.whitelabelHost`, calling convention `(dict "label" <x> "ctx" $)`, and app name `wl-api` are used identically across every task and test case. Expected domains (`mycarriertms.com` for prod, `mycarrier.dev` otherwise) match `helm.domain`'s behavior and the spec table.
