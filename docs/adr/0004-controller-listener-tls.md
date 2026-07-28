# 4. The controller listener uses mutual TLS, and changing it needs an outage

## Status

Accepted.

## Context

The client-facing listeners were migrated from PLAINTEXT to SASL_SSL without
downtime, by adding the secure listener alongside the old one, moving traffic
onto it, and removing the old one — three rolling restarts, no window where
half the brokers spoke one protocol and half spoke another.

That approach is not available for the controller listener.
`controller.quorum.voters` names exactly one endpoint per node:

```
controller.quorum.voters=1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093
```

There is one port, so there can be one controller listener. A second cannot be
added for the quorum to migrate onto.

The first attempt kept the controller listener PLAINTEXT and secured only
client traffic. That worked until the authorizer was switched on, at which
point every broker terminated itself:

```
ERROR Encountered fatal fault: Unexpected error in raft IO thread
org.apache.kafka.common.errors.ClusterAuthorizationException:
  Received cluster authorization error ... source=kafka-1:9093
```

Quorum traffic over a PLAINTEXT listener authenticates as `User:ANONYMOUS`.
That principal is not a super user, the authorizer denied the raft fetch, and
a broker that cannot reach the quorum stops.

Adding `User:ANONYMOUS` to `super.users` would have restored the cluster, and
would have meant that anything reaching port 9093 has unrestricted access.

## Decision

The controller listener uses SSL with `ssl.client.auth=required`. Brokers
authenticate to the quorum with the certificate the `tls` role issues them,
and `ssl.principal.mapping.rules` turns the subject into the principal
`kafka-1`, `kafka-2`, `kafka-3` — all of which are super users.

SASL is not used there. SCRAM credentials live in the metadata log that the
quorum itself manages, which would make reaching the quorum a prerequisite for
reading the credentials needed to reach the quorum.

Changing this listener's protocol requires restarting all three controllers
together. That is a planned outage, and it is deliberately not something
`rolling-restart.yml` will do.

## Consequences

- The certificate a broker presents is now part of the cluster's ability to
  form a quorum. An expired certificate stops the broker, and the `tls` role's
  825-day validity has to be renewed before then.
- The principal mapping rule matters more than it looks. The commonly copied
  `RULE:^CN=(.*?),?.*$/$1/` uses a lazy group, which matches the empty string
  when the subject is a bare `CN=kafka-1`; the principal comes out as `User:`
  and every authorization fails in a way that does not mention certificates.
  The rule here is `RULE:^CN=([^,]+).*$/$1/`.
- A cluster built with `kafka_listener_profile: secure` from the start never
  needs the coordinated restart. It only applies to migrating an existing one.
- KIP-853's dynamic quorum removes the single-endpoint constraint. Revisiting
  this once that path is well trodden would make the controller listener
  migratable like the others.
