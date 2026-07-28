# Installation

## In the lab

```bash
make lab-up    # four containers with systemd and sshd
make ping      # confirm Ansible can reach them
make site      # deploy everything
make verify    # check it worked
```

That is the whole thing. The cluster comes up on plaintext listeners; see
[Security](06-security.md) for turning TLS and authentication on.

## On real hosts

### 1. Describe the machines

Copy `inventories/lab/` to `inventories/prod/` and edit `hosts.yml`:

```yaml
all:
  vars:
    ansible_user: deploy
    ansible_ssh_private_key_file: ~/.ssh/id_ed25519
  children:
    kafka_brokers:
      hosts:
        kafka-1.internal:
          kafka_node_id: 1
          kafka_external_advertised_port: 9092
        kafka-2.internal:
          kafka_node_id: 2
          kafka_external_advertised_port: 9092
        kafka-3.internal:
          kafka_node_id: 3
          kafka_external_advertised_port: 9092
    kafka_controllers:
      hosts:
        kafka-1.internal:
        kafka-2.internal:
        kafka-3.internal:
    kafka_ui:
      hosts:
        tools-1.internal:
```

`kafka_node_id` must be unique and stable. Preflight asserts uniqueness; it
cannot check stability, and changing one after the fact means that node loses
its identity in the quorum.

### 2. Set the environment profile

`inventories/prod/group_vars/all/profile.yml`:

```yaml
kafka_env_profile: production
kafka_heap_size: 6g
kafka_tune_os: true
```

`kafka_tune_os: true` is what applies the sysctl settings and disables
transparent huge pages. The lab leaves it off because those settings either do
nothing in a container or leak into the host kernel.

### 3. Point the addresses at the right interfaces

`inventories/prod/group_vars/all/cluster.yml`:

```yaml
kafka_internal_host: "{{ ansible_default_ipv4.address }}"
kafka_controller_host: "{{ ansible_default_ipv4.address }}"
kafka_external_advertised_host: "{{ inventory_hostname }}"
```

The lab uses container names for all three because they resolve everywhere.
On real hosts the internal listener should advertise a private address and the
external one whatever clients actually reach.

### 4. Generate a cluster id

```bash
make cluster-id
```

Put it in `inventories/prod/group_vars/all/cluster_id.yml`. It is generated
once and never changed: the brokers format their storage with it, and every
component checks it to confirm it joined the cluster it was pointed at.

### 5. Pin the distribution

`inventories/prod/group_vars/all/cluster.yml` carries the version and its
checksum:

```yaml
kafka_distribution_version: "4.3.1"
kafka_distribution_sha512: "c7d7b231..."
```

The checksum comes from Apache:

```bash
curl -s https://downloads.apache.org/kafka/4.3.1/kafka_2.13-4.3.1.tgz.sha512 \
  | tr -d ' \n' | sed 's/^.*tgz://' | tr 'A-Z' 'a-z'
```

`get_url` refuses to keep a file that does not match, which is what turns
"downloaded a file" into "downloaded the right file".

### 6. Deploy

```bash
ansible-playbook -i inventories/prod playbooks/site.yml
ansible-playbook -i inventories/prod playbooks/verify.yml
```

The first run deploys all brokers at once. That is deliberate: forming a
quorum for the first time needs a majority up together, and one at a time
would leave the first broker waiting for peers Ansible has not reached yet.

**Every run after that is different.** A configuration change applied
all-at-once restarts the whole cluster simultaneously:

```bash
ansible-playbook -i inventories/prod playbooks/site.yml -e kafka_serial=1
```

## What gets installed where

```
/opt/kafka-4.3.1/          the distribution
/opt/kafka                 symlink to the active version
/etc/kafka/                server.properties, kafka.env, tls/
/var/lib/kafka/            the service account's home
/var/lib/kafka/data/       log.dirs — the messages themselves
/var/log/kafka/            the broker's own log4j output
```

The data directory is deliberately *inside* the home directory rather than
being it. Anything that writes to a service account's home — Ansible's own
temporary directory, for one — would otherwise land in `log.dirs`, and Kafka
refuses to start when it finds anything there that is not a topic partition.

## Adding a component

Covered separately in [Extending](09-extending.md), because the interesting
part is that it does not involve the cluster.
