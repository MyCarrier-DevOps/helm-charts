# Test Trigger Configuration Guide

## Overview

Test triggers are configured in the Helm values files (e.g., `values.dev.yaml`, `values.prod.yaml`) and are processed by the Helm templates to create Kubernetes jobs that execute test triggers. For each application, all of its test definitions are bundled into a single curl call to the test engine API with a `{"Tests": [...]}` payload. Each application can have its own configuration of test triggers with their respective test definitions.

### ArgoCD Integration

Test trigger jobs run as post-sync hooks in ArgoCD. This means that after ArgoCD successfully syncs your application to the desired state, it automatically triggers the test jobs as part of the deployment process. A failed TestEngine call does not fail the sync: the hook logs an `ERROR:` line for each failed call and exits 0, so Argo CD does not retry the sync. The hook Job itself can still fail the sync when its pod does not run to the end, for example when the image cannot be pulled, Vault cannot resolve a `vault:` value, or the Job passes `activeDeadlineSeconds`: Argo CD marks the sync failed when a PostSync hook fails, and the sync result names the `<fullName>-trigger` hook with the reason. The tests themselves run in the Jobs that TestEngine starts; their results reach the pipeline and the PR checks, not the sync. If tests do not appear in TestEngine, read the trigger pod's log during the sync; if the trigger pod never started (an image pull failure leaves no log), read the hook's message in the sync result.

How it works:
1. ArgoCD deploys your application resources based on the Helm chart
2. Once the sync is successful, ArgoCD identifies the jobs with the `argocd.argoproj.io/hook: PostSync` annotation
3. These test trigger jobs are then executed
4. These jobs make curl calls to TestEngineApi that deploys tests to the appropriate k8s cluster and namespace, allowing the tests to run against the internal k8s service

### Rollouts in prod

In prod, an application with `deploymentType: rollout` (without `migratingToRollouts`) whose repository's `deployment-strategy` property is `canary` (chart-renderer passes it as `global.deploymentStrategy`) gets no PostSync hook (Tech Spec D7): the hook can fire at the start of a canary sync, after the last promote or after an abort, so it can test the wrong version. The release's rollout-watch (DEVOPS-319) starts the prod tests after the canary is promoted instead:

- rollout-watch runs only on the canary release path, and the chart follows the same property: a prod Rollout in a `rolling` or unset repository runs no canary steps and keeps its PostSync hook.
- The chart renders the ConfigMap `<fullName>-prod-tests` in the application's namespace, labelled `mycarrier.tech/correlationId`. Its key `request.json` holds the same TestEngine v1 request the hook sends (one template renders both, with no `SlipStep`), and rollout-watch posts it to TestEngine's v1 trigger. rollout-watch posts only to TestEngine's v1 trigger until it reads the ConfigMap's `version` key (DEVOPS-613), and v1 refuses a v2 request with a `422`, so for now a prod canary Rollout whose test definitions set `testEnvironmentTag` fails the render: keep `filters` in its prod values. Once rollout-watch reads `version`, the chart can render `request.json` with the v2 request and a second key, `version: v2`, so rollout-watch posts it to `/v2/trigger`; without `version` the request is v1.
- `apikey` must be `vault:DevOps/data/testengine/api#encoded_header` or unset, and `global.testengineWebhookUrl` must not be set: rollout-watch posts with the shared key and its own URL, so the render fails instead of ignoring them.

Other environments, Deployments, StatefulSets, migrating Rollouts and Rollouts whose property is not `canary` keep the PostSync hook.

### Test definitions in canary analysis

