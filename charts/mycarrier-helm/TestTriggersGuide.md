# Test Trigger Configuration Guide

## Overview

Test triggers are configured in the Helm values files (e.g., `values.dev.yaml`, `values.prod.yaml`) and are processed by the Helm templates to create Kubernetes jobs that execute test triggers. Each test definition configures a curl call to the test engine API. This means that each test trigger can have an array of test definitions, and each application can have its own configuration of test triggers with their respective test definitions.

### ArgoCD Integration

Test trigger jobs run as post-sync hooks in ArgoCD. This means that after ArgoCD successfully syncs your application to the desired state, it automatically triggers the test jobs as part of the deployment process. The ArgoCD sync operation will be marked as successful only if all the test jobs complete successfully.

How it works:
1. ArgoCD deploys your application resources based on the Helm chart
2. Once the sync is successful, ArgoCD identifies the jobs with the `argocd.argoproj.io/hook: PostSync` annotation
3. These test trigger jobs are then executed
4. These jobs make curl calls to TestEngineApi that deploys tests to the appropriate k8s cluster and namespace, allowing the tests to run against the internal k8s service

## Configuration Structure

Test triggers are configured at the application level in the values file. Below is the general structure:

```yaml
applications:
  <application-name>:
    testtrigger:
      activeDeadlineSeconds: "<seconds>"
      ttlSecondsAfterFinished: "<seconds>"
      apikey: "<api-key-or-vault-reference>"
      webhook_url: "<webhook-url-or-vault-reference>"
      backoffLimit: <number>
      resources:
        requests:
          memory: "<memory-request>"
          cpu: "<cpu-request>"
        limits:
          memory: "<memory-limit>"
          cpu: "<cpu-limit>"
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
| `webhook_url` | URL of the test engine webhook, can be a direct value or a vault reference | Yes | None | `"vault:Secrets/data/path/to/secret#url"` |

*Default resource values:
```yaml
resources:
  requests:
    memory: "64Mi"
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
| `filters` | Array of test filters to apply | No | `[]` (empty array) | `["TestCategory=coretests", "TestCategory=othercoretests"]` |
| `name` | Name of the test | Yes | None | `"apitests"` |
| `secretId` | Secret ID for authentication, can be a direct value or a vault reference | Yes | None | `"vault:Secrets/data/auth#secretid"` |
| `serviceAddress` | Optional service address for the test to target | No | `"<fullname>.<namespace>.svc.cluster.local:<httpPort>"` | `"my-service.namespace.svc.cluster.local:8080"` |
| `releaseDefinitionName` | Optional release definition name - overrides default value = stack-component | No | stack-compoent | `"somestack-somecomponent"`
| `additionalEnvVars` | Additional environment variables to pass to container as key-value pairs delimited by colon | No | `""` | `"key1=value1;key2=value2"` |

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

### Multiple Applications with Multiple Tests

The following example shows how multiple applications can each have their own test triggers with multiple test definitions:

```yaml
applications:
  api:
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
      webhook_url: "vault:Secrets/data/path/to/secret#url"
      backoffLimit: 0
      testdefinitions:
        - containerImage: testing/internalapitests
          containerTag: ijkl9012
          filters:
            - TestCategory=internalapitests
          name: internalapitests
          secretId: "vault:Secrets/data/auth#secretid"
```
Explanation: This configuration will create test jobs for both the `api` and `internal-api` applications. The `api` application will have two separate test jobs, while the `internal-api` application will have one. The `api` test jobs have custom resource requirements and the first test definition specifies a custom service address.

## Usage Notes

1. **Vault References**: Parameters like `apikey`, `secretId`, and `webhook_url` can reference values stored in a vault using the format `vault:<path>#<key>`.

2. **Test Filters**: The `filters` array allows you to specify which tests to run. If no filters are provided (empty array), all tests in the container will be executed.

3. **Multiple Test Definitions**: You can define multiple test definitions under a single `testtrigger` configuration, each with its own container image, tag, and filters.

4. **Application-Specific Tests**: Each application in your deployment can have its own `testtrigger` configuration, allowing for application-specific tests.

5. **Resource Configuration**: You can specify custom resources for the test job pods. If not specified, default values (64Mi memory request, 100m CPU request, 256Mi memory limit, 500m CPU limit) will be used.

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
