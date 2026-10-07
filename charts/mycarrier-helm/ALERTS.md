# Alerts

mycarrier-helm renders a stack's Grafana alerting from its `alerts:` values: one `GrafanaAlertRuleGroup` with the
standard rules and any additional rules, two `GrafanaContactPoint`s (general and Sev1) and one
`GrafanaNotificationPolicyRoute`. Alerts are off by default (`alerts.enabled: false`).

## How alerts reach Grafana

Every alert resource lives under `templates/alerts/` and is rendered into namespace `monitoring`:

| Stack deployed with | GitOps path |
| --- | --- |
| mycarrier-helm | `Apps/<metaEnv>-<project>/<project>-<app>/alerts/` |
| mc-environment | `Apps/<metaEnv>-<project>/<project>-<app>/<env>/alerts/` (written by the pipeline's render step, chart-renderer) |

Application clusters never apply them: the app-cluster Applications exclude `*/alerts/*`, and the Applications that
mc-environment's ApplicationSet generates (which render this chart from the Helm repository and so do render the
alerts) run on an Argo CD that excludes the `grafana.integreatly.org` group. The management cluster applies only
`*/alerts/*`. Alerts render only in the environments listed in `alerts.environments` (default `prod`): the queries
read production telemetry, and resource names do not include the environment.

## Enabling alerts for a stack

```yaml
alerts:
  enabled: true
  serviceName: MC.Invoice
  displayName: Invoice
```

- `serviceName` is the HyperDX `ServiceName` prefix the queries match (`ServiceName LIKE '<serviceName>%'`).
- `displayName` (letters and digits) names the resources (`invoice-alerts`, `invoice`, `invoice-sev1`), the Grafana
  contact points (`Invoice`, `Invoice Sev1`) and the rule uids.
- `observabilityName` is the `observability.availability` service the availability rule reads; it defaults to
  `global.appStack`.

`alerts:` belongs to the stack, next to `secrets:`: set it once in `helm/values.yaml` (an mc-environment stack sets
it at the top level and every environment's Application receives it).

The Squadcast webhooks must exist in Vault under the keys `<serviceName lowercased>` and
`<serviceName lowercased>-sev1` (the `squadcast-webhooks` secret in `monitoring`), or set
`alerts.contactPoints.secretKey`.

## Standard alerts

`global.language` selects the standard alerts and their defaults:

| Key | Default title | Fires when | csharp | nodejs |
| --- | --- | --- | --- | --- |
| `serverErrorRatio` | `[Sev1] <displayName> Server HTTP Errors > 30% in 5m` | 5xx responses exceed `threshold` percent of non-error responses | on | on |
| `clientErrorRatio` | `[Sev2] <displayName> Client HTTP Errors > 30% in 5m` | 4xx responses exceed `threshold` percent of non-error responses | on | on |
| `serverErrorCount` | `[Sev3] <displayName> HTTP Errors > 5 in 5m` | more than `threshold` 5xx responses | on | on |
| `http503Returned` | `[Sev1] <displayName> HTTP 503 Service Unavailable in 5m` | the service returned a 503 outside `probePaths` | on | off |
| `http503Received` | `[Sev2] <displayName> Dependency HTTP 503 in 5m` | the service received a 503 from a dependency outside `excludedHosts` | on | off |
| `availabilityProbe` | `[Sev1] <displayName> Availability Probe Failure` | an availability probe reports state 0 | on | on |
| `nonHttpErrors` | `[Sev3] <displayName> Non HTTP Errors > 5 in 5m` | more than `threshold` error log lines outside the `apiServiceSuffix` service | on | on, paused |

Other languages (`python`, `go`) have no standard alerts; use `alerts.additional`.

`alerts.standard.<key>` overrides the language's defaults for that alert: `enabled`, `severity` (`sev1`, `sev2`,
`sev3`), `threshold` (all but `availabilityProbe`), `for`, `title`, `paused`, `noDataState`, `execErrState`, and the
alert's own `probePaths`, `excludedHosts`, `excludedComponents` or `apiServiceSuffix`. An override replaces the
default, including `false`, `0` and an empty list:

```yaml
alerts:
  standard:
    serverErrorRatio:
      threshold: 10
    http503Returned:
      enabled: true
```

Severity sets the `[SevN]` title prefix and the `severity` label, which selects the Sev1 contact point. Rule uids never
change with severity or title, so Grafana keeps the rule's state, silences and history. The render fails when
`alerts.standard` is set for a language without standard alerts, and when alerts are enabled with no rule at all.

