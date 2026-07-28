# 1. KRaft, not ZooKeeper

## Status

Accepted. Not really a choice any more.

## Context

Kafka historically kept its metadata — which topics exist, who leads each
partition, where the replicas are — in ZooKeeper. Running Kafka meant running
and understanding a second distributed system with its own failure modes,
its own operational tooling, and its own upgrade path.

KRaft moves that metadata into Kafka itself. Some nodes take a `controller`
role and maintain the metadata as a Raft log among themselves.

Kafka 4.0 removed ZooKeeper support entirely.

## Decision

KRaft, in combined mode: the same three nodes are both brokers and
controllers.

## Consequences

- One system to install, monitor and upgrade.
- Controller counts must be odd. Three tolerate one failure; five tolerate
  two; four tolerate the same as three while costing more.
- The metadata version only moves forward. A cluster formatted by 4.3 cannot
  be read by 4.2, which makes a downgrade a restore rather than a rollback.
- `controller.quorum.voters` is static here, which is simple and predictable
  but pins the quorum to one endpoint per node. That constraint is what makes
  the controller listener the only thing in this repository that cannot be
  migrated without an outage. KIP-853's dynamic quorum would remove it.
