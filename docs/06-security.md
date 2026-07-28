# Security

## What is enabled

| Layer | Mechanism |
|---|---|
| Encryption in transit | TLS on every listener |
| Client authentication | SASL/SCRAM-SHA-512 |
| Broker-to-quorum authentication | mutual TLS, principal from the certificate subject |
| Authorization | `StandardAuthorizer`, deny by default |
| Secrets | `ansible-vault` |

```
INTERNAL_SSL  :9094   SASL_SSL   brokers, UI, Schema Registry, Connect
EXTERNAL_SSL  :39092  SASL_SSL   clients outside the cluster
CONTROLLER    :9093   SSL        the Raft quorum, mutual TLS
```

## Certificates

A private CA is generated on the control machine and never leaves it. Each
host gets a key and a certificate signed by that CA, distributed as PEM.

```bash
ansible-playbook -i inventories/lab playbooks/tls.yml
```

Safe on a running cluster: it issues material without changing any service
configuration, which is also what makes it the renewal procedure.

The certificate's subject is `CN=<inventory hostname>`, and the SAN covers
both the name used inside the cluster and the one used from outside. The
subject matters beyond identification: on the controller listener it *is* the
principal, mapped by `ssl.principal.mapping.rules`.

PEM rather than JKS — see [ADR 0003](adr/0003-pem-not-jks.md). The private key
is unencrypted, so its file mode is what protects it: `0640`, root-owned,
readable by the service group.

## Accounts

| Account | Used by | May |
|---|---|---|
| `admin` | operators and the tooling | everything (super user) |
| `kafka-1/2/3` | the brokers | everything (super users) |
| `kafka-ui` | Kafka UI | read topics and groups, describe the cluster |
| `schema-registry` | Schema Registry | read and write `_schemas` |
| `kafka-connect` | Kafka Connect | read and write `connect-*` |
| `client` | external clients | read and write `rolling-test` |

Every broker has its own credential rather than sharing one, so a leaked
credential identifies which host leaked it and can be rotated alone.

```bash
ansible-playbook -i inventories/lab playbooks/scram-users.yml
```

Idempotent, and safe on a running cluster. Run it *before* a listener starts
requiring SASL: the credentials have to be in the metadata before anything
asks for them.

Passwords live in `inventories/<env>/group_vars/all/vault.yml`. The vault
password is in `.vault_pass`, which is gitignored — an encrypted file and its
key in the same repository is not encryption.

## Authorization

The authorizer is **off by default**, and it has to be. A fresh cluster has no
ACLs, and `kafka-acls.sh` cannot create any until an authorizer exists — so a
default of on makes a new cluster undeployable: the authorizer denies every
component, and the tool that would fix that needs the cluster working first.

Once it is on, `allow.everyone.if.no.acl.found` is false: anything without a
matching rule is denied. The brokers and `admin` are super users, because the authorizer
applies to them too and a broker that cannot manage the cluster cannot start.

```bash
ansible-playbook -i inventories/lab playbooks/acls.yml
```

Rules are declared in `roles/kafka_acls/defaults/main.yml`, one entry per
grant. The UI is given no `Write` anywhere, deliberately.

Verified by trying:

```
client   -> rolling-test   allowed   (has an ACL)
client   -> connect-demo   denied    (has none)
kafka-ui -> rolling-test   denied    (read-only)
no credentials             refused at the transport
```

## Turning security on

The order is not guessable and getting it wrong locks the cluster out of
itself.

### 1. Issue certificates and create accounts

```bash
ansible-playbook -i inventories/lab playbooks/tls.yml
ansible-playbook -i inventories/lab playbooks/scram-users.yml
```

Neither changes a running service.

### 2. Add the secure listener

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka \
  -e kafka_listener_profile=add-secure -e kafka_serial=1
```

It exists; nothing uses it yet.

### 3. Move traffic onto it

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka \
  -e kafka_listener_profile=switch -e kafka_serial=1
ansible-playbook -i inventories/lab playbooks/site.yml \
  --tags kafka_ui,schema_registry,kafka_connect -e kafka_listener_profile=switch
```

Inter-broker traffic and the components are now authenticated and encrypted.

### 4. Remove the plaintext listeners

```bash
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka \
  -e kafka_listener_profile=secure -e kafka_serial=1
```

Then set `kafka_listener_profile: secure` in
`group_vars/all/security.yml` so it stays that way.

Steps 2 to 4 are rolling restarts with no downtime. Changing a listener's
protocol in place is what does not work: half the brokers would speak one
protocol and half the other on the same port.

### 5. Authorize

```bash
# permissive: the authorizer exists, nothing is denied yet
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka -e kafka_serial=1 \
  -e kafka_authorizer_enabled=true -e kafka_allow_everyone_if_no_acl_found=true

# the rules
ansible-playbook -i inventories/lab playbooks/acls.yml

# enforce
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka -e kafka_serial=1
```

The permissive step is not optional. `kafka-acls.sh` refuses to work without
an authorizer, and an authorizer with no rules denies everything that is not a
super user — which is every component.

**The controller listener changes protocol in this sequence too, and that one
is a coordinated restart rather than a rolling one.** It cannot stay
unauthenticated once the authorizer is on, and it cannot migrate gradually.
See [ADR 0004](adr/0004-controller-listener-tls.md).

## What is not covered

- **Kafka UI has no authentication in front of it.** Anyone who reaches port
  8080 sees the cluster. It authenticates *to* Kafka with a read-only account,
  so it cannot be used to write, but the port should not be exposed.
- **Schema Registry and Connect REST APIs are unauthenticated** for the same
  reason and with the same caveat.
- **No encryption at rest.** Disk-level encryption is the host's job.
- **The CA is self-signed and offline-ish.** It sits in `.tls/` on the control
  machine. A real deployment would use an existing PKI.
