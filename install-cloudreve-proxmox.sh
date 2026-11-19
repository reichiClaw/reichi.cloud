#!/usr/bin/env bash
# =============================================================================
# install-cloudreve-proxmox.sh
#
# Legt auf einem Proxmox-VE-Host einen Debian-LXC-Container mit fester IP an
# und installiert darin Cloudreve (v4) mit eigenem TLS-Endpunkt
# (Let's Encrypt) - ohne Reverse Proxy.
#
# Aufruf auf dem Proxmox-Host als root, z.B.:
#
#   # Bridge im LAN 10.2.0.0/24, Router leitet die oeffentliche IP auf den Container:
#   CT_IP=10.2.0.5 GATEWAY=10.2.0.1 BRIDGE=vmbr1 PUBLIC_IP=91.112.42.60 \
#   DATA_HOST_DIR=/mnt/pve/CloudStorage/cloudreve LE_EMAIL=admin@reichi.cloud \
#     bash install-cloudreve-proxmox.sh
#
#   # Private Bridge, oeffentliche IP am Host (DNAT 80/443 wird eingerichtet):
#   CT_IP=10.2.0.5 BRIDGE=vmbr1 BRIDGE_IP=10.2.0.1/24 PUBLIC_IP=91.112.42.60 \
#   LE_EMAIL=admin@reichi.cloud bash install-cloudreve-proxmox.sh
#
#   # Container hat die oeffentliche IP selbst:
#   CT_IP=203.0.113.10/24 GATEWAY=203.0.113.1 LE_EMAIL=admin@reichi.cloud \
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

# --- Netzwerk ----------------------------------------------------------------
# Drei Betriebsarten:
#  a) Container hat die oeffentliche IP selbst:  CT_IP=203.0.113.10/24 GATEWAY=203.0.113.1
#  b) Bridge haengt an einem LAN mit eigenem Router, der die oeffentliche IP auf den
#     Container weiterleitet:  CT_IP=10.2.0.5 GATEWAY=10.2.0.1 BRIDGE=vmbr1 PUBLIC_IP=91.112.42.60
#     -> kein NAT am Host (PUBLIC_IP dient nur dem DNS-Check).
#  c) Private Bridge, die oeffentliche IP liegt am Proxmox-Host selbst:
#     CT_IP=10.2.0.5 BRIDGE=vmbr1 BRIDGE_IP=10.2.0.1/24 PUBLIC_IP=91.112.42.60
#     -> Script richtet DNAT (80/443) vom Host auf den Container ein.
CT_IP="${CT_IP:-}"                       # Pflicht: IPv4 des Containers, mit oder ohne CIDR
GATEWAY="${GATEWAY:-}"                   # IPv4-Gateway; leer = IP des Hosts auf $BRIDGE
PUBLIC_IP="${PUBLIC_IP:-}"               # oeffentliche IPv4 (ohne CIDR), unter der $DOMAIN erreichbar ist
NAT_FORWARD="${NAT_FORWARD:-auto}"       # auto = an, wenn PUBLIC_IP gesetzt und != CT_IP
NAT_PORTS="${NAT_PORTS:-80 443}"         # Ports, die vom Host auf den Container weitergeleitet werden
WAN_IFACE="${WAN_IFACE:-}"               # Host-Interface mit der oeffentlichen IP; leer = Default-Route
PUBLIC_IP6="${PUBLIC_IP6:-}"             # optional: IPv6 des Containers mit CIDR, z.B. 2001:db8::10/64
GATEWAY6="${GATEWAY6:-}"                 # optional: IPv6-Gateway
CT_MAC="${CT_MAC:-}"                     # optional: feste MAC (manche Hoster verlangen das fuer Zusatz-IPs)
BRIDGE="${BRIDGE:-vmbr0}"
BRIDGE_IP="${BRIDGE_IP:-}"               # optional: IPv4/CIDR, die der Host auf $BRIDGE bekommen soll (z.B. 10.2.0.1/24),
                                         # falls die Bridge noch keine hat; wird in /etc/network/interfaces persistiert
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
DATA_HOST_DIR="${DATA_HOST_DIR:-}"       # Host-Verzeichnis, das als /opt/cloudreve/data in den Container gemountet wird
                                         # (z.B. /mnt/pve/CloudStorage/cloudreve); schliesst DATA_DISK_GB aus
