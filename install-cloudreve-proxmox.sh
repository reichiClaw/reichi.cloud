#!/usr/bin/env bash
# =============================================================================
# install-cloudreve-proxmox.sh
#
# Legt auf einem Proxmox-VE-Host einen Debian-LXC-Container mit fester
# oeffentlicher IP an und installiert darin Cloudreve (v4) mit eigenem
# TLS-Endpunkt (Let's Encrypt) - ohne Reverse Proxy.
#
# Aufruf auf dem Proxmox-Host als root, z.B.:
#
#   PUBLIC_IP=203.0.113.10/24 GATEWAY=203.0.113.1 LE_EMAIL=admin@reichi.cloud \
#     bash install-cloudreve-proxmox.sh
#
# Alle Werte lassen sich per Umgebungsvariable anpassen (siehe unten).
# Die eigentliche Installation im Container erledigt cloudreve-setup.sh,
# das neben diesem Script liegen muss (oder automatisch geladen wird).
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Konfiguration
# ----------------------------------------------------------------------------
DOMAIN="${DOMAIN:-reichi.cloud}"
LE_EMAIL="${LE_EMAIL:-}"                 # Pflicht: E-Mail fuer Let's Encrypt
PUBLIC_IP="${PUBLIC_IP:-}"               # Pflicht: feste oeffentliche IPv4 mit CIDR, z.B. 203.0.113.10/24
GATEWAY="${GATEWAY:-}"                   # Pflicht: IPv4-Gateway
PUBLIC_IP6="${PUBLIC_IP6:-}"             # optional: IPv6 mit CIDR, z.B. 2001:db8::10/64
GATEWAY6="${GATEWAY6:-}"                 # optional: IPv6-Gateway
CT_MAC="${CT_MAC:-}"                     # optional: feste MAC (manche Hoster verlangen das fuer Zusatz-IPs)
BRIDGE="${BRIDGE:-vmbr0}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"

CTID="${CTID:-}"                         # leer = naechste freie ID
CT_HOSTNAME="${CT_HOSTNAME:-cloudreve}"
CT_PASSWORD="${CT_PASSWORD:-}"           # leer = zufaellig, wird am Ende ausgegeben
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"   # optional: Public Key fuer root-Login im Container
STORAGE="${STORAGE:-local-lvm}"          # Storage fuer rootfs (und Daten-Volume)
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE_PATTERN="${TEMPLATE_PATTERN:-debian-12-standard}"
DISK_GB="${DISK_GB:-16}"                 # Groesse rootfs
DATA_DISK_GB="${DATA_DISK_GB:-0}"        # >0 = separates Volume fuer /opt/cloudreve/data (Uploads)
MEMORY_MB="${MEMORY_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
CORES="${CORES:-2}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
START_ONBOOT="${START_ONBOOT:-1}"
PVE_FIREWALL="${PVE_FIREWALL:-1}"        # Regelsatz fuer den Container anlegen (22/80/443 offen)

# Werden 1:1 an cloudreve-setup.sh durchgereicht (siehe dort fuer Bedeutung)
CLOUDREVE_VERSION="${CLOUDREVE_VERSION:-latest}"
USE_POSTGRES="${USE_POSTGRES:-1}"
USE_REDIS="${USE_REDIS:-1}"
HTTP_REDIRECT="${HTTP_REDIRECT:-1}"
INSTALL_MEDIA_TOOLS="${INSTALL_MEDIA_TOOLS:-1}"
SKIP_LETSENCRYPT="${SKIP_LETSENCRYPT:-0}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

SETUP_SCRIPT_NAME="cloudreve-setup.sh"
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/reichiClaw/reichi.cloud/main/${SETUP_SCRIPT_NAME}"

