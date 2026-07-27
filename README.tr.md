# kafka-kraft-ansible

Ansible ile **3 broker'lı, KRaft modunda Apache Kafka** cluster'ı — üzerine
Kafka UI, Schema Registry ve Kafka Connect'i *cluster'ı durdurmadan*
ekleyebilen modüler bir yapı.

🇬🇧 [English README](README.md) · Bu dosya Türkçe çeviridir; repo'nun ana dili
İngilizce'dir.

> **Durum:** yapım aşamasında. Yol haritası ve her fazın kabul kriterleri için
> [PLAN.md](PLAN.md).

## Neden bu repo?

Çoğu Kafka kurulum örneği tek seferlik bir `docker-compose up` gösterir.
Burada amaç farklı:

- **Gerçek VM'lerde çalışacak kurulum** — tarball + systemd, Kafka'nın etrafında
  container sarmalayıcı yok
- **Modülerlik kanıtlanır, iddia edilmez** — Schema Registry çalışan cluster'a
  sıfır broker kesintisiyle eklenir ve bu test edilir
- **Idempotency kabul kriteridir** — playbook ikinci kez çalıştığında `changed=0`
- **İşletme dahil** — rolling restart, upgrade ve troubleshooting runbook'ları

## Mimari

```
kafka-1 ┐
kafka-2 ├── process.roles = broker,controller   (KRaft combined mode)
kafka-3 ┘
tools-1 ─── Kafka UI (ileride Schema Registry, Kafka Connect)
```

| Listener | Bind | Advertised | Kim kullanır |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | broker'lar arası, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | dışarıdan bağlanan client'lar |
| `CONTROLLER` | `:9093` | — | KRaft quorum (dışarı açılmaz) |

## Hızlı başlangıç

Gereksinimler: `podman` (veya `docker`), `ansible-core`, `make`.

```bash
make lab-up    # WSL'de 4 adet systemd+sshd container ayağa kalkar
make ping      # bağlantı testi
make site      # kurulum
make verify    # uçtan uca doğrulama
```

Kafka UI: <http://localhost:8080> · Broker (host'tan): `localhost:39091`

## Lab ile prod arasındaki fark: sadece inventory

Lab node'ları container ama Ansible onlara **SSH ile** bağlanır ve içlerinde
gerçek `systemd` çalışır. Roller ortamı bilmez. Prod'a geçiş:

```
inventories/lab/hosts.yml    → 127.0.0.1:2221-2224  (podman)
inventories/prod/hosts.yml   → gerçek IP'ler:22     (VM)
```

Profil farkları (heap, OS tuning) tek dosyada toplanır:
`inventories/*/group_vars/all/profile.yml`.

## Yeni bileşen eklemek

```bash
# 1) inventory'ye grubu + host'u ekle
# 2) sadece o bileşeni kur
ansible-playbook -i inventories/lab playbooks/site.yml --tags schema_registry
# 3) UI'ı yeni bileşenden haberdar et — broker'lara tek task gitmez
ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_ui
```

Bunu mümkün kılan tasarım kuralları: [CONTRIBUTING.md](CONTRIBUTING.md)

## Dizin yapısı

```
lab/           WSL test ortamı (Containerfile + up/down scriptleri)
inventories/   lab ve prod envanterleri
playbooks/     site, verify, rolling-restart, upgrade
roles/         common, java, kafka_kraft, kafka_ui, schema_registry, kafka_connect
molecule/      CI test senaryoları
docs/          mimari, kurulum, işletme, güvenlik, troubleshooting
```

## Lisans

MIT
