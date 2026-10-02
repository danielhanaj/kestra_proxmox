#!/usr/bin/env bash
# Copyright (c) 2021-2026 Your Name
# Author: YourName (GitHubUser)
# License: MIT | https://github.com/YourUser/YOUR_REPO/raw/main/kestra-lxc/LICENSE
#
# Single-file Kestra installer — bare-metal, no Docker in the container.
#
#   - Run on a Proxmox VE host: creates an unprivileged Debian 13 LXC and runs
#     the Kestra standalone launcher natively (OpenJDK 25 + systemd), then
#     prints the access URL (web UI on http://IP:8080).
#   - Run `update` (or `upgrade`) inside the LXC console: a self-contained
#     command this installer writes into the container at install time. It runs
#     `apt-get update && apt-get upgrade` (keeping the container's Debian
#     packages and OpenJDK current), then re-reads the latest version from the
#     Kestra API, re-downloads the launcher (SHA256-verified against its
#     manifest entry), swaps it in, and restarts the service exactly once.
#     It downloads NO script at runtime - not this installer, not a helper -
#     so `update` works even with GitHub's raw host blocked. Pass --no-apt to
#     upgrade the Kestra binary only.
#   - Docker task runner support: the HOST's /var/run/docker.sock is
#     bind-mounted into the (still unprivileged) LXC. Set var_docker_socket=no
#     to skip it. This is host-root-equivalent — only run trusted workflows.
#
# Everything needed is embedded in this ONE file: the install fragment. Kestra
# itself is downloaded at install time from the official Kestra GitHub releases
# (public, checksum-verified); the version is read from the official Kestra API.

# ---------------------------------------------------------------------------
# 0. Guard: this file is the Proxmox *host* installer.
#
#    The container gets its own self-contained `update` command, written into it
#    at install time (see _kestra_write_update_entrypoint). Nothing about the
#    updater is fetched at runtime - not this installer, not a helper from
#    GitHub - unlike upstream community-scripts, whose /usr/bin/update curls
#    misc/update.sh and bash -c's it on every run. That is not usable here:
#    Kestra is not an upstream community-scripts app, so the engine's generated
#    entrypoint 404s on ct/Kestra.sh.
#
#    If someone copies this file into the container and runs it there, point
#    them at the built-in updater instead of falling into the host install path.
# ---------------------------------------------------------------------------
if [[ -f /opt/kestra/kestra ]]; then
  echo "kestra.sh is the Proxmox host installer." >&2
  echo "Inside the container, upgrade Kestra with:  update    (or: upgrade)" >&2
  exit 1
fi

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

# Grep THIS asset's line out of the manifest — never take the first line, which
# is only the right answer by accident. Warn loudly if there is no entry rather
# than silently pretending the download was verified.
EXPECTED_SHA="$(curl -fsSL "https://github.com/kestra-io/kestra/releases/download/v${KESTRA_VERSION}/checksums_sha256.txt" | awk -v a="kestra-${KESTRA_VERSION}" '{ n=$2; sub(/^\*/, "", n); if (n == a) { print $1; exit } }' || true)"
GOT_SHA="$(sha256sum /tmp/kestra | awk '{print $1}')"
if [[ -z "$EXPECTED_SHA" ]]; then
  msg_error "Release ${KESTRA_VERSION} publishes no checksum for kestra-${KESTRA_VERSION} - continuing UNVERIFIED."
elif [[ "$EXPECTED_SHA" != "$GOT_SHA" ]]; then
  msg_error "Checksum verification failed for the Kestra binary!"
  msg_error "  expected ${EXPECTED_SHA}"
  msg_error "  got      ${GOT_SHA}"
  exit 1
fi
msg_ok "Downloaded Kestra"

msg_info "Installing Kestra"
if ! install -o kestra -g kestra -m 0755 /tmp/kestra /opt/kestra/kestra; then
  msg_error "Failed to install /opt/kestra/kestra - aborting."
  exit 1
