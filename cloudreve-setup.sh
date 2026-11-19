#!/usr/bin/env bash
# =============================================================================
# cloudreve-setup.sh
#
# Installiert Cloudreve (v4) auf einem Debian/Ubuntu-System (LXC-Container
# oder VM) OHNE Reverse Proxy. Cloudreve terminiert TLS selbst auf Port 443,
# das Zertifikat kommt von Let's Encrypt (certbot).
#
# Wird normalerweise von install-cloudreve-proxmox.sh im Container
# aufgerufen, kann aber auch direkt auf einer VM ausgefuehrt werden:
#
#   DOMAIN=reichi.cloud LE_EMAIL=admin@reichi.cloud bash cloudreve-setup.sh
#
# Erneutes Ausfuehren ist ungefaehrlich: bestehende Konfiguration/Datenbank
# bleiben erhalten, das Binary wird auf die gewuenschte Version aktualisiert.
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Konfiguration (per Umgebungsvariable ueberschreibbar)
# ----------------------------------------------------------------------------
DOMAIN="${DOMAIN:-reichi.cloud}"
LE_EMAIL="${LE_EMAIL:-}"                       # Pflicht, ausser SKIP_LETSENCRYPT=1
PUBLIC_IP="${PUBLIC_IP:-}"                     # optional, nur fuer DNS-Check (ohne /CIDR)
CLOUDREVE_VERSION="${CLOUDREVE_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cloudreve}"
SERVICE_USER="${SERVICE_USER:-cloudreve}"
SERVICE_UID="${SERVICE_UID:-1500}"             # feste UID, damit Bind-Mounts/Shares vom Host aus passend berechtigt werden koennen
USE_POSTGRES="${USE_POSTGRES:-1}"              # 1 = PostgreSQL (empfohlen), 0 = SQLite
USE_REDIS="${USE_REDIS:-1}"                    # 1 = lokaler Redis als Cache
HTTP_REDIRECT="${HTTP_REDIRECT:-1}"            # 1 = Port 80 -> 301 https:// (minimaler nginx, KEIN Proxy)
INSTALL_MEDIA_TOOLS="${INSTALL_MEDIA_TOOLS:-1}" # ffmpeg + libvips fuer Thumbnails/Video-Metadaten
INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-1}"
SKIP_LETSENCRYPT="${SKIP_LETSENCRYPT:-0}"      # 1 = nur Self-Signed-Zertifikat
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

DATA_DIR="$INSTALL_DIR/data"
SSL_DIR="$DATA_DIR/ssl"
CONF_FILE="$DATA_DIR/conf.ini"
BIN="$INSTALL_DIR/cloudreve"
DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/cloudreve.sh"
ISSUE_HELPER="/usr/local/sbin/cloudreve-issue-cert"
ACME_WEBROOT="/var/www/letsencrypt"

export DEBIAN_FRONTEND=noninteractive
# LXC-Templates setzen oft LANG=en_US.UTF-8, ohne die Locale zu generieren -> Perl/apt-Warnungen
export LC_ALL=C.UTF-8 LANG=C.UTF-8

# ----------------------------------------------------------------------------
# Hilfsfunktionen
# ----------------------------------------------------------------------------
log()  { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Fehler in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "Dieses Script muss als root laufen."
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "Nur Debian/Ubuntu (apt) wird unterstuetzt."
}

detect_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    armhf) echo "armv7" ;;
    armel) echo "armv6" ;;
    *) die "Nicht unterstuetzte Architektur: $(dpkg --print-architecture)" ;;
  esac
}

