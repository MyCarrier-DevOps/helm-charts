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
- When the client sets a `quota`, a produce/fetch byte-rate quota on the client ID prefix `<id>.`, applied by a
  post-install/upgrade Job with `rpk`.

Clients get no cluster-level permissions and can't create topics.

## Prerequisites

- The [Redpanda Operator](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/) with the
  `cluster.redpanda.com/v1alpha2` `User` and `Topic` CRDs, managing the cluster named in `cluster.name`.
- On the cluster: SASL with SCRAM, authorization enabled (`kafka_enable_authorization: true`) and topic auto-creation
  off (`auto_create_topics_enabled: false`). Without authorization the ACLs aren't enforced.
- A secret `redpanda-client-<id>` (key `password`) for every client, created outside this chart.
- For quotas: an admin user's credentials in `quotaJob.credentialsSecret` and the brokers' CA in `quotaJob.caSecret`.

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
username. Consumer groups and transactional IDs must start with `<id>.`, and `client.id` should be `<id>.<app>` so the
quota applies.

## Naming rules

The render fails when:

- a client ID isn't lowercase letters and digits. Dots aren't allowed, so no client's `<id>.` prefix can overlap
  another's.
- two clients share an ID.
- a topic name isn't lowercase letters, digits and dashes.

## Removing a client

Removing a client from values deletes its `User`, which revokes its access. Its topics are kept
(`helm.sh/resource-policy: keep` and `argocd.argoproj.io/sync-options: Prune=false`) and its quota stays in place.
Delete them deliberately:

```bash
rpk topic delete '<id>.<name>'
rpk cluster quotas alter --name client-id-prefix=<id>. --delete producer_byte_rate --delete consumer_byte_rate
```

Then delete the leftover `Topic` resources.

## Parameters