A canary Rollout stack (repository `deployment-strategy` property `canary`) can also run its test definitions inside the
canary (DEVOPS-515): list `tests` in `global.strategy.canary.analysis.templates`. The chart then renders the
AnalysisTemplate `<environment>-<fullName>-tests`,
and each analysis step runs a Job that sends the same v1 request as the hook, with four changes: `ServiceAddress` is the
`-preview` Service (a definition's `serviceAddress` must point at the application's own Service, with no port or the
`http` Service port, and the run keeps its path; another host or port fails the render), `RunKind: canary` and `SlipStep: none` inside `TestEnvironmentVariables`, and
`Tolerations: []`. `apikey` must be unset (the shared key) or a `vault:` reference. The Job polls TestEngine's `GET /v1/runs/{id}` and exits 0 only when
the run passes, so a failing suite aborts the canary. The hook and the prod-tests ConfigMap do not change. Every canary
Rollout application needs `testdefinitions` where `tests` is listed, and TestEngine must run with `RUN_KINDS_ENABLED=true`. See
the stack-values guidance (Rollouts, Analysis) for the timeout (`analysis.tests.timeout`, default `7m`, plus
`analysis.tests.startupSeconds`, default `120`), the canary budget and the barrier window. A Rollout
whose property is not `canary` ignores `tests`: it renders no tests template and runs none of its checks.
The `tests` and `tests-dark` runs post to TestEngine's v1 trigger only: an application whose test definitions set
`testEnvironmentTag` fails the render where the chart's `tests` or `tests-dark` template renders for it (`tests-dark` is on by
default for a prod canary leader). Keep `filters` on such an application, define your own template under
`analysisTemplates`, or leave `tests` out of `analysis.templates` (for `tests-dark`, set `dark: false`).

## Configuration Structure

Test triggers are configured at the application level in the values file. Below is the general structure:

```yaml
applications:
  <application-name>:
    testtrigger:
      activeDeadlineSeconds: "<seconds>"
      ttlSecondsAfterFinished: "<seconds>"
      apikey: "<api-key-or-vault-reference>"
      backoffLimit: <number>
      resources:
        requests:
          memory: "<memory-request>"
          cpu: "<cpu-request>"
        limits:
          memory: "<memory-limit>"
          cpu: "<cpu-limit>"
      enableV1: true                 # Optional; unset or null means true (false fails the render)
      env:                           # Optional — variables for every test definition's test container
        <NAME>: "<value>"
      testdefinitions:
        - containerImage: <image-name>
          containerTag: <tag>
          filters:
            - <filter1>
            - <filter2>
          name: <test-name>
          secretId: "<secret-id-or-vault-reference>"
          serviceAddress: "<optional-service-address>"
          additionalEnvVars: "key1=value1;key2=value2"   # Deprecated: use env
          env:                       # Optional — this definition only; wins over testtrigger.env on a name clash
            <NAME>: "<value>"
          resultsApiKey: "<optional-vault-reference-to-the-results-api-key>"
          resultsApiUrl: "<vault-reference-or-https-url, set together with resultsApiKey>"
          legacyMode: <true|false>
          useDefaultNodeAffinity: <true|false>
          spreadAcrossNodes: <true|false>
          tolerations:
            - key: "<key>"
              operator: "<operator>"
              value: "<value>"
              effect: "<effect>"
          nodeAffinity:
            - key: "<key>"
              operator: "<operator>"
              type: "<type>"
              values:
                - "<value>"
          podResources:
            limits:
              cpu: "<cpu-limit>"
              memory: "<memory-limit>"
            requests:
              cpu: "<cpu-request>"
              memory: "<memory-request>"
```

## Configuration Parameters

### Top-Level Parameters

