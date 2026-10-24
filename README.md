# Elastic Stack Homelab (Bewerberaufgabe KastGroup)

Ein kleiner, vollständiger Elastic Stack mit Docker Compose: drei Elasticsearch-Nodes inklusive Frozen Tier, Kibana, Snapshots mit SLM und ILM, Fleet Server und ein Elastic Agent mit System- und Docker-Integration. Security ist durchgehend aktiv (TLS zwischen den Nodes und zu den Clients, Login für alle Zugriffe).

## Umgebung und Versionen

| Was | Wert |
|---|---|
| Host | Proxmox LXC (Debian 13), 6 Kerne, 20 GB RAM, kein Swap, 60 GB Disk |
| Docker | 29.9.2, Docker Compose 5.6.1 |
| Elastic Stack | **9.4.0** (Elasticsearch, Kibana, Elastic Agent / Fleet Server) |
| Lizenz | 30-Tage-Trial (`xpack.license.self_generated.type=trial`), nötig für Searchable Snapshots / Frozen Tier |

## Voraussetzungen

- Linux-Host mit Docker und Docker Compose Plugin, mindestens 12 bis 16 GB RAM frei.
- `vm.max_map_count` mindestens `262144` **auf dem Host** (bei LXC auf dem Proxmox-Host, weil der Container den Kernel teilt):
  ```bash
  sysctl -w vm.max_map_count=262144
  ```
- Swap aus oder sehr klein (Elasticsearch wird mit Swap langsam).

## Start

```bash
cp .env.example .env
# Werte in .env setzen, zum Beispiel:
#   ELASTIC_PASSWORD=$(openssl rand -hex 12)
#   KIBANA_PASSWORD=$(openssl rand -hex 12)
#   ENCRYPTION_KEY=$(openssl rand -hex 32)
chmod 600 .env
docker compose up -d es01 es02 es03 kibana
docker compose ps        # nach 1 bis 2 Minuten: es01, es02, es03, kibana = healthy
```

Fleet Server und Agent brauchen Tokens, die erst Kibana erzeugt. Darum beim ersten Start in zwei Phasen:

1. In Kibana → Fleet → Settings den Output `default` auf `https://es01:9200` stellen, Advanced YAML `ssl.certificate_authorities: ["/certs/ca/ca.crt"]`.
2. *Add Fleet Server* → Advanced → Policy `fleet-server-policy`, Production, Host `https://fleet-server:8220`, Service Token erzeugen → in `.env` als `FLEET_SERVER_SERVICE_TOKEN`.
3. `docker compose up -d fleet-server`, warten bis Fleet ihn als Healthy zeigt.
4. Agent-Policy anlegen (UI oder `./fleet/homelab-docker.sh`), Enrollment Token → `.env` als `FLEET_ENROLLMENT_TOKEN`.
5. `docker compose up -d elastic-agent`.

Danach startet `docker compose up -d` alles in einem Zug.

- Kibana: `http://<host>:5601`, Login `elastic` mit `ELASTIC_PASSWORD`.
- Elasticsearch-API: `https://<host>:9200` (nur es01 ist nach aussen offen).
- API-Test mit Zertifikatsprüfung statt `-k`:
  ```bash
  curl --cacert /var/lib/docker/volumes/elastic-lab_certs/_data/ca/ca.crt \
       -u elastic https://localhost:9200/_cluster/health?pretty
  ```

Neu starten oder einen einzelnen Dienst holen: immer `docker compose up -d [dienst]` (nicht `start`, siehe Entscheid 4).

## Aufbau

```
certs ──(fertig, Exit 0)──▶ es01  es02  es03 ──(es01 healthy)──▶ kibana-password ──(fertig)──▶ kibana
                                                                                                 │ (healthy)
                                                         elastic-agent ◀──(gestartet)── fleet-server
```

