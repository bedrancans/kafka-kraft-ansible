# 2. Tarballs and systemd, not containers

## Status

Accepted.

## Context

Kafka has good container images. Running the cluster from them would be less
work than downloading archives, rendering configuration and writing unit
files.

But the point of this repository is to be a deployment someone could put on
real machines, and to be an honest exercise in configuration management. With
containers, Ansible's contribution reduces to writing a compose file: the
interesting parts — verified downloads, generated configuration, service
supervision, resource limits, controlled restarts — all move inside an image
that somebody else built.

## Decision

Every component is installed from its published archive and run under systemd:
the brokers, Kafka Connect, Schema Registry and Kafka UI alike. No container
runtime is part of the deployment.

The lab uses containers, but only as stand-ins for VMs: they run systemd and
sshd, and Ansible reaches them over SSH exactly as it would a real host.

## Consequences

- The roles do the work that server configuration actually involves. Moving to
  real VMs is an inventory change, and that claim is testable rather than
  aspirational.
- Upgrades are a symlink flip, which also makes rollback one — as long as the
  old version's directory is still there, which it is.
- Version pinning and checksum verification are explicit rather than implied
  by an image tag.
- More code than a compose file, and each component's packaging quirks have to
  be dealt with individually: Schema Registry only ships inside a 416 MB
  Confluent archive, and Kafka UI is a Spring Boot jar with its own JDK
  requirement.
- Components on one host can need different Java versions, and they do.