`alerts.filters.excludedPaths` leaves `url.path` values out of every HTTP rule (both sides of the ratios), for example
synthetic monitoring endpoints:

```yaml
alerts:
  filters:
    excludedPaths:
      - /api/v1/customer-health
```

## Additional rules

`alerts.additional` is a map keyed by rule name. The compact form builds a ClickHouse rule like the standard ones:

```yaml
alerts:
  additional:
    smc3ParseErrors:
      title: "[Sev3] MC.Invoice.InboundIntegration.Worker SMC3 Parse Errors"
      severity: sev3
      sql: |
        SELECT COUNT(1)
        FROM hyperdx.prod_otel_logs
        WHERE Body LIKE 'Processing of DocumentCreatedEvent failed because the retry limit was reached.%'
          AND ServiceName = 'MC.Invoice.InboundIntegration.Worker'
          AND SeverityText = 'Error'
          AND Timestamp > now() - INTERVAL 1 MINUTE
      condition:
        threshold: 1
        reducer: min
      for: 0m
      annotations:
        description: More than 1 smc3 document parse error in the last minute.
```

Defaults: `uid` `<displayName lowercased>_<key in snake_case>`, `alertType` `<key in snake_case>`, `timeRange` 300
(seconds), `condition.type` `gt`, `condition.reducer` `last`, `for` `5m`, `noDataState` `OK`, `execErrState`
`KeepLast`, `paused` `alerts.paused`. `labels` and `annotations` merge over the defaults.

The raw form passes a Grafana `AlertRule` through unchanged (`uid`, `title`, `condition` and `data` are required);
the chart adds `alertSource` and, when absent, `service`. Grafana templating such as `{{ $labels.PartnerId }}` is
never evaluated by Helm:

```yaml
alerts:
  additional:
    sustainedRetries:
      rule:
        uid: integration_sustained_retries
        title: "[Sev2] Integration Sustained Retries"
        condition: C
        data:
          - refId: A
            datasourceUid: clickhouse
            relativeTimeRange:
              from: 3600
              to: 0
            model:
              refId: A
              rawSql: SELECT ...
        for: 10m
        noDataState: OK
        execErrState: KeepLast
        annotations:
          summary: "{{ $labels.Connector }} partner {{ $labels.PartnerId }} is retrying outbound calls"
        labels:
          alertType: sustained_retries
          severity: sev2
```

Rule uids must be unique and at most 40 characters of `[A-Za-z0-9_-]`; the render fails otherwise.

## Routing

The route matches `service = <serviceName lowercased>`, sends to `<displayName>` and has a `severity = sev1` child
route to `<displayName> Sev1`. `alerts.routing.routes` appends child routes after it, for example a dedicated
grouping:

```yaml
alerts:
  routing:
    routes:
      - receiver: Integration
        object_matchers:
          - - alertType
            - "="
            - sustained_retries
        group_by:
          - grafana_folder
          - alertname
          - PartnerId
```

The central `GrafanaNotificationPolicy` picks the route up through its `routeSelector`
(`mycarrier.tech/notification-policy: mycarrier`) for alerts labelled `alertSource: mycarrier-helm`.

## Migrating a stack from AlertManagement

| AlertManagement (`service-alert.yaml` header) | mycarrier-helm value |
| --- | --- |
| `appstack_display_name` | `alerts.displayName` |
| `appstack_service_name` | `alerts.serviceName` |
| `appstack_observability_name` | `alerts.observabilityName` (only when it differs from `global.appStack`) |
| `error_threshold` | `alerts.standard.serverErrorCount.threshold` and `alerts.standard.nonHttpErrors.threshold` |
| `server_error_percent` | `alerts.standard.serverErrorRatio.threshold` |
| `client_error_percent` | `alerts.standard.clientErrorRatio.threshold` |
| `is_paused` | `alerts.paused` |
| `provisioning/specialAlerts/<stack>/*` | `alerts.additional` (raw form where needed) and `alerts.routing.routes` |

Template special cases become values: MyCarrier (`nonHttpErrors.apiServiceSuffix: API`,
`availabilityProbe.excludedComponents` listing `quoteapi`), IntegrationEventPublisher (every standard rule
except `nonHttpErrors` disabled), Integration (`filters.excludedPaths`), Invoice (`additional.smc3ParseErrors` with
`uid: invoice_sev2_smc3_parse_errors`).
