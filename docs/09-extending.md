# Adding a component

This repository claims you can add a component to a running Kafka cluster
without taking the cluster down. This page is that claim, written out as the
procedure — and the measurements that were taken while following it.

## The procedure

Adding Schema Registry to a live three-broker cluster took two commands and a
five-line inventory change.

### 1. Put the host in the group

```yaml
# inventories/lab/hosts.yml
schema_registry:
  hosts:
    tools-1:
      ansible_host: 127.0.0.1
      ansible_port: 2224
```

That is the entire inventory change. `playbooks/site.yml` already had a play
scoped to the `schema_registry` group; it had simply been skipping, because
the group was empty.

### 2. Deploy the component

```bash
ansible-playbook -i inventories/lab playbooks/site.yml \
  --tags java,schema_registry --limit schema_registry
```

`--limit` is what keeps the promise honest. The `java` play covers every host
that runs a JVM, brokers included, so without it the brokers would appear in
the run — doing nothing, but appearing. Limiting to the group being deployed
means the brokers are not contacted at all.

### 3. Let the UI discover it

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_ui
```

Nothing about the UI's configuration was edited. Its environment file renders
a Schema Registry entry when, and only when, the `schema_registry` group has a
host:

```jinja
{% if groups['schema_registry'] | default([]) | length > 0 %}
KAFKA_CLUSTERS_0_SCHEMAREGISTRY=http://{{ groups['schema_registry'][0] }}:{{ schema_registry_port }}
{% else %}
# schema_registry group is empty — no Schema Registry configured.
{% endif %}
```

Before and after, the same file:

```diff
-# schema_registry group is empty — no Schema Registry configured.
+KAFKA_CLUSTERS_0_SCHEMAREGISTRY=http://tools-1:8081
```

## What it cost the cluster

Nothing, and that was measured rather than assumed.

| Check | Before | After |
|---|---|---|
| `kafka-1` service start | `21:45:25 UTC` | `21:45:25 UTC` |
| `kafka-2` service start | `21:45:36 UTC` | `21:45:36 UTC` |
| `kafka-3` service start | `21:45:46 UTC` | `21:45:46 UTC` |
| Messages in `rolling-test` | 7612 | 7612 |
| Broker lines in the play recap | — | 0 |

The service start timestamps are the useful signal: a restart would move them.
They did not move.

## What made it possible

Four of the five rules in [CONTRIBUTING.md](../CONTRIBUTING.md) are load
bearing here.

**One component, one role, one group.** The play existed before the component
did. Deploying it was a matter of giving the group a host, not of editing
`site.yml`.

**No role hardcodes an address.** The UI renders `http://tools-1:8081` from
the inventory. Nobody typed that string anywhere.

**Only the broker role touches brokers.** The Schema Registry role has no way
to restart a broker, so no amount of getting it wrong could have caused an
outage.

**Broker-side needs are declared, not applied.** Schema Registry needs a
compacted `_schemas` topic replicated three ways. It says so in its
`defaults/main.yml`, and the replication factor in the rendered configuration
comes from that declaration rather than from a number typed twice.

## Adding a different component

The same shape holds. For a component that is not yet written:

1. `roles/<component>/` with the four required files — a commented
   `defaults/main.yml`, `tasks/verify.yml`, a molecule scenario, a docs page
2. A play in `site.yml` scoped to `hosts: <component>` and tagged
   `<component>`
3. If other components need its address, its port goes in
   `group_vars/all/cluster.yml` rather than inside its own role, so a
   component can render a URL for something that has not been deployed yet
4. If the UI should display it, one conditional block in
   `roles/kafka_ui/templates/kafka-ui.env.j2`

Then the two commands above.

## The one thing to watch

A component that needs a different Java version than something already on the
host is not a special case — it is the normal case. Kafka UI 1.5 is compiled
for Java 25; Confluent 8.0 is supported on 21. Both run on `tools-1`.

The `java` role installs a list, and each component resolves the JVM it was
built for:

```yaml
# inventories/lab/host_vars/tools-1.yml
java_majors: [21, 25]
```

```yaml
# roles/schema_registry/defaults/main.yml
schema_registry_java_major: 21
# roles/kafka_ui/defaults/main.yml
kafka_ui_java_major: 25
```

Resolving by major version rather than by following `/usr/bin/java` is what
keeps the two components from fighting over the system default.