| Dienst | Aufgabe | Rollen / Ressourcen |
|---|---|---|
| `certs` | erzeugt einmalig CA und Zertifikate (`setup/certs.sh`, Liste in `setup/instances.yml`), setzt Rechte, beendet sich | Hilfscontainer |
| `es01` | Hot-Node, einziger Node mit Port 9200 nach aussen | master, data_hot, data_content, ingest · Heap 2 GB, Limit 4 GB |
| `es02` | Hot-Node | master, data_hot, data_content, ingest · Heap 2 GB, Limit 4 GB |
| `es03` | Frozen-Node | master, data_frozen · Heap 1 GB, Limit 2 GB, Shared Cache 5 GB |
| `kibana-password` | setzt das Passwort für den internen User `kibana_system` (`setup/kibana-password.sh`) | Hilfscontainer |
| `kibana` | Weboberfläche, Port 5601 | Limit 1.5 GB |
| `fleet-server` | Elastic Agent im Fleet-Server-Modus, Port 8220, eigenes Zertifikat | Limit 1 GB |
| `elastic-agent` | Agent mit Policy `homelab-docker` (System + Docker), läuft als root, Docker-Socket nur lesend | Limit 1 GB |

Volumes: `certs` (Zertifikate, von allen gelesen), `esdata01..03` (Daten je Node), `kibanadata`, `snapshots` (gemeinsames Snapshot-Repository), `agentstate` (Anmeldung des Agents).

Weitere Dateien: `setup/` (Zertifikate, Kibana-Passwort), `fleet/homelab-docker.sh` (Policy-as-Code), `docs/screenshots/` (Nachweise).

## Architekturentscheide

1. **Eigene CA statt `-k`.** `certs` erzeugt mit `elasticsearch-certutil` eine CA und pro Dienst ein Zertifikat mit den Namen und IPs, unter denen er erreichbar ist (Subject Alternative Name). Alle Dienste und Clients prüfen gegen `ca.crt`. Zertifikate werden nur erzeugt, wenn sie fehlen, damit sich die Nodes nach einem Neustart weiter vertrauen.
2. **Transport-TLS mit `verification_mode=certificate`.** Die Nodes sprechen sich intern über Container-IPs an, die nicht im Zertifikat stehen. Geprüft wird deshalb, ob das Zertifikat von unserer CA stammt, nicht der Hostname. HTTP (Port 9200) prüft den Hostnamen voll.
3. **Secrets nur in `.env`.** `.env` steht in `.gitignore`, im Repo liegt nur `.env.example` mit Platzhaltern.
4. **Setup in zwei Hilfscontainer getrennt.** Ursprünglich warteten die Nodes auf einen `setup`-Container im Zustand *healthy*. Beim Neustart war setup in unter einer Sekunde fertig (Zertifikate schon da) und beendet, bevor der Healthcheck *healthy* melden konnte: `docker compose up -d es02` brach mit "dependency failed to start" ab (Race Condition). Jetzt warten die Nodes auf `certs` mit `service_completed_successfully`, was auch für einen längst beendeten Container gilt. Das Kibana-Passwort setzt ein eigener Container, der auf es01 *healthy* wartet.
5. **Kein `bootstrap.memory_lock`.** Der Host hat keinen Swap, darum ist Memory Lock nicht nötig (und im unprivilegierten LXC schwierig, weil `ulimit memlock` begrenzt ist).
6. **Snapshot-Repository: Shared Filesystem statt MinIO/S3.** Alle Nodes laufen auf einem Host, ein gemeinsames Docker-Volume ist einfach und stabil. MinIO veröffentlicht seit 2025 keine Community-Images mehr (`minio/minio` auf Docker Hub nicht mehr verfügbar), Alternativen sind mit Elastic weniger erprobt. In Produktion: S3-kompatibler Objektspeicher (siehe unten).
7. **Agent als root mit Docker-Socket und Zustands-Volume.** Die Docker-Integration braucht den Socket (`root:docker`). Als root sieht der Agent auch alle Prozesse. Der Socket ist nur lesend eingebunden. Ohne Volume für `/usr/share/elastic-agent/state` meldet sich der Agent nach jedem Neuerstellen als neuer Agent an.
8. **Lesbarkeit vor Kürze.** Die drei Node-Blöcke wiederholen sich bewusst, statt YAML-Anker zu verwenden. So sieht man pro Node direkt, was gilt.