| Parameter | Description | Required | Default | Example |
|-----------|-------------|----------|---------|---------|
| `activeDeadlineSeconds` | Maximum time in seconds that the test job can run before being terminated | No | `"300"` | `"300"` |
| `apikey` | API key for the test engine, can be a direct value or a vault reference | Yes | None | `"vault:Secrets/data/path/to/secret#apikey"` |
| `backoffLimit` | Number of retries for the test job in case of failure | No | `0` | `0` |
| `resources` | Resource requests and limits for the test job pod | No | See below* | See example below |
| `ttlSecondsAfterFinished` | Time in seconds to keep the job after it finishes | No | `"3600"` | `"3600"` |
| `enableV1` | Unset or `null` means `true`, the default and the only value that renders: all test definitions are bundled into a single POST to TestEngine's v1 trigger (`api/v1`) with a `{"Tests":[...]}` payload, or its v2 trigger for test definitions with `testEnvironmentTag`. `false` fails the render for every application, with or without test definitions: it selected one POST per test definition to TestEngine's legacy `POST /trigger`, which is removed (DEVOPS-623). The webhook URL is set automatically (`vault:DevOps/data/testengine/api/v1#url`, or `#dev_url` on `argo-events-test`); `global.testengineWebhookUrl` overrides it, except for a canary Rollout in prod (property `canary`), where setting it fails the render (see Rollouts in prod). | No | `true` | `true` |
| `env` | Environment variables set on the test container of **every** test definition of this application: a map of names to quoted strings. A definition's own `env` wins on a name clash. See [Environment variables for test pods](#environment-variables-for-test-pods-env) | No | None | `{RESULTS_DB: "qa-results"}` |

*Default resource values:
```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"
```

### Test Definition Parameters

Each test definition under `testdefinitions` supports the following parameters:

| Parameter | Description | Required | Default | Example |
|-----------|-------------|----------|---------|---------|
| `containerImage` | The container image containing the test code | Yes | None | `"testing/exampletestapp"` |
| `containerTag` | The tag of the container image to use | Yes | None | `"abcd1234"` |
| `filters` | Test filters to apply, sent to TestEngine's v1 trigger. Accepts a single string or an array of strings. Not together with `testEnvironmentTag`. | No | `[]` (empty array) | `"TestCategory=coretests"` or `["TestCategory=coretests", "TestCategory=othercoretests"]` |
| `testEnvironmentTag` | The tag (a `TestCategory` in the test code) of the tests to run, sent to TestEngine's v2 trigger in place of `filters`. Letters, digits, `_`, `.` and `-`, at most 100 characters, at least one letter or digit. See [Tag-based runs](#tag-based-runs-testenvironmenttag-v2-trigger) | No | None (v1 with `filters`) | `"FeatureCore"` |
| `testTags` | With `testEnvironmentTag` only: runs the tests that carry the tag **and** every listed tag. At most 10, same characters as the tag | No | None | `["Invoices"]` |
| `multiRun` | With `testEnvironmentTag` only: asks TestEngine to pack the tests into several Jobs. Packed only while that TestEngine reports `multi_run_enabled: true` in `GET /v1/capabilities` (its `MULTI_RUN_ENABLED` switch, off by default); otherwise the run is one Job and the hook logs a `WARN:` line | No | `false` | `true` |
| `name` | Name of the test | Yes | None | `"apitests"` |
| `secretId` | Secret ID for authentication, can be a direct value or a vault reference | Yes | None | `"vault:Secrets/data/auth#secretid"` |
| `serviceAddress` | Optional service address for the test to target | No | `"<fullname>.<namespace>.svc.cluster.local:<http Service port>"` | `"my-service.namespace.svc.cluster.local:8080"` |
| `releaseDefinitionName` | Optional release definition name - overrides default value = stack-component | No | stack-compoent | `"somestack-somecomponent"`
| `env` | Environment variables set on **this definition's** test container only, as a map of names to quoted strings. Merged key by key over `testtrigger.env`; this definition wins on a name clash. See [Environment variables for test pods](#environment-variables-for-test-pods-env) | No | None | `{SHARED_KEY: "vault:QA/data/x#y"}` |
| `additionalEnvVars` | **Deprecated**: use `env`. Reaches the pod as one variable, `ADDITIONAL_ENV_VARS`, entries separated by `;` | No | `""` | `"key1=value1;key2=value2"` |
| `resultsApiKey` | Vault reference to the autotest-results-api key, set on the test container as `AUTOTEST_RESULTS_API_KEY`. A value that is not a `vault:` reference fails the render, so the key itself never goes in a values file. Set together with `resultsApiUrl`, or not at all | No | None (the variable is not set) | `"vault:DevOps/data/autotestresults_api/api#key"` |
| `resultsApiUrl` | autotest-results-api base URL, a `vault:` reference or an `https` URL under `mycarrier.tech` with no user info, set on the test container as `AUTOTEST_RESULTS_API_URL`. Set together with `resultsApiKey`: one without the other fails the render, since the test uploads only when both are set. There is no default | No | None (the variable is not set) | `"vault:QA/data/autotestresults_api#url"` |
| `legacyMode` | Enable legacy mode for test execution. Accepts boolean or string. | No | `false` | `true` |
| `tolerations` | Tolerations for test pods scheduled by the test engine | No | Spot instance toleration* | See example below |
| `nodeAffinity` | Node affinity rules for test pods scheduled by the test engine | No | `[]` (empty array) | See example below |
| `useDefaultNodeAffinity` | Whether to use default node affinity for test pods. Accepts boolean or string. | No | `false` | `true` |
| `spreadAcrossNodes` | Whether to spread test pods across nodes. Accepts boolean or string. | No | `true` | `false` |
| `hardenedSecurityContext` | Run test pods with a hardened security context (non-root, read-only rootfs). Accepts boolean or string; set `false` to opt out. | No | `true` | `false` |
| `podResources` | Resource requests and limits for test pods scheduled by the test engine | No | See below** | See example below |

