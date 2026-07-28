# Monitoring

> This repository does not deploy a metrics stack. This page is what to watch
> and how to expose it, not a description of something that is already
> running — the JMX exporter and Prometheus roles are the obvious next
> addition, and would follow the same shape as every other component here.

## What Kafka exposes

Everything is JMX. Enabling remote JMX means setting `JMX_PORT` in
`/etc/kafka/kafka.env`; the usual production approach is instead to run the
Prometheus JMX exporter as a Java agent, which turns the same MBeans into an
HTTP endpoint without opening JMX itself.

```
KAFKA_OPTS=-javaagent:/opt/jmx_exporter/jmx_prometheus_javaagent.jar=7071:/etc/kafka/jmx-exporter.yml
```

## The metrics worth alerting on

| Metric | Healthy | Why it matters |
|---|---|---|
| `UnderReplicatedPartitions` | 0 | Anything else means a replica is behind. Sustained non-zero is one broker away from refusing writes |
| `OfflinePartitionsCount` | 0 | A partition with no leader is a partition nobody can use |
| `ActiveControllerCount` | exactly 1 cluster-wide | Zero means no controller; more than one means split brain |
| `IsrShrinksPerSec` | near 0 | Frequent shrinking usually means GC pauses or a slow disk, not a network problem |
| `RequestHandlerAvgIdlePercent` | > 0.3 | Below that the broker is saturated and latency is about to climb |
| `NetworkProcessorAvgIdlePercent` | > 0.3 | Same, on the network side |
| `TotalTimeMs` (Produce, Fetch) | watch p99 | The number a client actually experiences |
| `MaxLag` (per consumer group) | bounded | Growing lag means consumers cannot keep up |
| JVM `GC pause time` | < 100 ms | Long pauses look like network failures from outside |
| Disk usage on `log.dirs` | < 70% | A full log directory stops the broker |

`UnderReplicatedPartitions` is the single most useful one, and it is what
`rolling-restart.yml` already waits on between nodes.

## Beyond the brokers

| Component | Endpoint |
|---|---|
| Kafka UI | `/actuator/health`, `/actuator/prometheus` |
| Schema Registry | `/subjects` as a liveness check; JMX for the rest |
| Kafka Connect | `/connectors/<name>/status` — a connector can be `RUNNING` while its tasks are `FAILED` |

That last one is worth an alert of its own. A connector reports its own state
and its tasks' states separately, and the tasks are the part doing the work.

## What the repository does instead, today

`playbooks/verify.yml` answers "is this working" on demand rather than
continuously:

```bash
make verify
```

It waits for each listener, asserts the quorum has a leader, checks that no
partition is under-replicated, confirms the UI sees every broker, and confirms
Connect joined the expected cluster. That is a health check, not monitoring —
it tells you the state now, and nothing about the state five minutes ago.
