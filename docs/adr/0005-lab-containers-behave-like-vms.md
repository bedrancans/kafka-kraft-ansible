# 5. Lab containers run systemd and are reached over SSH

## Status

Accepted.

## Context

The lab has to fit on a laptop, so the three brokers and the tools node are
containers. That leaves a choice about how Ansible talks to them.

The obvious option is the podman connection plugin: no sshd, no keys, no
published ports. It is also how molecule works by default.

The cost is that the roles would then only ever be exercised against something
that is not a VM. systemd would never be tested — a container without an init
system cannot run `systemctl` — and "these roles work on real machines" would
be an assertion with nothing behind it.

## Decision

The lab image runs real systemd as PID 1 and a real sshd. Ansible connects
over SSH with a generated key, to a published port.

Moving to production is then a different inventory and nothing else:

```
inventories/lab/hosts.yml    127.0.0.1:2221-2224   (podman)
inventories/prod/hosts.yml   real IPs:22           (VMs)
```

## Consequences

- Every role is exercised against the same service manager it will meet in
  production. Unit files, `TimeoutStopSec`, `LimitNOFILE` and restart
  behaviour are all real.
- The image needs `dbus`, or `systemctl` only works as root — it falls back to
  systemd's private socket, and an unprivileged user gets "Failed to connect
  to bus".
- The image keeps its apt lists. Deleting them is a container-size habit with
  no equivalent on a VM, and it leaves apt's freshness stamp behind so tasks
  using `cache_valid_time` skip an update they needed.
- Containers must share a network. Rootless podman otherwise gives every
  container the same address, and a node reaches itself while believing it
  reached a peer.
- The molecule scenario *does* use the podman connection, deliberately: it
  tests role logic in CI, while the lab tests the SSH and systemd path. They
  answer different questions.
