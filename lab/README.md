# Lab environment

A test environment on WSL2 that stays **as close to real VMs as it can get**.

## Why containers that behave like VMs?

Real `systemd` and `sshd` run inside these containers. Ansible connects over
**SSH**, not `podman exec`. The result: roles, templates and playbooks have no
idea whether they are running in a container or on a VM.

Moving to production is a single change — the inventory:

```
inventories/lab/hosts.yml    → 127.0.0.1:2221-2224 (podman)
inventories/prod/hosts.yml   → real IPs:22         (VMs)
```

## Usage

```bash
./lab/lab-up.sh          # 4 containers + network
make ping                # connectivity check
./lab/lab-down.sh        # remove the containers
./lab/lab-down.sh --all  # also remove the network and image
```

To run it with Docker instead:

```bash
CONTAINER_ENGINE=docker ./lab/lab-up.sh
```

> Note: Docker additionally needs `--privileged --cgroupns=host` for systemd.
> Podman handles this on its own via `--systemd=always`.

## Topology

| Container | Role | SSH (host) | Other ports |
|---|---|---|---|
| `kafka-1` | broker + controller | 2221 | 39091 → 39092 |
| `kafka-2` | broker + controller | 2222 | 39092 → 39092 |
| `kafka-3` | broker + controller | 2223 | 39093 → 39092 |
| `tools-1` | Kafka UI / SR / Connect | 2224 | 8080, 8081, 8083 |

All of them share the `kafka-lab` podman network. Thanks to `aardvark-dns`
the containers resolve each other as `kafka-1`, `kafka-2` and so on —
`advertised.listeners` relies on those names.

## Listeners

| Listener | Bind | Advertised | Consumers |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | brokers, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | clients on the host |
| `CONTROLLER` | `:9093` | — | KRaft quorum (never exposed) |

## Connecting manually

```bash
ssh -i ~/.ssh/kafka_lab -p 2221 ansible@127.0.0.1
```

## Known limitations

- **RAM:** WSL gets around 7 GB, which is why
  `kafka_heap_size: 512m` (see `inventories/lab/group_vars/all/profile.yml`).
- **OS tuning is off:** `kafka_tune_os: false`. Inside a container `sysctl`
  and THP settings are either no-ops or they leak into the host kernel.
  The production inventory sets it to `true`.
- SSH host keys are baked into the image and shared by every node.
  Acceptable for a lab; `host_key_checking` is disabled anyway.

## Molecule and the lab

The molecule scenario uses container names prefixed with `ci-`, because
container names are global per user and molecule's first action is `destroy`.
Without the prefix, `make test` would tear the lab down before starting.

They can run side by side, but not on 8 GB of RAM: two clusters is roughly
7 GB of heap and JVM overhead. Take the lab down first.

```bash
make lab-down
make test
make lab-up
```
