# Lab ortamı

WSL2 üzerinde, **gerçek VM'lere ne kadar benziyorsa o kadar** benzeyen bir test ortamı.

## Neden container "VM gibi"?

Container'ların içinde gerçek `systemd` ve `sshd` çalışır. Ansible bunlara
`podman exec` ile değil, **SSH ile** bağlanır. Sonuç: roller, template'ler ve
playbook'lar container'da mı VM'de mi çalıştıklarını bilmez.

Prod'a geçmek için tek yapılan şey inventory değiştirmektir:

```
inventories/lab/hosts.yml    → 127.0.0.1:2221-2224 (podman)
inventories/prod/hosts.yml   → gerçek IP'ler:22    (VM)
```

## Kullanım

```bash
./lab/lab-up.sh          # 4 container + network
make ping                # bağlantı testi
./lab/lab-down.sh        # container'ları sil
./lab/lab-down.sh --all  # network ve imajı da sil
```

Docker ile çalıştırmak istersen:

```bash
CONTAINER_ENGINE=docker ./lab/lab-up.sh
```

> Not: docker'da systemd için ek olarak `--privileged --cgroupns=host`
> gerekebilir. Podman `--systemd=always` ile bunu kendi halleder.

## Topoloji

| Container | Rol | SSH (WSL) | Diğer portlar |
|---|---|---|---|
| `kafka-1` | broker + controller | 2221 | 39091 → 39092 |
| `kafka-2` | broker + controller | 2222 | 39092 → 39092 |
| `kafka-3` | broker + controller | 2223 | 39093 → 39092 |
| `tools-1` | Kafka UI / SR / Connect | 2224 | 8080, 8081, 8083 |

Hepsi `kafka-lab` podman network'ünde. `aardvark-dns` sayesinde container'lar
birbirini `kafka-1`, `kafka-2` gibi isimlerle çözer — `advertised.listeners`
bu isimleri kullanır.

## Listener'lar

| Listener | Bind | Advertised | Kim kullanır |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | broker'lar arası, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | WSL host'undan bağlanan client'lar |
| `CONTROLLER` | `:9093` | — | KRaft quorum (dışarı açılmaz) |

## Elle bağlanma

```bash
ssh -i ~/.ssh/kafka_lab -p 2221 ansible@127.0.0.1
```

## Bilinen sınırlar

- **RAM:** WSL'e ayrılan bellek 7 GB civarında. `kafka_heap_size: 512m`
  (bkz. `inventories/lab/group_vars/all/profile.yml`) bu yüzden.
- **OS tuning kapalı:** `kafka_tune_os: false`. `sysctl` ve THP ayarları
  container'da ya işe yaramaz ya da WSL host çekirdeğini etkiler.
  Prod inventory'sinde `true`.
- SSH host anahtarları imaja gömülüdür, tüm node'larda aynıdır.
  Lab için kabul edilebilir; `host_key_checking` zaten kapalı.
