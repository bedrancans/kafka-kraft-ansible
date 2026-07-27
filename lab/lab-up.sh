#!/usr/bin/env bash
#
# Lab ortamını ayağa kaldırır: kafka-lab network'ü + 4 systemd container.
# Ansible bunlara SSH ile bağlanır, tıpkı gerçek VM'lerde olduğu gibi.
#
# Kullanım:
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

# Container içi port -> WSL host portu.
# Kafka EXTERNAL listener'ı her broker'da 39092; dışarıya 39091/2/3 olarak çıkar.
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
    echo "HATA: '$ENGINE' bulunamadı. CONTAINER_ENGINE ile değiştirebilirsin." >&2
    exit 1
}

# 1) SSH anahtarı
if [[ ! -f "$SSH_KEY" ]]; then
    log "SSH anahtarı üretiliyor: $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C 'kafka-lab' >/dev/null
fi
cp "${SSH_KEY}.pub" "${LAB_DIR}/authorized_keys"

# 2) İmaj
log "İmaj build ediliyor: $IMAGE"
"$ENGINE" build -t "$IMAGE" -f "${LAB_DIR}/Containerfile" "$LAB_DIR"

# 3) Network (aardvark-dns sayesinde container adları hostname olarak çözülür)
if ! "$ENGINE" network exists "$NETWORK" >/dev/null 2>&1; then
    log "Network oluşturuluyor: $NETWORK"
    "$ENGINE" network create "$NETWORK" >/dev/null
fi

# 4) Container'lar
for node in "${NODES[@]}"; do
    if "$ENGINE" container exists "$node" >/dev/null 2>&1; then
        log "Mevcut container siliniyor: $node"
        "$ENGINE" rm -f "$node" >/dev/null
    fi
    log "Başlatılıyor: $node (ssh 127.0.0.1:$(ssh_port "$node"))"
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

# 5) SSH hazır olana kadar bekle
log "SSH portları bekleniyor..."
for node in "${NODES[@]}"; do
    port="$(ssh_port "$node")"
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            printf '    %-8s hazır (%s)\n' "$node" "$port"
            break
        fi
        sleep 1
    done
done

cat <<EOF

Lab hazır. Sonraki adım:

    ansible -i inventories/lab all -m ping

Elle bağlanmak için:

    ssh -i ${SSH_KEY} -p 2221 ansible@127.0.0.1

EOF
