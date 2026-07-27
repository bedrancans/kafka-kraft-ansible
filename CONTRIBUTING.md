# Katkı ve tasarım kuralları

Bu repo'nun tek iddiası var: **çalışan bir Kafka cluster'ına, cluster'ı
durdurmadan yeni bileşen eklenebilmesi.** Aşağıdaki beş kural bu iddiayı
mümkün kılan şeydir; yeni bir rol eklerken hepsine uyulması beklenir.

## Modülerlik sözleşmesi

### 1. Bir bileşen = bir rol = bir inventory grubu

Yeni bir bileşen eklemek, mevcut rollerin içine dokunmayı **gerektirmez**.
`roles/<bileşen>/` + `playbooks/site.yml`'de kendi play'i + inventory'de
kendi grubu. Grup boşsa play atlanır, yani rol repoda dursa bile kurulmaz.

### 2. Hiçbir rol adres hardcode etmez

Broker listesi, Schema Registry URL'i, Connect adresi — hepsi inventory'den
türetilir. Örnek (`inventories/*/group_vars/all/cluster.yml`):

```yaml
kafka_bootstrap_servers: >-
  {{ groups['kafka_brokers']
     | map('extract', hostvars, 'kafka_internal_host')
     | map('regex_replace', '$', ':' ~ kafka_internal_port)
     | join(',') }}
```

Broker'ı 3'ten 5'e çıkarmak = `hosts.yml`'e iki satır eklemek. Başka hiçbir
dosyaya dokunulmaz.

### 3. Broker'a yalnızca `kafka_kraft` rolü dokunur

Uydu bileşen rolleri (UI, Schema Registry, Connect) broker restart **edemez**.
Broker'ın yeniden başlaması yalnızca planlı bir işlemdir ve
`playbooks/rolling-restart.yml` üzerinden yapılır.

Tek istisna: listener/güvenlik değişiklikleri (Faz 8). O da bilinçli bir
rolling restart'tır, yan etki değil.

### 4. Her rolün dört zorunlusu vardır

| Dosya | Neden |
|---|---|
| `defaults/main.yml` — her değişken yorumlu | `docs/04-configuration-reference.md`'nin kaynağı |
| `tasks/verify.yml` | rol kendi kendini doğrulayabilmeli |
| `molecule/` senaryosu | CI'da test edilebilmeli |
| `docs/` sayfası | dökümansız rol merge edilmez |

### 5. Broker tarafı ihtiyaçları bildirilir, uygulanmaz

Bir bileşenin topic'e veya ACL'e ihtiyacı varsa (örn. Connect'in
`connect-configs`/`connect-offsets`/`connect-status` topic'leri), bunu kendi
`defaults`'unda **bildirir**; oluşturma işini ortak `kafka_topics` rolü yapar.
Böylece sıralama ve idempotency tek yerde çözülür.

## Lab vs prod farkları

Rol içinde "lab mı prod mu" sorgusu yapılmaz. Tüm farklar
`inventories/*/group_vars/all/profile.yml` içindeki bayraklarda toplanır:

| Değişken | lab | prod |
|---|---|---|
| `kafka_heap_size` | `512m` | `6g` |
| `kafka_tune_os` | `false` | `true` |

## Çalıştırmadan önce

```bash
make lint     # yamllint + ansible-lint
make lab-up   # temiz lab
make site     # kurulum
make verify   # uçtan uca test
```

Playbook'un **iki kez** çalıştırıldığında ikincisinde `changed=0` vermesi
zorunludur. Idempotency bu repo'da bir tercih değil, kabul kriteridir.

## Commit ve sürüm

- Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `ci:`)
- Her faz sonunda tag: `v0.1.0`, `v0.2.0`, ... (bkz. [PLAN.md](PLAN.md))
