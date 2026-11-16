# reichi.cloud – Cloudreve auf Proxmox

Zwei Bash-Scripts, die [Cloudreve](https://cloudreve.org) (v4) auf einem Proxmox-VE-Host
in einem eigenen Debian-LXC-Container installieren.

Zielbild:

- Container mit **fester öffentlicher IP** direkt an der Bridge (`vmbr0`)
- **kein Reverse Proxy**: Cloudreve terminiert TLS selbst auf Port 443
- Zertifikat von **Let's Encrypt** (certbot), automatische Erneuerung
- Domain: **reichi.cloud**
- PostgreSQL + Redis lokal im Container (empfohlene Produktions-Konfiguration)
- Port 80 leitet nur per `301` auf `https://reichi.cloud` um (minimaler nginx ohne Proxy-Funktion, optional abschaltbar)

| Datei | Läuft auf | Zweck |
| --- | --- | --- |
| `install-cloudreve-proxmox.sh` | Proxmox-Host (root) | Template laden, LXC anlegen, Netzwerk/Firewall setzen, Setup im Container starten |
| `cloudreve-setup.sh` | im Container (oder jeder Debian/Ubuntu-VM) | Cloudreve, DB, Redis, Zertifikat, systemd-Dienst |

## Voraussetzungen

- Proxmox VE 7/8/9, Zugriff als `root` auf den Host
- Eine freie öffentliche IPv4 (mit Netzmaske und Gateway laut Hoster) auf einer Bridge
- DNS: `A`-Record `reichi.cloud` → diese IP (für Let's Encrypt; sonst wird ein Self-Signed-Zertifikat
  erzeugt und das echte Zertifikat kann später nachgeholt werden)
- Wenn die Domain bei Cloudflare liegt: den Eintrag auf **DNS only** (graue Wolke) stellen,
  sonst steht Cloudflare als Reverse Proxy davor.

## Installation

```bash
git clone https://github.com/reichiClaw/reichi.cloud.git
cd reichi.cloud

PUBLIC_IP=203.0.113.10/24 \
GATEWAY=203.0.113.1 \
LE_EMAIL=admin@reichi.cloud \
bash install-cloudreve-proxmox.sh
```

Das Script

1. lädt das aktuelle `debian-12-standard`-Template (falls nicht vorhanden),
2. legt einen unprivilegierten Container an (Default: 2 Cores, 2 GB RAM, 16 GB Disk),
3. setzt die statische IP, DNS, Autostart und einen Proxmox-Firewall-Regelsatz (22/80/443),
4. startet den Container, setzt ein zufälliges root-Passwort (wird am Ende angezeigt),
5. kopiert `cloudreve-setup.sh` in den Container und führt es aus.

Am Ende erscheint eine Zusammenfassung mit URL, Container-ID und root-Passwort.

### Erste Schritte nach der Installation

1. `https://reichi.cloud` öffnen und den **ersten Account registrieren** – dieser wird automatisch Administrator.
2. Unter `https://reichi.cloud/admin` die **Site URL** auf `https://reichi.cloud` setzen,
   Speicherrichtlinien und Gruppen anpassen.

## Konfiguration

Alle Werte werden als Umgebungsvariablen übergeben.

### Host-Script (`install-cloudreve-proxmox.sh`)

| Variable | Default | Beschreibung |
| --- | --- | --- |
| `PUBLIC_IP` | – (Pflicht) | Öffentliche IPv4 mit CIDR, z. B. `203.0.113.10/24` |
| `GATEWAY` | – (Pflicht) | IPv4-Gateway |
| `LE_EMAIL` | – (Pflicht) | E-Mail für Let's Encrypt (entfällt bei `SKIP_LETSENCRYPT=1`) |
| `DOMAIN` | `reichi.cloud` | Domain |
| `PUBLIC_IP6` / `GATEWAY6` | leer | Optional IPv6 mit CIDR + Gateway |
| `CT_MAC` | leer | Feste MAC-Adresse (manche Hoster verlangen das für Zusatz-IPs) |
| `BRIDGE` | `vmbr0` | Proxmox-Bridge |
| `DNS_SERVERS` | `1.1.1.1 9.9.9.9` | Resolver im Container |
| `CTID` | nächste freie ID | Container-ID |
| `CT_HOSTNAME` | `cloudreve` | Hostname |
| `CT_PASSWORD` | zufällig | root-Passwort im Container |
| `SSH_PUBKEY_FILE` | leer | Public Key für root-SSH-Login |
| `STORAGE` | `local-lvm` | Storage für rootfs / Daten-Volume |
| `TEMPLATE_STORAGE` | `local` | Storage für das LXC-Template |
| `TEMPLATE_PATTERN` | `debian-12-standard` | Template-Präfix (z. B. `debian-13-standard`) |
| `DISK_GB` | `16` | rootfs-Größe |
| `DATA_DISK_GB` | `0` | >0: separates Volume für `/opt/cloudreve/data` (Uploads) |
| `MEMORY_MB` / `SWAP_MB` / `CORES` | `2048` / `512` / `2` | Ressourcen |
| `UNPRIVILEGED` | `1` | Unprivilegierter Container |
| `START_ONBOOT` | `1` | Autostart |
| `PVE_FIREWALL` | `1` | `/etc/pve/firewall/<CTID>.fw` mit 22/80/443 anlegen (wirkt nur bei aktiver Datacenter-Firewall) |

Die folgenden Variablen werden unverändert an `cloudreve-setup.sh` weitergereicht.

### Container-Script (`cloudreve-setup.sh`)

| Variable | Default | Beschreibung |
| --- | --- | --- |
| `DOMAIN` | `reichi.cloud` | Domain |
| `LE_EMAIL` | – | E-Mail für Let's Encrypt |
| `CLOUDREVE_VERSION` | `latest` | Konkrete Version, z. B. `4.19.1` |
| `USE_POSTGRES` | `1` | `0` = SQLite statt PostgreSQL |
| `USE_REDIS` | `1` | `0` = In-Memory-Cache statt Redis |
| `HTTP_REDIRECT` | `1` | `0` = kein nginx, nur Port 443 (certbot nutzt dann `--standalone` auf Port 80) |
| `INSTALL_MEDIA_TOOLS` | `1` | ffmpeg + libvips für Thumbnails/Video-Metadaten |
| `INSTALL_UNATTENDED_UPGRADES` | `1` | Automatische Sicherheitsupdates |
| `SKIP_LETSENCRYPT` | `0` | `1` = nur Self-Signed-Zertifikat |
| `TIMEZONE` | `Europe/Berlin` | Zeitzone im Container |
| `INSTALL_DIR` | `/opt/cloudreve` | Installationsverzeichnis |

Das Container-Script kann auch allein auf einer beliebigen Debian/Ubuntu-VM laufen:

```bash
DOMAIN=reichi.cloud LE_EMAIL=admin@reichi.cloud bash cloudreve-setup.sh
```

## Was im Container entsteht

```
/opt/cloudreve/cloudreve              Binary (läuft als Systemuser "cloudreve")
/opt/cloudreve/data/conf.ini          Konfiguration ([SSL], [Database], [Redis])
/opt/cloudreve/data/ssl/*.pem         Zertifikat, das Cloudreve lädt
/etc/systemd/system/cloudreve.service Dienst (CAP_NET_BIND_SERVICE für Port 443, gehärtet)
/etc/letsencrypt/renewal-hooks/deploy/cloudreve.sh
                                      kopiert nach jeder Erneuerung das Zertifikat & startet Cloudreve neu
/usr/local/sbin/cloudreve-issue-cert  Zertifikat (erneut) anfordern
/etc/nginx/sites-available/cloudreve-redirect
                                      Port 80 → 301 https://reichi.cloud + ACME-Webroot (nur bei HTTP_REDIRECT=1)
```

Cloudreve lauscht bei aktivem `[SSL]`-Block **ausschließlich** auf 443; der HTTP-Listener
(`:5212`) ist dann deaktiviert. Die Erneuerung läuft über den `certbot.timer` von Debian.

## Betrieb

```bash
pct enter <CTID>                                   # in den Container
systemctl status cloudreve                         # Status
journalctl -u cloudreve -f                         # Logs
cloudreve-issue-cert                               # Zertifikat anfordern/erneuern (z. B. nach DNS-Korrektur)
CLOUDREVE_VERSION=latest bash /root/cloudreve-setup.sh   # Update auf neueste Version
```

Das Setup-Script ist idempotent: Konfiguration, Datenbank und Zertifikate bleiben bei erneutem
Ausführen erhalten, nur das Binary wird auf die gewünschte Version gebracht.

## Hinweise

- **DNS zuerst** setzen. Schlägt die Zertifikatsausstellung fehl (DNS zeigt noch woanders hin,
  Port 80 von außen blockiert), startet Cloudreve mit einem Self-Signed-Zertifikat; danach einfach
  `cloudreve-issue-cert` im Container ausführen.
- **Routed-Setups** (z. B. Hetzner Zusatz-IPs): `PUBLIC_IP=<IP>/32` und `GATEWAY=<Host-IP>` sowie ggf.
  `CT_MAC` laut Hoster verwenden.
- Große Uploads: Ohne Reverse Proxy gibt es kein `client_max_body_size`-Limit; Chunk-Größen werden
  in der Cloudreve-Speicherrichtlinie konfiguriert.
- Backups: Container per Proxmox-Backup sichern (`DATA_DISK_GB` > 0 legt die Uploads auf ein eigenes,
  mitgesichertes Volume).
