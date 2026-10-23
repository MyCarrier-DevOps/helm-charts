# Test Trigger Configuration Guide

## Overview

Test triggers are configured in the Helm values files (e.g., `values.dev.yaml`, `values.prod.yaml`) and are processed by the Helm templates to create Kubernetes jobs that execute test triggers. For each application, all of its test definitions are bundled into a single curl call to the test engine API with a `{"Tests": [...]}` payload. Each application can have its own configuration of test triggers with their respective test definitions.

### ArgoCD Integration

Test trigger jobs run as post-sync hooks in ArgoCD. This means that after ArgoCD successfully syncs your application to the desired state, it automatically triggers the test jobs as part of the deployment process. The ArgoCD sync operation will be marked as successful only if all the test jobs complete successfully.

How it works:
1. ArgoCD deploys your application resources based on the Helm chart
2. Once the sync is successful, ArgoCD identifies the jobs with the `argocd.argoproj.io/hook: PostSync` annotation
3. These test trigger jobs are then executed
4. These jobs make curl calls to TestEngineApi that deploys tests to the appropriate k8s cluster and namespace, allowing the tests to run against the internal k8s service

### Rollouts in prod

In prod, an application with `deploymentType: rollout` (without `migratingToRollouts`) gets no PostSync hook (Tech Spec D7): the hook can fire at the start of a canary sync, after the last promote or after an abort, so it can test the wrong version. The release's rollout-watch (DEVOPS-319) starts the prod tests after the canary is promoted instead:

- rollout-watch runs only on the canary release path, so the repository's `deployment-strategy` property must be `canary` before the release that removes `migratingToRollouts`. The chart cannot see the property; a prod Rollout in a `rolling` or unset repository gets no prod tests.
- With `enableV1: true` (the default), the chart renders the ConfigMap `<fullName>-prod-tests` in the application's namespace, labelled `mycarrier.tech/correlationId`. Its key `request.json` holds the same TestEngine v1 request the hook sends (one template renders both, with no `SlipStep`), and rollout-watch posts it to TestEngine's v1 trigger.
- With `enableV1: false`, the render fails, because nothing would start the application's prod tests.
- With `enableV1: true`, `apikey` must be `vault:DevOps/data/testengine/api#encoded_header` or unset, and `global.testengineWebhookUrl` must not be set: rollout-watch posts with the shared key and its own URL, so the render fails instead of ignoring them.

Other environments, Deployments, StatefulSets and migrating Rollouts keep the PostSync hook.

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
      enableV1: <true|false>         # Optional — see enableV1 section below
      testdefinitions:
        - containerImage: <image-name>
          containerTag: <tag>
          filters:
            - <filter1>
            - <filter2>
          name: <test-name>
          secretId: "<secret-id-or-vault-reference>"
          serviceAddress: "<optional-service-address>"
          additionalEnvVars: "key1=value1;key2=value2"
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
| `enableV1` | When `true`, all test definitions are bundled into a single POST to `api/v1` with a `{"Tests":[...]}` payload. When `false`, each test definition sends a separate POST to the legacy `api` endpoint, which is retired; `true` is the default. The webhook URL is set automatically based on this flag; `global.testengineWebhookUrl` overrides it, except for a Rollout in prod, where setting it fails the render (see Rollouts in prod). | No | `true` | `true` |

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
| `filters` | Test filters to apply. Accepts a single string or an array of strings. | No | `[]` (empty array) | `"TestCategory=coretests"` or `["TestCategory=coretests", "TestCategory=othercoretests"]` |
| `name` | Name of the test | Yes | None | `"apitests"` |
| `secretId` | Secret ID for authentication, can be a direct value or a vault reference | Yes | None | `"vault:Secrets/data/auth#secretid"` |
| `serviceAddress` | Optional service address for the test to target | No | `"<fullname>.<namespace>.svc.cluster.local:<httpPort>"` | `"my-service.namespace.svc.cluster.local:8080"` |
| `releaseDefinitionName` | Optional release definition name - overrides default value = stack-component | No | stack-compoent | `"somestack-somecomponent"`
| `additionalEnvVars` | Additional environment variables to pass to container as key-value pairs delimited by colon | No | `""` | `"key1=value1;key2=value2"` |
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
  webhook_url: "vault:Secrets/data/path/to/secret#url"
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
  webhook_url: "vault:Secrets/data/path/to/secret#url"
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
  webhook_url: "vault:Secrets/data/path/to/secret#url"
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
  webhook_url: "vault:Secrets/data/path/to/secret#url"
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