fi
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
# 4. The in-container `update` / `upgrade` command (HOST side; runs after
#    build_container, once CTID and a running container exist).
#
#    This writes a COMPLETE, SELF-CONTAINED updater into the container. The
#    heredoc below is the whole thing: it is not a stub, it does not fetch
#    kestra.sh, and there is no KESTRA_SCRIPT_URL to configure. The heredoc is
#    quoted, so its ${...} stay literal and are evaluated inside the container.
#
#    It does two things in order:
#      1. apt-get update && apt-get -y upgrade   (Debian packages, incl. OpenJDK)
#      2. download the newest Kestra launcher, verify it, swap it in
#    then restarts kestra.service exactly once, and only if something changed.
#    apt goes first so a fresh OpenJDK is on disk before that restart.
#
#    Use --no-apt (or KESTRA_APT_UPGRADE=0) to bump only the Kestra binary.
#
#    To change the updater's behaviour: edit this heredoc in kestra.sh on the
#    host and re-run the installer. It is rewritten on every install.
# ---------------------------------------------------------------------------
function _kestra_write_update_entrypoint() {
  pct exec "$CTID" -- sh -c 'cat >/usr/bin/update' <<'KESTRA_UPDATE_ENTRY'
#!/usr/bin/env bash
# Kestra upgrade command - generated by kestra.sh at install time.
#
# Self-contained on purpose: this container never downloads an installer or a
# helper from GitHub. The only network traffic is Debian packages and the
# Kestra release itself. Regenerate by re-running kestra.sh on the host.

BIN=/opt/kestra/kestra
VERSION_FILE=/opt/kestra/VERSION
VERSION_API=https://api.kestra.io/v1/versions/latest
RELEASES=https://github.com/kestra-io/kestra/releases/download

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Fingerprint of every installed package, so we restart the service only when
# something actually changed.
pkg_fingerprint() {
  dpkg-query -W -f='${binary:Package} ${Version}\n' 2>/dev/null | sort | md5sum | awk '{print $1}'
}

# This asset's hash out of a sha256sum-style manifest - never just line 1.
manifest_sha() {
  awk -v want="$2" '{ n = $2; sub(/^\*/, "", n); if (n == want) { print $1; exit } }' <<<"$1"
}

# --- arguments -------------------------------------------------------------
do_apt=1
for arg in "$@"; do
  case "$arg" in
    --no-apt) do_apt=0 ;;
    --apt) do_apt=1 ;;
    -h|--help)
      echo "usage: update [--no-apt|--apt]"
      echo "  --no-apt   upgrade only the Kestra binary, skip apt-get"
      echo "  --apt      also run apt-get update && apt-get upgrade (default)"
      exit 0
      ;;
    *) err "unknown option: $arg"; exit 2 ;;
  esac
done
[[ "${KESTRA_APT_UPGRADE:-1}" == "0" ]] && do_apt=0

if [[ ! -f "$BIN" ]]; then
  err "Kestra is not installed in this container ($BIN is missing)."
  exit 1
fi

current="$(cat "$VERSION_FILE" 2>/dev/null || true)"
pkg_changed=0
binary_changed=0

# --- 1. container packages -------------------------------------------------
if [[ "$do_apt" == "1" ]]; then
  say "Updating the container's system packages (apt)..."
  before="$(pkg_fingerprint)"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
    err "apt-get update failed - continuing with the Kestra upgrade only."
  elif ! DEBIAN_FRONTEND=noninteractive apt-get -y upgrade; then
    err "apt-get upgrade failed - continuing with the Kestra upgrade only."
  fi
  if [[ "$before" != "$(pkg_fingerprint)" ]]; then
    say "System packages updated."
    pkg_changed=1
  else
    say "System packages already up to date."
  fi
  apt-get clean >/dev/null 2>&1 || true
else
  say "Skipping the apt step (--no-apt or KESTRA_APT_UPGRADE=0)."
fi