CT_DATA_DIR="/opt/cloudreve/data"
SERVICE_UID="${SERVICE_UID:-1500}"       # UID des cloudreve-Users im Container (Host-seitig: 100000 + UID bei unprivilegiert)
RESUME=0                                 # 1 = bestehender Container, Setup wird nur erneut ausgefuehrt
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

# Erste IPv4 (mit CIDR) des Hosts auf der Bridge, z.B. 10.2.0.1/24
bridge_addr() { { ip -4 -o addr show dev "$BRIDGE" 2>/dev/null || true; } | awk '{print $4; exit}'; }

bridge_has_address_in_interfaces() {
  awk -v br="$BRIDGE" '
    $1=="iface" && $2==br {in_stanza=1; next}
    /^(iface|auto|allow-|source)/ {in_stanza=0}
    in_stanza && $1=="address" {found=1}
    END {exit !found}' /etc/network/interfaces
}

configure_bridge_ip() {
  [[ -n "$BRIDGE_IP" ]] || return 0
  valid_ipv4_cidr "$BRIDGE_IP" || die "BRIDGE_IP muss IPv4 mit CIDR sein, z.B. 10.2.0.1/24 (aktuell: $BRIDGE_IP)."

  local current
  current=$(bridge_addr)
  if [[ "$current" == "$BRIDGE_IP" ]]; then
    log "$BRIDGE hat bereits $BRIDGE_IP."
    return 0
  fi
  if [[ -n "$current" ]]; then
    die "$BRIDGE hat bereits $current - BRIDGE_IP=$BRIDGE_IP passt nicht dazu. BRIDGE_IP weglassen oder angleichen."
  fi

  local f=/etc/network/interfaces backup
  grep -qE "^iface $BRIDGE inet " "$f" || die "$BRIDGE ist nicht in $f definiert - bitte die Bridge-IP in der Proxmox-UI (Node -> Network) setzen."
  backup="$f.bak-cloudreve-$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$backup"
  log "Setze $BRIDGE_IP auf $BRIDGE (Backup: $backup) ..."

  if grep -qE "^iface $BRIDGE inet manual" "$f"; then
    sed -i "s|^iface $BRIDGE inet manual|iface $BRIDGE inet static\n\taddress $BRIDGE_IP|" "$f"
  elif grep -qE "^iface $BRIDGE inet static" "$f" && ! bridge_has_address_in_interfaces; then
    sed -i "/^iface $BRIDGE inet static/a\\\taddress $BRIDGE_IP" "$f"
  else
    die "Unerwartete Konfiguration fuer $BRIDGE in $f - bitte die IP manuell in der Proxmox-UI setzen."
  fi

  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a || die "ifreload -a fehlgeschlagen; $f wurde geaendert (Backup: $backup)."
  else
    ip addr add "$BRIDGE_IP" dev "$BRIDGE"
  fi
  ip link set "$BRIDGE" up
  [[ "$(bridge_addr)" == "$BRIDGE_IP" ]] || die "$BRIDGE hat nach dem Reload nicht $BRIDGE_IP."
}

