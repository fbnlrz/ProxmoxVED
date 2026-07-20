#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: fbnlrz (fbnlrz)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/chr0nzz/traefik-manager

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ------------------------------------------------------------------
# Interactive configuration
# ------------------------------------------------------------------
read -r -p "${TAB3}Domain for Traefik Manager (blank = use container IP): " TM_DOMAIN
read -r -p "${TAB3}Connect to an EXISTING CrowdSec instance instead of installing one? (y/N): " CS_ANSWER
if [[ "${CS_ANSWER,,}" == "y" || "${CS_ANSWER,,}" == "yes" ]]; then
  CROWDSEC_MODE="existing"
  read -r -p "${TAB3}CrowdSec LAPI URL (e.g. http://192.168.1.50:8080): " CROWDSEC_LAPI_URL
  read -r -p "${TAB3}CrowdSec bouncer API key: " CROWDSEC_BOUNCER_KEY
  read -r -p "${TAB3}CrowdSec machine ID for alerts/unban (optional): " CROWDSEC_MACHINE_ID
  read -r -p "${TAB3}CrowdSec machine password (optional): " CROWDSEC_MACHINE_PASSWORD
else
  CROWDSEC_MODE="local"
  CROWDSEC_LAPI_URL="http://127.0.0.1:8080"
  CROWDSEC_MACHINE_ID="traefik-manager"
fi

UV_PYTHON="3.12" setup_uv

if [ "$(dpkg --print-architecture)" = "arm64" ]; then
  fetch_and_deploy_gh_release "traefik" "traefik/traefik" "prebuild" "latest" "/opt/traefik" "traefik_*_linux_arm64.tar.gz"
else
  fetch_and_deploy_gh_release "traefik" "traefik/traefik" "prebuild" "latest" "/opt/traefik" "traefik_*_linux_amd64.tar.gz"
fi

if [[ "$CROWDSEC_MODE" == "local" ]]; then
  msg_info "Installing CrowdSec"
  # CrowdSec does not publish a Debian 13 (trixie) repo yet; its bookworm build
  # is a static Go binary and runs fine on trixie.
  setup_deb822_repo \
    "crowdsec" \
    "https://packagecloud.io/crowdsec/crowdsec/gpgkey" \
    "https://packagecloud.io/crowdsec/crowdsec/debian" \
    "bookworm"
  $STD apt install -y crowdsec
  msg_ok "Installed CrowdSec"
fi

msg_info "Configuring Traefik"
mkdir -p /etc/traefik /var/log/traefik
cat <<EOF >/etc/traefik/traefik.yml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
  traefik:
    address: ":8081"

api:
  dashboard: true
  insecure: true

accessLog:
  filePath: /var/log/traefik/access.log

providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

log:
  level: INFO
EOF
cat <<EOF >/etc/traefik/dynamic.yml
http:
  routers: {}
  services: {}
  middlewares: {}
EOF
cat <<EOF >/etc/systemd/system/traefik.service
[Unit]
Description=Traefik
After=network.target

[Service]
Type=simple
ExecStart=/opt/traefik/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now traefik
msg_ok "Configured Traefik"

if [[ "$CROWDSEC_MODE" == "local" ]]; then
  msg_info "Wiring CrowdSec to Traefik"
  cat <<EOF >/etc/crowdsec/acquis.d/traefik.yaml
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
EOF
  $STD cscli collections install crowdsecurity/traefik
  CROWDSEC_BOUNCER_KEY=$(cscli bouncers add traefik-manager -o raw)
  CROWDSEC_MACHINE_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  $STD cscli machines add traefik-manager --password "$CROWDSEC_MACHINE_PASSWORD" --force
  systemctl restart crowdsec
  msg_ok "Wired CrowdSec to Traefik"
fi

fetch_and_deploy_gh_release "traefik-manager" "chr0nzz/traefik-manager" "tarball"

msg_info "Setting up Python Environment"
cd /opt/traefik-manager
$STD uv venv /opt/traefik-manager/.venv
$STD uv pip install -r /opt/traefik-manager/requirements.txt gunicorn --python /opt/traefik-manager/.venv/bin/python
msg_ok "Set up Python Environment"

msg_info "Building Frontend Assets"
$STD bash /opt/traefik-manager/scripts/setup-assets.sh
msg_ok "Built Frontend Assets"