*Default tolerations:
```yaml
tolerations:
  - key: "kubernetes.azure.com/scalesetpriority"
    operator: "Equal"
    value: "spot"
    effect: "NoSchedule"
```

**Default pod resources:
```yaml
podResources:
  limits:
    cpu: "2000m"
    memory: "4Gi"
  requests:
    cpu: "250m"
    memory: "1Gi"
```

## Example Configurations

### Basic Configuration with Filters

```yaml
testtrigger:
  activeDeadlineSeconds: "300"
  ttlSecondsAfterFinished: "3600"
  apikey: "vault:Secrets/data/path/to/secret#apikey"
  backoffLimit: 0
  testdefinitions:
    - containerImage: testing/exampletestapp
      containerTag: abcd1234
      filters:
        - TestCategory=coretests
        - TestCategory=othercoretests
      name: apitests
      secretId: "vault:Secrets/data/auth#secretid"
      additionalEnvVars: ""
```

### Configuration without Filters

```yaml
testtrigger:
  activeDeadlineSeconds: "300"
  ttlSecondsAfterFinished: "3600"
  apikey: "vault:Secrets/data/path/to/secret#apikey"
  backoffLimit: 0
  testdefinitions:
    - containerImage: testing/exampletestapp
      containerTag: abcd1234
      filters: []
      name: somedependencytest
      secretId: "vault:Secrets/data/auth#secretid"
      additionalEnvVars: "key1=value1;key2=value2;key3=value3"
```

### Configuration with Resources and Custom Service Address

```yaml
testtrigger:
  activeDeadlineSeconds: "300"
  ttlSecondsAfterFinished: "3600"
  apikey: "vault:Secrets/data/path/to/secret#apikey"
  backoffLimit: 0
  resources:
    requests:
      memory: "128Mi"
      cpu: "200m"
    limits:
      memory: "512Mi"
      cpu: "1000m"
  testdefinitions:
    - containerImage: testing/exampletestapp
      containerTag: abcd1234
      filters:
        - TestCategory=coretests
      name: apitests
      secretId: "vault:Secrets/data/auth#secretid"
      serviceAddress: "custom-service.custom-namespace.svc.cluster.local:8080"
      additionalEnvVars: "key1=value1"
```

### Configuration with Pod Scheduling and Resources

