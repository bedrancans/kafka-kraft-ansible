# Operations

## Restarting the cluster

```bash
ansible-playbook -i inventories/lab playbooks/rolling-restart.yml
```

One broker at a time, waiting between each for every partition to regain a
full set of in-sync replicas. That wait is the whole point: with
`min.insync.replicas=2`, one broker out of the ISR is survivable and two at
once stops producers.

The playbook refuses to start if the cluster is already degraded, and
`any_errors_fatal` stops the rollout the moment a node does not come back
rather than working through the rest.

Measured: a producer writing continuously with `acks=all` through a restart of
all three brokers sent 7562 messages, had 7562 acknowledged, and the cluster
held 7562.

### When the guard is in the way

During a recovery the cluster *is* degraded — that is why you are there.

```bash
ansible-playbook -i inventories/lab playbooks/rolling-restart.yml --skip-tags precheck
```

A guard that cannot be bypassed is a liability during an incident.

## Applying a configuration change

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka -e kafka_serial=1
```

`kafka_serial` defaults to all-at-once, which is right for the first deploy
and wrong for everything after. Without it a config change restarts all three
brokers within seconds of each other.

## Upgrading

```bash
SHA=$(curl -s https://downloads.apache.org/kafka/4.3.2/kafka_2.13-4.3.2.tgz.sha512 \
      | tr -d ' \n' | sed 's/^.*tgz://' | tr 'A-Z' 'a-z')

ansible-playbook -i inventories/lab playbooks/upgrade.yml \
  -e kafka_version=4.3.2 -e kafka_archive_sha512="$SHA"
```

Two stages. The new version is downloaded and unpacked on every broker first,
which is safe on a running one; only then is the symlink flipped and the
service restarted, one node at a time with the same health wait as a rolling
restart. A failed download therefore fails before anything has restarted
rather than halfway through the cluster.

Both the version and the checksum are required. The role's defaults belong to
the version currently installed, and inheriting them would verify a new
archive against an old hash.

### Rolling back

Every version keeps its own directory under `/opt`, so a rollback is the same
playbook pointed at the previous version — no download needed.

```bash
ansible-playbook -i inventories/lab playbooks/upgrade.yml --skip-tags precheck \
  -e kafka_version=4.3.1 -e kafka_archive_sha512="$OLD_SHA"
```

**Downgrading across a metadata version does not work.** Moving 4.3.1 → 4.2.1
fails with `UnsupportedVersionException: Can't read version 4 of
BrokerEndpoint`: the metadata log was written by the newer release and the
older binaries cannot read it. Going back across that boundary is a
restore-from-backup operation, not a symlink flip.

That failure is worth knowing what it looks like, because the safety nets
behaved: the rollout stopped at the first node, the other two kept serving,
the quorum elected a new leader, and the same playbook put the failed node
back.

## Health checks

```bash
K="podman exec kafka-1 /opt/kafka/bin"
ADM="--command-config /etc/kafka/admin.properties"

# Empty output means every partition is fully replicated.
$K/kafka-topics.sh --bootstrap-server kafka-1:9094 $ADM \
  --describe --under-replicated-partitions

# LeaderId set and MaxFollowerLag near zero.
$K/kafka-metadata-quorum.sh --bootstrap-server kafka-1:9094 $ADM describe --status

# What is actually running.
podman exec kafka-1 cat /etc/kafka/installed-version
podman exec kafka-1 readlink /opt/kafka
```

Or all of it at once:

```bash
make verify
```

## Managing topics

Topics are declared, not created by hand. Components declare theirs in
`roles/<component>/vars/required_topics.yml`; anything cluster-wide goes in
`group_vars/all/topics.yml`. Then:

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_topics
```

The role creates what is missing and reconciles topic configuration. It
deliberately does **not** change partition count or replication factor on an
existing topic — adding partitions changes which partition a key hashes to,
and changing replication needs a reassignment plan. A mismatch is reported and
left alone.

## Replacing a broker

1. Give the replacement the same `kafka_node_id` in the inventory.
2. Issue it a certificate: `ansible-playbook playbooks/tls.yml --limit <host>`.
3. Deploy: `ansible-playbook playbooks/site.yml --tags kafka --limit <host>`.
4. Wait for replication to catch up before touching anything else:
   `--under-replicated-partitions` must come back empty.

The node id is what ties a broker to its place in the quorum. A replacement
with a new id is a new member, not a replacement.

## When a disk fills up

`log.dirs` filling stops the broker. In order of preference:

1. Lower `kafka_log_retention_hours` for the offending topic and let retention
   reclaim space.
2. Delete a topic that should not exist.
3. Add a disk and extend the volume.

Deleting log segments by hand is how a partition ends up unreadable.

## Rotating credentials

SCRAM passwords live in `inventories/<env>/group_vars/all/vault.yml`.

```bash
ansible-vault edit inventories/lab/group_vars/all/vault.yml
ansible-playbook -i inventories/lab playbooks/scram-users.yml
```

Changing a password creates the new credential immediately. Components using
that account need their configuration re-rendered and to be restarted; the
brokers do not, unless it was a broker's own credential, in which case it is a
rolling restart.

## Renewing certificates

```bash
ansible-playbook -i inventories/lab playbooks/tls.yml
ansible-playbook -i inventories/lab playbooks/rolling-restart.yml
```

Certificates are valid for 825 days and the CA for ten years. An expired
broker certificate stops the broker, because the controller listener uses it
to authenticate to the quorum.
