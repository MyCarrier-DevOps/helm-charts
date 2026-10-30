# redpanda-clients

Onboards clients to a shared Redpanda cluster from a list in values. Each client can only see and use resources under
its own `<id>.` prefix.

For each client the chart renders:

- A `User` (SCRAM-SHA-512) whose password is read from the secret `redpanda-client-<id>` (key `password`), with
  prefixed ACLs on `<id>.`:
  - topics: Read, Write, Describe
  - consumer groups: Read, Describe
  - transactional IDs: Write, Describe, only when `transactions: true`
- A `Topic` per listed topic, created in Redpanda as `<id>.<name>`.
- Produce and fetch byte-rate quotas on the client's user, applied by a post-install/upgrade Job with `rpk`. The quota
  follows the authenticated user, so a client can't avoid it or use another client's by choosing its `client.id`. A rate
  the client doesn't set is removed, so it's unlimited even if it was set before.

Clients get no cluster-level permissions and can't create topics.

## Prerequisites

- The [Redpanda Operator](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/) with the
  `cluster.redpanda.com/v1alpha2` `User` and `Topic` CRDs, managing the cluster named in `cluster.name`.
- On the cluster: SASL with SCRAM, authorization enabled (`kafka_enable_authorization: true`) and topic auto-creation
  off (`auto_create_topics_enabled: false`). Without authorization the ACLs aren't enforced.
- A secret `redpanda-client-<id>` (key `password`) for every client, created outside this chart.
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
clients:
  - id: alpha
    quota:
      producerByteRate: 5242880
      consumerByteRate: 10485760
    topics:
      - name: shipments
        partitions: 6
        retentionMs: 1209600000
      - name: quotes
  - id: bravo
    transactions: true
    topics:
      - name: orders
```

Clients connect with `security.protocol=SASL_SSL`, `sasl.mechanism=SCRAM-SHA-512` and their client ID as the
username. Consumer groups and transactional IDs must start with `<id>.`.

## Naming rules

The render fails when:

- a client ID isn't a string of lowercase letters and digits starting with a letter. Dots aren't allowed, so no
  client's `<id>.` prefix can overlap another's.
- two clients share an ID, or an ID is in `cluster.reservedUsers`.
- a topic name isn't lowercase letters, digits and dashes, or a client lists the same topic twice.
- a quota has a key other than `producerByteRate` and `consumerByteRate`, or a rate that isn't a positive number. Leave
  a rate out for unlimited.

## Removing a client

Removing a client from values deletes its `User`, which revokes its access. Its topics are kept
(`helm.sh/resource-policy: keep` and `argocd.argoproj.io/sync-options: Prune=false`) and its quota stays in place.
Delete them deliberately:

```bash
rpk topic delete '<id>.<name>'
rpk cluster quotas alter --name user=<id> --delete producer_byte_rate --delete consumer_byte_rate
```

Then delete the leftover `Topic` resources. Never give a removed client's ID to a different client while its topics
exist: the new client's ACLs on `<id>.` would give it the old client's data.

## Parameters
