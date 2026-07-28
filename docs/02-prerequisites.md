# Prerequisites

## Control machine

| Requirement | Version used here | Why |
|---|---|---|
| `ansible-core` | 2.21 | 2.16 is the floor the roles declare |
| `ansible-lint`, `yamllint` | any current | `make lint` runs both |
| `podman` or `docker` | podman 4.9 | the lab only; production needs neither |
| `make`, `git`, `openssh-client` | any | |
| `molecule` + `molecule-plugins[podman]` | 26.6 | `make test` only |

Install the Ansible tooling with pipx so each keeps its own dependencies:

```bash
pipx install --include-deps ansible
pipx install ansible-lint
pipx install yamllint
```

Collections come from `requirements.yml`:

```bash
make deps
```

## Target hosts

| Requirement | Note |
|---|---|
| Ubuntu 24.04 or 22.04, or Debian 12 | `common` asserts the family and fails early on anything else |
| `python3` | Ansible modules run as Python on the target |
| systemd | every component is a unit; `common` asserts it |
| An account with sudo | key-based SSH, no password prompt |
| DNS or `/etc/hosts` entries | every node must resolve every other by the name used in the inventory |

The last one is worth dwelling on. KRaft addresses nodes by hostname —
`controller.quorum.voters`, `advertised.listeners`, the bootstrap list are all
names. If resolution is broken the quorum never forms, and the error Kafka
logs for it does not say "DNS". The `kafka` role's preflight checks this
before touching anything.

## Sizing

| | Lab | Production starting point |
|---|---|---|
| Broker heap | 512m | 6g |
| RAM per broker | ~1 GB | 32 GB |
| Disk | whatever the container has | dedicated volume for `log.dirs`, XFS |
| CPU | shared | 8 cores |

Kafka reads most data from the page cache, so memory beyond the heap is not
spare — it is where the cluster's read performance comes from. A 6 GB heap on
a 32 GB machine is deliberate, not conservative: a larger heap steals from the
page cache and lengthens GC pauses.

`kafka_heap_size` lives in `group_vars/all/profile.yml` alongside
`kafka_tune_os`, which is the only other thing that differs between
environments.

## Network

| Port | Component | Reachable from |
|---|---|---|
| 9094 | Kafka `INTERNAL_SSL` | the cluster and the tools node |
| 39092 | Kafka `EXTERNAL_SSL` | wherever clients live |
| 9093 | Kafka `CONTROLLER` | **the other brokers only** |
| 8080 | Kafka UI | operators |
| 8081 | Schema Registry | the cluster and clients using Avro |
| 8083 | Kafka Connect | operators and the UI |

The controller port is the one to be strict about. It carries the metadata
log, it is authenticated by certificate rather than by password, and it is
never advertised.

## What the lab needs instead

The lab replaces the target hosts with four containers that run systemd and
sshd, so Ansible reaches them over SSH exactly as it would reach a VM. See
[lab/README.md](../lab/README.md). Requirements there are podman and about
4 GB of free memory.