resolve_version() {
  if [[ "$CLOUDREVE_VERSION" == "latest" ]]; then
    local url
    url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/cloudreve/cloudreve/releases/latest) \
      || die "Konnte neueste Cloudreve-Version nicht ermitteln."
    CLOUDREVE_VERSION="${url##*/}"
  fi
  CLOUDREVE_VERSION="${CLOUDREVE_VERSION#v}"
  [[ "$CLOUDREVE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Ungueltige Version: $CLOUDREVE_VERSION"
}

# Das Binary kennt kein --version und legt beim Aufruf sofort data/ an,
# deshalb wird die installierte Version separat gemerkt.
VERSION_FILE="$INSTALL_DIR/.version"
installed_version() {
  [[ -x "$BIN" && -f "$VERSION_FILE" ]] || return 1
  cat "$VERSION_FILE"
}

rand_secret() { openssl rand -hex 24; }

# Alles unterhalb von $DATA_DIR wird als $SERVICE_USER gelesen/geschrieben, nie als
# root + chown. Grund: $DATA_DIR ist oft ein Bind-Mount auf ein Netzwerk-Share
# (CIFS/NFS), und dort darf root eines unprivilegierten Containers kein chown.
as_svc() { runuser -u "$SERVICE_USER" -- "$@"; }
# stdin -> Datei $1 als Service-User, Modus 0600
# shellcheck disable=SC2016
write_as_svc() { as_svc sh -c 'umask 077; cat > "$1"' sh "$1"; }
svc_file_exists() { as_svc test -f "$1"; }

# ----------------------------------------------------------------------------
# Schritte
# ----------------------------------------------------------------------------
step_preflight() {
  require_root
  require_apt
  [[ -n "$DOMAIN" ]] || die "DOMAIN ist leer."
  if [[ "$SKIP_LETSENCRYPT" != "1" && -z "$LE_EMAIL" ]]; then
    die "LE_EMAIL fehlt (wird fuer Let's Encrypt benoetigt). Alternativ SKIP_LETSENCRYPT=1 setzen."
  fi
  log "Domain: $DOMAIN | Installationsverzeichnis: $INSTALL_DIR"
}

step_system() {
  log "Systempakete installieren ..."
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl tar gzip openssl certbot tzdata locales >/dev/null

  if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
  else
    warn "Zeitzone $TIMEZONE unbekannt, wird uebersprungen."
  fi

  if [[ "$INSTALL_MEDIA_TOOLS" == "1" ]]; then
    log "Medien-Tools (ffmpeg, libvips) installieren ..."
    apt-get install -y -qq --no-install-recommends ffmpeg libvips-tools >/dev/null
  fi

  if [[ "$INSTALL_UNATTENDED_UPGRADES" == "1" ]]; then
    apt-get install -y -qq --no-install-recommends unattended-upgrades >/dev/null
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  fi
}

step_user_dirs() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Systembenutzer $SERVICE_USER (uid $SERVICE_UID) anlegen ..."
    local -a uid_args=()
    if ! getent passwd "$SERVICE_UID" >/dev/null; then
      uid_args=(--uid "$SERVICE_UID")
    else
      warn "UID $SERVICE_UID ist bereits vergeben, $SERVICE_USER bekommt eine freie UID."
    fi
    getent group "$SERVICE_USER" >/dev/null || groupadd --gid "$SERVICE_UID" "$SERVICE_USER"
    useradd "${uid_args[@]}" --gid "$SERVICE_USER" --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  elif [[ "$(id -u "$SERVICE_USER")" != "$SERVICE_UID" ]]; then
    if getent passwd "$SERVICE_UID" >/dev/null; then
      die "UID $SERVICE_UID ist vergeben, $SERVICE_USER hat aber $(id -u "$SERVICE_USER"). SERVICE_UID anders setzen."
    fi
    log "$SERVICE_USER von uid $(id -u "$SERVICE_USER") auf $SERVICE_UID umstellen ..."
    getent group "$SERVICE_USER" >/dev/null || groupadd --gid "$SERVICE_UID" "$SERVICE_USER"
    groupmod -g "$SERVICE_UID" "$SERVICE_USER" 2>/dev/null || true
    usermod -u "$SERVICE_UID" -g "$SERVICE_USER" "$SERVICE_USER"
  fi
  SERVICE_UID=$(id -u "$SERVICE_USER")

  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
  chmod 750 "$INSTALL_DIR"

  # $DATA_DIR kann ein Bind-Mount sein (Netzwerk-Share): chown/chmod duerfen dort
  # scheitern, entscheidend ist, dass der Service-User schreiben kann.
  chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" 2>/dev/null || true
  chmod 750 "$DATA_DIR" 2>/dev/null || true
  # shellcheck disable=SC2016
  if ! as_svc sh -c 'f="$1/.rw-test.$$" && : > "$f" && rm -f "$f"' sh "$DATA_DIR"; then
    local owner
    owner=$(stat -c '%u:%g (%A)' "$DATA_DIR" 2>/dev/null || echo "?")
    warn "$SERVICE_USER (uid $SERVICE_UID) kann nicht in $DATA_DIR schreiben. Owner/Modus: $owner"
    if mountpoint -q "$DATA_DIR"; then
      warn "$DATA_DIR ist ein Mount vom Host. Das Host-Verzeichnis muss uid $((100000 + SERVICE_UID)) gehoeren"
      warn "(unprivilegierter Container: 100000 + $SERVICE_UID). Bei CIFS: Mount-Option uid=$((100000 + SERVICE_UID)),gid=$((100000 + SERVICE_UID));"
      warn "bei NFS: Verzeichnis auf dem Server entsprechend chown'en."
    fi
    die "Datenverzeichnis nicht beschreibbar."
  fi

  as_svc mkdir -p "$SSL_DIR"
  as_svc chmod 700 "$SSL_DIR" 2>/dev/null || true
}