resolve_network() {
  configure_bridge_ip
  # Abwaertskompatibel: frueher wurde die Container-IP als PUBLIC_IP=<ip>/<cidr> uebergeben.
  if [[ -z "$CT_IP" && "$PUBLIC_IP" == */* ]]; then
    CT_IP="$PUBLIC_IP"; PUBLIC_IP="${PUBLIC_IP%%/*}"
  fi
  [[ -n "$CT_IP" ]] || die "CT_IP fehlt (z.B. CT_IP=10.2.0.5 oder CT_IP=203.0.113.10/24)."

  local br_addr
  br_addr=$(bridge_addr)

  if [[ "$CT_IP" != */* ]]; then
    valid_ipv4 "$CT_IP" || die "CT_IP ist keine gueltige IPv4-Adresse: $CT_IP"
    if [[ -n "$br_addr" ]]; then
      CT_IP="$CT_IP/${br_addr##*/}"
    else
      log "Keine IPv4 auf $BRIDGE, nehme /24 fuer $CT_IP an (sonst CT_IP mit CIDR angeben)."
      CT_IP="$CT_IP/24"
    fi
  fi
  valid_ipv4_cidr "$CT_IP" || die "CT_IP muss IPv4 (optional mit CIDR) sein, aktuell: $CT_IP"

  if [[ -z "$GATEWAY" ]]; then
    [[ -n "$br_addr" ]] || die "GATEWAY fehlt und $BRIDGE hat keine IPv4-Adresse. Entweder GATEWAY=<Router-IP im Container-Netz> angeben (Bridge haengt an einem LAN mit eigenem Router) oder BRIDGE_IP=10.2.0.1/24 setzen, wenn der Proxmox-Host selbst Gateway/NAT fuer den Container sein soll."
    GATEWAY="${br_addr%%/*}"
    log "GATEWAY nicht angegeben, verwende Host-IP auf $BRIDGE: $GATEWAY"
  fi
  valid_ipv4 "$GATEWAY" || die "GATEWAY ist keine gueltige IPv4-Adresse: $GATEWAY"

  if [[ -n "$PUBLIC_IP" ]]; then
    valid_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP muss eine IPv4 ohne CIDR sein: $PUBLIC_IP"
  fi

  local public_ip_on_host=0
  if [[ -n "$PUBLIC_IP" ]] && ip -4 -o addr show | grep -q " ${PUBLIC_IP}/"; then
    public_ip_on_host=1
  fi

  if [[ "$NAT_FORWARD" == "auto" ]]; then
    NAT_FORWARD=0
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "${CT_IP%%/*}" ]]; then
      if [[ "$public_ip_on_host" == "1" ]]; then
        NAT_FORWARD=1
      else
        log "PUBLIC_IP $PUBLIC_IP liegt nicht auf diesem Host -> kein NAT am Host. Das Port-Forwarding 80/443 -> ${CT_IP%%/*} muss auf dem Router passieren."
      fi
    fi
  fi

  if [[ "$NAT_FORWARD" == "1" ]]; then
    [[ -n "$PUBLIC_IP" ]] || die "NAT_FORWARD=1 benoetigt PUBLIC_IP."
    command -v iptables >/dev/null 2>&1 || die "iptables nicht gefunden (fuer NAT_FORWARD benoetigt)."
    if [[ -z "$WAN_IFACE" ]]; then
      WAN_IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
    [[ -n "$WAN_IFACE" ]] || die "WAN_IFACE konnte nicht ermittelt werden (keine Default-Route?). Bitte WAN_IFACE=... setzen."
    [[ "$public_ip_on_host" == "1" ]] || warn "PUBLIC_IP $PUBLIC_IP ist auf diesem Host auf keinem Interface konfiguriert - DNAT greift nur, wenn der Traffic hier ankommt."
  fi
}