# ----------------------------------------------------------------------------
# Hilfsfunktionen
# ----------------------------------------------------------------------------
log()  { printf '\e[1;34m[host]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[host!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[host x]\e[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Fehler in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

valid_ipv4_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
valid_ipv4()      { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

ct_exec() { pct exec "$CTID" -- "$@"; }

preflight() {
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
  for cmd in pct pveam pvesh pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' nicht gefunden - ist das ein Proxmox-VE-Host?"
  done

  [[ -n "$PUBLIC_IP" ]] || die "PUBLIC_IP fehlt (z.B. PUBLIC_IP=203.0.113.10/24)."
  valid_ipv4_cidr "$PUBLIC_IP" || die "PUBLIC_IP muss IPv4 mit CIDR sein, z.B. 203.0.113.10/24 (aktuell: $PUBLIC_IP)."
  [[ -n "$GATEWAY" ]] || die "GATEWAY fehlt (z.B. GATEWAY=203.0.113.1)."
  valid_ipv4 "$GATEWAY" || die "GATEWAY ist keine gueltige IPv4-Adresse: $GATEWAY"
  if [[ -n "$PUBLIC_IP6" && -z "$GATEWAY6" ]]; then
    die "PUBLIC_IP6 gesetzt, aber GATEWAY6 fehlt."
  fi
  if [[ "$SKIP_LETSENCRYPT" != "1" && -z "$LE_EMAIL" ]]; then
    die "LE_EMAIL fehlt (fuer Let's Encrypt). Alternativ SKIP_LETSENCRYPT=1."
  fi
  if [[ -n "$SSH_PUBKEY_FILE" && ! -r "$SSH_PUBKEY_FILE" ]]; then
    die "SSH_PUBKEY_FILE nicht lesbar: $SSH_PUBKEY_FILE"
  fi

  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE existiert nicht auf diesem Host."
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage $STORAGE nicht gefunden."
  pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Template-Storage $TEMPLATE_STORAGE nicht gefunden."

  if [[ -z "$CTID" ]]; then
    CTID=$(pvesh get /cluster/nextid)
  fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID muss numerisch sein: $CTID"
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CTID $CTID ist bereits belegt. Anderen Wert mit CTID=... angeben."
  fi

  log "Container #$CTID ($CT_HOSTNAME) -> $PUBLIC_IP via $GATEWAY auf $BRIDGE, Domain $DOMAIN"
}

locate_setup_script() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/$SETUP_SCRIPT_NAME" ]]; then
    SETUP_SCRIPT_PATH="$here/$SETUP_SCRIPT_NAME"
  else
    log "$SETUP_SCRIPT_NAME nicht lokal gefunden, lade von GitHub ..."
    SETUP_SCRIPT_PATH="$(mktemp)"
    curl -fsSL -o "$SETUP_SCRIPT_PATH" "$SETUP_SCRIPT_URL" || die "Download fehlgeschlagen: $SETUP_SCRIPT_URL"
  fi
  bash -n "$SETUP_SCRIPT_PATH" || die "Syntaxfehler in $SETUP_SCRIPT_PATH"
}

ensure_template() {
  log "Template-Liste aktualisieren ..."
  pveam update >/dev/null

  TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep "^${TEMPLATE_PATTERN}" | sort -V | tail -n1 || true)
  [[ -n "$TEMPLATE" ]] || die "Kein Template passend zu '$TEMPLATE_PATTERN' gefunden."

  if pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -q "vztmpl/${TEMPLATE}$"; then
    log "Template $TEMPLATE bereits vorhanden."
  else
    log "Template $TEMPLATE herunterladen ..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi
  TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
}

create_container() {
  local net0="name=eth0,bridge=${BRIDGE},ip=${PUBLIC_IP},gw=${GATEWAY},firewall=1"
  [[ -n "$PUBLIC_IP6" ]] && net0+=",ip6=${PUBLIC_IP6},gw6=${GATEWAY6}"
  [[ -n "$CT_MAC" ]] && net0+=",hwaddr=${CT_MAC}"

  local features="nesting=1"
  [[ "$UNPRIVILEGED" == "1" ]] && features+=",keyctl=1"

  local -a args=(
    "$CTID" "$TEMPLATE_VOLID"
    --hostname "$CT_HOSTNAME"
    --ostype debian
    --cores "$CORES"
    --memory "$MEMORY_MB"
    --swap "$SWAP_MB"
    --rootfs "${STORAGE}:${DISK_GB}"
    --net0 "$net0"
    --nameserver "$DNS_SERVERS"
    --searchdomain "$DOMAIN"
    --unprivileged "$UNPRIVILEGED"
    --features "$features"
    --onboot "$START_ONBOOT"
    --tags "cloudreve"
    --description "Cloudreve ($DOMAIN) - erstellt von install-cloudreve-proxmox.sh"
    --start 0
  )
  [[ -n "$SSH_PUBKEY_FILE" ]] && args+=(--ssh-public-keys "$SSH_PUBKEY_FILE")

  log "Container anlegen ..."
  pct create "${args[@]}"

  if [[ "$DATA_DISK_GB" -gt 0 ]]; then
    log "Daten-Volume (${DATA_DISK_GB}G) fuer /opt/cloudreve/data anlegen ..."
    pct set "$CTID" --mp0 "${STORAGE}:${DATA_DISK_GB},mp=/opt/cloudreve/data,backup=1"
  fi

  if [[ "$PVE_FIREWALL" == "1" ]]; then
    # Greift nur, wenn die Proxmox-Firewall auf Datacenter-Ebene aktiv ist.
    # Dann sind trotzdem nur SSH, HTTP und HTTPS von aussen erreichbar.
    log "Proxmox-Firewall-Regeln fuer den Container schreiben ..."
    cat > "/etc/pve/firewall/${CTID}.fw" <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p tcp -dport 22 -log nolog
IN ACCEPT -p tcp -dport 80 -log nolog
IN ACCEPT -p tcp -dport 443 -log nolog
IN ACCEPT -p icmp -log nolog
IN ACCEPT -p ipv6-icmp -log nolog
EOF
  fi
}

