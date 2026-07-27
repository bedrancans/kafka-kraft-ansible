#!/usr/bin/env bash
#
# Lab ortamını kaldırır.
#   ./lab/lab-down.sh          -> container'ları siler
#   ./lab/lab-down.sh --all    -> network ve imajı da siler
#
set -euo pipefail

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${LAB_IMAGE:-kafka-lab-node:24.04}"
NETWORK="${LAB_NETWORK:-kafka-lab}"
NODES=(kafka-1 kafka-2 kafka-3 tools-1)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

for node in "${NODES[@]}"; do
    if "$ENGINE" container exists "$node" >/dev/null 2>&1; then
        log "Siliniyor: $node"
        "$ENGINE" rm -f "$node" >/dev/null
    fi
done

if [[ "${1:-}" == "--all" ]]; then
    "$ENGINE" network exists "$NETWORK" >/dev/null 2>&1 && {
        log "Network siliniyor: $NETWORK"
        "$ENGINE" network rm "$NETWORK" >/dev/null
    }
    "$ENGINE" image exists "$IMAGE" >/dev/null 2>&1 && {
        log "İmaj siliniyor: $IMAGE"
        "$ENGINE" rmi "$IMAGE" >/dev/null
    }
fi

log "Lab kaldırıldı."