preflight() {
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
  for cmd in pct pveam pvesh pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' nicht gefunden - ist das ein Proxmox-VE-Host?"
  done

  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE existiert nicht auf diesem Host."
  resolve_network

  if [[ -n "$PUBLIC_IP6" && -z "$GATEWAY6" ]]; then
    die "PUBLIC_IP6 gesetzt, aber GATEWAY6 fehlt."
  fi
  if [[ "$SKIP_LETSENCRYPT" != "1" && -z "$LE_EMAIL" ]]; then
    die "LE_EMAIL fehlt (fuer Let's Encrypt). Alternativ SKIP_LETSENCRYPT=1."
  fi
  if [[ -n "$SSH_PUBKEY_FILE" && ! -r "$SSH_PUBKEY_FILE" ]]; then
    die "SSH_PUBKEY_FILE nicht lesbar: $SSH_PUBKEY_FILE"
  fi
  if [[ -n "$DATA_HOST_DIR" ]]; then
    [[ "$DATA_HOST_DIR" == /* ]] || die "DATA_HOST_DIR muss ein absoluter Pfad sein: $DATA_HOST_DIR"
    [[ "$DATA_DISK_GB" -eq 0 ]] || die "DATA_HOST_DIR und DATA_DISK_GB schliessen sich aus."
    local parent="$DATA_HOST_DIR"
    while [[ "$parent" != "/" ]] && ! mountpoint -q "$parent" 2>/dev/null; do
      parent=$(dirname "$parent")
    done
    if ! mountpoint -q "$parent" 2>/dev/null && [[ "$DATA_HOST_DIR" == /mnt/* ]]; then
      warn "$DATA_HOST_DIR liegt unter keinem Mountpoint - sicher, dass das Storage gemountet ist?"
    fi
  fi

  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage $STORAGE nicht gefunden."
  pvesm status --storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Template-Storage $TEMPLATE_STORAGE nicht gefunden."

  local existing=""
  existing=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" 'NR>1 && $NF==h {print $1; exit}') || true
  if [[ -z "$CTID" ]]; then
    if [[ -n "$existing" ]]; then
      CTID="$existing"
      RESUME=1
    else
      CTID=$(pvesh get /cluster/nextid)
    fi
  fi
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID muss numerisch sein: $CTID"
  if pct status "$CTID" >/dev/null 2>&1; then
    RESUME=1
    log "Container #$CTID existiert bereits - Installation wird fortgesetzt (kein Neu-Anlegen)."
  elif [[ -n "$existing" && "$existing" != "$CTID" ]]; then
    die "Hostname $CT_HOSTNAME ist bereits Container #$existing. CTID=$existing setzen oder den alten Container entfernen."
  fi

  log "Container #$CTID ($CT_HOSTNAME) -> $CT_IP via $GATEWAY auf $BRIDGE, Domain $DOMAIN"
  if [[ "$NAT_FORWARD" == "1" ]]; then
    log "NAT: $PUBLIC_IP ($WAN_IFACE) Ports $NAT_PORTS -> ${CT_IP%%/*}"
  fi
  [[ -n "$DATA_HOST_DIR" ]] && log "Daten: $DATA_HOST_DIR -> $CT_DATA_DIR (Bind-Mount)"
  return 0
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

# UID, unter der der cloudreve-User des Containers auf dem Host erscheint
host_svc_uid() {
  if [[ "$UNPRIVILEGED" == "1" ]]; then echo $((100000 + SERVICE_UID)); else echo "$SERVICE_UID"; fi
}

# Bestehende pvesm --options behalten und uid/gid fuer den Container-User setzen.
merge_cifs_uid() {
  local storage=$1 want=$2
  local current merged
  current=$(pvesm config "$storage" 2>/dev/null | awk '
    /^[[:space:]]*options:[[:space:]]*/ {
      sub(/^[[:space:]]*options:[[:space:]]*/, ""); print; exit
    }
    /^[[:space:]]*options[[:space:]]+/ {
      sub(/^[[:space:]]*options[[:space:]]+/, ""); print; exit
    }') || current=""
  # grep -v kann Exit 1 liefern, wenn alle Zeilen rausgefiltert werden (pipefail)
  merged=$(
    set +o pipefail
    printf '%s\n' "$current" | tr ',' '\n' \
      | grep -Ev '^(uid|gid|file_mode|dir_mode|forceuid|forcegid)=' \
      | grep -Ev '^(forceuid|forcegid)$' \
      | grep -v '^$' \
      | paste -sd, -
  )
  merged="${merged:+$merged,}uid=${want},gid=${want},file_mode=0660,dir_mode=0770,forceuid,forcegid"
  log "CIFS-Storage $storage: Mount-Optionen auf uid=$want setzen ..."
  pvesm set "$storage" --options "$merged"
}

remount_pve_storage() {
  local storage=$1 mp="/mnt/pve/$1"
  log "Storage $storage neu einhaengen ..."
  if mountpoint -q "$mp"; then
    umount "$mp" || umount -l "$mp" || die "umount $mp fehlgeschlagen (wird der Pfad gerade benutzt?)."
  fi
  local i
  for i in $(seq 1 30); do
    pvesm status --storage "$storage" >/dev/null 2>&1 || true
    if mountpoint -q "$mp"; then
      log "$mp ist nach ${i}s wieder gemountet."
      return 0
    fi
    sleep 1
  done
  die "$mp wurde nach dem umount nicht automatisch neu gemountet. Mit 'pvesm status' pruefen."
}

host_can_write_as() {
  local dir=$1 uid=$2
  local tmp rc=0
  command -v setpriv >/dev/null 2>&1 || return 0
  # Nicht direkt über $dir testen: /mnt/pve/<storage> ist oft 0700 (root), dann
  # scheitert uid $uid am Parent, obwohl der Container das Verzeichnis per
  # Bind-Mount ohne den Parent-Pfad erreicht.
  tmp=$(mktemp -d /tmp/cr-rwtest.XXXXXX)
  chmod 755 "$tmp"
  if ! mount --bind "$dir" "$tmp"; then
    rmdir "$tmp" 2>/dev/null || true
    return 1
  fi
  # shellcheck disable=SC2016
  setpriv --reuid="$uid" --regid="$uid" --clear-groups -- \
    sh -c 'f="$1/.host-rw.$$"; : > "$f" && rm -f "$f"' sh "$tmp" || rc=$?
  umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
  return "$rc"
}

prepare_data_dir() {
  [[ -n "$DATA_HOST_DIR" ]] || return 0
  local want fstype opts storage
  want=$(host_svc_uid)
  log "Host-Verzeichnis $DATA_HOST_DIR vorbereiten (Owner soll uid $want sein) ..."
  mkdir -p "$DATA_HOST_DIR"

  fstype=$(findmnt -n -o FSTYPE -T "$DATA_HOST_DIR" 2>/dev/null || echo "?")
  opts=$(findmnt -n -o OPTIONS -T "$DATA_HOST_DIR" 2>/dev/null || true)
  storage=""
  [[ "$DATA_HOST_DIR" == /mnt/pve/* ]] && { storage="${DATA_HOST_DIR#/mnt/pve/}"; storage="${storage%%/*}"; }

  case "$fstype" in
    cifs|smb3)
      # CIFS kennt kein chown; Owner kommt aus der Mount-Option uid=/gid=.
      if [[ ",$opts," != *",uid=${want},"* ]]; then
        [[ -n "$storage" ]] || die "CIFS-Mount ohne uid=$want und kein PVE-Storage-Name ableitbar. Mount-Option uid=$want,gid=$want setzen."
        merge_cifs_uid "$storage" "$want"
        remount_pve_storage "$storage"
        mkdir -p "$DATA_HOST_DIR"
        opts=$(findmnt -n -o OPTIONS -T "$DATA_HOST_DIR" 2>/dev/null || true)
        [[ ",$opts," == *",uid=${want},"* ]] || die "CIFS-Share hat nach dem Remount immer noch nicht uid=$want (Optionen: $opts)."
      fi
      ;;
    nfs|nfs4)
      # chown geht nur, wenn der Export root nicht squasht (no_root_squash).
      if [[ "$(stat -c %u "$DATA_HOST_DIR")" != "$want" ]]; then
        chown "$want:$want" "$DATA_HOST_DIR" 2>/dev/null || {
          warn "chown auf dem NFS-Share $DATA_HOST_DIR nicht moeglich (root_squash?)."
          warn "Auf dem NFS-Server ausfuehren: chown $want:$want <Export-Pfad>/${DATA_HOST_DIR#/mnt/pve/*/}"
          die "NFS-Berechtigungen anpassen und Script erneut starten."
        }
      fi
      ;;
    *)
      # lokales Dateisystem (ext4/zfs/xfs/...): chown reicht. Nicht rekursiv, data/ kann gross sein.
      if [[ "$(stat -c %u "$DATA_HOST_DIR")" != "$want" ]]; then
        chown "$want:$want" "$DATA_HOST_DIR" || die "chown $want:$want $DATA_HOST_DIR fehlgeschlagen (Dateisystem $fstype)."
      fi
      ;;
  esac
  chmod 750 "$DATA_HOST_DIR" 2>/dev/null || true
  if ! host_can_write_as "$DATA_HOST_DIR" "$want"; then
    warn "uid $want kann nicht in $DATA_HOST_DIR schreiben (Dateisystem $fstype, $(stat -c 'Owner %u:%g %A' "$DATA_HOST_DIR"))."
    if [[ "$fstype" == nfs || "$fstype" == nfs4 ]]; then
      warn "Der Container wuerde dort genauso scheitern. Auf dem NFS-Server pruefen:"
      warn "  - kein all_squash (mappt jede UID auf nobody)"
      warn "  - chmod u+w auf dem Ordner, Owner UID $want (unprivilegierter LXC: 100000+${SERVICE_UID})"
      warn "  - NFS4-Idmap: numerische UID $want muss auf dem NAS existieren oder idmapping aus (nfsd-Disable)"
    fi
    die "Datenverzeichnis nicht beschreibbar."
  fi
  log "Dateisystem: $fstype, Owner: $(stat -c %u:%g "$DATA_HOST_DIR")"
}

create_container() {
  local net0="name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${GATEWAY},firewall=1"
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

  if [[ -n "$DATA_HOST_DIR" ]]; then
    log "Bind-Mount $DATA_HOST_DIR -> $CT_DATA_DIR einrichten ..."
    pct set "$CTID" --mp0 "${DATA_HOST_DIR},mp=${CT_DATA_DIR}"
  elif [[ "$DATA_DISK_GB" -gt 0 ]]; then
    log "Daten-Volume (${DATA_DISK_GB}G) fuer $CT_DATA_DIR anlegen ..."
    pct set "$CTID" --mp0 "${STORAGE}:${DATA_DISK_GB},mp=${CT_DATA_DIR},backup=1"
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

NAT_SCRIPT="/usr/local/sbin/cloudreve-nat"
setup_nat() {
  [[ "$NAT_FORWARD" == "1" ]] || return 0
  local ct_ip="${CT_IP%%/*}"
  log "Port-Forwarding $PUBLIC_IP -> $ct_ip (TCP $NAT_PORTS) auf dem Host einrichten ..."

  cat > /etc/sysctl.d/99-cloudreve-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl -q -p /etc/sysctl.d/99-cloudreve-forward.conf

  cat > "$NAT_SCRIPT" <<EOF
#!/usr/bin/env bash
# Leitet TCP $NAT_PORTS von $PUBLIC_IP ($WAN_IFACE) an den Cloudreve-Container $ct_ip weiter.
# Idempotent: Regeln werden nur angelegt, wenn sie noch nicht existieren.
# Erzeugt von install-cloudreve-proxmox.sh - wird beim Boot ueber cloudreve-nat.service ausgefuehrt.
set -euo pipefail
PUBLIC_IP="$PUBLIC_IP"
CT_IP="$ct_ip"
WAN_IFACE="$WAN_IFACE"
PORTS="$NAT_PORTS"

add() { # <table> <chain> <rule...>
  local table=\$1 chain=\$2; shift 2
  iptables -w -t "\$table" -C "\$chain" "\$@" 2>/dev/null || iptables -w -t "\$table" -A "\$chain" "\$@"
}

for p in \$PORTS; do
  add nat PREROUTING -d "\$PUBLIC_IP/32" -p tcp --dport "\$p" -j DNAT --to-destination "\$CT_IP:\$p"
  add filter FORWARD -d "\$CT_IP/32" -p tcp --dport "\$p" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
done
add filter FORWARD -s "\$CT_IP/32" -j ACCEPT
# Ausgehender Traffic des Containers (Updates, Let's Encrypt) ueber die oeffentliche IP
add nat POSTROUTING -s "\$CT_IP/32" -o "\$WAN_IFACE" -j SNAT --to-source "\$PUBLIC_IP"
EOF
  chmod 755 "$NAT_SCRIPT"

  cat > /etc/systemd/system/cloudreve-nat.service <<EOF
[Unit]
Description=Cloudreve NAT port forwarding ($PUBLIC_IP -> $ct_ip)
After=network-online.target pve-firewall.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NAT_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudreve-nat.service >/dev/null || die "cloudreve-nat.service konnte nicht gestartet werden: journalctl -u cloudreve-nat"
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
    LC_ALL=C.UTF-8 LANG=C.UTF-8 \
    DOMAIN="$DOMAIN" \
    LE_EMAIL="$LE_EMAIL" \
    SERVICE_UID="$SERVICE_UID" \
    PUBLIC_IP="${PUBLIC_IP:-${CT_IP%%/*}}" \
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
 Container-IP:     ${CT_IP} auf ${BRIDGE}${PUBLIC_IP6:+  /  $PUBLIC_IP6}
 NAT:              $( [[ "$NAT_FORWARD" == "1" ]] && echo "$PUBLIC_IP ($WAN_IFACE) TCP $NAT_PORTS -> ${CT_IP%%/*}  [$NAT_SCRIPT, cloudreve-nat.service]" || echo "keins (Container ist direkt erreichbar)" )
 Daten:            $( [[ -n "$DATA_HOST_DIR" ]] && echo "$DATA_HOST_DIR (Host) -> $CT_DATA_DIR" || echo "$CT_DATA_DIR im Container" )
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

stop_for_remount() {
  [[ "$RESUME" == "1" ]] || return 0
  if pct status "$CTID" 2>/dev/null | grep -qi running; then
    log "Container #$CTID kurz stoppen, damit das Daten-Storage neu gemountet werden kann ..."
    pct shutdown "$CTID" --timeout 20 >/dev/null 2>&1 || pct stop "$CTID"
  fi
}

main() {
  preflight
  locate_setup_script
  if [[ "$RESUME" == "1" ]]; then
    TEMPLATE="${TEMPLATE:-bestehend}"
  else
    ensure_template
  fi
  stop_for_remount
  prepare_data_dir
  [[ "$RESUME" == "1" ]] || create_container
  setup_nat
  start_container
  set_root_password
  run_setup
  print_summary
}

main "$@"