start_container() {
  log "Container starten ..."
  pct start "$CTID"

  log "Warte auf Netzwerk im Container ..."
  local i
  for i in $(seq 1 60); do
    if ct_exec bash -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
      log "Netzwerk ok (nach ${i}s)."
      return
    fi
    sleep 1
  done
  warn "Container hat nach 60s keine Namensaufloesung. Netzwerk-Konfiguration pruefen (IP/Gateway/Bridge/MAC)."
  ct_exec ip -4 addr show eth0 || true
  ct_exec ip route || true
  die "Abbruch - Container $CTID bleibt zur Analyse bestehen."
}

set_root_password() {
  if [[ -z "$CT_PASSWORD" ]]; then
    CT_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
    GENERATED_PASSWORD=1
  fi
  # ueber stdin, damit das Passwort nicht in der Prozessliste auftaucht
  printf 'root:%s\n' "$CT_PASSWORD" | ct_exec chpasswd
}

run_setup() {
  log "Setup-Script in den Container kopieren ..."
  pct push "$CTID" "$SETUP_SCRIPT_PATH" "/root/$SETUP_SCRIPT_NAME" --perms 0755

  log "Cloudreve im Container installieren (dauert einige Minuten) ..."
  ct_exec env \
    DOMAIN="$DOMAIN" \
    LE_EMAIL="$LE_EMAIL" \
    PUBLIC_IP="${PUBLIC_IP%%/*}" \
    CLOUDREVE_VERSION="$CLOUDREVE_VERSION" \
    USE_POSTGRES="$USE_POSTGRES" \
    USE_REDIS="$USE_REDIS" \
    HTTP_REDIRECT="$HTTP_REDIRECT" \
    INSTALL_MEDIA_TOOLS="$INSTALL_MEDIA_TOOLS" \
    SKIP_LETSENCRYPT="$SKIP_LETSENCRYPT" \
    TIMEZONE="$TIMEZONE" \
    bash "/root/$SETUP_SCRIPT_NAME"
}

print_summary() {
  cat <<EOF

#############################################################################
 Fertig. Proxmox-Container #$CTID ($CT_HOSTNAME)
#############################################################################
 Cloudreve:        https://$DOMAIN
 IP:               ${PUBLIC_IP}${PUBLIC_IP6:+  /  $PUBLIC_IP6}
 Template:         $TEMPLATE
 Root-Passwort:    $( [[ "${GENERATED_PASSWORD:-0}" == "1" ]] && echo "$CT_PASSWORD  (generiert - bitte notieren!)" || echo "(wie vorgegeben)" )

 Zugriff:          pct enter $CTID
 Logs:             pct exec $CTID -- journalctl -u cloudreve -f
 Update:           pct exec $CTID -- env CLOUDREVE_VERSION=latest bash /root/$SETUP_SCRIPT_NAME
 Zertifikat:       pct exec $CTID -- cloudreve-issue-cert

 Firewall:         $( [[ "$PVE_FIREWALL" == "1" ]] && echo "/etc/pve/firewall/${CTID}.fw (22/80/443 offen; aktiv nur bei eingeschalteter Datacenter-Firewall)" || echo "keine Container-Regeln angelegt" )
#############################################################################
EOF
}

main() {
  preflight
  locate_setup_script
  ensure_template
  create_container
  start_container
  set_root_password
  run_setup
  print_summary
}

main "$@"
