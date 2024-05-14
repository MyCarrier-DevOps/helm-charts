# Helm Chart for qryn-cloud
<a href="https://qryn.dev" target="_blank">
<img src='https://user-images.githubusercontent.com/1423657/218816262-e0e8d7ad-44d0-4a7d-9497-0d383ed78b83.png' style="margin-left:-10px" width=150/>

## Disclaimer
This is a modified version of helm chart provided by qryn. Reference to qyrn helm chart: https://metrico.github.io/qryn-cloud-helm/.

## Overview
This Helm chart provides Kubernetes deployment configurations for [qryn-cloud](https://github.com/metrico) a polyglot, lighweight, multi-standard observability framework for Logs, Metrics and Traces, designed to be drop-in compatible with Loki, Prometheus, Tempo and Opentelemetry.

## Prerequisites
- Kubernetes 1.19+
- Helm 3.7+

## Get Repository Info

```bash
helm repo add qryn-helm https://metrico.github.io/qryn-cloud-helm/
helm repo update
```


# Installation

1. Create namespace in the kubernetes cluster you want to use: `kubectl create namespace qryn`
2. Create docker registry secret yaml to pull docker images
```
cat <<EOR >docker-registry-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: qryn-dckr
  namespace: qryn
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(base64 -w 0 <<< $(cat <<'EOF'
{
  "auths": {
    "your-registry.com": {
      "username": "<USERNAME>",
      "password": "<PASSWORD>"
    }
  }
}
EOF
))
EOR
```
3. Make the kubectl secret in the qryn namespace to reach the private docker registry as 
https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
```
kubectl apply -f docker-registry-secret.yaml
``` 
4. Create `values.yaml` to override the needed parameters. 
Please take a look to the [configuration](#configuration-options). Some of the parameters are required to override.
5. Install helmchart
```
helm install qryn . -f values.base.yaml -f values.yaml --namespace qryn --create-namespace
```

# First database setup

Before using Qryn the database should be set up. 
In order to set up the database you need to create an API call to qryn-ctrl.

1. Forward the qryn-ctrl port
`kubectl port forward 8080:8080 -n qryn <qryn-ctrl pod name>`
2. Do the API http call to qryn-ctrl:
```bash
cat <<EOF | curl -X POST http://localhost:8080/initialize --data-binary @-
{
  "database_data": [
    {
      "help": "Settings for Clickhouse Database (data)",
      "user": "<USER NAME>",
      "node": "clickhouse1",
      "pass": "<CLICKHOUSE PASS>",
      "name": "<DATABASE NAME>",
      "host": "<HOST NAME>",
      "port": <CLICKHOUSE PORT>,
      "primary": true,
      "debug": true,
      "secure": <TRUE IF CLICKHOUSE USES SSL>,
      "cloud": <TRUE IF YOU WANT THE Distributed..... tables, FALSE for Clickhouse cloud>,
      "cluster_name": "<NAME OF THE CLUSTER IF YOU USE ONE, EMPTY for Clickhouse cloud>",
      "distributed": <true if you use multiple shards, empty for Clickhouse cloud>,
      "ttl_days": <default TTL for the data, days>,
    }
  ]
}

EOF
```

# Ingress setup
In order to reach Qryn from outside, the http ingress rules should be configured.
Current helm has a default ingress definition. It can be enabled for writer and reader separately by configuring
`reader.ingress` and `writer.ingress` configuration. Please look at the [configuration](#configuration-options). 

The http routes should be configured for Qryn reader and writer services are as follows.

For qryn-writer service (regexp notation):
- /loki/api/v1/push
- (/api)?(/v1)?/prom/remote/write
- /tempo/spans
- /tempo/api/push
- /influx/api/v2/write
- /v1/traces
- /[^/]+/_doc(/[^/]+)?
- /[^/]+/_create/[^/]+
- (/[^/]+)?/_bulk
- /api/v2/spans
- /api/v2/logs
- /api/v2/series
- /cf/v1/insert

For qryn-reader service (regexp notation):
- /ready
- /metrics
- /config
- /api/v1/metadata
- /api/v1/status/buildinfo
- /api/v1/labels
- /api/v1/labels
- /api/v1/label/[^/]+/values
- /api/v1/metadata
- /api/v1/query_exemplars
- /api/v1/rules
- /api/v1/series
- /api/v1/series
- /api/v1/status/tsdb
- /loki/api/v1/query_range
- /loki/api/v1/query
- /loki/api/v1/delete
- /loki/api/v1/label
- /loki/api/v1/label
- /loki/api/v1/labels
- /loki/api/v1/labels
- /loki/api/v1/label/[^/]+/values
- /loki/api/v1/label/[^/]+/values
- /loki/api/v1/series
- /loki/api/v1/series
- /tempo/api/traces/[^/]+
- /api/traces/[^/]+
- /api/traces/[^/]+/json
- /tempo/api/echo
- /api/echo
- /tempo/api/search/tags
- /api/search/tags
- /tempo/api/search/tag/[^/]+/values
- /api/search/tag/[^/]+/values
- /api/v2/search/tag/[^/]+/values
- /tempo/api/search
- /api/search

Websocket connection for qryn-reader service:
- /loki/api/v1/tail

# Configuration options

The required options are marked **bold**

| Configuration                                        | Description                                                        | Default Value              |
|------------------------------------------------------|--------------------------------------------------------------------|----------------------------|
| kubernetesClusterDomain                              | The domain to use for Kubernetes cluster.                          | cluster.local              |
| nameOverride                                         | A string to partially replace the name of the qryn deployment.     | qryn                       |
| qryn.podAnnotations                                  | Additional pod annotations for the configmap.                      | []                         |
| qryn.data.QRYN_LOG_SETTINGS_LEVEL                    | The log level for qryn.                                            | debug                      |
| qryn.data.QRYN_LOG_SETTINGS_STDOUT                   | Whether to log to stdout.                                          | true                       |
| qryn.data.QRYN_LOG_SETTINGS_SYSLOG                   | Whether to log to syslog.                                          | true                       |
| qryn.data.QRYN_MULTITENANCE_SETTINGS_ENABLED         | Whether to enable multi-tenancy.                                   | true                       |
| qryn.data.QRYN_SYSTEM_SETTINGS_DB_TIMER              | The timeout between two subsequent inserts into the database (sec) | 1                          |
| qryn.data.QRYN_SYSTEM_SETTINGS_DYNAMIC_DATABASES     | Whether to enable X-CH-DSN header controlled databases.            | false                      |
| qryn.data.QRYN_SYSTEM_SETTINGS_NO_FORCE_ROTATION     | Whether to disable forced rotation (not used).                     | true                       |
| qryn.data.QRYN_SYSTEM_SETTINGS_QUERY_STATS           | Whether to enable query statistics.                                | true                       |
| qryn.data.QRYNCLOUD_LICENSE                          | The license key for qrynCloud.                                     | XXXX                       |
| **qryn.data.QRYN_DATABASE_DATA_0_NODE**              | The node for the qryn database.                                    | clickhouse1                |
| **qryn.data.QRYN_DATABASE_DATA_0_USER**              | The user for the qryn database.                                    | default                    |
| **qryn.data.QRYN_DATABASE_DATA_0_PASS**              | The password for the qryn database.                                |                            |
| **qryn.data.QRYN_DATABASE_DATA_0_HOST**              | The host for the qryn database.                                    | localhost                  |
| **qryn.data.QRYN_DATABASE_DATA_0_NAME**              | The name for the qryn database.                                    | qryn                       |
| **qryn.data.QRYN_DATABASE_DATA_0_PORT**              | The port for the qryn database.                                    | 9000                       |
| **qryn.data.QRYN_DATABASE_DATA_0_SECURE**            | Whether to use secure connection for the qryn database.            | false                      |
| reader.autoscaling.enabled                           | Whether to enable hpa autoscaling for the reader.                  | True                       |
| reader.autoscaling.minReplicas                       | The minimum number of replicas for the reader.                     | 1                          | 
| reader.autoscaling.maxReplicas                       | The maximum number of replicas for the reader.                     | 10                         | 
| reader.autoscaling.targetCPUUtilizationPercentage    | The target CPU utilization percentage for autoscaling.             | 80                         |
| reader.autoscaling.targetMemoryUtilizationPercentage | The target memory utilization percentage for autoscaling.          | 80                         |
| reader.ingress.enabled                               | Whether to enable ingress for the reader.                          | false                      |
| reader.ingress.hosts                                 | The list of hostnames for the reader's ingress.                    | ['qryn-reader.local.qryn'] |
| reader.labels                                        | Additional labels for the reader deployment.                       | []                         |
| reader.podAnnotations                                | Additional pod annotations for the reader deployment.              | []                         |
| reader.enabled                                       | Whether to enable the reader deployment.                           | True                       |
| reader.env.qrynHttpSettingsPort                      | The port for the qryn reader HTTP endpoint.                        | 3200                       |
| reader.image.repository                              | The repository for the reader image.                               | qxip/qryn-go-cloud         |
| reader.image.tag                                     | The tag for the reader image.                                      | 1.2.91-beta.55             |
| reader.imagePullPolicy                               | The image pull policy for the reader image.                        | IfNotPresent               |
| reader.resources.requests.memory                     | The requested memory for the reader.                               | 1Gi                        |
| reader.resources.requests.cpu                        | The requested CPU for the reader.                                  | 100m                       |
| reader.resources.limits.memory                       | The memory limit for the reader.                                   | 1Gi                        |
| reader.resources.limits.cpu                          | The CPU limit for the reader.                                      | 100m                       |
| reader.replicas                                      | The number of replica sets for the reader.                         | 1                          |
| reader.revisionHistoryLimit                          | The number of history revisions for the reader.                    | 10                         |
| reader.type                                          | The type of deployment for the reader.                             | ClusterIP                  |
| writer.labels                                        | Additional labels for the writer deployment.                       | []                         |
| writer.podAnnotations                                | Additional pod annotations for the writer deployment.              | []                         |
| writer.enabled                                       | Whether to enable the writer deployment.                           | True                       |
| writer.ingress.enabled                               | Whether to enable ingress for the writer.                          | True                       |
| writer.ingress.hosts                                 | The list of hostnames for the writer's ingress.                    | ['qryn-writer.local.qryn'] |
| writer.autoscaling.enabled                           | Whether to enable autoscaling for the writer.                      | True                       |
| writer.autoscaling.minReplicas                       | The minimum number of replicas for the writer.                     | 1                          |
| writer.autoscaling.maxReplicas                       | The maximum number of replicas for the writer.                     | 10                         |
| writer.autoscaling.targetCPUUtilizationPercentage    | The target CPU utilization percentage for autoscaling.             | 80                         |
| writer.autoscaling.targetMemoryUtilizationPercentage | The target memory utilization percentage for autoscaling.          | 80                         |
| writer.env.qrynHttpSettingsPort                      | The port for the qryn HTTP endpoint.                               | 3100                       |
| writer.image.repository                              | The repository for the writer image.                               | qxip/qryn-writer-cloud     |
| writer.image.tag                                     | The tag for the writer image.                                      | 1.9.95-beta.13             |
| writer.imagePullPolicy                               | The image pull policy for the writer image.                        | IfNotPresent               |
| writer.resources.requests.memory                     | The requested memory for the writer.                               | 1Gi                        |
| writer.resources.requests.cpu                        | The requested CPU for the writer.                                  | 100m                       |
| writer.resources.limits.memory                       | The memory limit for the writer.                                   | 1Gi                        |
| writer.resources.limits.cpu                          | The CPU limit for the writer.                                      | 100m                       |
| writer.replicas                                      | The number of replica sets for the writer.                         | 1                          |
| writer.revisionHistoryLimit                          | The number of history revisions for the writer.                    | 10                         |
| writer.type                                          | The type of deployment for the writer.                             | ClusterIP                  |
| ctrl.labels                                          | Additional labels for the qryn-ctrl deployment.                    | []                         |
| ctrl.podAnnotations                                  | Additional pod annotations for the ctrl deployment.                | []                         |
| ctrl.enabled                                         | Whether to enable the qryn-ctrl deployment.                        | True                       |
| ctrl.image.repository                                | The repository for the qryn-ctrl image.                            | qxip/qryn-ctrl             |
| ctrl.imagePullPolicy                                 | Whether to pull the image for the qryn-ctrl.                       | IfNotPresent               |
| ctrl.replicas                                        | The number of replica sets for the qryn-ctrl.                      | 1                          |
| ctrl.revisionHistoryLimit                            | The number of history revisions for the qryn-ctrl.                 | 10                         |
| ctrl.type                                            | The type of deployment for the qryn-ctrl.                          | ClusterIP                  |