step_binary() {
  resolve_version
  local arch current tmp url
  arch=$(detect_arch)
  current=$(installed_version || true)

  if [[ -n "$current" && "$current" == "$CLOUDREVE_VERSION" ]]; then
    log "Cloudreve $current ist bereits installiert."
    return
  fi

  url="https://github.com/cloudreve/cloudreve/releases/download/${CLOUDREVE_VERSION}/cloudreve_${CLOUDREVE_VERSION}_linux_${arch}.tar.gz"
  log "Cloudreve $CLOUDREVE_VERSION ($arch) herunterladen ..."
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/cloudreve.tar.gz" "$url" || die "Download fehlgeschlagen: $url"
  tar -xzf "$tmp/cloudreve.tar.gz" -C "$tmp" cloudreve
  if systemctl is-active --quiet cloudreve 2>/dev/null; then
    log "Laufenden Dienst fuer Update stoppen ..."
    systemctl stop cloudreve
  fi
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$tmp/cloudreve" "$BIN"
  echo "$CLOUDREVE_VERSION" > "$VERSION_FILE"
  rm -rf "$tmp"
  log "Binary installiert: Cloudreve $CLOUDREVE_VERSION${current:+ (vorher: $current)}"
}

DB_PASSWORD=""
step_postgres() {
  [[ "$USE_POSTGRES" == "1" ]] || return 0
  log "PostgreSQL installieren/konfigurieren ..."
  apt-get install -y -qq --no-install-recommends postgresql >/dev/null
  systemctl enable --now postgresql >/dev/null

  # Warten bis der Server Verbindungen annimmt
  for _ in $(seq 1 30); do
    su - postgres -c "pg_isready -q" && break
    sleep 1
  done

  if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='cloudreve'\"" | grep -q 1; then
    log "DB-Rolle cloudreve existiert bereits."
    if svc_file_exists "$CONF_FILE"; then
      # shellcheck disable=SC2016
      DB_PASSWORD=$(as_svc cat "$CONF_FILE" | sed -n 's/^Password *= *`\?\([^`]*\)`\?.*/\1/p' | head -n1)
    fi
    if [[ -z "$DB_PASSWORD" ]]; then
      DB_PASSWORD=$(rand_secret)
      su - postgres -c "psql -qc \"ALTER ROLE cloudreve WITH PASSWORD '$DB_PASSWORD'\""
      warn "DB-Passwort wurde neu gesetzt."
    fi
  else
    DB_PASSWORD=$(rand_secret)
    su - postgres -c "psql -qc \"CREATE ROLE cloudreve LOGIN PASSWORD '$DB_PASSWORD'\""
  fi

  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='cloudreve'\"" | grep -q 1; then
    su - postgres -c "psql -qc \"CREATE DATABASE cloudreve OWNER cloudreve ENCODING 'UTF8' TEMPLATE template0\""
  fi
}

step_redis() {
  [[ "$USE_REDIS" == "1" ]] || return 0
  log "Redis installieren ..."
  apt-get install -y -qq --no-install-recommends redis-server >/dev/null
  # Debian bindet Redis standardmaessig an 127.0.0.1 - sicherstellen, dass es so bleibt.
  if ! grep -Eq '^bind 127\.0\.0\.1' /etc/redis/redis.conf; then
    sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
  fi
  systemctl enable --now redis-server >/dev/null
}

