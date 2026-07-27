#!/usr/bin/env bash
#
# Brings the lab up: the kafka-lab network plus four systemd containers.
# Ansible connects to them over SSH, exactly as it would to real VMs.
#
# Usage:
#   ./lab/lab-up.sh
#   CONTAINER_ENGINE=docker ./lab/lab-up.sh
#
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${LAB_IMAGE:-kafka-lab-node:24.04}"
NETWORK="${LAB_NETWORK:-kafka-lab}"
SSH_KEY="${LAB_SSH_KEY:-$HOME/.ssh/kafka_lab}"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODES=(kafka-1 kafka-2 kafka-3 tools-1)

ssh_port() {
    case "$1" in
        kafka-1) echo 2221 ;;
        kafka-2) echo 2222 ;;
        kafka-3) echo 2223 ;;
        tools-1) echo 2224 ;;
    esac
}

# Container port -> host port.
# The Kafka EXTERNAL listener is 39092 inside every broker and is published
# as 39091/39092/39093 on the host.
extra_ports() {
    case "$1" in
        kafka-1) echo "-p 127.0.0.1:39091:39092" ;;
        kafka-2) echo "-p 127.0.0.1:39092:39092" ;;
        kafka-3) echo "-p 127.0.0.1:39093:39092" ;;
        tools-1) echo "-p 127.0.0.1:8080:8080 -p 127.0.0.1:8081:8081 -p 127.0.0.1:8083:8083" ;;
    esac
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

command -v "$ENGINE" >/dev/null 2>&1 || {
    echo "ERROR: '$ENGINE' not found. Override it with CONTAINER_ENGINE." >&2
    exit 1
}

# 1) SSH key
if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C 'kafka-lab' >/dev/null
fi
cp "${SSH_KEY}.pub" "${LAB_DIR}/authorized_keys"

# 2) Image
log "Building image: $IMAGE"
"$ENGINE" build -t "$IMAGE" -f "${LAB_DIR}/Containerfile" "$LAB_DIR"

# 3) Network (aardvark-dns resolves container names as hostnames)
if ! "$ENGINE" network exists "$NETWORK" >/dev/null 2>&1; then
    log "Creating network: $NETWORK"
    "$ENGINE" network create "$NETWORK" >/dev/null
fi

# 4) Containers
for node in "${NODES[@]}"; do
    if "$ENGINE" container exists "$node" >/dev/null 2>&1; then
        log "Removing existing container: $node"
        "$ENGINE" rm -f "$node" >/dev/null
    fi
    log "Starting: $node (ssh 127.0.0.1:$(ssh_port "$node"))"
    # shellcheck disable=SC2046
    "$ENGINE" run -d \
        --name "$node" \
        --hostname "$node" \
        --network "$NETWORK" \
        --systemd=always \
        -p "127.0.0.1:$(ssh_port "$node"):22" \
        $(extra_ports "$node") \
        "$IMAGE" >/dev/null
done

# 5) Wait until SSH is accepting connections
log "Waiting for SSH..."
for node in "${NODES[@]}"; do
    port="$(ssh_port "$node")"
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            printf '    %-8s ready (%s)\n' "$node" "$port"
            break
        fi
        sleep 1
    done
done

cat <<EOF

Lab is ready. Next step:

    ansible -i inventories/lab all -m ping

To connect manually:

    ssh -i ${SSH_KEY} -p 2221 ansible@127.0.0.1

EOF