# Restart on our own if the packages changed but Kestra does not, so a fresh
# OpenJDK is never left unloaded.
finish_on_package_change() {
  err "System packages were updated; restarting kestra.service."
  if systemctl restart kestra; then
    say "kestra.service restarted."
  else
    err "kestra.service failed to restart - check: journalctl -u kestra -n 50"
  fi
}

# --- 2. the Kestra binary --------------------------------------------------
say "Installed Kestra version: ${current:-unknown}"
say "Resolving the latest Kestra version..."
latest="$(curl -fsSL --retry 3 --connect-timeout 15 "$VERSION_API" 2>/dev/null | jq -r '.version' 2>/dev/null || true)"

if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err "Could not read the latest version from the Kestra API."
  [[ "$pkg_changed" == "1" ]] && finish_on_package_change
  err "Leaving the installed version ${current:-unknown} untouched."
  exit 1
fi
say "Latest Kestra version:  ${latest}"

if [[ -n "$current" && "$current" == "$latest" ]]; then
  if [[ "$pkg_changed" == "0" ]]; then
    say "Already up to date (${latest}); nothing to do."
    exit 0
  fi
  say "Kestra is already ${latest} - only the system packages changed."
else
  asset="kestra-${latest}"
  url="${RELEASES}/v${latest}/${asset}"

  say "Downloading ${asset} (~125 MB)..."
  if ! curl -fsSL --retry 3 --connect-timeout 30 -o /tmp/kestra "$url"; then
    err "Download failed: ${url}"
    err "The Kestra binary was NOT changed (still ${current:-unknown})."
    [[ "$pkg_changed" == "1" ]] && finish_on_package_change
    exit 1
  fi

  manifest="$(curl -fsSL --retry 3 --connect-timeout 30 "${RELEASES}/v${latest}/checksums_sha256.txt" 2>/dev/null || true)"
  expected="$(manifest_sha "$manifest" "$asset")"
  got="$(sha256sum /tmp/kestra | awk '{print $1}')"
  if [[ -z "$expected" ]]; then
    err "WARNING: release ${latest} publishes no checksum for ${asset} - continuing UNVERIFIED."
  elif [[ "$expected" != "$got" ]]; then
    err "Checksum mismatch for ${asset}:"
    err "  expected ${expected}"
    err "  got      ${got}"
    rm -f /tmp/kestra
    err "The Kestra binary was NOT changed (still ${current:-unknown})."
    [[ "$pkg_changed" == "1" ]] && finish_on_package_change
    exit 1
  else
    say "Checksum verified."
  fi

  say "Installing Kestra ${current:-unknown} -> ${latest}"
  # install MUST be checked: unchecked, VERSION would move ahead of the binary.
  if ! install -o kestra -g kestra -m 0755 /tmp/kestra "$BIN"; then
    err "Failed to install the new binary - still on ${current:-unknown}."
    rm -f /tmp/kestra
    [[ "$pkg_changed" == "1" ]] && finish_on_package_change
    exit 1
  fi
  printf '%s\n' "$latest" >"$VERSION_FILE"
  rm -f /tmp/kestra
  binary_changed=1
fi

# --- 3. one restart, covering both -----------------------------------------
say "Restarting kestra.service..."
if systemctl restart kestra; then
  if [[ "$binary_changed" == "1" ]]; then
    say "Done - Kestra is now ${latest}, system packages current."
  else
    say "Done - Kestra ${latest}, system packages updated and service restarted."
  fi
else
  err "Updates installed, but kestra.service failed to restart."
  err "Check: journalctl -u kestra -n 50"
  exit 1
