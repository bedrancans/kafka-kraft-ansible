#!/usr/bin/env bash
#
# Tears the lab down.
#   ./lab/lab-down.sh          -> remove the containers
#   ./lab/lab-down.sh --all    -> also remove the network and the image
#
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${LAB_IMAGE:-kafka-lab-node:24.04}"
NETWORK="${LAB_NETWORK:-kafka-lab}"
NODES=(kafka-1 kafka-2 kafka-3 tools-1)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

for node in "${NODES[@]}"; do
    if "$ENGINE" container exists "$node" >/dev/null 2>&1; then
        log "Removing: $node"
        "$ENGINE" rm -f "$node" >/dev/null
    fi
done

if [[ "${1:-}" == "--all" ]]; then
    "$ENGINE" network exists "$NETWORK" >/dev/null 2>&1 && {
        log "Removing network: $NETWORK"
        "$ENGINE" network rm "$NETWORK" >/dev/null
    }
    "$ENGINE" image exists "$IMAGE" >/dev/null 2>&1 && {
        log "Removing image: $IMAGE"
        "$ENGINE" rmi "$IMAGE" >/dev/null
    }
fi

log "Lab torn down."
