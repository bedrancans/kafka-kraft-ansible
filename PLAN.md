# kafka-kraft-ansible — Implementation plan

Deploy a three-broker Apache Kafka cluster in KRaft mode with Ansible, add
Kafka UI on top of it, and be able to add components such as Schema Registry
and Kafka Connect later **without stopping the cluster**.

The lab runs on WSL2 + podman, but the whole deployment is designed to run on
real VMs. The only difference between lab and production is the inventory.

---

## 0. Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Kafka version | 4.x (exact version pinned at the start of phase 2) | KRaft-only, no ZooKeeper |
| Topology | 3 nodes, `process.roles=broker,controller` (combined) | standard for three nodes; the role also supports `isolated` |
| Install method | tarball + systemd for every component | avoids containers inside containers, one consistent model |
| Java | OpenJDK 21 (`openjdk-21-jre-headless`, apt) | Kafka 4.x brokers require Java 17+ |
| Lab engine | podman 4.9 + netavark/aardvark-dns | already installed, rootless, systemd works cleanly |
| Connection | SSH, including to the containers | so roles cannot tell VMs and containers apart |
| Security | PLAINTEXT through phase 7, SASL/SCRAM + TLS in phase 8 | working cluster first, hardening second |
| Quorum | static `controller.quorum.voters` | fewer surprises; dynamic quorum is captured as an ADR |

### Components and how they are installed

| Component | Source | Service |
|---|---|---|
| Kafka broker + controller | Apache Kafka tarball | `kafka.service` |
| Kafka Connect | **the same tarball** (`connect-distributed.sh`) | `kafka-connect.service` |
| Schema Registry | Confluent Community tarball | `schema-registry.service` |
| Kafka UI | kafbat/kafka-ui jar (provectus is archived) | `kafka-ui.service` |

---

## 1. Lab port and name map

Podman network: `kafka-lab` (aardvark-dns resolves container names as hostnames).

| Container | Hostname | SSH (host) | EXTERNAL Kafka | Service ports |
|---|---|---|---|---|
| kafka-1 | `kafka-1` | 2221 | 39091 → 39092 | 9092 / 9093 (internal) |
| kafka-2 | `kafka-2` | 2222 | 39092 → 39092 | 9092 / 9093 (internal) |
| kafka-3 | `kafka-3` | 2223 | 39093 → 39092 | 9092 / 9093 (internal) |
| tools-1 | `tools-1` | 2224 | — | UI 8080, SR 8081, Connect 8083 |

### Listener design (three listeners from day one)

| Listener | Bind | Advertised | Consumers |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | brokers, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | clients on the host |
| `CONTROLLER` | `:9093` | — | KRaft quorum, never exposed |

On production the same structure becomes `INTERNAL=private-ip` /
`EXTERNAL=public-ip`.

---

## 2. Repository layout

```
kafka-kraft-ansible/
├── README.md  README.tr.md  PLAN.md  LICENSE  CONTRIBUTING.md  Makefile  .gitignore
├── ansible.cfg
├── requirements.yml
├── lab/
│   ├── Containerfile            # ubuntu:24.04 + systemd + sshd + python3
│   ├── lab-up.sh  lab-down.sh
│   └── README.md
├── inventories/
│   ├── lab/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │       ├── all/{cluster.yml, profile.yml}
│   │       ├── kafka_brokers/{main.yml, cluster_id.yml}
│   │       └── kafka_ui/main.yml
│   └── prod.example/            # template for real VMs
├── playbooks/
│   ├── site.yml  verify.yml  rolling-restart.yml  upgrade.yml  teardown.yml
├── roles/
│   ├── common/  java/
│   ├── kafka/                   # ★ the main role (broker + controller)
│   ├── kafka_topics/
│   ├── kafka_ui/
│   ├── schema_registry/
│   └── kafka_connect/
├── molecule/default/
├── docs/                        # 00..09 + adr/
└── .github/workflows/ci.yml
```

---

## 3. Phases

Every phase has a **Definition of Done**; the next phase does not start until
it is met. Commit at the end of every phase, tag at the end of each milestone.