```yaml
testtrigger:
  activeDeadlineSeconds: "300"
  ttlSecondsAfterFinished: "3600"
  apikey: "vault:Secrets/data/path/to/secret#apikey"
  backoffLimit: 0
  testdefinitions:
    - containerImage: testing/exampletestapp
      containerTag: abcd1234
      filters:
        - TestCategory=coretests
      name: apitests
      secretId: "vault:Secrets/data/auth#secretid"
      legacyMode: false
      spreadAcrossNodes: true
      useDefaultNodeAffinity: false
      tolerations:
        - key: "kubernetes.azure.com/scalesetpriority"
          operator: "Equal"
          value: "spot"
          effect: "NoSchedule"
      nodeAffinity:
        - key: "agentpool"
          operator: "In"
          type: "nodeSelector"
          values:
            - "testpool"
      podResources:
        limits:
          cpu: "2000m"
          memory: "4Gi"
        requests:
          cpu: "250m"
          memory: "1Gi"
```

### Multiple Applications with Multiple Tests

The following example shows how multiple applications can each have their own test triggers with multiple test definitions:

```yaml
applications:
  api:
    testtrigger:
      activeDeadlineSeconds: "300"
      ttlSecondsAfterFinished: "3600"
      apikey: "vault:Secrets/data/path/to/secret#apikey"

      backoffLimit: 0
      resources:
        requests:
          memory: "128Mi"
          cpu: "200m"
        limits:
          memory: "512Mi"
          cpu: "1000m"
      testdefinitions:
        - containerImage: testing/exampletestapp
          containerTag: abcd1234
          filters:
            - TestCategory=coretests
            - TestCategory=othercoretests
          name: apitests
          secretId: "vault:Secrets/data/auth#secretid"
          serviceAddress: "api.default.svc.cluster.local:9000"
        - containerImage: testing/dependencytests
          containerTag: efgh5678
          filters: []
          name: somedependencytest
          secretId: "vault:Secrets/data/auth#secretid"
  internal-api:
    testtrigger:
      apikey: "vault:Secrets/data/path/to/secret#apikey"

      backoffLimit: 0
      testdefinitions:
        - containerImage: testing/internalapitests
          containerTag: ijkl9012
          filters:
            - TestCategory=internalapitests
          name: internalapitests
          secretId: "vault:Secrets/data/auth#secretid"
```
Explanation: This configuration creates one test trigger Job per application: one Job for `api` and one Job for `internal-api`. Each Job sends a single curl POST to the test engine API whose payload bundles all of that application's test definitions in a `Tests` array — so the `api` Job's payload contains two test entries and the `internal-api` Job's payload contains one. The `api` Job has custom resource requirements and the first test definition specifies a custom service address.

## Tag-based runs (`testEnvironmentTag`, v2 trigger)

A test definition can name a **test environment tag** instead of a `filters` list (AQA-38). The hook then posts to
TestEngine's v2 trigger (`/v2/trigger`), which runs the tests that carry the tag (a `TestCategory` in the test code) in
one Job and reports them under Stage = the tag. The service no longer keeps a Vault list of test categories.

```yaml
testtrigger:
  apikey: vault:DevOps/data/testengine/api#encoded_header
  enableV1: true
  testdefinitions:
    - name: apitests
      containerImage: testing/mc/document/automatedtests/tests
      containerTag: 26.47.0a103e0
      secretId: vault:QA/data/app_auth#SecretId
      testEnvironmentTag: FeatureCore   # in place of filters
      testTags: [Invoices]              # optional: tests with FeatureCore and Invoices
      multiRun: false                   # optional, default false
      resultsApiKey: vault:DevOps/data/autotestresults_api/api#key
      resultsApiUrl: vault:QA/data/autotestresults_api#url
```

The v2 request is the v1 request without `TestFilters`, with `TestEnvironmentTag`, `TestTags` (left out when empty) and
`MultiRun` (left out when false). Everything else is the same: `podResources` and its default, tolerations, the results
API settings, `env` and its limits.

### Rules (checked at render)

The render fails, naming the application, the test definition and the field, when:

- a definition sets both `filters` (not empty) and `testEnvironmentTag`;
- `testTags` or `multiRun: true` is set without `testEnvironmentTag`;
- the tag or a test tag has a character other than letters, digits, `_`, `.` and `-`, is longer than 100 characters, or
  (the tag) has no letter or digit; or there are more than 10 `testTags`;
