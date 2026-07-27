# kafka-kraft-ansible

[![CI](https://github.com/bedrancans/kafka-kraft-ansible/actions/workflows/ci.yml/badge.svg)](https://github.com/bedrancans/kafka-kraft-ansible/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A three-broker **Apache Kafka cluster in KRaft mode, deployed with Ansible** —
plus a modular layout that lets you add Kafka UI, Schema Registry and Kafka
Connect *without taking the cluster down*.

Every push builds a four-node cluster from scratch, runs the same `site.yml`
an operator would run, converges it twice and fails if the second pass changes
anything.

🇹🇷 [Türkçe README](README.tr.md)

> **Status:** work in progress. See [PLAN.md](PLAN.md) for the roadmap and the
> acceptance criteria of each phase.

## Why this repo?

Most Kafka examples show a one-shot `docker-compose up`. The goal here is
different:

- **A deployment that runs on real VMs** — tarballs and systemd, no container
  wrapper around Kafka itself
- **Modularity is proven, not claimed** — Schema Registry is added to a running
  cluster with zero broker downtime, and that is tested
- **Idempotency is an acceptance criterion** — the second run must report
  `changed=0`
- **Operations included** — rolling restart, upgrade and troubleshooting
  runbooks

## Architecture

```
kafka-1 ┐
kafka-2 ├── process.roles = broker,controller   (KRaft combined mode)
kafka-3 ┘
tools-1 ─── Kafka UI (later: Schema Registry, Kafka Connect)
```

| Listener | Bind | Advertised | Consumers |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | brokers, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | clients outside the cluster |
| `CONTROLLER` | `:9093` | — | KRaft quorum (never exposed) |

## Quick start

Requirements: `podman` (or `docker`), `ansible-core`, `make`.

```bash
make lab-up    # four systemd + sshd containers come up on WSL
make ping      # connectivity check
make site      # deploy
make verify    # end-to-end verification
```

Kafka UI: <http://localhost:8080> · Broker from the host: `localhost:39091`

## Lab and production differ only by inventory

The lab nodes are containers, but Ansible reaches them over **SSH** and real
`systemd` runs inside them. Roles never learn which environment they are in.
Moving to production:

```
inventories/lab/hosts.yml    → 127.0.0.1:2221-2224  (podman)
inventories/prod/hosts.yml   → real IPs:22          (VMs)
```

Profile differences (heap size, OS tuning) live in a single file:
`inventories/*/group_vars/all/profile.yml`.

## Adding a component

```bash
# 1) add the group and host to the inventory
# 2) deploy just that component
ansible-playbook -i inventories/lab playbooks/site.yml --tags schema_registry
# 3) let the UI discover it — not a single task touches the brokers
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_ui
```

The design rules that make this possible: [CONTRIBUTING.md](CONTRIBUTING.md)

## Layout

```
lab/           WSL test environment (Containerfile + up/down scripts)
inventories/   lab and production inventories
playbooks/     site, verify, rolling-restart, upgrade
roles/         common, java, kafka_kraft, kafka_ui, schema_registry, kafka_connect
molecule/      CI test scenarios
docs/          architecture, installation, operations, security, troubleshooting
```

## License

MIT