## Antworten Teil 1

**Warum drei master-fähige Nodes und nicht zwei?**
Der Master wird per Mehrheit gewählt. Bei drei Nodes ist die Mehrheit zwei: ein Node darf ausfallen, die anderen zwei wählen weiter. Bei zwei Nodes ist die Mehrheit ebenfalls zwei: fällt einer aus, hat der übrige keine Mehrheit, und der Cluster kann keinen Master mehr wählen. Zwei Nodes bringen also keine Ausfallsicherheit. Die Mehrheit verhindert Split Brain (zwei Teile halten sich je für den Chef und schreiben verschiedene Daten).
*Test:* `docker compose stop es02` (war Master) → es03 wurde in Sekunden neuer Master, Cluster lief weiter.

**Welche Host-Einstellungen braucht Elasticsearch im Container?**
- `vm.max_map_count ≥ 262144` auf dem Host (Elasticsearch bildet Index-Dateien per mmap in den Speicher ab). Im LXC teilt der Container den Kernel, also auf dem Proxmox-Host setzen.
- Genug offene Dateien: `ulimits nofile 65535`.
- Kein Swap, sonst `bootstrap.memory_lock=true` mit `ulimits memlock -1`.
- Heap fest setzen (`-Xms` = `-Xmx`), höchstens etwa die Hälfte des Container-RAM. Der Rest dient Linux als Datei-Cache.

**Welche Rolle spielt der Shared Cache auf dem Frozen-Node, und wie ist er dimensioniert?**
Daten im Frozen Tier liegen im Snapshot-Repository, nicht auf dem Node. Der Frozen-Node lädt nur die Teile, die eine Suche gerade braucht, und hält sie im lokalen Shared Cache. Ohne Einstellung nimmt ein reiner Frozen-Node 90 % der Disk. Hier teilen sich alle Container dieselbe 60-GB-Disk, darum ist der Cache fest auf `5gb` gesetzt, genug für die Demo. In Produktion: eigene schnelle Disk, Cache so gross, dass die häufig gesuchten Daten hineinpassen.

## Teil 2: Snapshots und Lifecycle

**2.1 Repository registriert und verifiziert**
```
PUT _snapshot/lab-repo
{ "type": "fs", "settings": { "location": "/usr/share/elasticsearch/snapshots" } }

POST _snapshot/lab-repo/_verify
```
`_verify` lässt jeden Node testweise schreiben. Die Antwort listet es01, es02 und es03: alle sehen denselben Speicher. Voraussetzung: Volume `snapshots` auf allen Nodes und `path.repo` gesetzt; `certs` übergibt den Ordner an UID 1000.

**2.2 SLM-Policy (täglicher Snapshot mit Aufbewahrung)**
```
PUT _slm/policy/nightly
{ "schedule": "0 30 1 * * ?", "name": "<nightly-{now/d}>", "repository": "lab-repo",
  "config": { "indices": "*", "include_global_state": true },
  "retention": { "expire_after": "30d", "min_count": 5, "max_count": 50 } }
POST _slm/policy/nightly/_execute
GET  _slm/policy/nightly?human
```
Täglich 01:30 UTC, alle Indizes plus Cluster-Zustand. Snapshots werden nach 30 Tagen gelöscht, mindestens 5 bleiben immer (falls Backups länger ausfallen), höchstens 50. Erster Lauf von Hand ausgelöst: erfolgreich in 15 s.