- some definitions of an application set `testEnvironmentTag` and others do not. All definitions of an application use the
  same trigger: two triggers are two batches, and two batches of one deployment write its tests step twice;
- the application's canary `tests` or `tests-dark` template renders (they post to v1 only, see Test definitions in canary
  analysis);
- the application is a Rollout in prod with no PostSync hook (a `canary` repository, see above): rollout-watch posts
  its prod-tests request to v1 only until DEVOPS-613, so keep `filters` in its prod values.

A definition with neither `filters` nor a tag still goes to v1 and runs every test, as before.

### What the hook does

1. Reads `GET /v1/capabilities` on the TestEngine of the hook's URL (the URL without its `/v1/trigger`).
2. A `404` there (a TestEngine older than capabilities), or a `trigger_versions` without `v2`, logs
   `ERROR: TestEngine v2 trigger not sent: v2 is switched off in this TestEngine ...` and posts nothing. Any other failure
   (no answer, `401`, `5xx`) logs its own `ERROR:` line and posts nothing.
3. With `multiRun: true` and `multi_run_enabled` not `true`, logs a `WARN:` line: the run is one Job.
4. Posts the v2 request to `/v2/trigger`. A `404` there, with `v2` listed, logs
   `ERROR: ... the /v2/trigger route is missing`. Any other non-2xx answer logs `ERROR: TestEngine v2 trigger failed (HTTP <code>)`.

There is no fallback to v1. Like the v1 hook, the script exits 0 after an error, so Argo CD does not retry the sync:
look for `ERROR:` in the trigger pod's log. Nothing then runs the tests or writes the slip's tests step.

**One Job.** A v2 run is one Job for the whole tag, and TestEngine stops watching a Job after 25 minutes. Keep a large
serial suite on `filters` (one Job per filter) until TestEngine packs Jobs (`multiRun`, `multi_run_enabled: true`).
Because every definition of an application uses the same trigger, such an application keeps all its definitions on
`filters` until then.

### Moving a service to the tag

1. Check that TestEngine has v2 on in the instance the service calls: `GET /v1/capabilities` lists `"v2"` in
   `trigger_versions`. The switch is per TestEngine instance (`testengine-dev`, `testengine`), not per environment.
2. Check that every caller the service uses knows v2: this chart version, autotriggertests (AQA-54) and, for a prod canary
   Rollout, rollout-watch (DEVOPS-613) and the canary `tests` template (not yet: keep `filters` there; the render fails
   for a tag on a prod canary Rollout). An older chart
   version does not know `testEnvironmentTag` and would send no filter, which runs every test.
3. In one change, replace `filters` with `testEnvironmentTag` (and `testTags` if needed) on every test definition of the
   application.

**Rollback:** put `filters` back in place of the tag. Do the same if TestEngine switches v2 off: the hook then logs the
switched-off `ERROR:` line and runs no tests until `filters` are back.

## Environment variables for test pods (`env`)

`env` sets environment variables on the test container that TestEngine starts for a test definition. They reach TestEngine as `TestEnvironmentVariables.EnvVars` in every request the chart renders: the PostSync hook (v1 or v2 body), the `<fullName>-prod-tests` ConfigMap and the canary `TESTS_REQUEST`. The field is omitted when there are no variables.

```yaml
applications:
  api:
    testtrigger:
      env:                         # every test definition of this application
        RESULTS_DB: "qa-results"
      testdefinitions:
        - name: apitests
          # ... containerImage, containerTag, secretId, filters ...
          env:                     # this definition only; wins over testtrigger.env on a name clash
            SHARED_KEY: "vault:QA/data/x#y"
```

### Where it goes and how it merges