---

### PHASE 0 — Lab infrastructure and tooling ✅

**Steps**

1. Host tooling:
   ```bash
   sudo apt install -y podman openssh-client make uidmap gh
   pipx install --include-deps ansible
   pipx install ansible-lint
   pipx install yamllint
   ```
2. `git init` + `.gitignore` (`*.retry`, `.vault_pass`, `*.tar.gz`, `.venv/`).
3. `lab/Containerfile`: `ubuntu:24.04` plus `systemd systemd-sysv dbus
   openssh-server python3 sudo iproute2 curl ca-certificates`; an `ansible`
   user with passwordless sudo and `authorized_keys`; container-irrelevant
   systemd units masked; `STOPSIGNAL SIGRTMIN+3`; `CMD ["/sbin/init"]`.
4. SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/kafka_lab -N ''`.
5. `lab/lab-up.sh`:
   - create the `kafka-lab` network if missing
   - build the image
   - start four containers with `--systemd=always --network kafka-lab
     --hostname <name>` and publish the ports from the table above
   - keep `CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}` so Docker also works
6. `ansible.cfg` (inventory path, `host_key_checking=False`, `pipelining=True`).
7. `inventories/lab/hosts.yml`: groups `kafka_brokers` (3),
   `kafka_controllers` (the same 3), `kafka_ui` (tools-1);
   `ansible_host=127.0.0.1`, `ansible_port=222N`.

**DoD**
- `./lab/lab-up.sh` brings up four containers ✅
- `ansible -i inventories/lab all -m ping` → 4 nodes SUCCESS ✅
- `systemctl is-system-running` returns `running`, as an unprivileged user too ✅
- `getent hosts kafka-2` resolves from kafka-1 (aardvark-dns check) ✅

**Lesson learned:** without the `dbus` package `systemctl` only works as root,
because it falls back to systemd's private socket. A real VM always has a
system bus, so the lab image must install `dbus` too.

---

### PHASE 1 — `common` and `java` roles ✅

**Steps**

1. `roles/common`: `kafka` user and group (nologin), `/opt`, `/var/lib/kafka`
   and `/var/log/kafka` directories, a limits file for `LimitNOFILE`.
2. **Put OS tuning behind a flag:** `kafka_tune_os` (`true` in production,
   `false` in the lab). Tasks such as `vm.swappiness`, `vm.max_map_count` and
   disabling THP are either no-ops in a container or they leak into the host
   kernel, so they must be skipped in the lab. The distinction is documented.
3. `roles/java`: `openjdk-21-jre-headless`, detect `JAVA_HOME` and set it as a
   fact.
4. Skeleton of `playbooks/site.yml` (tagged, group-scoped plays).

**DoD**
- `ansible-playbook -i inventories/lab playbooks/site.yml --tags common,java`
  succeeds ✅
- the **second run reports `changed=0`** (idempotency) ✅ (3 → 0)
- `ansible all -a 'java --version'` reports 21 ✅
- `make lint` passes at ansible-lint's `production` profile ✅

**Lessons learned**

- The lab image used to delete `/var/lib/apt/lists/*` to save space. That has
  no equivalent on a VM and it leaves apt's "cache is fresh" stamp behind, so
  `apt` tasks using `cache_valid_time` skipped the update and could not find
  any package. The lists are kept now.
- `stdout_callback = yaml` was removed from `community.general`; the
  replacement is `result_format = yaml` on the built-in callback.
- Parsing `java -version` (one dash, quoted string on stderr) needs a
  backreference argument whose escaping breaks inside YAML block scalars.
  `java --version` (two dashes) prints a plain line to stdout and needs no
  regex at all.
- ansible-lint's `production` profile requires role variables to carry the
  role name as a prefix. Project-wide flags are consumed through a prefixed
  alias instead: `common_tune_os: "{{ kafka_tune_os | default(true) }}"`.

---

### PHASE 2 — `kafka` role → a working cluster ★ ✅

**Steps, in this order**

1. **Pin the version:** take the exact version and its SHA512 from the Apache
   Kafka download page and write them into `defaults/main.yml`. Verify the
   `kafka-storage.sh format` syntax against that version's own documentation —
   it has changed between minor releases.
2. `defaults/main.yml`: every tunable, commented (this file is the source for
   `docs/04`).
3. `tasks/preflight.yml`: assert unique `node_id`s, RAM and disk thresholds,
   and that every node resolves the others over DNS.
4. `tasks/install.yml`: `get_url` with **checksum verification**, unpack into
   `/opt/kafka-<version>`, symlink `/opt/kafka`. (The symlink makes upgrade and
   rollback a single step.)
5. `templates/server.properties.j2`: three listeners,
   `listener.security.protocol.map`, `inter.broker.listener.name=INTERNAL`,
   `controller.listener.names=CONTROLLER`, and quorum voters derived from the
   inventory:
   ```jinja
   controller.quorum.voters={% for h in groups['kafka_controllers'] -%}
   {{ hostvars[h].kafka_node_id }}@{{ hostvars[h].kafka_controller_host }}:{{ kafka_controller_port }}
   {{- "," if not loop.last }}{%- endfor %}
   ```
   Replication: `default.replication.factor=3`, `min.insync.replicas=2`,
   `offsets.topic.replication.factor=3`,
   `transaction.state.log.replication.factor=3`.
6. **Cluster ID:** generated once (`kafka-storage.sh random-uuid`) and written
   to `group_vars/kafka_brokers/cluster_id.yml` (plain in the lab, vaulted in
   production). A `make cluster-id` target prints a fresh one.
7. `tasks/format.yml`: `stat` `log.dirs/meta.properties` and format only when
   it is **missing**. Without that guard, a re-run wipes the data.
8. `templates/kafka.service.j2` plus `kafka-env` (heap comes from the profile
   variable: `512m` in the lab, `6g` in production), `Restart=on-failure`,
   `TimeoutStopSec=180`, `LimitNOFILE`.
9. `handlers/main.yml`: `restart kafka`.
10. `tasks/verify.yml`: ports 9092/9093, then
    `kafka-metadata-quorum.sh --describe` showing three voters and a leader.

**DoD**
- `ansible-playbook site.yml --tags kafka` → three brokers `active (running)` ✅
- `kafka-metadata-quorum.sh describe --status` → LeaderId set, three voters ✅
- a `--replication-factor 3` topic is created, produce and consume work ✅
  (leadership spread over all three brokers, ISR complete)
- an external client on the host reaches `localhost:39091` and sees the
  brokers advertised as `localhost:3909N` ✅
- the second run reports `changed=0` and the **format task is skipped** ✅

**Lessons learned**

- The role is named `kafka`, not `kafka_kraft`: ansible-lint's `production`
  profile requires role variables to be prefixed with the role name, and
  `kafka_kraft_heap_size` reads far worse than `kafka_heap_size`.
- The service account's home must not be `log.dirs`. It was, and Ansible's
  `become_user` created `~/.ansible/tmp` inside the data directory; Kafka
  then refused to start with *"Found directory /var/lib/kafka/data/.ansible,
  Kafka's log directories should only contain Kafka topic data"*. Home is now
  `/var/lib/kafka` with data in `/var/lib/kafka/data`.
- `kafka-storage.sh format` in 4.x also accepts `--standalone`,
  `--no-initial-controllers` and `--initial-controllers`. Those belong to the
  dynamic quorum (KIP-853) and must not be combined with a static
  `controller.quorum.voters` list. The syntax was read from the installed
  distribution's own `--help` rather than assumed.
- `--ignore-formatted` makes the format command itself idempotent, but the
  role still guards it with a `stat` on `meta.properties` so the skip is
  visible in the play recap.
- Kafka 4.x dropped `kafka.tools.GetOffsetShell`; the replacement is
  `bin/kafka-get-offsets.sh`.

→ `git tag v0.1.0`

---

### PHASE 3 — `kafka_ui` role and the modularity payoff ✅

**Steps**

1. Download the kafbat/kafka-ui jar (`get_url` + checksum) into `/opt/kafka-ui`.
2. `kafka-ui.service` plus an env file rendered **conditionally**:
   ```jinja
   KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS={{ kafka_bootstrap_servers }}
   {% if groups['schema_registry'] | default([]) | length > 0 %}
   KAFKA_CLUSTERS_0_SCHEMAREGISTRY=http://{{ ... }}:8081
   {% endif %}
   {% if groups['kafka_connect'] | default([]) | length > 0 %}
   KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS=http://{{ ... }}:8083
   {% endif %}
   ```
3. The derived variable in `group_vars/all/cluster.yml`:
   ```yaml
   kafka_bootstrap_servers: "{{ groups['kafka_brokers']
     | map('extract', hostvars, 'kafka_internal_host')
     | map('regex_replace', '$', ':' ~ kafka_internal_port) | join(',') }}"
   ```
4. `playbooks/verify.yml`: end-to-end smoke test
   (create topic → produce → consume → clean up).

**DoD**
- `http://localhost:8080` shows three brokers and the topics ✅
  (`/api/clusters` reports `status: ONLINE`, `brokerCount: 3`,
  `controller: KRAFT`)
- running `--tags kafka_ui` sends **no tasks to the brokers** ✅
  (zero broker lines in the recap; broker service start timestamps unchanged
  across the whole phase)
- full `site.yml` still reports `changed=0` on the second run ✅

**Lessons learned**

- Components do not have to agree on a Java version. Kafka UI 1.5 is compiled
  for Java 25 (class file version 69) and fails on 21 with
  `UnsupportedClassVersionError`, while Kafka 4.x is supported on 17 and 21.
  Following `/usr/bin/java` would have made the two components fight over the
  system default, so the java role gained `tasks_from: resolve.yml`, which
  locates a JVM by major version. Each component states the version it needs
  and the group_vars for `kafka_ui` install Java 25 on that host only.
- The GitHub releases API exposes an asset `digest`, so the jar is pinned by
  checksum like the broker tarball. It is worth being precise about what that
  buys: Apache publishes a checksum signed by the release manager, while
  GitHub computes this one from the uploaded asset, so it protects the
  download rather than the upload.
- `DYNAMIC_CONFIG_ENABLED` is off deliberately. With it on, a change made in
  the browser would be silently reverted by the next Ansible run — the two
  sources of truth would quietly disagree.

→ `git tag v0.2.0`

---

### PHASE 4 — Testing and CI ✅

**Steps**

1. `molecule/default/` — podman driver, the same `lab/Containerfile`,
   a three-node scenario.
2. `molecule.yml` + `converge.yml` + `verify.yml` (the phase 2 checks).
3. `.github/workflows/ci.yml`: `yamllint` → `ansible-lint` → `molecule test`
   (molecule measures idempotency automatically).
4. Add the CI badge to the README.

**DoD**
- `molecule test` is green locally ✅ (7 actions, 7 successful, and the
  `idempotence` action passes, so a second converge changes nothing)
- the GitHub Actions badge is green ✅

**Lessons learned**

- Rootless podman gives every container the same slirp4netns address
  (`10.0.2.100`) unless the platforms name a shared network. The symptom was
  not a connection error but the opposite: `kafka-1` reached "kafka-2:9093"
  successfully — because it was talking to itself — and the Raft quorum
  rejected the votes with `voter key ... doesn't match the local key`.
  Reachability and correctness are different questions.
- Molecule's schema error for `systemd: true` rendered as an empty string.
  Running the driver's own schema (`api.drivers()["podman"].schema_file()`)
  through jsonschema gave the real message: the field takes the strings
  `'true'`, `'false'` or `'always'`, not a YAML boolean.
- Molecule ignores the repository's `ansible.cfg`, so `ANSIBLE_ROLES_PATH`
  and `ANSIBLE_COLLECTIONS_PATH` have to be set in `provisioner.env`.
- Once `inventory.links` is declared, molecule stops writing its own inline
  `host_vars`, so the per-node identities live in a real directory.
- `converge.yml` imports `playbooks/site.yml` instead of restating it.
  A scenario that converged a hand-written copy would only prove the copy
  works.

→ `git tag v0.3.0`

---

### PHASE 5 — Operational playbooks ✅

**Steps**

1. `rolling-restart.yml`: `serial: 1` → stop → start → wait for the port →
   `retries/until` on
   `kafka-topics.sh --describe --under-replicated-partitions` returning empty →
   next node.
2. `upgrade.yml`: download the new version → flip the symlink → rolling restart
   → verify.
3. Runbooks in `docs/05-operations.md`: replacing a broker, a full disk,
   log cleanup.

**DoD**
- a producer running throughout a rolling restart **loses no messages** ✅
  (7562 sent, 7562 acknowledged, 7562 stored, zero delivery failures, with
  `acks=all` and idempotence enabled while all three brokers restarted)
- the cluster keeps accepting writes while one broker is stopped ✅
  (50/50 accepted with one broker down; 0/50 with two down, which is
  `min.insync.replicas=2` refusing data it cannot protect rather than
  silently accepting it)
- `upgrade.yml` moves the cluster between versions and back ✅

**Lessons learned**

- Playbooks do not inherit a role's defaults. This bit three times — the
  service name, the config directory, `kafka_java_home` — and the fix each
  time was to move the knowledge back into the role as a `tasks_from` file
  (`restart.yml`, `report_version.yml`, `resolve_java.yml`) rather than
  restating paths in the playbook.
- Installing and activating a release are different operations.
  `install.yml` now only downloads and unpacks, which is safe on a running
  broker; `activate.yml` flips the symlink, which is not. `upgrade.yml`
  stages across the whole cluster before activating a single node, so a bad
  download fails before anything has restarted.
- **KRaft cannot be downgraded below the metadata version its log was written
  with.** Moving from 4.3.1 to 4.2.1 failed with
  `UnsupportedVersionException: Can't read version 4 of BrokerEndpoint`.
  This was worth running: `any_errors_fatal` stopped after the first node, the
  remaining two kept serving, the quorum elected a new leader, and the same
  playbook rolled that node back. A downgrade is a restore-from-backup
  operation, not a symlink flip — the runbook says so now.
- A guard that cannot be bypassed is a liability during an incident. The
  health precheck is tagged `precheck` precisely so a rollback can skip it,
  because the state it refuses to proceed from is exactly the state you are
  trying to recover from.

→ `git tag v0.4.0`

---

### PHASE 6 — `schema_registry`, the proof of modularity ★ ✅

This phase proves the central claim: **adding a component to a running cluster
with zero downtime.**

1. `roles/schema_registry` (Confluent Community tarball + systemd); the
   `_schemas` topic is declared and created through the `kafka_topics` role.
2. Add the `schema_registry` group and `tools-1` to
   `inventories/lab/hosts.yml`.
3. ```bash
   ansible-playbook -i inventories/lab playbooks/site.yml --tags schema_registry
   ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_ui
   ```
4. `docs/09-extending.md` walks through the flow.

**DoD**
- Schema Registry comes up, register and get work ✅
  (a schema registered and read back; an incompatible one rejected with
  `READER_FIELD_MISSING_DEFAULT_VALUE`, which is BACKWARD compatibility being
  enforced rather than configured and forgotten)
- the Schema Registry tab **appears in Kafka UI on its own** ✅
  (`/api/clusters` gained `SCHEMA_REGISTRY` in its feature list and lists the
  registered subject)
- not a single task ran against the brokers ✅
  (zero broker lines in the recap, and the three broker service start
  timestamps are byte-identical before and after; message count unchanged
  at 7612)

The procedure and the measurements are written up in
[docs/09-extending.md](docs/09-extending.md).

**Lessons learned**

- Components on one host can need different JDKs, and that is ordinary rather
  than exceptional: Kafka UI 1.5 is compiled for Java 25, Confluent 8.0 is
  supported on 21, and both run on the tools node. `roles/java` now installs
  a list, and `java_majors` is set in `host_vars` rather than `group_vars`
  because the host belongs to both groups and two group_vars files defining
  the same variable would leave the winner to chance.
- `--limit <group>` is what makes "the brokers were not touched" true rather
  than merely almost true. The `java` play spans every JVM host, so without it
  the brokers appear in the run doing nothing — which is not the same claim.
- Confluent does not publish Schema Registry on its own; it ships inside the
  Community archive. Taking the 416 MB download keeps every component on one
  installation model instead of introducing an apt repository with its own
  unit files and its own idea of how the service is managed.
- Read-only verification tasks need `check_mode: false`, or `--check` leaves
  the `uri` results empty and the assertions fail on nothing.

→ `git tag v0.5.0`

---

### PHASE 7 — `kafka_connect` and `kafka_topics`

**Steps**

1. `roles/kafka_connect`: `connect-distributed.sh` from the Apache Kafka
   tarball, its own systemd unit, managed `plugin.path`.
2. `connect-configs`, `connect-offsets` and `connect-status` topics created up
   front by the `kafka_topics` role (RF=3, compacted).
3. An end-to-end demo with an example connector (FileStream or Datagen).

**DoD**
- the Connect REST API answers on `:8083` and a connector runs
- the Connect tab shows up in Kafka UI

→ `git tag v0.6.0`

---

### PHASE 8 — Security

**Steps**

1. TLS: generate a CA and broker certificates (`openssl`/`keytool`), distribute
   keystores and truststores.
2. SASL/SCRAM-SHA-512: create users, JAAS config, `sasl.enabled.mechanisms`.
3. Switch the listeners to `SASL_SSL` through a **planned rolling restart**
   (using the phase 5 playbook).
4. ACLs plus service users for UI, Schema Registry and Connect.
5. Passwords under `ansible-vault`.

**DoD**
- unauthenticated clients are rejected
- every component talks over SASL_SSL
- the migration ran as a rolling restart with no data loss

→ `git tag v0.7.0`

---

### PHASE 9 — Documentation and release

| File | Contents |
|---|---|
| `README.md` | what it does, mermaid architecture diagram, five-minute quick start, UI screenshot, CI badge |
| `docs/01-architecture.md` | KRaft, topology, listener matrix, port table |
| `docs/02-prerequisites.md` | OS, Java, disk/RAM/network, lab vs production |
| `docs/03-installation.md` | step by step, filling in the inventory |
| `docs/04-configuration-reference.md` | every variable in `defaults/main.yml` |
| `docs/05-operations.md` | runbooks |
| `docs/06-security.md` | TLS, SASL, ACLs |
| `docs/07-monitoring.md` | JMX, the ten metrics to watch, alert thresholds |
| `docs/08-troubleshooting.md` | symptom / cause / fix table |
| `docs/09-extending.md` | how to add a new component |
| `docs/adr/` | why KRaft, why combined mode, why containers-as-VMs, why a static quorum |
| `CONTRIBUTING.md` | the five rules of the modularity contract |

→ `git tag v1.0.0`

---

## 4. The modularity contract

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full text.

1. One component = one role = one inventory group.
2. No role hardcodes an address; everything is derived from the inventory.
3. Only `kafka_kraft` touches the brokers; satellite roles never restart them.
4. Every role ships: a commented `defaults/main.yml`, `verify.yml`, a molecule
   scenario, and a `docs/` page.
5. Broker-side needs (topics, ACLs) are declared by the component and applied
   by the shared `kafka_topics` role.

---

## 5. Known pitfalls (the core of docs/08)

- Wrong `advertised.listeners` → clients cannot connect (in the lab EXTERNAL
  must advertise `localhost:3909N`)
- `controller.quorum.voters` differing between nodes → the quorum never forms
- Accidentally reformatting storage → all metadata is lost
- `min.insync.replicas=2` with `acks=all`: writes stop when a single broker is
  down — a deliberate trade-off
- `sysctl`/THP tasks leaking into the host in the lab → `kafka_tune_os: false`
- Oversized heaps → GC pauses; leave room for the page cache
- WSL has 7 GB of RAM: the lab profile uses a 512m broker heap