**2.3 ILM hot → frozen (Demo-Zeiten in Minuten)**
```
PUT _ilm/policy/lab-hot-frozen
{ "policy": { "phases": {
  "hot":    { "actions": { "rollover": { "max_age": "5m", "max_primary_shard_size": "1gb" } } },
  "frozen": { "min_age": "10m", "actions": { "searchable_snapshot": { "snapshot_repository": "lab-repo" } } },
  "delete": { "min_age": "1d", "actions": { "delete": {} } } } } }

PUT _cluster/settings
{ "persistent": { "indices.lifecycle.poll_interval": "10s" } }

PUT _index_template/lab-logs
{ "index_patterns": ["lab-logs*"], "data_stream": {}, "priority": 500,
  "template": { "settings": { "index.lifecycle.name": "lab-hot-frozen", "number_of_shards": 1, "number_of_replicas": 1 },
    "mappings": { "properties": { "@timestamp": {"type":"date"}, "message": {"type":"text"}, "host": {"type":"keyword"} } } } }
```
Daten gehen in den Data Stream `lab-logs`. Die Index-Vorlage weist die Policy zu. `poll_interval` (Standard 10 Minuten) ist nur fürs Labor auf 10 s gesetzt, damit die Demo in Minuten läuft. In Produktion etwa: Rollover täglich oder ab 50 GB, frozen nach 30 Tagen, löschen nach einem Jahr.

Beobachteter Ablauf (UTC): Index angelegt 12:34:50, Rollover 12:39:54, Phase frozen ab 12:49:54 (10 Minuten **nach dem Rollover**, `min_age` zählt ab dort), fertig 12:50:25. Vor dem Snapshot macht ILM standardmässig einen Force Merge (`force_merge_index: true`).

**2.4 Nachweis: Index liegt als Searchable Snapshot auf es03**
```
GET _cat/shards/.ds-lab-logs*,partial-*?v&h=index,shard,prirep,state,node
```
Vorher lag `.ds-lab-logs-…000001` als Primary auf es02 und Replica auf es01. Nachher heisst er `partial-.ds-lab-logs-…000001` und liegt nur noch auf es03, ohne Replica, denn die Sicherheit liefert der Snapshot im Repository. `partial` heisst: Auf dem Node liegt nur, was im Shared Cache ist. `GET lab-logs/_ilm/explain` zeigt `phase: frozen`, `step: complete` und den Snapshot-Namen.

**2.5 Suche im Frozen-Index**
```
GET lab-logs/_search
{ "query": { "match": { "message": "Tape-Roboter" } } }
```
Ein Treffer aus `partial-…000001` in 74 ms. Gesucht wird wie immer über den Data Stream, hot und frozen zusammen.

**2.6 Restore-Test**
```
POST restore-test/_doc { "@timestamp": "2026-10-24T13:15:00Z", "message": "Dieses Dokument muss den Restore überleben" }
PUT  _snapshot/lab-repo/restore-test-1?wait_for_completion=true { "indices": "restore-test", "include_global_state": false }
DELETE restore-test
GET  restore-test/_search                    # 404 index_not_found_exception
POST _snapshot/lab-repo/restore-test-1/_restore?wait_for_completion=true { "indices": "restore-test" }
GET  restore-test/_search                    # Dokument wieder da

# Variante für Produktion: unter neuem Namen neben dem laufenden Index
POST _snapshot/lab-repo/restore-test-1/_restore?wait_for_completion=true
{ "indices": "restore-test", "rename_pattern": "(.+)", "rename_replacement": "restored-$1" }
```
Elastic stellt nie über einen offenen Index wieder her. In Produktion holt man Daten unter neuem Namen zurück und prüft dort, statt den echten Index zu löschen.

## Teil 3: Fleet Server und Elastic Agent

```
Kibana (Fleet-UI) ──Policy──▶ Fleet Server :8220 ──Policy──▶ Elastic Agent ──Daten──▶ es01 :9200
```