- `testtrigger.env` applies to every definition; `testdefinitions[].env` to that definition. The effective map is the shared one overlaid by the definition's, key by key (the definition wins).
- `env: null` means none.
- mycarrier-helm layout (`applications:` root): `testtrigger.env` merges key by key across `helm/deployment/values.yaml` and `helm/deployment/values.<env>.yaml`; `testdefinitions` is replaced whole by the later file.
- mc-environment layout (`environments:` root): Helm replaces the whole `environments` list, so nothing merges across files. For each values file whose `environments[]` contains the entry, that entry's `applications.<app>.testtrigger` (possibly absent) is taken, and the last such file wins whole. A later file whose entry has no `testtrigger` means no `env` and no tests from `env`.
- Pipeline and 2c runs read the same values through autotriggertests. A 2d run takes a hand-filled JSON box instead, a JSON object whose values are all strings.

### Values and names

- Quote every value. A number, boolean, null, map or list (also reached through a YAML alias) is refused with `invalid_value (quote the value as a YAML string)`. `yes`, `no`, `on`, `off`, `~` and numbers with a leading zero (`017`) must be quoted too. A plain `2026-10-30` is a string.
- A duplicate key inside one `env` block: the last one wins, as Helm reads it.
- Quote names that YAML 1.1 reads as booleans (`y`, `n`, `yes`, `no`, `on`, `off`, `true`, `false`, in any case): unquoted, Helm turns them into `true` or `false`, which the chart refuses (`invalid_name`). A plain `~` name is refused by Helm itself while it reads the file.
- Names in error messages are not clipped.

### Limits

| Limit | Value |
|-------|-------|
| Name | `^[A-Za-z_][A-Za-z0-9_]*$` |
| Entries per definition, after the merge | 50 |
| Bytes per value | 4096 |
| Bytes per definition (names plus values) | 16384 |
| Bytes per v1 request (all definitions of one application) | 65536 |
| Escaped hook body and canary request | 100 KiB (a `'` counts 6 bytes, a `$` counts 2) |
| Control characters in a value | none (any character below U+0020, U+007F, U+0080 to U+009F, U+2028 or U+2029) |
| Two names that differ only in case | refused (`duplicate_name`; the first in sorted order is reported) |

The schema refuses some of these first (name pattern, 50 entries, 4096 bytes, non-string values) with Helm's own message naming the path; the template checks again, so the rules also hold when schema validation is skipped.

### Overriding TestEngine's defaults

`env` may set a name TestEngine already sets on the test container (`ENVIRONMENT`, `SECRETID`, `SERVICE_ADDRESS`, `HOME`, `TMPDIR`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and others): the `env` value replaces the default on the test container only. Overriding `HOME` or `TMPDIR` with a path that is not writable on the hardened read-only root breaks your own tests. Overriding `ENVIRONMENT`, `RELEASE_ID`, `RELEASE_DEFINITION_NAME` or `BRANCH_NAME` also changes what mc-test-cli files the uploaded results under.

### Protected names

These are refused with `protected_name`, compared case-insensitively: `ATTEMPT`, `ATTEMPT_ID`, `AUTOTEST_RESULTS_API_KEY`, `AUTOTEST_RESULTS_API_URL`, `BATCH_ID`, `CORRELATION_ID`, `JOB_NUMBER`, `OTEL_RESOURCE_ATTRIBUTES`, `PARTITION_ID`, `PATH`, `REQUEST_HEADERS`, `RUN_KIND`, `TEST_CATEGORY`, `TOTAL_TEST_JOB_COUNT`, `TRACEPARENT`, and every name starting with `LD_` or `VAULT_`. The reasons: `VAULT_*` and `LD_*` steer `vault-env`, which holds the Vault token; `PATH` chooses the program `vault-env` runs; the results API URL and key decide where results go and under whose identity; `REQUEST_HEADERS`, `CORRELATION_ID` and `RUN_KIND` tie the run to the canary and to its results; the batch, partition, job, attempt and category variables, `OTEL_RESOURCE_ATTRIBUTES` and `TRACEPARENT` identify the run's results and traces. `TRACESTATE` and other W3C or OTel variables a service sets are its own business.

### Secrets

Only `vault:QA/...` references. Every `vault:` in a value must be followed by `QA/`, with no `..` path segment (up to the next `#`). Never put a plain secret in a values file.