step_config() {
  if svc_file_exists "$CONF_FILE"; then
    log "Bestehende Konfiguration $CONF_FILE wird beibehalten."
    return
  fi
  log "Konfiguration $CONF_FILE schreiben ..."
  {
    cat <<EOF
[System]
Mode = master
; HTTP-Listener wird ignoriert, sobald [SSL] aktiv ist (Cloudreve lauscht dann nur auf 443)
Listen = :5212
Debug = false
LogLevel = info

[SSL]
Listen = :443
CertPath = $SSL_DIR/fullchain.pem
KeyPath = $SSL_DIR/privkey.pem
EOF
    if [[ "$USE_POSTGRES" == "1" ]]; then
      cat <<EOF

[Database]
Type = postgres
Host = 127.0.0.1
Port = 5432
User = cloudreve
Password = \`$DB_PASSWORD\`
Name = cloudreve
EOF
    else
      cat <<EOF

[Database]
Type = sqlite
DBFile = $DATA_DIR/cloudreve.db
EOF
    fi
    if [[ "$USE_REDIS" == "1" ]]; then
      cat <<EOF

[Redis]
Server = 127.0.0.1:6379
DB = 0
EOF
    fi
  } | write_as_svc "$CONF_FILE"
}

step_http_redirect() {
  [[ "$HTTP_REDIRECT" == "1" ]] || return 0
  log "HTTP->HTTPS Redirect auf Port 80 einrichten (nginx, nur Redirect + ACME, kein Proxy) ..."
  apt-get install -y -qq --no-install-recommends nginx-light >/dev/null
  mkdir -p "$ACME_WEBROOT"
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/cloudreve-redirect <<EOF
# Nur HTTP->HTTPS-Weiterleitung und ACME-Challenge. Cloudreve selbst lauscht auf 443.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN _;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }

    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/cloudreve-redirect /etc/nginx/sites-enabled/cloudreve-redirect
  nginx -t >/dev/null
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
}

write_deploy_hook() {
  mkdir -p "$(dirname "$DEPLOY_HOOK")"
  cat > "$DEPLOY_HOOK" <<EOF
#!/usr/bin/env bash
# Wird von certbot nach jeder erfolgreichen (Neu-)Ausstellung aufgerufen.
# Kopiert das Zertifikat in das Cloudreve-Datenverzeichnis und startet den
# Dienst neu (Cloudreve laedt Zertifikate nur beim Start).
set -euo pipefail
LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="$SSL_DIR"
# root liest, $SERVICE_USER schreibt - funktioniert auch auf Shares ohne chown-Recht
copy() { runuser -u "$SERVICE_USER" -- sh -c 'umask 077; cat > "\$1"' sh "\$2" < "\$1"; }
copy "\$LIVE/fullchain.pem" "\$DEST/fullchain.pem"
copy "\$LIVE/privkey.pem"   "\$DEST/privkey.pem"
systemctl try-restart cloudreve.service || true
EOF
  chmod 755 "$DEPLOY_HOOK"
}

write_issue_helper() {
  local method_args
  if [[ "$HTTP_REDIRECT" == "1" ]]; then
    method_args="--webroot -w $ACME_WEBROOT"
  else
    method_args="--standalone --preferred-challenges http"
  fi
  cat > "$ISSUE_HELPER" <<EOF
#!/usr/bin/env bash
# Fordert das Let's-Encrypt-Zertifikat fuer $DOMAIN an (oder erneuert es) und
# installiert es fuer Cloudreve. Kann jederzeit erneut ausgefuehrt werden,
# z.B. wenn der DNS-Eintrag bei der Installation noch nicht gestimmt hat.
set -euo pipefail
certbot certonly --non-interactive --agree-tos --keep-until-expiring \\
  -m "$LE_EMAIL" -d "$DOMAIN" \\
  $method_args \\
  --key-type ecdsa
"$DEPLOY_HOOK"
echo "Zertifikat installiert. Ablaufdatum:"
runuser -u "$SERVICE_USER" -- cat "$SSL_DIR/fullchain.pem" | openssl x509 -noout -enddate
EOF
  chmod 755 "$ISSUE_HELPER"
}

make_self_signed() {
  warn "Erzeuge temporaeres Self-Signed-Zertifikat, damit Cloudreve starten kann."
  local tmp
  tmp=$(mktemp -d)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -days 30 -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout "$tmp/privkey.pem" -out "$tmp/fullchain.pem" >/dev/null 2>&1
  write_as_svc "$SSL_DIR/privkey.pem"   < "$tmp/privkey.pem"
  write_as_svc "$SSL_DIR/fullchain.pem" < "$tmp/fullchain.pem"
  rm -rf "$tmp"
}

dns_check() {
  local resolved target
  resolved=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u | head -n1 || true)
  if [[ -z "$resolved" ]]; then
    warn "DNS: $DOMAIN loest derzeit auf keine IPv4-Adresse auf."
    return 1
  fi
  target="${PUBLIC_IP%%/*}"
  if [[ -z "$target" ]]; then
    target=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  fi
  if [[ -n "$target" && "$resolved" != "$target" ]]; then
    warn "DNS: $DOMAIN zeigt auf $resolved, dieser Server hat aber $target."
    return 1
  fi
  log "DNS: $DOMAIN -> $resolved"
}

CERT_STATUS="selfsigned"
step_certificate() {
  write_deploy_hook

  if [[ "$SKIP_LETSENCRYPT" == "1" ]]; then
    svc_file_exists "$SSL_DIR/fullchain.pem" || make_self_signed
    return
  fi

  write_issue_helper
  # Debian liefert certbot.timer fuer die automatische Erneuerung mit.
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true

  if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    log "Let's-Encrypt-Zertifikat vorhanden, wird uebernommen."
    "$DEPLOY_HOOK"
    CERT_STATUS="letsencrypt"
    return
  fi

  dns_check || warn "Let's Encrypt wird trotzdem versucht ..."

  log "Let's-Encrypt-Zertifikat fuer $DOMAIN anfordern ..."
  if "$ISSUE_HELPER"; then
    CERT_STATUS="letsencrypt"
  else
    warn "Let's Encrypt fehlgeschlagen (meist: DNS zeigt noch nicht hierher oder Port 80 ist von aussen nicht erreichbar)."
    warn "Spaeter einfach erneut ausfuehren: $ISSUE_HELPER"
    svc_file_exists "$SSL_DIR/fullchain.pem" || make_self_signed
  fi
}

step_service() {
  log "systemd-Dienst einrichten ..."
  local after="network-online.target"
  [[ "$USE_POSTGRES" == "1" ]] && after+=" postgresql.service"
  [[ "$USE_REDIS" == "1" ]] && after+=" redis-server.service"

  cat > /etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve self-hosted cloud storage
Documentation=https://docs.cloudreve.org
After=$after
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN
Restart=on-failure
RestartSec=5s
KillMode=mixed
TimeoutStopSec=30s
LimitNOFILE=65536

# Port 443 ohne root binden
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# Haertung
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cloudreve >/dev/null
  systemctl restart cloudreve
}

step_verify() {
  log "Warte auf Cloudreve ..."
  local i
  for i in $(seq 1 30); do
    if curl -ksf --max-time 3 -o /dev/null "https://127.0.0.1/"; then
      log "Cloudreve antwortet auf https://127.0.0.1/ (Versuch $i)."
      return
    fi
    sleep 2
  done
  warn "Cloudreve antwortet nicht. Letzte Logzeilen:"
  journalctl -u cloudreve -n 40 --no-pager || true
  die "Start fehlgeschlagen."
}

print_summary() {
  cat <<EOF

=============================================================================
 Cloudreve ist installiert.
=============================================================================
 URL:              https://$DOMAIN
 Zertifikat:       $CERT_STATUS$( [[ "$CERT_STATUS" == "selfsigned" ]] && echo "  -> spaeter: $ISSUE_HELPER" )
 Version:          $(installed_version || echo "$CLOUDREVE_VERSION")
 Installation:     $INSTALL_DIR
 Konfiguration:    $CONF_FILE
 Datenbank:        $( [[ "$USE_POSTGRES" == "1" ]] && echo "PostgreSQL (lokal, DB/User: cloudreve)" || echo "SQLite ($DATA_DIR/cloudreve.db)" )
 Cache:            $( [[ "$USE_REDIS" == "1" ]] && echo "Redis (127.0.0.1:6379)" || echo "In-Memory" )
 HTTP-Redirect:    $( [[ "$HTTP_REDIRECT" == "1" ]] && echo "Port 80 -> https://$DOMAIN" || echo "aus (nur Port 443)" )

 Naechste Schritte:
   1. https://$DOMAIN oeffnen und den ERSTEN Account registrieren
      -> dieser wird automatisch Administrator.
   2. Unter https://$DOMAIN/admin die "Site URL" auf https://$DOMAIN setzen
      und Speicherrichtlinien/Gruppen anpassen.

 Nuetzliche Befehle:
   systemctl status cloudreve        journalctl -u cloudreve -f
   $ISSUE_HELPER   (Zertifikat anfordern/erneuern)
   CLOUDREVE_VERSION=latest bash $0   (Update auf neueste Version)
=============================================================================
EOF
}

main() {
  step_preflight
  step_system
  step_user_dirs
  step_binary
  step_postgres
  step_redis
  step_config
  step_http_redirect
  step_certificate
  step_service
  step_verify
  print_summary
}

main "$@"