| Dienst | Aufgabe | Wichtige Variablen |
|---|---|---|
| `fleet-server` | Elastic Agent im Fleet-Server-Modus, verteilt Policies an die Agents | `FLEET_SERVER_ENABLE=1`, `FLEET_SERVER_ELASTICSEARCH_HOST/_CA`, `FLEET_SERVER_SERVICE_TOKEN`, `FLEET_SERVER_POLICY_ID=fleet-server-policy`, `FLEET_SERVER_CERT/_CERT_KEY`, `FLEET_URL`, `FLEET_CA` |
| `elastic-agent` | sammelt System-Metriken und Logs (Policy `homelab`, System-Integration) | `FLEET_ENROLL=1`, `FLEET_URL`, `FLEET_ENROLLMENT_TOKEN`, `FLEET_CA` |

Vorbereitung in Kibana (Fleet):
1. **Output** `default`: Hosts `https://es01:9200`, Advanced YAML `ssl.certificate_authorities: ["/certs/ca/ca.crt"]`. Agents schicken ihre Daten direkt an Elasticsearch und erhalten Adresse und CA mit der Policy.
2. **Fleet Server** (Add Fleet Server → Advanced, Production): Policy `fleet-server-policy`, Host `https://fleet-server:8220`, Service Token → `.env`.
3. **Policy** `homelab` mit "Collect system logs and metrics", Enrollment Token → `.env`.

Tokens stehen nur in `.env` (`FLEET_SERVER_SERVICE_TOKEN`, `FLEET_ENROLLMENT_TOKEN`), im Repo nur Platzhalter.

Beim ersten Start meldet der Agent `connection refused localhost:9200`. Das ist die Bootstrap-Phase: Bis die Policy da ist, gelten die Standardwerte. Danach ist alles healthy.

**Nachweis:** Fleet → Agents zeigt `fleet-server` und `elastic-agent` als Healthy. Das Dashboard *[Metrics System] Host overview* zeigt CPU, RAM, Netzwerk und Load.

**Beobachtung:** Der Agent im Container meldet den RAM des ganzen Servers (der Container teilt den Kernel, `/proc/meminfo` ist nicht isoliert), sieht aber nur die eigenen Prozesse (PID-Namespace) und keine Disk. Auf einem echten Server installiert man den Agent auf dem Host.

**Frage: TLS-Vertrauenskette**

Alle Zertifikate stammen von derselben eigenen CA. Jede Verbindung prüft das Zertifikat der Gegenseite gegen `ca.crt` **und** ob der angesprochene Name im Zertifikat steht (SAN):

| Verbindung | Geprüftes Zertifikat | Woher der Client die CA kennt |
|---|---|---|
| Agent → Fleet Server `:8220` | `fleet-server.crt` (SAN `fleet-server`) | `FLEET_CA` |
| Agent → es01 `:9200` (Daten) | `es01.crt` (SAN `es01`) | Output in der Policy: `ssl.certificate_authorities` |
| Fleet Server → es01 `:9200` | `es01.crt` | `FLEET_SERVER_ELASTICSEARCH_CA` |
| Kibana → es01 `:9200` | `es01.crt` | `ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES` |
| Node ↔ Node `:9300` | `es0N.crt` gegenseitig | `xpack.security.transport.ssl.certificate_authorities`, `verification_mode=certificate` |

Anmeldung ist davon getrennt: Der Fleet Server nutzt ein Service Token. Der Agent nutzt einmalig das Enrollment Token und erhält danach eigene API-Keys. Typische Fehler: `x509: certificate signed by unknown authority` (CA fehlt beim Client), `certificate is valid for X, not Y` (Name fehlt im SAN). Läuft die CA ab oder wird sie ersetzt, brechen alle Verbindungen gleichzeitig, darum gehört die Erneuerung in die Planung.

## Teil 4: Fleet Policy ausrollen