### Failures

The render fails with `EnvVars: test definition "<name>": variable "<VAR>": <code>`. Codes: `invalid_name`, `protected_name`, `duplicate_name`, `invalid_value`, `control_character`, `value_too_large`, `vault_prefix_not_allowed`, `too_many`, `definition_too_large`, `request_too_large`. The message names the variable, never the value; `too_many`, `definition_too_large`, `request_too_large` and a non-map `env` leave out the `variable` part. `control_character` means any character below U+0020, U+007F, U+0080 to U+009F, U+2028 or U+2029: YAML reads U+0085, U+2028 and U+2029 as line breaks, which could rewrite the rendered manifest.

### Escaping

The v1 hook body and the canary request are escaped (`'`, `$`, and `{{` on the canary). A stack whose testtrigger fields (filters, `serviceAddress`, `secretId`, `requestHeaders`) hold those characters renders different bytes for the same request, and a `$(VAR)` there stays literal instead of being expanded by Kubernetes.

The canary request also encodes `${` as `$\u007b` (the JSON escape, which decodes back to `${`). The request is an env value (`TESTS_REQUEST`) of a pod that `vault-env` wraps, and `vault-env` resolves an inline `${vault:...}` in any env value, which would put the plaintext secret into the request. The encoded form no longer matches, so an env value such as `${vault:QA/x#y}` reaches TestEngine as written. The hook body is not wrapped by `vault-env` and keeps the plain text.

## Usage Notes

1. **Vault References**: Parameters like `apikey` and `secretId` can reference values stored in a vault using the format `vault:<path>#<key>`.

2. **Test Filters**: The `filters` array allows you to specify which tests to run. If no filters are provided (empty array), all tests in the container will be executed.

3. **Multiple Test Definitions**: You can define multiple test definitions under a single `testtrigger` configuration, each with its own container image, tag, and filters. All test definitions for one application are bundled into a single curl POST to the test engine API; the request body is `{"Tests": [...]}` containing each definition as an entry.

4. **Application-Specific Tests**: Each application in your deployment can have its own `testtrigger` configuration, allowing for application-specific tests.

5. **Resource Configuration**: You can specify custom resources for the test job pods. If not specified, default values (128Mi memory request, 100m CPU request, 256Mi memory limit, 500m CPU limit) will be used.

6. **Service Address**: By default, the service address will be constructed as `<fullname>.<namespace>.svc.cluster.local:<httpPort>`. You can override this for specific test definitions by providing the `serviceAddress` parameter.


## Best Practices

1. Use meaningful test names to easily identify test purposes.
2. Keep `activeDeadlineSeconds` reasonably short to prevent long-running tests from blocking deployments.
3. Use vault references for sensitive values like API keys and secrets.
4. Use specific test filters to run only the tests relevant to the application being deployed.
5. Set appropriate `ttlSecondsAfterFinished` to maintain job history without cluttering the Kubernetes namespace.

## Troubleshooting

### Common Issues

1. **Invalid Test Filters**: Ensure that test filters match those available in your test container. Invalid filters may cause tests to run incorrectly or not at all.

2. **Vault Reference Issues**: Confirm that vault references are correctly formatted and accessible by the Kubernetes pods.

3. **Test Engine Response Failures**: When a test trigger pod's curl call fails, the response will contain the error code and information. Common causes include:
  - Test definition misconfiguration
  - Incorrect container image or tag specification
  - Network connectivity issues during test dispatch
  - Authentication or authorization failures

4. **`v2 is switched off in this TestEngine`**: the definitions set `testEnvironmentTag`, and the TestEngine the hook calls does not offer `/v2/trigger` (`GET /v1/capabilities` answered 404 or does not list `v2`). Nothing ran. Ask for `TRIGGER_V2_ENABLED` in that TestEngine, or put `filters` back.

5. **`the /v2/trigger route is missing`**: TestEngine lists `v2`, and the mesh does not route `/v2/trigger` to it. Nothing ran. Ask DevOps to route it, or put `filters` back.
