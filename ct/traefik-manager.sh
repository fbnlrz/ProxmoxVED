#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: fbnlrz (fbnlrz)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/chr0nzz/traefik-manager

APP="Traefik-Manager"
var_tags="${var_tags:-proxy;reverse-proxy;traefik;crowdsec}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/traefik-manager ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "traefik" "traefik/traefik"; then
    msg_info "Stopping Traefik"
    systemctl stop traefik
    msg_ok "Stopped Traefik"

    if [ "$(dpkg --print-architecture)" = "arm64" ]; then
      fetch_and_deploy_gh_release "traefik" "traefik/traefik" "prebuild" "latest" "/opt/traefik" "traefik_*_linux_arm64.tar.gz"
    else
      fetch_and_deploy_gh_release "traefik" "traefik/traefik" "prebuild" "latest" "/opt/traefik" "traefik_*_linux_amd64.tar.gz"
    fi

    msg_info "Starting Traefik"
    systemctl start traefik
    msg_ok "Started Traefik"
  fi

  if check_for_gh_release "traefik-manager" "chr0nzz/traefik-manager"; then
    msg_info "Stopping Traefik Manager"
    systemctl stop traefik-manager
    msg_ok "Stopped Traefik Manager"

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "traefik-manager" "chr0nzz/traefik-manager" "tarball"

    msg_info "Updating Python Environment"
    cd /opt/traefik-manager
    $STD uv venv /opt/traefik-manager/.venv
    $STD uv pip install -r /opt/traefik-manager/requirements.txt gunicorn --python /opt/traefik-manager/.venv/bin/python
    msg_ok "Updated Python Environment"

    msg_info "Building Frontend Assets"
    $STD bash /opt/traefik-manager/scripts/setup-assets.sh
    msg_ok "Built Frontend Assets"

    msg_info "Starting Traefik Manager"
    systemctl start traefik-manager
    msg_ok "Started Traefik Manager"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access the management UI using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:5000${CL}"
echo -e "${INFO}${YW}Access the Traefik dashboard using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8081${CL}"
echo -e "${INFO}${YW}CrowdSec credentials and access details saved to:${CL}"
echo -e "${GATEWAY}${BGN}/root/traefik-manager.creds${CL}"
echo -e "${INFO}${YW}The admin password is auto-generated on first start - retrieve it with:${CL}"
echo -e "${GATEWAY}${BGN}journalctl -u traefik-manager | grep -A3 AUTO-GENERATED${CL}"
