# 3. TLS material is PEM, not JKS or PKCS12

## Status

Accepted.

## Context

Java services traditionally read certificates from a JKS or PKCS12 keystore,
which means generating keys and certificates, converting them with `keytool`,
choosing store passwords, and distributing both the store and the password.

Kafka has read PEM directly since 2.7 (`ssl.keystore.type=PEM`), and every
component in this repository — the brokers, Schema Registry, Kafka Connect,
Kafka UI — is a Kafka client.

## Decision

Certificates and keys are distributed as PEM. The keystore file holds the
certificate followed by its private key; the truststore is the CA certificate.

## Consequences

- No `keytool` step, no store passwords to manage or leak, and a certificate
  that can be inspected with `openssl x509` without conversion.
- The private key is unencrypted, so file permissions are what protect it:
  `0640`, owned by root and readable by the service group.
- Keys must be PKCS#8. `community.crypto` produces PKCS#1 by default and Kafka
  rejects it with `algid parse error, not a sequence`, which does not
  obviously mean "wrong key encoding".
- A component that only reads from Kafka needs the truststore alone. On a host
  running several components the directory is `0755` so each can read the CA
  certificate, while the private key stays `0640`.
