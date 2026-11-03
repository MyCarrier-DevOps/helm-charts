# redpanda-clients

Onboards clients to a shared Redpanda cluster from a list in values. Each client can only see and use resources under
its own `<id>.` prefix. One release serves one environment; the same values can be given to every environment's
release, and each one renders only the clients that list its environment.

For each client in the release's environment the chart renders:

- A `User` (SCRAM-SHA-512) whose password is read from the secret `redpanda-client-<id>` (key `password`), with
  prefixed ACLs on `<id>.`:
  - topics: Read, Write, Describe
  - consumer groups: Read, Describe
  - transactional IDs: Write, Describe, only when `transactions: true`
- An `ExternalSecret` that creates `redpanda-client-<id>` from Vault: key `passwords.vaultKey`, property
  `client_<id>_pw`.
- A `Topic` per listed topic, created in Redpanda as `<id>.<name>`.
- Produce and fetch byte-rate quotas on the client's user, applied by a post-install/upgrade Job with `rpk`. The quota
  follows the authenticated user, so a client can't avoid it or use another client's by choosing its `client.id`. A rate
  the client doesn't set is removed, so it's unlimited even if it was set before.

Clients get no cluster-level permissions and can't create topics.

For the whole release, from `whitelist`, the chart renders the external access to the cluster, enforced twice:

- A `LoadBalancer` Service in front of the dedicated Istio ingress gateway, with `loadBalancerSourceRanges` set to the
  whitelisted addresses, so the Azure load balancer drops everything else.
- An `ipBlocks` `AuthorizationPolicy` on the gateway that allows only the same addresses.

Neither renders while the whitelist is empty: a load balancer without source ranges accepts every address.

## Prerequisites

- The [Redpanda Operator](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/) with the
  `cluster.redpanda.com/v1alpha2` `User` and `Topic` CRDs, managing the cluster named in `cluster.name`.
- On the cluster: SASL with SCRAM, authorization enabled (`kafka_enable_authorization: true`) and topic auto-creation
  off (`auto_create_topics_enabled: false`). Without authorization the ACLs aren't enforced.
- [External Secrets](https://external-secrets.io/) with the `ClusterSecretStore` named in `passwords.secretStore`, and
  each client's password in Vault under `passwords.vaultKey` as property `client_<id>_pw`. Write the password before
  adding the environment to the client; until it exists the `ExternalSecret` fails and the `User` can't sync.
- An Istio ingress gateway whose pods match `ingress.selector`, in `ingress.namespace`, that passes TLS through on
  `ingress.port` to the brokers (a `Gateway` and `VirtualService` routing each broker's SNI name). Give the gateway's
  own Service type `ClusterIP`, so this chart's Service is the only way in from outside.
- Redpanda v26.1.1 or later on the brokers, for user-based quotas. Older brokers reject them and the quota Job fails.
- A dedicated user for the quota Job, not a superuser. Its only grant is ALTER_CONFIGS on the cluster, which is all
  `rpk cluster quotas alter` needs:

  ```bash
  rpk security user create quota-manager --mechanism SCRAM-SHA-512
  rpk security acl create --allow-principal User:quota-manager --cluster --operation alter_configs
  ```

  Its credentials go in `quotaJob.credentialsSecret` (keys `username`, `password`) and the brokers' CA in
  `quotaJob.caSecret`. The quota Job runs on every install and upgrade that has clients.
- The cluster's superusers and the quota Job's user listed in `cluster.reservedUsers`. A client with one of those IDs
  would take over that user and set its password from the client's secret.

## Example

```yaml
environment: dev
passwords:
  vaultKey: redpanda/client_messaging/dev
whitelist:
  - name: Alpha Logistics
    ips:
      - 20.51.224.101
      - 74.235.92.224/28
clients:
  - id: alpha
    environments: [dev, prod]
    quota:
      producerByteRate: 5242880
      consumerByteRate: 10485760
    topics:
      - name: shipments
        partitions: 6
        retentionMs: 1209600000
      - name: quotes
  - id: bravo
    environments: [dev]
    transactions: true
    topics:
      - name: orders
```

The `dev` release renders both clients. A `prod` release given the same values renders only `alpha`.

Clients connect with `security.protocol=SASL_SSL`, `sasl.mechanism=SCRAM-SHA-512` and their client ID as the
username. Consumer groups and transactional IDs must start with `<id>.`.

## Environments

`environment` names the environment the release serves. Every client lists the environments it exists in under
`environments`, which is required. To bring a client to another environment, add that environment to its list after
its password for that environment is in Vault. Removing an environment from the list removes the client from it (see
[Removing a client](#removing-a-client)).

`whitelist` isn't per environment: the same addresses are allowed in every environment's release.

## Validation

The values schema rejects:

- a client without `environments`, or with an empty list;
- a key the chart doesn't know, on a client, a topic or a whitelist entry, so a misspelling (`partition:`, `topic:`,
  `ip:`) fails instead of being ignored;
- a `partitions` below 1, or a `retentionMs` below 1. Unlimited retention (`-1`) isn't allowed, so no client can fill
  the shared disk;
- a whitelist entry without a `name` or without `ips`, or an address that isn't IPv4 or an IPv4 CIDR range. `/0`
  isn't allowed.

The render also fails when:

- there are clients but `environment` isn't set, or `passwords.vaultKey` isn't set;
- a client ID isn't a string of lowercase letters and digits starting with a letter. Dots aren't allowed, so no
  client's `<id>.` prefix can overlap another's;
- two clients share an ID, or an ID is in `cluster.reservedUsers`;
- a topic name isn't lowercase letters, digits and dashes, or a client lists the same topic twice;
- a quota has a key other than `producerByteRate` and `consumerByteRate`, or a rate that isn't a positive number. Leave
  a rate out for unlimited.

## Removing a client

Removing a client, or one of its environments, deletes its `User`, which revokes its access, and its `ExternalSecret`
and secret. Its topics are kept (`helm.sh/resource-policy: keep` and `argocd.argoproj.io/sync-options: Prune=false`)
and its quota stays in place. Delete them deliberately:

```bash
rpk topic delete '<id>.<name>'
rpk cluster quotas alter --name user=<id> --delete producer_byte_rate --delete consumer_byte_rate
```

Then delete the leftover `Topic` resources, the client's Vault property, and its whitelist entry. Never give a removed
client's ID to a different client while its topics exist: the new client's ACLs on `<id>.` would give it the old
client's data.

## Parameters
