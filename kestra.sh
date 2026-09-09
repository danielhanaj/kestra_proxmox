#!/usr/bin/env bash
# Copyright (c) 2021-2026 Your Name
# Author: YourName (GitHubUser)
# License: MIT | https://github.com/YourUser/YOUR_REPO/raw/main/kestra-lxc/LICENSE
#
# Single-file Kestra installer — bare-metal, no Docker.
#
#   - Run on a Proxmox VE host: creates an unprivileged Debian 13 LXC and runs
#     the Kestra standalone launcher natively (OpenJDK 25 + systemd), then
#     prints the access URL (web UI on http://IP:8080).
#   - Run again inside the LXC console: shows the "Update" menu, which
#     re-downloads the latest launcher (SHA256-verified) and restarts.
#
# Everything needed is embedded in this ONE file: the install fragment. Kestra
# itself is downloaded at install time from the official Kestra GitHub releases
# (public, checksum-verified); the version is read from the official Kestra API.

# ---------------------------------------------------------------------------
# 1. Materialize the embedded install fragment (build_container resolves it
#    locally, so no second file is fetched from the network).
# ---------------------------------------------------------------------------
if [[ -z "${COMMUNITY_SCRIPTS_ROOT:-}" ]]; then
  COMMUNITY_SCRIPTS_ROOT="$(mktemp -d)"
  trap 'rm -rf "${COMMUNITY_SCRIPTS_ROOT}"' EXIT
fi
mkdir -p "${COMMUNITY_SCRIPTS_ROOT}/install"

cat >"${COMMUNITY_SCRIPTS_ROOT}/install/kestra-install.sh" <<'KESTRA_INSTALL_BELOW'
#!/usr/bin/env bash
# Container install fragment (embedded in kestra.sh — do not edit here).

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y curl jq openjdk-25-jre-headless ca-certificates
msg_ok "Installed Dependencies"

msg_info "Resolving Latest Kestra Version"
KESTRA_VERSION="$(curl -fsSL https://api.kestra.io/v1/versions/latest | jq -r '.version' 2>/dev/null || true)"
[[ "$KESTRA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || KESTRA_VERSION="2.0.0"
msg_ok "Latest Kestra is ${KESTRA_VERSION}"

msg_info "Creating Application User"
$STD useradd -r -m -d /opt/kestra -s /usr/sbin/nologin kestra
mkdir -p /opt/kestra/plugins /opt/kestra/confs
chown kestra:kestra /opt/kestra/plugins /opt/kestra/confs
msg_ok "Created Application User"

msg_info "Downloading Kestra ${KESTRA_VERSION} (~125 MB)"
$STD curl -fsSL --retry 3 --output /tmp/kestra "https://github.com/kestra-io/kestra/releases/download/v${KESTRA_VERSION}/kestra-${KESTRA_VERSION}"

EXPECTED_SHA="$(curl -fsSL "https://github.com/kestra-io/kestra/releases/download/v${KESTRA_VERSION}/checksums_sha256.txt" | awk '{print $1}' || true)"
GOT_SHA="$(sha256sum /tmp/kestra | awk '{print $1}')"
if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != "$GOT_SHA" ]]; then
  msg_error "Checksum verification failed for the Kestra binary!"
  exit 1
fi
msg_ok "Downloaded Kestra"

msg_info "Installing Kestra"
install -o kestra -g kestra -m 0755 /tmp/kestra /opt/kestra/kestra
echo "${KESTRA_VERSION}" > /opt/kestra/VERSION
msg_ok "Installed Kestra"

msg_info "Creating Service"
cat >/etc/systemd/system/kestra.service <<'EOF'
[Unit]
Description=Kestra Event-Driven Orchestrator
Documentation=https://kestra.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kestra
Group=kestra
WorkingDirectory=/opt/kestra
Environment=HOME=/opt/kestra
ExecStart=/bin/sh /opt/kestra/kestra server local
Restart=on-failure
RestartSec=5
KillMode=mixed
SuccessExitStatus=143
SyslogIdentifier=kestra

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now kestra
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
KESTRA_INSTALL_BELOW
export COMMUNITY_SCRIPTS_ROOT

# ---------------------------------------------------------------------------
# 2. Engine comes from community-scripts/core; a local checkout wins.
# ---------------------------------------------------------------------------
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

APP="Kestra"
var_tags="${var_tags:-automation;workflow;pipelines}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

# ---------------------------------------------------------------------------
# 3. ASCII header — keep this single file self-contained (no banner fetch).
# ---------------------------------------------------------------------------
function header_info() {
  _cs_clear
}

header_info "$APP"
variables
color
catch_errors

# ---------------------------------------------------------------------------
# 4. In-place update helper (used by the Update menu inside the container).
# ---------------------------------------------------------------------------
function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/kestra/kestra ]]; then
    msg_error "No ${APPLICATION} Installation Found!"
    exit
  fi

  CURRENT="$(cat /opt/kestra/VERSION 2>/dev/null || true)"
  LATEST="$(curl -fsSL https://api.kestra.io/v1/versions/latest | jq -r '.version' 2>/dev/null || true)"
  [[ "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || LATEST="$CURRENT"

  if [[ -n "$CURRENT" && "$CURRENT" == "$LATEST" ]]; then
    msg_info "Kestra is already at the latest version (${LATEST})"
    msg_ok "Nothing to update"
    exit
  fi

  msg_info "Downloading Kestra ${LATEST} (~125 MB)"
  $STD curl -fsSL --retry 3 --output /tmp/kestra "https://github.com/kestra-io/kestra/releases/download/v${LATEST}/kestra-${LATEST}"

  EXPECTED_SHA="$(curl -fsSL "https://github.com/kestra-io/kestra/releases/download/v${LATEST}/checksums_sha256.txt" | awk '{print $1}' || true)"
  GOT_SHA="$(sha256sum /tmp/kestra | awk '{print $1}')"
  if [[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" != "$GOT_SHA" ]]; then
    msg_error "Checksum verification failed for the Kestra binary!"
    exit 1
  fi

  msg_info "Updating Kestra ${CURRENT:-unknown} -> ${LATEST}"
  install -o kestra -g kestra -m 0755 /tmp/kestra /opt/kestra/kestra
  echo "${LATEST}" > /opt/kestra/VERSION
  rm -f /tmp/kestra
  $STD systemctl restart kestra
  msg_ok "Updated Kestra"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Update or reconfigure it from the container's console via the Proxmox menu.${CL}"