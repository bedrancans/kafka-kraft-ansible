# kafka-kraft-ansible — Uygulama Planı

3 broker'lı KRaft modunda Apache Kafka cluster'ını Ansible ile kurmak, üzerine
Kafka UI eklemek ve sonradan Schema Registry / Kafka Connect gibi bileşenleri
**cluster'ı durdurmadan** ekleyebilmek.

Lab ortamı WSL2 + podman; ancak kurulumun tamamı gerçek VM'lerde çalışacak
şekilde tasarlanır. Lab ile prod arasındaki tek fark inventory dosyasıdır.

---

## 0. Sabitlenen kararlar

| Konu | Karar | Gerekçe |
|---|---|---|
| Kafka sürümü | 4.x (kesin sürüm Faz 2 başında pinlenir) | KRaft-only, ZooKeeper yok |
| Topoloji | 3 node, `process.roles=broker,controller` (combined) | 3 node için standart; rol `isolated`'ı da destekler |
| Kurulum yöntemi | tarball + systemd (tüm bileşenler) | container-in-container'dan kaçınmak, tek tutarlı model |
| Java | OpenJDK 21 (`openjdk-21-jre-headless`, apt) | Kafka 4.x broker'ı Java 17+ ister |
| Lab motoru | podman 4.9 + netavark/aardvark-dns | kurulu, rootless, systemd container'da sorunsuz |
| Bağlantı | SSH (container'lara da SSH ile) | rollerin VM/container farkını görmemesi için |
| Güvenlik | Faz 1–7 PLAINTEXT, Faz 8'de SASL/SCRAM + TLS | önce çalışan cluster, sonra sertleştirme |
| Quorum | statik `controller.quorum.voters` | daha az sürpriz; dinamik quorum ADR olarak yazılır |

### Bileşenler ve kurulum biçimi

| Bileşen | Kaynak | Servis |
|---|---|---|
| Kafka broker + controller | Apache Kafka tarball | `kafka.service` |
| Kafka Connect | **aynı tarball** (`connect-distributed.sh`) | `kafka-connect.service` |
| Schema Registry | Confluent Community tarball | `schema-registry.service` |
| Kafka UI | kafbat/kafka-ui jar (provectus arşivlendi) | `kafka-ui.service` |

---

## 1. Lab port ve isim haritası

Podman network: `kafka-lab` (aardvark-dns sayesinde container adları hostname olarak çözülür).

| Container | Hostname | SSH (WSL) | EXTERNAL Kafka | Servis portu |
|---|---|---|---|---|
| kafka-1 | `kafka-1` | 2221 | 39091 → 39092 | 9092 / 9093 (iç) |
| kafka-2 | `kafka-2` | 2222 | 39092 → 39092 | 9092 / 9093 (iç) |
| kafka-3 | `kafka-3` | 2223 | 39093 → 39092 | 9092 / 9093 (iç) |
| tools-1 | `tools-1` | 2224 | — | UI 8080, SR 8081, Connect 8083 |

### Listener tasarımı (baştan üç listener)

| Listener | Bind | Advertised | Kim kullanır |
|---|---|---|---|
| `INTERNAL` | `:9092` | `kafka-N:9092` | broker'lar arası, UI, SR, Connect |
| `EXTERNAL` | `:39092` | `localhost:3909N` | WSL host'undan bağlanan client'lar |
| `CONTROLLER` | `:9093` | — | KRaft quorum, dışarı açılmaz |

Prod'a geçişte aynı yapı `INTERNAL=private-ip` / `EXTERNAL=public-ip` olarak devam eder.

---

## 2. Repo yapısı

```
kafka-kraft-ansible/
├── README.md  PLAN.md  LICENSE  CONTRIBUTING.md  Makefile  .gitignore
├── ansible.cfg
├── requirements.yml
├── lab/
│   ├── Containerfile            # ubuntu:24.04 + systemd + sshd + python3
│   ├── lab-up.sh  lab-down.sh
│   └── README.md
├── inventories/
│   ├── lab/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │       ├── all/{cluster.yml, profile.yml}
│   │       ├── kafka_brokers/{main.yml, cluster_id.yml}
│   │       └── kafka_ui/main.yml
│   └── prod.example/            # gerçek VM şablonu
├── playbooks/
│   ├── site.yml  verify.yml  rolling-restart.yml  upgrade.yml  teardown.yml
├── roles/
│   ├── common/  java/
│   ├── kafka_kraft/             # ★ ana rol
│   ├── kafka_topics/
│   ├── kafka_ui/
│   ├── schema_registry/
│   └── kafka_connect/
├── molecule/default/
├── docs/                        # 00..09 + adr/
└── .github/workflows/ci.yml
```

---

## 3. Faz Faz Uygulama

Her fazın sonunda **Definition of Done (DoD)** var; sağlanmadan sonraki faza geçilmez.
Her faz sonunda commit + faz sonlarında git tag.

---

### FAZ 0 — Lab altyapısı ve araçlar

**Adımlar**

1. WSL araçları:
   ```bash
   sudo apt update && sudo apt install -y podman openssh-client make uidmap
   pipx install --include-deps ansible
   pipx inject ansible ansible-lint yamllint
   ```
2. Git init + `.gitignore` (`*.retry`, `.vault_pass`, `*.tar.gz`, `.venv/`).
3. `lab/Containerfile`: `ubuntu:24.04` üzerine `systemd systemd-sysv openssh-server
   python3 sudo iproute2 curl ca-certificates`; `ansible` kullanıcısı + NOPASSWD sudo +
   `authorized_keys`; gereksiz systemd unit'lerinin maskelenmesi; `STOPSIGNAL SIGRTMIN+3`;
   `CMD ["/sbin/init"]`.
4. SSH anahtarı: `ssh-keygen -t ed25519 -f ~/.ssh/kafka_lab -N ''`.
5. `lab/lab-up.sh`:
   - `podman network create kafka-lab` (varsa geç)
   - imajı build et
   - 4 container'ı `--systemd=always --network kafka-lab --hostname <ad>` ile başlat,
     port haritasını yukarıdaki tabloya göre publish et
   - `CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}` değişkeni ile docker'a da açık bırak
6. `ansible.cfg` (inventory yolu, `host_key_checking=False`, `pipelining=True`).
7. `inventories/lab/hosts.yml`: `kafka_brokers` (3), `kafka_controllers` (aynı 3),
   `kafka_ui` (tools-1) grupları; `ansible_host=127.0.0.1`, `ansible_port=222N`.

**DoD**
- `./lab/lab-up.sh` 4 container'ı ayağa kaldırıyor
- `ansible -i inventories/lab all -m ping` → 4 node SUCCESS
- `podman exec kafka-1 systemctl is-system-running` → `running` / `degraded` (crash değil)
- kafka-1 içinden `getent hosts kafka-2` çözüyor (aardvark-dns doğrulaması)

**Riskler:** rootless podman'de systemd; çözülmezse `--privileged` fallback'i lab README'ye not düşülür.

---

### FAZ 1 — `common` + `java` rolleri

**Adımlar**

1. `roles/common`: `kafka` user/group (nologin), `/opt`, `/var/lib/kafka`, `/var/log/kafka`
   dizinleri, `LimitNOFILE` için limits dosyası.
2. **OS tuning'i bayrağa bağla:** `kafka_tune_os` (prod'da `true`, lab'da `false`).
   `vm.swappiness`, `vm.max_map_count`, THP kapatma gibi task'lar container'da ya no-op
   ya da host'u etkiler — lab'da atlanmalı. Bu ayrım `docs/`'ta açıkça anlatılır.
3. `roles/java`: `openjdk-21-jre-headless`, `JAVA_HOME` tespiti ve fact olarak set.
4. `playbooks/site.yml` iskeleti (tag'li, grup bazlı play'ler).

**DoD**
- `ansible-playbook -i inventories/lab playbooks/site.yml --tags common,java` başarılı
- **İkinci çalıştırmada `changed=0`** (idempotency)
- `ansible all -a 'java -version'` 21 döndürüyor

---

### FAZ 2 — `kafka_kraft` rolü → çalışan cluster ★

**Adımlar (bu sırayla)**

1. **Sürüm pinle:** Apache Kafka indirme sayfasından tam sürüm + SHA512'yi al,
   `defaults/main.yml`'ye yaz. Sürüme ait `kafka-storage.sh format` sözdizimini
   o sürümün kendi dökümanından doğrula (minor'lar arası değişebiliyor).
2. `defaults/main.yml`: tüm tunable'lar yorumlu (bu dosya `docs/04`'ün kaynağı).
3. `tasks/preflight.yml`: `node_id` benzersizliği, RAM/disk eşiği, node'ların
   birbirini DNS ile çözmesi → `assert`.
4. `tasks/install.yml`: `get_url` + **checksum doğrulama**, `/opt/kafka-<ver>` altına aç,
   `/opt/kafka` symlink. (Symlink = upgrade/rollback tek adım.)
5. `templates/server.properties.j2`: 3 listener, `listener.security.protocol.map`,
   `inter.broker.listener.name=INTERNAL`, `controller.listener.names=CONTROLLER`,
   quorum voters Jinja döngüsüyle inventory'den:
   ```jinja
   controller.quorum.voters={% for h in groups['kafka_controllers'] -%}
   {{ hostvars[h].kafka_node_id }}@{{ hostvars[h].kafka_controller_host }}:{{ kafka_controller_port }}
   {{- "," if not loop.last }}{%- endfor %}
   ```
   Replikasyon: `default.replication.factor=3`, `min.insync.replicas=2`,
   `offsets.topic.replication.factor=3`, `transaction.state.log.replication.factor=3`.
6. **Cluster ID:** bir kez üretilir (`kafka-storage.sh random-uuid`),
   `group_vars/kafka_brokers/cluster_id.yml`'ye yazılır (lab'da düz, prod'da vault).
   Makefile'a `make cluster-id` hedefi.
7. `tasks/format.yml`: `stat` ile `log.dirs/meta.properties` kontrolü →
   **yoksa** format et. Bu koşul olmadan re-run veriyi siler.
8. `templates/kafka.service.j2` + `kafka-env` (heap profil değişkeninden:
   lab `512m`, prod `6g`), `Restart=on-failure`, `TimeoutStopSec=180`, `LimitNOFILE`.
9. `handlers/main.yml`: `restart kafka`.
10. `tasks/verify.yml`: 9092/9093 portları, `kafka-metadata-quorum.sh --describe`
    → 3 voter + 1 leader.

**DoD**
- `ansible-playbook site.yml --tags kafka` → 3 broker `active (running)`
- `kafka-metadata-quorum.sh --describe` → LeaderId dolu, 3 voter
- `--replication-factor 3` topic oluşuyor, produce/consume çalışıyor
- WSL host'undan `localhost:39091` ile bağlanılabiliyor (EXTERNAL listener testi)
- İkinci çalıştırmada `changed=0`, **format task'ı skipped**

→ `git tag v0.1.0`

---

### FAZ 3 — `kafka_ui` rolü + dinamiklik kanıtı

**Adımlar**

1. kafbat/kafka-ui jar release'ini indir (`get_url` + checksum), `/opt/kafka-ui`.
2. `kafka-ui.service` + env dosyası — **koşullu template**:
   ```jinja
   KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS={{ kafka_bootstrap_servers }}
   {% if groups['schema_registry'] | default([]) | length > 0 %}
   KAFKA_CLUSTERS_0_SCHEMAREGISTRY=http://{{ ... }}:8081
   {% endif %}
   {% if groups['kafka_connect'] | default([]) | length > 0 %}
   KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS=http://{{ ... }}:8083
   {% endif %}
   ```
3. `group_vars/all/cluster.yml` içinde türetilmiş değişken:
   ```yaml
   kafka_bootstrap_servers: "{{ groups['kafka_brokers']
     | map('extract', hostvars, 'kafka_internal_host')
     | map('regex_replace', '$', ':' ~ kafka_internal_port) | join(',') }}"
   ```
4. `playbooks/verify.yml`: uçtan uca smoke test (topic → produce → consume → temizlik).

**DoD**
- Tarayıcıdan `http://localhost:8080` → 3 broker ve topic'ler görünüyor
- `--tags kafka_ui` çalıştırınca broker'lara **hiç task gitmiyor** (downtime 0)

→ `git tag v0.2.0`

---

### FAZ 4 — Test ve CI

**Adımlar**

1. `molecule/default/` — podman driver, aynı `lab/Containerfile`, 3 node senaryosu.
2. `molecule.yml` + `converge.yml` + `verify.yml` (Faz 2 doğrulamalarının aynısı).
3. `.github/workflows/ci.yml`: `yamllint` → `ansible-lint` → `molecule test`
   (idempotency dahil, molecule bunu otomatik ölçer).
4. README'ye CI badge.

**DoD**
- `molecule test` lokalde yeşil
- GitHub Actions'ta yeşil badge

→ `git tag v0.3.0`

---

### FAZ 5 — Operasyonel playbook'lar

**Adımlar**

1. `rolling-restart.yml`: `serial: 1` → stop → start → port bekle →
   `kafka-topics.sh --describe --under-replicated-partitions` boş dönene kadar
   `retries/until` → sonraki node.
2. `upgrade.yml`: yeni sürümü indir → symlink değiştir → rolling restart → doğrula.
3. `docs/05-operations.md` runbook'ları: broker değiştirme, disk dolması, log temizliği.

**DoD**
- Rolling restart sırasında sürekli çalışan bir producer **mesaj kaybetmiyor**
- Bir broker `stop` edildiğinde cluster yazmaya devam ediyor (`min.insync.replicas=2` testi)

→ `git tag v0.4.0`

---

### FAZ 6 — `schema_registry` ile modülerliğin kanıtı ★

Bu faz projenin ana iddiasını ispatlar: **çalışan cluster'a sıfır kesintiyle bileşen ekleme.**

**Adımlar**

1. `roles/schema_registry` (Confluent Community tarball + systemd), `_schemas` topic'i
   `kafka_topics` rolü üzerinden deklaratif olarak bildirilir.
2. `inventories/lab/hosts.yml`'ye `schema_registry` grubu + `tools-1` eklenir.
3. ```bash
   ansible-playbook -i inventories/lab playbooks/site.yml --tags schema_registry
   ansible-playbook -i inventories/lab playbooks/site.yml --tags kafka_ui
   ```
4. `docs/09-extending.md` bu akışı adım adım anlatır.

**DoD**
- SR ayağa kalkıyor, şema register/get çalışıyor
- Kafka UI'da **Schema Registry sekmesi kendiliğinden** beliriyor
- Broker'lara tek bir task gitmedi — `site.yml` çıktısıyla kanıtlanır

→ `git tag v0.5.0`

---

### FAZ 7 — `kafka_connect` + `kafka_topics`

**Adımlar**

1. `roles/kafka_connect`: Apache Kafka tarball'ındaki `connect-distributed.sh`,
   ayrı systemd unit, `plugin.path` yönetimi.
2. `connect-configs` / `connect-offsets` / `connect-status` topic'leri
   `kafka_topics` rolüyle (RF=3, compact) önceden oluşturulur.
3. Örnek connector (FileStream veya Datagen) ile uçtan uca demo.

**DoD**
- Connect REST `:8083` cevap veriyor, connector çalışıyor
- Kafka UI'da Connect sekmesi görünüyor

→ `git tag v0.6.0`

---

### FAZ 8 — Güvenlik

**Adımlar**

1. TLS: CA + broker sertifikaları üretimi (`openssl`/`keytool`), keystore/truststore dağıtımı.
2. SASL/SCRAM-SHA-512: kullanıcı oluşturma, JAAS, `sasl.enabled.mechanisms`.
3. Listener'ları `SASL_SSL`'e çevir → **planlı rolling restart** (Faz 5 playbook'u kullanılır).
4. ACL'ler + UI/SR/Connect için servis kullanıcıları.
5. `ansible-vault` ile parolalar.

**DoD**
- Kimlik doğrulamasız client reddediliyor
- Tüm bileşenler SASL_SSL üzerinden çalışıyor
- Geçiş rolling restart ile, sıfır veri kaybıyla yapıldı

→ `git tag v0.7.0`

---

### FAZ 9 — Dökümantasyon ve yayın

| Dosya | İçerik |
|---|---|
| `README.md` | Ne yapar, mermaid mimari diyagramı, 5 dakikalık quickstart, UI ekran görüntüsü, CI badge |
| `docs/01-architecture.md` | KRaft, topoloji, listener matrisi, port tablosu |
| `docs/02-prerequisites.md` | OS, Java, disk/RAM/ağ, lab vs prod farkı |
| `docs/03-installation.md` | Adım adım, inventory doldurma |
| `docs/04-configuration-reference.md` | `defaults/main.yml`'deki her değişken |
| `docs/05-operations.md` | Runbook'lar |
| `docs/06-security.md` | TLS/SASL/ACL |
| `docs/07-monitoring.md` | JMX, izlenecek 10 metrik, alarm eşikleri |
| `docs/08-troubleshooting.md` | Belirti / sebep / çözüm tablosu |
| `docs/09-extending.md` | Yeni bileşen ekleme akışı |
| `docs/adr/` | Neden KRaft, neden combined, neden container-as-VM lab, neden statik quorum |
| `CONTRIBUTING.md` | Modülerlik sözleşmesinin 5 kuralı |

→ `git tag v1.0.0`

---

## 4. Modülerlik sözleşmesi (CONTRIBUTING.md'ye girecek)

1. Bir bileşen = bir rol = bir inventory grubu. Yeni bileşen, mevcut rollerin içine dokunmayı gerektirmez.
2. Hiçbir rol adres hardcode etmez; her şey inventory'den türetilir.
3. Broker'a yalnızca `kafka_kraft` rolü dokunur. Uydu rolleri broker restart edemez.
4. Her rolün 4 zorunlusu: yorumlu `defaults/main.yml`, `verify.yml`, molecule senaryosu, `docs/` sayfası.
5. Broker tarafı ihtiyaçları (topic, ACL) bileşen tarafından bildirilir, ortak `kafka_topics` rolü uygular.

---

## 5. Bilinen tuzaklar (docs/08'in çekirdeği)

- `advertised.listeners` yanlış → client bağlanamaz (lab'da EXTERNAL mutlaka `localhost:3909N`)
- `controller.quorum.voters` node'lar arası farklı → quorum kurulmaz
- Storage'ın yanlışlıkla yeniden formatlanması → tüm metadata gider
- `min.insync.replicas=2` + `acks=all`: tek broker düşünce yazma durur (bilinçli tercih)
- Lab'da `sysctl`/THP task'larının host'u etkilemesi → `kafka_tune_os: false`
- Heap'i şişirmek → GC duraklamaları; page cache'e yer bırak
- WSL RAM'i 7 GB: lab profilinde broker heap 512m