**Vorbereitung Agent:** Für die Docker-Integration läuft der Agent als `root` und bekommt den Docker-Socket nur lesend (`/var/run/docker.sock:ro`). Der Zustand liegt im Volume `agentstate`, damit sich der Agent nach dem Neuerstellen des Containers nicht neu anmeldet. Beim Umbau entstand einmalig ein zweiter Agent; der alte wurde nach dem Offline-Status per *Unenroll* entfernt.

**4.1 Zweite Policy `homelab-docker` als Code** (Bonus): Statt über das UI per Fleet-API angelegt. Das Skript liegt in `fleet/homelab-docker.sh`, in Dev Tools sind es diese Aufrufe:
```
POST kbn:/api/fleet/epm/packages/docker/2.16.0
POST kbn:/api/fleet/agent_policies?sys_monitoring=true
{ "id": "homelab-docker", "name": "homelab-docker", "description": "Homelab: System plus Docker-Container",
  "namespace": "default", "monitoring_enabled": ["logs", "metrics"] }
POST kbn:/api/fleet/package_policies
{ "policy_ids": ["homelab-docker"], "package": { "name": "docker", "version": "2.16.0" }, "name": "docker-1", "namespace": "default" }
```
Die feste ID `homelab-docker` macht die Policy für Skripte adressierbar. Das Skript ist für die Erstanlage gedacht. In Produktion würde ich Terraform (Provider `elastic/elasticstack`) nehmen, das auch Änderungen abgleicht.

**4.2 Zuweisen und Daten:** Fleet → Agents → *Assign to new policy*. Der Agent übernimmt die Policy ohne Neustart. Die Docker-Integration liefert `metrics-docker.*` (Container, CPU, RAM, Netz, Healthchecks), sichtbar im Dashboard *[Metrics Docker] Overview*.

**4.3 Neue Revision:**
```
PUT kbn:/api/fleet/agent_policies/homelab-docker
{ "name": "homelab-docker", "namespace": "default", "description": "Homelab: System plus Docker-Container",
  "global_data_tags": [ { "name": "umgebung", "value": "lab" } ] }
```
Die Policy springt auf Revision 3, der Agent meldet nach wenigen Sekunden `policy_revision 3`. Nachweis, dass die Änderung wirkt: Neue Dokumente tragen das Feld.
```
GET metrics-system.cpu-default/_search?q=umgebung:lab&size=1
```

**Frage: Wie würdest du eine Policy-Änderung auf 500 Agents ausrollen, ohne alle gleichzeitig zu treffen?**
Eine geänderte Policy erreicht alle Agents dieser Policy beim nächsten Check-in, also praktisch sofort. Darum würde ich wie bei Intune in Ringen arbeiten: dieselbe Policy pro Ring (zum Beispiel 5 Test-Agents, 50 Pilot, Rest), die Agents per Tag zugeordnet. Die Änderung kommt zuerst in den kleinsten Ring. Danach prüfe ich in Fleet Unhealthy-Zähler und `policy_revision`, ob die Daten weiter ankommen und ob die Last auf den Hosts steigt. Erst dann folgt der nächste Ring. Die Policies liegen als Code im Git, Änderungen laufen per Pull Request; der Rückweg ist die vorherige Version. Für Agent-Upgrades hat Fleet die Staffelung eingebaut (*Rollout period*).

## Teil 5: Konfiguration verstehen und abfragen

**5.1 Wege, über die Einstellungen in mein Setup kommen**

| Quelle | Im Setup | Beispiel | Prüfen mit |
|---|---|---|---|
| Umgebungsvariablen im Compose-File | Hauptweg für alle Node-Einstellungen | `node.name`, `node.roles`, `path.repo`, TLS-Pfade | `docker exec es01 printenv` |
| `elasticsearch.yml` | nicht gemountet, nur die Datei aus dem Image | `cluster.name: "docker-cluster"`, `network.host: 0.0.0.0` | `docker exec es01 cat config/elasticsearch.yml` |
| JVM-Optionen | über `ES_JAVA_OPTS` | `-Xms2g -Xmx2g` (es03: 1g) | `GET _nodes/jvm` |
| Keystore | Secure Settings | `bootstrap.password` (aus `ELASTIC_PASSWORD`) | `bin/elasticsearch-keystore list` |
| Cluster-Settings-API | dynamische Einstellungen zur Laufzeit | `indices.lifecycle.poll_interval: 10s` (persistent) | `GET _cluster/settings` |

