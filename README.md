# reichi.cloud – Cloudreve auf Proxmox

Zwei Bash-Scripts, die [Cloudreve](https://cloudreve.org) (v4) auf einem Proxmox-VE-Host
in einem eigenen Debian-LXC-Container installieren.

Zielbild:

- Container mit **fester IP** – entweder direkt mit der öffentlichen IP an der Bridge oder
  an einer privaten Bridge, wobei der Host die öffentliche IP hält und TCP 80/443 per
  DNAT an den Container weiterreicht
- **kein Reverse Proxy**: Cloudreve terminiert TLS selbst auf Port 443 (DNAT ist reines
  Port-Forwarding, Cloudreve sieht die echte Client-IP)
- Daten optional auf einem **Host-Verzeichnis** (z. B. `/mnt/pve/CloudStorage`) per Bind-Mount
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
- Eine Bridge für den Container: entweder mit öffentlicher IP (Netzmaske/Gateway laut Hoster)
  oder eine private NAT-Bridge (z. B. `vmbr1` mit `10.2.0.1/24` am Host)
- DNS: `A`-Record `reichi.cloud` → öffentliche IP (für Let's Encrypt; sonst wird ein Self-Signed-Zertifikat
  erzeugt und das echte Zertifikat kann später nachgeholt werden)
- Wenn die Domain bei Cloudflare liegt: den Eintrag auf **DNS only** (graue Wolke) stellen,
  sonst steht Cloudflare als Reverse Proxy davor.
- Optional ein Host-Verzeichnis für die Daten (z. B. ein in Proxmox eingebundenes Storage unter `/mnt/pve/...`)

## Installation

```bash
git clone https://github.com/reichiClaw/reichi.cloud.git
cd reichi.cloud
```

### Variante A: Bridge im LAN, externer Router leitet die öffentliche IP weiter

`vmbr1` hängt an einer NIC im Netz `10.2.0.0/24`; der Router dort (hier `10.2.0.1`) macht NAT
und leitet TCP 80/443 der öffentlichen IP auf den Container weiter. Der Proxmox-Host braucht
keine eigene IP auf der Bridge.

```bash
CT_IP=10.2.0.5 \
GATEWAY=10.2.0.1 \
BRIDGE=vmbr1 \
PUBLIC_IP=91.112.42.60 \
DATA_HOST_DIR=/mnt/pve/CloudStorage/cloudreve \
LE_EMAIL=admin@reichi.cloud \
bash install-cloudreve-proxmox.sh
```

`PUBLIC_IP` dient hier nur dem DNS-Check im Container. Weil die IP nicht auf dem Host liegt,
richtet das Script kein NAT ein (Port-Forwarding ist Sache des Routers).

### Variante B: private Bridge, öffentliche IP am Proxmox-Host (NAT am Host)

```bash
CT_IP=10.2.0.5 \
BRIDGE=vmbr1 \
BRIDGE_IP=10.2.0.1/24 \
PUBLIC_IP=91.112.42.60 \
LE_EMAIL=admin@reichi.cloud \
bash install-cloudreve-proxmox.sh
```

Der Host ist hier Gateway und braucht eine IP im Container-Netz. Hat `vmbr1` noch keine, setzt
`BRIDGE_IP` sie: `/etc/network/interfaces` wird (mit Backup) angepasst und per `ifreload -a` aktiviert;
hat die Bridge bereits eine IP, `BRIDGE_IP` weglassen. `GATEWAY` und Netzmaske werden daraus abgeleitet.
Weil `PUBLIC_IP` auf dem Host liegt, bekommt er `/usr/local/sbin/cloudreve-nat` plus
`cloudreve-nat.service` (iptables DNAT 80/443 → Container, SNAT für ausgehenden Container-Traffic,
`ip_forward=1`) – idempotent, überlebt Reboots. Mit `NAT_FORWARD=0/1` lässt sich die Automatik übersteuern.

### Variante C: Container hat die öffentliche IP selbst

```bash
CT_IP=203.0.113.10/24 \
GATEWAY=203.0.113.1 \
LE_EMAIL=admin@reichi.cloud \
bash install-cloudreve-proxmox.sh
```

Das Script

1. lädt das aktuelle `debian-12-standard`-Template (falls nicht vorhanden),
2. bereitet ggf. das Host-Datenverzeichnis vor (Owner `100000` = root im unprivilegierten Container),
3. legt einen unprivilegierten Container an (Default: 2 Cores, 2 GB RAM, 16 GB Disk) inkl. Bind-Mount
   nach `/opt/cloudreve/data`,
4. setzt die statische IP, DNS, Autostart und einen Proxmox-Firewall-Regelsatz (22/80/443),
5. richtet bei Variante B das Port-Forwarding am Host ein,
6. startet den Container, setzt ein zufälliges root-Passwort (wird am Ende angezeigt),
7. kopiert `cloudreve-setup.sh` in den Container und führt es aus.

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
| `CT_IP` | – (Pflicht) | IPv4 des Containers, mit oder ohne CIDR (`10.2.0.5` oder `203.0.113.10/24`); ohne CIDR wird die Maske der Bridge übernommen |
| `GATEWAY` | Host-IP auf `BRIDGE` | IPv4-Gateway des Containers |
| `PUBLIC_IP` | leer | Öffentliche IPv4 (ohne CIDR), unter der die Domain erreichbar ist (DNS-Check im Container); liegt sie auf dem Host und weicht von `CT_IP` ab, wird NAT am Host eingerichtet |
| `NAT_FORWARD` | `auto` | `1`/`0` erzwingt bzw. unterdrückt das Port-Forwarding |
| `NAT_PORTS` | `80 443` | Weitergeleitete TCP-Ports |
| `WAN_IFACE` | Default-Route | Host-Interface mit der öffentlichen IP (für SNAT) |
| `LE_EMAIL` | – (Pflicht) | E-Mail für Let's Encrypt (entfällt bei `SKIP_LETSENCRYPT=1`) |
| `DOMAIN` | `reichi.cloud` | Domain |
| `PUBLIC_IP6` / `GATEWAY6` | leer | Optional IPv6 mit CIDR + Gateway |
| `CT_MAC` | leer | Feste MAC-Adresse (manche Hoster verlangen das für Zusatz-IPs) |
| `BRIDGE` | `vmbr0` | Proxmox-Bridge |
| `BRIDGE_IP` | leer | IPv4/CIDR, die der Host auf `BRIDGE` bekommen soll (z. B. `10.2.0.1/24`), falls die Bridge noch keine hat; wird in `/etc/network/interfaces` persistiert |
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
| `DATA_HOST_DIR` | leer | Host-Verzeichnis, das als `/opt/cloudreve/data` in den Container gemountet wird (z. B. `/mnt/pve/CloudStorage/cloudreve`); schließt `DATA_DISK_GB` aus |
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

Bei NAT-Betrieb zusätzlich auf dem **Host**:

```
/usr/local/sbin/cloudreve-nat                 iptables-Regeln (DNAT 80/443, FORWARD, SNAT), idempotent
/etc/systemd/system/cloudreve-nat.service     führt das Script beim Boot aus
/etc/sysctl.d/99-cloudreve-forward.conf       net.ipv4.ip_forward = 1
```

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
- **Routed-Setups** (z. B. Hetzner Zusatz-IPs): `CT_IP=<IP>/32` und `GATEWAY=<Host-IP>` sowie ggf.
  `CT_MAC` laut Hoster verwenden.
- **NAT-Betrieb**: Die Regeln werden mit `iptables` angelegt und laufen parallel zur Proxmox-Firewall
  (die ihre eigenen Chains nutzt). Wenn der Host bereits eine eigene NAT-Konfiguration in
  `/etc/network/interfaces` hat (`post-up iptables -t nat ... MASQUERADE`), bleibt sie unberührt.
  Zugriff auf `https://reichi.cloud` **aus dem Container-Netz selbst** (Hairpin-NAT) ist nicht eingerichtet.
- **`DATA_HOST_DIR` auf einem PVE-Storage**: Ein Unterverzeichnis verwenden (z. B.
  `/mnt/pve/CloudStorage/cloudreve`), damit Cloudreve nicht neben den PVE-Ordnern (`dump/`, `images/`, …)
  liegt. Das Script setzt den Owner des Verzeichnisses auf `100000` (uid 0 im unprivilegierten Container);
  bei CIFS/NFS ohne uid-Mapping ggf. `uid=100000,gid=100000` als Mount-Option setzen.
- Große Uploads: Ohne Reverse Proxy gibt es kein `client_max_body_size`-Limit; Chunk-Größen werden
  in der Cloudreve-Speicherrichtlinie konfiguriert.
- Backups: Container per Proxmox-Backup sichern. Ein Bind-Mount (`DATA_HOST_DIR`) wird von `vzdump`
  **nicht** mitgesichert – das Host-Verzeichnis separat sichern. `DATA_DISK_GB` > 0 legt stattdessen ein
  eigenes, mitgesichertes Volume an.