msg_info "Creating Restart Watcher"
mkdir -p /var/lib/traefik-manager/backups /var/lib/traefik-manager/signals
cat <<'EOF' >/usr/local/bin/traefik-restart-watcher.sh
#!/bin/sh
SIGNAL=/var/lib/traefik-manager/signals/restart.sig
mkdir -p "$(dirname "$SIGNAL")"
while true; do
  if [ -f "$SIGNAL" ]; then
    systemctl restart traefik
    rm -f "$SIGNAL"
  fi
  sleep 2
done
EOF
chmod +x /usr/local/bin/traefik-restart-watcher.sh
cat <<EOF >/etc/systemd/system/traefik-restart-watcher.service
[Unit]
Description=Traefik restart watcher
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traefik-restart-watcher.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now traefik-restart-watcher
msg_ok "Created Restart Watcher"

msg_info "Preconfiguring Traefik Manager"
ADMIN_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
PASSWORD_HASH=$(/opt/traefik-manager/.venv/bin/python -c "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" "$ADMIN_PASSWORD")
cat <<EOF >/var/lib/traefik-manager/manager.yml
domains:
  - ${TM_DOMAIN:-$LOCAL_IP}
cert_resolver: none
traefik_api_url: http://127.0.0.1:8081
access_log_path: /var/log/traefik/access.log
static_config_path: /etc/traefik/traefik.yml
auth_enabled: true
password_hash: "${PASSWORD_HASH}"
setup_complete: true
must_change_password: true
default_theme: dark
visible_tabs:
  dashboard: true
  routemap: true
  logs: true
  plugins: true
EOF
msg_ok "Preconfigured Traefik Manager"

msg_info "Creating Service"
CROWDSEC_AFTER=""
[[ "$CROWDSEC_MODE" == "local" ]] && CROWDSEC_AFTER=" crowdsec.service"
cat <<EOF >/etc/systemd/system/traefik-manager.service
[Unit]
Description=Traefik Manager
After=network.target${CROWDSEC_AFTER}

[Service]
Type=simple
WorkingDirectory=/opt/traefik-manager
Environment=HOME=/opt/traefik-manager
Environment=CONFIG_PATH=/etc/traefik/dynamic.yml
Environment=STATIC_CONFIG_PATH=/etc/traefik/traefik.yml
Environment=ACCESS_LOG_PATH=/var/log/traefik/access.log
Environment=BACKUP_DIR=/var/lib/traefik-manager/backups
Environment=SETTINGS_PATH=/var/lib/traefik-manager/manager.yml
Environment=RESTART_METHOD=poison-pill
Environment=SIGNAL_FILE_PATH=/var/lib/traefik-manager/signals/restart.sig
Environment=CROWDSEC_LAPI_URL=${CROWDSEC_LAPI_URL}
Environment=CROWDSEC_API_KEY=${CROWDSEC_BOUNCER_KEY}
Environment=CROWDSEC_MACHINE_ID=${CROWDSEC_MACHINE_ID}
Environment=CROWDSEC_MACHINE_PASSWORD=${CROWDSEC_MACHINE_PASSWORD}
Environment=COOKIE_SECURE=false
ExecStart=/opt/traefik-manager/.venv/bin/gunicorn --bind 0.0.0.0:5000 --workers 1 --log-level info app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now traefik-manager
msg_ok "Created Service"

{
  echo "Traefik Manager"
  echo "  URL: http://${LOCAL_IP}:5000"
  echo "  Password: ${ADMIN_PASSWORD}"
  echo "  Note: you must set a new password on first login"
  echo ""
  echo "Traefik Dashboard"
  echo "  URL: http://${LOCAL_IP}:8081"
  echo ""
  echo "CrowdSec (${CROWDSEC_MODE}, wired into Traefik Manager)"
  echo "  LAPI URL: ${CROWDSEC_LAPI_URL}"
  echo "  Bouncer API key: ${CROWDSEC_BOUNCER_KEY}"
  echo "  Machine ID: ${CROWDSEC_MACHINE_ID}"
  echo "  Machine password: ${CROWDSEC_MACHINE_PASSWORD}"
} >/root/traefik-manager.creds

motd_ssh
customize
cleanup_lxc