fi
KESTRA_UPDATE_ENTRY

  pct exec "$CTID" -- chmod 0755 /usr/bin/update
  pct exec "$CTID" -- ln -sf /usr/bin/update /usr/local/bin/upgrade

  # Verify it landed intact. `pct exec` can exit 0 without having forwarded
  # stdin, which would leave a truncated updater that only fails much later.
  if ! pct exec "$CTID" -- bash -c '[[ -s /usr/bin/update ]] && bash -n /usr/bin/update'; then
    msg_error "The 'update' / 'upgrade' command did not land correctly."
    msg_error "Inspect: pct exec ${CTID} -- ls -l /usr/bin/update"
    return 1
  fi
}
# ---------------------------------------------------------------------------
# 6. Host Docker socket passthrough (runs on the Proxmox host, after
#    build_container, so the CTID exists and the container is up).
#
#    The Kestra Docker task runner needs a Docker engine. Running dockerd inside
#    this LXC would need nesting=1, keyctl=1 and fuse-overlayfs=1 and would
#    give up the unprivileged guarantee the README advertises. Instead the
#    host's socket is bind-mounted in: the LXC stays unprivileged and isolated.
#
#    SECURITY: this is host-root-equivalent. Any task using the Docker task
#    runner gets a container handle to the Proxmox host. Only run workflows you
#    trust. Set var_docker_socket=no to skip it entirely.
# ---------------------------------------------------------------------------
KESTRA_DOCKER_SOCK="/var/run/docker.sock"

function _kestra_mount_docker_socket() {
  local sock="${KESTRA_DOCKER_SOCK}"

  if [[ ! -S "$sock" ]]; then
    msg_warn "No Docker socket at ${sock} on the host - skipping the passthrough."
    msg_info "Kestra works regardless; use taskRunner: io.kestra.plugin.core.runner.Process."
    return 0
  fi

  # Bind-mount it in, reusing the slot if a previous run already added it.
  # `pct set -mpN` fails outright if slot N is taken, so find a free one.
  if pct config "$CTID" | grep -qE '^mp[0-9]+: .*mp='"${sock}"'(,|$)'; then
    msg_ok "Docker socket already mounted in the container"
  else
    local idx placed=0
    for idx in 0 1 2 3 4 5; do
      if ! pct config "$CTID" | grep -q "^mp${idx}:"; then
        pct set "$CTID" -mp"${idx}" "${sock},mp=${sock}"
        msg_ok "Mounted ${sock} into the container as mp${idx}"
        placed=1
        break
      fi
    done
    if [[ "$placed" != "1" ]]; then
      msg_error "No free Proxmox mountpoint slot left for the Docker socket."
      return 1
    fi
  fi

  # The socket is root:docker on the host, Kestra runs as the unprivileged
  # `kestra` system user. Add a matching supplementary group. The gid is read
  # from inside the container on purpose: unprivileged LXCs id-map bind mounts,
  # so the host gid appears shifted, and hardcoding 998/999 would be wrong.
  pct exec "$CTID" -- bash -c '
    gid="$(stat -c "%g" "$1")"
    grp="$(getent group "$gid" | cut -d: -f1)"
    if [ -z "$grp" ]; then
      groupadd -g "$gid" docker
      grp=docker
    fi
    if ! id -nG kestra | tr " " "\n" | grep -qx "$grp"; then
      usermod -aG "$grp" kestra
    fi
    msg="kestra is now in groups: $(id -nG kestra)"
    echo "$msg"
  ' _ "$sock"

  # Supplementary groups are captured at process start, so the service has to
  # be restarted to pick the new group up.
  pct exec "$CTID" -- systemctl restart kestra
  msg_ok "Kestra restarted with access to ${sock}"
}

start
build_container
description

# Replace the engine's upstream-pointing /usr/bin/update with ours.
# customize ran inside the container and wrote the broken one during build_container.
_kestra_write_update_entrypoint
msg_ok "Installed the 'update' / 'upgrade' commands in the container"

if [[ "${var_docker_socket:-yes}" != "no" ]]; then
  _kestra_mount_docker_socket
else
  msg_info "var_docker_socket=no - skipping the Docker socket passthrough"
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Update or reconfigure it from the container's console: ${CL}${BGN}update${CL} or ${BGN}upgrade${CL}"
