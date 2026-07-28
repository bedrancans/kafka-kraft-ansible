# Troubleshooting

Every entry here happened while building this repository. The symptom column
is what you actually see; none of them mention the real cause.

## The broker will not start

| Symptom | Cause | Fix |
|---|---|---|
| `Found directory /var/lib/kafka/data/.ansible` | The service account's home *is* `log.dirs`, so Ansible's temp directory landed in it. Kafka refuses anything in `log.dirs` that is not a topic partition. | Home is `/var/lib/kafka`, data is `/var/lib/kafka/data` |
| `Could not find a 'KafkaServer' or '<name>.KafkaServer' entry in the JAAS configuration` | A SASL listener with no JAAS entry. The entry has to exist for *every* SASL listener, not only the inter-broker one. | Render `listener.name.<name>.<mech>.sasl.jaas.config` per SASL listener |
| `Failed to load PEM SSL keystore` / `algid parse error, not a sequence` | The private key is PKCS#1. Kafka's PEM reader wants PKCS#8. | `format: pkcs8` on `openssl_privatekey` |
| `UnsupportedVersionException: Can't read version 4 of BrokerEndpoint` | Downgraded below the metadata version the log was written with. | Not fixable by configuration; restore from backup or go back to the newer release |
| `ClusterAuthorizationException` in the raft IO thread, broker exits | The authorizer is on and the controller listener is PLAINTEXT, so quorum traffic authenticates as `User:ANONYMOUS`. | Mutual TLS on the controller listener — see [ADR 0004](adr/0004-controller-listener-tls.md) |

## The cluster is up but something cannot reach it

| Symptom | Cause | Fix |
|---|---|---|
| A client connects and then times out talking to a broker | `advertised.listeners` points somewhere the client cannot reach | Check what the broker advertises: `AdminClient(...).list_topics()` prints the addresses it was given |
| The quorum never forms; `LeaderId` is absent | The nodes disagree on `controller.quorum.voters`, or cannot resolve each other | The string must be byte-identical everywhere. Preflight checks resolution before anything is changed |
| `nc -z` to a peer succeeds but the quorum still fails | Every container has the same address, so the node reached itself | Rootless podman gives all containers `10.0.2.100` without a shared network. Reachability and correctness are different questions |
| Every authorization fails, `principal=User:` in the logs | The SSL principal mapping rule's lazy group matched the empty string | `RULE:^CN=([^,]+).*$/$1/`, not `(.*?)` |
| `AccessDeniedException` on a file that is `0644` | The *directory* is `0750` and owned by another component's group | `tls_dir_mode: "0755"` on hosts running several components |

## Something is running but not doing anything

| Symptom | Cause | Fix |
|---|---|---|
| A connector is `RUNNING`, the topic stays empty, the log repeats `UNKNOWN_TOPIC_OR_PARTITION` | The target topic does not exist and `auto.create.topics.enable` is false | Declare the topic. This is the setting working as intended: the alternative is a typo creating a single-replica topic |
| Writes hang and time out | Two brokers are out of the ISR, so `min.insync.replicas=2` cannot be met | Check `--under-replicated-partitions`. The refusal is deliberate |
| The UI shows the cluster but no Schema Registry tab | The `schema_registry` group has a host but the UI was not re-rendered | `ansible-playbook site.yml --tags kafka_ui` |

## Ansible itself

| Symptom | Cause | Fix |
|---|---|---|
| A variable is undefined in a playbook that a role clearly defines | Playbooks do not inherit a role's defaults | Move the knowledge into the role as a `tasks_from` file, or into `group_vars/all/` if two roles need it |
| A config file is correct but the process is running the old one, and re-running changes nothing | A previous run failed, so the handler was dropped; now the file matches and nothing notifies | `force_handlers: true` |
| `regex_search` returns `None` on a pattern that works elsewhere | Backreference escaping does not survive a YAML block scalar | Split on the field name instead of matching it |
| A package is not found although the repository is enabled | The image deleted `/var/lib/apt/lists` but left apt's freshness stamp, so `cache_valid_time` skipped the update | Keep the lists |
| `SecurityDisabledException: No Authorizer is configured` from `kafka-acls.sh` | ACLs cannot be created before an authorizer exists | Enable it permissively, create the rules, then enforce |

## Where to look

```bash
podman exec kafka-1 journalctl -u kafka -f
podman exec tools-1 journalctl -u schema-registry -f
podman exec tools-1 journalctl -u kafka-connect -f
podman exec tools-1 journalctl -u kafka-ui -f
```

Kafka logs its entire effective configuration at startup. When a setting is
not doing what you expect, the first question is whether the running process
has the value you think it has — which is not the same as what the file says.
