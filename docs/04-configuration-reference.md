# Configuration reference

Every variable is documented where it is defined, with the reasoning next to
it. This page is a map of where to look, not a copy of those comments — a copy
would go stale and there would be no way to tell which one was wrong.

| File | Holds |
|---|---|
| `roles/<role>/defaults/main.yml` | everything that role can be told to do |
| `inventories/<env>/group_vars/all/cluster.yml` | ports, addresses, the derived bootstrap list |
| `inventories/<env>/group_vars/all/profile.yml` | the only things that differ between lab and production |
| `inventories/<env>/group_vars/all/security.yml` | listener profiles and the migration stages |
| `inventories/<env>/group_vars/all/topics.yml` | cluster-wide topic declarations |
| `inventories/<env>/group_vars/all/cluster_id.yml` | the KRaft cluster identity |
| `inventories/<env>/group_vars/all/vault.yml` | SCRAM passwords, encrypted |
| `inventories/<env>/host_vars/<host>.yml` | per-node identity |
| `roles/<component>/vars/required_topics.yml` | topics a component needs |

## The rule about where things live

A variable belongs to a role until a second role needs it. Then it moves to
`group_vars/all/`, because a fact two roles depend on is not one role's
private business.

Four things have made that trip: the distribution version and checksum, the
install path, the cluster id, and the SASL mechanism. Each moved the moment a
second component needed it, and the commit that moved it says why.

## The ones you will actually change

### Environment profile

`group_vars/all/profile.yml` — the complete list of what differs between
environments:

| Variable | Lab | Production |
|---|---|---|
| `kafka_heap_size` | `512m` | `6g` |
| `kafka_tune_os` | `false` | `true` |

Roles never ask which environment they are in. Everything conditional lives
here.

### The distribution

`group_vars/all/cluster.yml`:

| Variable | Note |
|---|---|
| `kafka_distribution_version` | pinned; "latest" installs something different tomorrow |
| `kafka_distribution_sha512` | published beside the archive; `get_url` refuses a mismatch |
| `kafka_install_dir` | `/opt/kafka`, the symlink to the active version |

### Addresses

`group_vars/all/cluster.yml`:

| Variable | Lab | Production |
|---|---|---|
| `kafka_internal_host` | the inventory name | usually the private IP |
| `kafka_controller_host` | the inventory name | the private IP |
| `kafka_external_advertised_host` | `localhost` | whatever clients reach |
| `kafka_internal_port` / `kafka_controller_port` | 9092 / 9093 | |
| `schema_registry_port` / `kafka_connect_port` | 8081 / 8083 | |

The satellite ports live here rather than in their roles because the UI has to
render a Schema Registry URL before that role has run.

### Security

`group_vars/all/security.yml`:

| Variable | Note |
|---|---|
| `kafka_listener_profile` | `plaintext` → `add-secure` → `switch` → `secure` |
| `kafka_sasl_mechanism` | `SCRAM-SHA-512` |
| `kafka_listener_profiles` | the listener list for each stage |

Derived from the profile, so nothing else needs setting: the inter-broker
listener, whether TLS and SASL are rendered, which port clients use, and
whether components need credentials.

`roles/kafka/defaults/main.yml`:

| Variable | Default | Note |
|---|---|---|
| `kafka_authorizer_enabled` | `true` | deny by default once on |
| `kafka_allow_everyone_if_no_acl_found` | `false` | set true only while creating the first rules |
| `kafka_super_users` | admin + the brokers | a broker that cannot manage the cluster cannot start |
| `kafka_ssl_principal_mapping` | `RULE:^CN=([^,]+).*$/$1/` | a lazy group here yields an empty principal |

### Durability

`roles/kafka/defaults/main.yml`. Changing these changes what the cluster
promises:

| Variable | Default | Consequence |
|---|---|---|
| `kafka_default_replication_factor` | 3 | survives one broker |
| `kafka_min_insync_replicas` | 2 | refuses writes when two are down |
| `kafka_auto_create_topics_enable` | `false` | a typo cannot create a topic |
| `kafka_log_retention_hours` | 168 | |

### Java

| Variable | Where | Note |
|---|---|---|
| `java_majors` | `host_vars/<host>.yml` | a list; one host can need several |
| `kafka_java_major` | `roles/kafka/defaults` | 21 |
| `kafka_ui_java_major` | `roles/kafka_ui/defaults` | 25 |
| `schema_registry_java_major` | `roles/schema_registry/defaults` | 21 |

Each component states what it was built for and the JVM path is resolved from
that number, rather than from wherever `/usr/bin/java` points.

### Per-node

`inventories/<env>/hosts.yml` and `host_vars/`:

| Variable | Note |
|---|---|
| `kafka_node_id` | unique, and permanent — it is the node's identity in the quorum |
| `kafka_external_advertised_port` | what a client outside reaches this broker on |
| `java_majors` | the JDKs this host needs |

## Command-line overrides worth knowing

| Flag | Effect |
|---|---|
| `-e kafka_serial=1` | one broker at a time; **required** for config changes on a live cluster |
| `-e kafka_listener_profile=<stage>` | advance the security migration |
| `--tags <component>` | deploy one component |
| `--limit <group>` | and touch only its hosts |
| `--skip-tags precheck` | bypass the health guard during a recovery |