Das Docker-Startskript gibt jede Umgebungsvariable mit Punkt im Namen als `-E name=wert` an Elasticsearch weiter. Darum schlägt `cluster.name=kast-lab` aus Compose den Wert `docker-cluster` aus der Datei im Image.

**5.2 Effektive Einstellungen eines Nodes inklusive Defaults**
```
GET _nodes/es01/settings?flat_settings=true            # alles, was beim Start übergeben wurde (Datei + Umgebung)
GET _cluster/settings?include_defaults=true&flat_settings=true   # persistent, transient und alle Defaults
GET _cluster/settings?include_defaults=true&filter_path=persistent,transient,defaults.cluster.name,defaults.indices.lifecycle,defaults.cluster.routing.allocation.disk.watermark
```
`include_defaults` listet unter `defaults` nur Einstellungen, die nirgends anders gesetzt sind. Jede Einstellung erscheint also genau einmal, mit dem Wert, der gilt, und dem Abschnitt, aus dem er kommt. Beispiel: `poll_interval` steht unter `persistent` (10s), `cluster.name` unter `defaults` mit dem Wert aus der Umgebung (`kast-lab`), die Disk-Watermarks unter `defaults` mit den eingebauten Werten (85 / 90 / 95 %).

**5.3 Welche Quelle gewinnt**

Reihenfolge, schwach nach stark: Default im Code < `elasticsearch.yml` < Kommandozeile `-E` bzw. Umgebungsvariable < Cluster-Settings `persistent` < `transient` (veraltet). Statische Einstellungen (z.B. `cluster.name`, `node.roles`) lassen sich per API gar nicht setzen.

Nachweis mit `indices.lifecycle.poll_interval`, gesetzt an drei Orten: Default 10m, Compose auf es01 `1m`, Cluster-API `10s`.
```
GET _nodes/es01/settings?filter_path=nodes.*.settings.indices
# → poll_interval: 1m  (Node hat den Wert aus Compose)
GET _cluster/settings?include_defaults=true&filter_path=persistent,defaults.indices.lifecycle
# → persistent: 10s, kein Eintrag unter defaults  ⇒ API gewinnt
PUT _cluster/settings { "persistent": { "indices.lifecycle.poll_interval": null } }
GET _cluster/settings?include_defaults=true&filter_path=persistent,defaults.indices.lifecycle
# → defaults: poll_interval 1m (nicht 10m)  ⇒ Umgebung gewinnt gegen Default
PUT _cluster/settings { "persistent": { "indices.lifecycle.poll_interval": "10s" } }
```

**5.4 Heap und Rollen jedes Nodes, ohne Compose-Datei**
```
GET _cat/nodes?v&h=name,node.role,master,heap.max,heap.percent,ram.max
GET _nodes/jvm?filter_path=nodes.*.name,nodes.*.roles,nodes.*.jvm.mem.heap_max_in_bytes,nodes.*.jvm.mem.heap_init_in_bytes
```

| Node | Rollen | Heap (init = max) | Container-RAM |
|---|---|---|---|
| es01 | master, data_hot, data_content, ingest (`hims`) | 2 GB | 4 GB |
| es02 | master, data_hot, data_content, ingest (`hims`) | 2 GB | 4 GB |
| es03 | master, data_frozen (`fm`), aktuell gewählter Master | 1 GB | 2 GB |

`heap_init` gleich `heap_max` zeigt, dass `-Xms` und `-Xmx` gleich gesetzt sind.

**5.5 Schreibweise bei Kibana und Fleet Server**

