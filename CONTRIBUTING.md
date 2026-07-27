# Contributing and design rules

This repo makes exactly one claim: **you can add a new component to a running
Kafka cluster without taking the cluster down.** The five rules below are what
make that claim true, and every new role is expected to follow them.

## The modularity contract

### 1. One component = one role = one inventory group

Adding a component must **never** require editing an existing role.
It gets `roles/<component>/`, its own play in `playbooks/site.yml`, and its own
inventory group. If the group is empty the play is skipped, so a role can sit
in the repo without being deployed.

### 2. No role hardcodes an address

The broker list, the Schema Registry URL, the Connect endpoint — all of them
are derived from the inventory. Example
(`inventories/*/group_vars/all/cluster.yml`):

```yaml
kafka_bootstrap_servers: >-
  {{ groups['kafka_brokers']
     | map('extract', hostvars, 'kafka_internal_host')
     | map('regex_replace', '$', ':' ~ kafka_internal_port)
     | join(',') }}
```

Going from three brokers to five means adding two lines to `hosts.yml`.
Nothing else changes.

### 3. Only `kafka_kraft` touches the brokers

Satellite roles (UI, Schema Registry, Connect) **must not** restart brokers.
A broker restart is always a deliberate operation and goes through
`playbooks/rolling-restart.yml`.

The one exception is a listener or security change (phase 8) — which is still a
planned rolling restart, not a side effect.

### 4. Every role ships four things

| File | Why |
|---|---|
| `defaults/main.yml` with every variable commented | it is the source for `docs/04-configuration-reference.md` |
| `tasks/verify.yml` | a role must be able to check itself |
| a `molecule/` scenario | it must be testable in CI |
| a `docs/` page | an undocumented role does not get merged |

### 5. Broker-side needs are declared, not applied

If a component needs topics or ACLs (for example Connect's `connect-configs`,
`connect-offsets` and `connect-status`), it **declares** them in its own
`defaults`; the shared `kafka_topics` role creates them. Ordering and
idempotency are then solved in exactly one place.

## Lab vs production

A role never asks which environment it is in. Every difference lives in
`inventories/*/group_vars/all/profile.yml`:

| Variable | lab | production |
|---|---|---|
| `kafka_heap_size` | `512m` | `6g` |
| `kafka_tune_os` | `false` | `true` |

## Before you push

```bash
make lint     # yamllint + ansible-lint
make lab-up   # clean lab
make site     # deploy
make verify   # end-to-end test
```

Running a playbook **twice** must report `changed=0` on the second run.
Idempotency is not a preference in this repo, it is an acceptance criterion.

## Commits and releases

- Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `ci:`)
- A tag at the end of every phase: `v0.1.0`, `v0.2.0`, … (see [PLAN.md](PLAN.md))
- Documentation and code comments are written in English.