| Dienst | Schreibweise im Container | Beispiel |
|---|---|---|
| Elasticsearch | Name wie in der yml, mit Punkten; das Startskript macht daraus `-E` | `node.name=es01` |
| Kibana | GROSS mit Unterstrichen, Kibana übersetzt in den yml-Namen | `SERVER_PUBLICBASEURL` → `server.publicBaseUrl`, `ELASTICSEARCH_HOSTS` → `elasticsearch.hosts` |
| Fleet Server / Agent | eigene feste `FLEET_*`-Variablen, die das Image in Parameter für `enroll`/`install` übersetzt; keine allgemeine Übersetzung von yml-Namen | `FLEET_SERVER_ELASTICSEARCH_HOST` = `--fleet-server-es`, `FLEET_ENROLLMENT_TOKEN` = `--enrollment-token` |

Eine Kibana-Variable in Punkt-Schreibweise wird stillschweigend ignoriert. Alles, was der Agent nicht über `FLEET_*` kennt (Output, Integrationen, Logging), kommt über die Policy aus Fleet.

## Nachweise

Screenshots unter `docs/screenshots/` (Nummer = Teil im Aufgabenblatt):
- `1-1_cluster-health.png`, `1-2_nodes-rollen.png`, `1-3_lizenz-trial.png`, `1-4_docker-ps.png`
- `2-1_snapshot-repo-verify.png`, `2-2_slm.png`, `2-4a_vorher-hot.png`, `2-4b_nachher-frozen.png`, `2-4c_ilm-frozen.png`, `2-5_frozen-suche.png`, `2-6a_index-geloescht.png`, `2-6b_restore-ok.png`, `2-6c_restore-umbenannt.png`
- `3-1_fleet-agents.png`, `3-2_daten-dashboard.png`
- `4-1_policy-zweite.png`, `4-1b_docker-daten.png`, `4-2_policy-revision.png`, `4-3_revision-in-daten.png`
- `5-1_settings-defaults.png`, `5-2a_vorrang-api.png`, `5-2b_vorrang-env.png`, `5-3_heap-rollen.png`

## Was ich in Produktion anders machen würde

- **Dedizierte Master-Nodes** (nur Master-Rolle, keine Daten). Im Labor wurde nach dem Ausfalltest der Frozen-Node es03 Master, das ist nicht ideal.
- **Nodes auf getrennten Hosts und Disks**, damit ein Hardware-Ausfall nicht alles trifft.
- **Snapshot-Repository auf S3-kompatiblem Objektspeicher** statt Shared Filesystem.
- **Frozen-Cache auf eigener schneller Disk**, grösser dimensioniert.
- **Zertifikate aus der Firmen-PKI**, Ablauf überwachen (hier selbst erzeugte CA, 3 Jahre gültig).
- **Kibana per HTTPS** und mit mehreren Elasticsearch-Hosts oder Load Balancer (heute nur es01: fällt es01 aus, ist Kibana weg).
- **Secrets in einem Secret-Store** (Vault, Keystore) statt `.env`.
- **ILM-Prüfintervall** auf Standard (10 Minuten) lassen, Phasen in Tagen statt Minuten.
- **Elastic Agent auf dem Host installieren** (oder mit `/hostfs` und Rechten), nicht als reiner Container, sonst fehlen Disk- und Prozessdaten. Tamper Protection einschalten.
- **Fleet Server hochverfügbar** (mindestens zwei hinter einem Load Balancer) und Agent-Zustand in einem Volume speichern.
- **Policy-as-Code mit Terraform** (Provider `elastic/elasticstack`) statt Einmal-Skript, Änderungen per Pull Request, Rollout in Ringen.
- **Einstellungen an einem Ort:** eigene `elasticsearch.yml` pro Node aus dem Git mounten statt langer Umgebungslisten, Demo-Werte (`poll_interval`) entfernen.
- **Restart-Policy** für die Dienste und Monitoring (Stack Monitoring, Alarme auf Cluster-Status und Disk).
