#!/usr/bin/env bash
set -Eeuo pipefail

REDIS_VERSION="${REDIS_VERSION:-8.8.1}"
REDIS_PKG_VERSION=""
NODE_COUNT="${NODE_COUNT:-4}"
AUTO_SECURITY_UPDATE="${AUTO_SECURITY_UPDATE:-1}"
BASE_PORT=7000
PORTS=()
DEFAULT_RAW_BASE_URL="https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master"
RAW_BASE_URL="${REDIS_CLUSTER_RAW_BASE:-$DEFAULT_RAW_BASE_URL}"

log() {
  printf '[redis-cluster-setup] %s\n' "$*" >&2
}

die() {
  printf '[redis-cluster-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo bash setup.sh [vm-private-ip]

Remote GitHub raw install:
  curl -fsSL https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master/setup.sh | sudo bash

The VM private IP is detected automatically. Pass [vm-private-ip] only to override it.

Optional environment variables:
  NODE_COUNT=<1-4>            (default 4; installs nodes on ports 7000..700N)
  PRIVATE_CIDR=<custom-private-cidr>
  REDIS_VERSION=8.8.1             (upstream version; the exact APT build is resolved automatically)
  AUTO_SECURITY_UPDATE=0          (default 1; unattended security updates never restart Redis)
  SKIP_REBOOT=1
  REDIS_CLUSTER_SKIP_IP_BIND_CHECK=1
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root, for example: sudo bash setup.sh"
  fi
}

validate_private_ipv4() {
  local ip="$1"
  local o1 o2 o3 o4

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"

  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done

  if ((o1 == 10)); then
    return 0
  fi

  if ((o1 == 172 && o2 >= 16 && o2 <= 31)); then
    return 0
  fi

  if ((o1 == 192 && o2 == 168)); then
    return 0
  fi

  return 1
}

detect_private_ipv4() {
  local route_ip candidate
  local -a candidates=()

  command -v ip >/dev/null 2>&1 || die "Cannot detect the VM private IP because the ip command is not available. Pass the private IP explicitly."

  route_ip="$(
    ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' \
      || true
  )"
  if [[ -n "${route_ip}" ]] && validate_private_ipv4 "${route_ip}"; then
    printf '%s\n' "${route_ip}"
    return
  fi

  while IFS= read -r candidate; do
    validate_private_ipv4 "${candidate}" || continue
    if [[ " ${candidates[*]:-} " != *" ${candidate} "* ]]; then
      candidates+=("${candidate}")
    fi
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')

  if ((${#candidates[@]} == 1)); then
    printf '%s\n' "${candidates[0]}"
    return
  fi

  if ((${#candidates[@]} == 0)); then
    die "Cannot detect an RFC1918 private IPv4 address. Pass it explicitly: sudo bash setup.sh <vm-private-ip>"
  fi

  die "Multiple private IPv4 addresses detected (${candidates[*]}). Pass the correct one explicitly: sudo bash setup.sh <vm-private-ip>"
}

derive_cidr24() {
  local ip="$1"
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  printf '%s.%s.%s.0/24\n' "${o1}" "${o2}" "${o3}"
}

check_ip_bound_to_host() {
  local ip="$1"

  if [[ "${REDIS_CLUSTER_SKIP_IP_BIND_CHECK:-0}" == "1" ]]; then
    log "Skipping local IP binding check."
    return
  fi

  if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${ip}"; then
    die "${ip} is not configured on this VM. Pass this VM's private IP, or set REDIS_CLUSTER_SKIP_IP_BIND_CHECK=1 if you know what you are doing."
  fi
}

install_prerequisites() {
  log "Installing OS prerequisites."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release ufw chrony htop unattended-upgrades
}

configure_redis_apt_repo() {
  local codename arch

  codename="$(
    . /etc/os-release
    printf '%s' "${VERSION_CODENAME:-}"
  )"
  if [[ -z "${codename}" ]]; then
    codename="$(lsb_release -cs)"
  fi

  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64 | arm64) ;;
    *) die "Unsupported architecture: ${arch}. packages.redis.io publishes amd64 and arm64 builds only." ;;
  esac

  log "Configuring Redis APT repository for ${codename} (${arch})."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor >/etc/apt/keyrings/redis-archive-keyring.gpg.tmp
  mv /etc/apt/keyrings/redis-archive-keyring.gpg.tmp /etc/apt/keyrings/redis-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/redis-archive-keyring.gpg

  cat >/etc/apt/sources.list.d/redis.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${codename} main
EOF

  apt-get update
}

# Turns a plain upstream version (8.8.1) into the exact APT version string for this
# codename/architecture (for example 6:8.8.1-1rl1~noble1). A full APT version string
# is also accepted and used as-is.
resolve_redis_package_version() {
  local requested="$1"
  local available escaped resolved

  available="$(apt-cache madison redis-server 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/, "", $2); if ($2 != "") print $2}')"
  [[ -n "${available}" ]] || die "apt-cache madison redis-server returned no candidate versions."

  if grep -Fxq "${requested}" <<<"${available}"; then
    printf '%s\n' "${requested}"
    return
  fi

  escaped="${requested//./\\.}"
  resolved="$(grep -E -m1 "^([0-9]+:)?${escaped}(-|\$)" <<<"${available}" || true)"
  if [[ -z "${resolved}" ]]; then
    log "Available redis-server versions:"
    printf '%s\n' "${available}" >&2
    die "Redis ${requested} is not available from APT for this OS codename/architecture."
  fi

  printf '%s\n' "${resolved}"
}

install_redis() {
  export DEBIAN_FRONTEND=noninteractive

  REDIS_PKG_VERSION="$(resolve_redis_package_version "${REDIS_VERSION}")"
  log "Installing Redis ${REDIS_VERSION} (package version ${REDIS_PKG_VERSION}) and locking package versions."

  apt-mark unhold redis redis-server redis-tools 2>/dev/null || true
  apt-get install -y --allow-downgrades \
    "redis=${REDIS_PKG_VERSION}" \
    "redis-server=${REDIS_PKG_VERSION}" \
    "redis-tools=${REDIS_PKG_VERSION}"
  apt-mark hold redis redis-server redis-tools

  systemctl disable --now redis-server 2>/dev/null || true
  rm -f /etc/systemd/system/redis-server.service \
    /lib/systemd/system/redis-server.service \
    /etc/init.d/redis-server
  systemctl daemon-reload
}

configure_thp() {
  log "Configuring Transparent Huge Pages disable service."
  cat >/etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now disable-thp
  cat /sys/kernel/mm/transparent_hugepage/enabled
  cat /sys/kernel/mm/transparent_hugepage/defrag
}

configure_firewall() {
  local private_cidr="$1"
  local first_port="${PORTS[0]}"
  local last_port="${PORTS[-1]}"
  local redis_ports bus_ports

  if [[ "${first_port}" == "${last_port}" ]]; then
    redis_ports="${first_port}"
    bus_ports="$((first_port + 10000))"
  else
    redis_ports="${first_port}:${last_port}"
    bus_ports="$((first_port + 10000)):$((last_port + 10000))"
  fi

  log "Configuring UFW for SSH and Redis cluster traffic from ${private_cidr}."
  ufw allow ssh
  ufw allow from "${private_cidr}"
  ufw allow from "${private_cidr}" to any port "${redis_ports}" proto tcp
  ufw allow from "${private_cidr}" to any port "${bus_ports}" proto tcp
  ufw --force enable
}

configure_kernel() {
  log "Configuring kernel/network parameters."
  cat >/etc/sysctl.d/99-redis-cluster.conf <<'EOF'
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=262144
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10000 65000
net.netfilter.nf_conntrack_max=1048576
EOF

  while IFS= read -r setting; do
    [[ -n "${setting}" ]] || continue
    sysctl -w "${setting}" || log "Warning: unable to apply sysctl ${setting}"
  done </etc/sysctl.d/99-redis-cluster.conf
}

# apt 跑完後，needrestart 會掃描還在使用舊 library 的行程，並重啟對應的 systemd
# unit。它不看 unit 屬於哪個套件，所以這裡自建的 redis-70xx.service 一樣會被重啟。
# 這些 node 沒有 RDB/AOF，重啟等於整個 node 的資料消失，因此明確禁止。
configure_needrestart() {
  log "Configuring needrestart to never restart Redis nodes."

  if [[ -f /etc/needrestart/needrestart.conf ]]; then
    sed -i "s/^#\?\$nrconf{restart}.*/\$nrconf{restart} = 'l';/" /etc/needrestart/needrestart.conf
  fi

  # 用 conf.d 再釘一次，避免主設定檔日後被套件更新覆蓋。
  # 這裡用「單一 key 指派」與 push，而不是整個 hash/array 重新賦值，
  # 否則會蓋掉 needrestart 自帶的預設值（dbus、sudo 等）。
  install -d -m 0755 /etc/needrestart/conf.d
  cat >/etc/needrestart/conf.d/99-redis-cluster.conf <<'EOF'
# Managed by rapid-redis-cluster-installer.
# List outdated services instead of restarting them.
$nrconf{restart} = 'l';
# Never restart the Redis cluster nodes, whatever triggered the apt run.
$nrconf{override_rc}{qr(^redis-\d+\.service$)} = 0;
push @{$nrconf{blacklist}}, qr(^/usr/bin/redis-server(\.dpkg-new)?$);
EOF
}

# 保留安全性更新，但禁止它重開機；redis 套件則完全排除在自動更新之外。
configure_auto_updates() {
  cat >/etc/apt/apt.conf.d/99-redis-cluster.conf <<'EOF'
// Managed by rapid-redis-cluster-installer.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Package-Blacklist {
  "redis";
  "redis-server";
  "redis-tools";
};
EOF

  if [[ "${AUTO_SECURITY_UPDATE}" != "1" ]]; then
    log "AUTO_SECURITY_UPDATE=0: disabling unattended upgrades."
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    return
  fi

  log "Enabling unattended security updates (no service restart, no auto reboot)."
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
}

configure_timers() {
  log "Configuring logrotate timer."

  mkdir -p /etc/systemd/system/logrotate.timer.d
  cat >/etc/systemd/system/logrotate.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
EOF

  systemctl daemon-reload
  systemctl restart logrotate.timer 2>/dev/null || true
}

configure_time_and_shell_helpers() {
  local target_user target_home

  log "Configuring timezone, chrony, and shell helper bindings."
  systemctl enable --now chrony 2>/dev/null || true
  timedatectl set-timezone Asia/Taipei

  target_user="${SUDO_USER:-${USER:-root}}"
  target_home="$(getent passwd "${target_user}" | cut -d: -f6 || true)"
  if [[ -z "${target_home}" || ! -d "${target_home}" ]]; then
    target_home="/root"
  fi

  touch "${target_home}/.nanorc"
  grep -Fqx "bind ^H chopwordleft main" "${target_home}/.nanorc" || echo 'bind ^H chopwordleft main' >>"${target_home}/.nanorc"

  touch "${target_home}/.inputrc"
  grep -Fqx '"\C-h": backward-kill-word' "${target_home}/.inputrc" || echo '"\C-h": backward-kill-word' >>"${target_home}/.inputrc"
  grep -Fqx '"\C-?": backward-delete-char' "${target_home}/.inputrc" || echo '"\C-?": backward-delete-char' >>"${target_home}/.inputrc"
  grep -Fqx '"\e[3~": delete-char' "${target_home}/.inputrc" || echo '"\e[3~": delete-char' >>"${target_home}/.inputrc"
  grep -Fqx '"\e[3;5~": kill-word' "${target_home}/.inputrc" || echo '"\e[3;5~": kill-word' >>"${target_home}/.inputrc"

  chown "${target_user}:${target_user}" "${target_home}/.nanorc" "${target_home}/.inputrc" 2>/dev/null || true
}

prepare_source_tree() {
  local script_dir tmp_dir file port
  local -a files=()

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)"
  if [[ -n "${script_dir}" \
    && -d "${script_dir}/scripts/etc/redis" \
    && -d "${script_dir}/scripts/etc/systemd/system" \
    && -f "${script_dir}/scripts/root/.bashrc" \
    && -f "${script_dir}/scripts/~/.config/htop/htoprc" ]]; then
    printf '%s\n' "${script_dir}/scripts"
    return
  fi

  [[ -n "${RAW_BASE_URL}" ]] || die "Cannot find local scripts/. Set REDIS_CLUSTER_RAW_BASE to the GitHub raw base URL."

  tmp_dir="$(mktemp -d)"
  RAW_BASE_URL="${RAW_BASE_URL%/}"
  log "Downloading scripts/ from ${RAW_BASE_URL}."

  for port in "${PORTS[@]}"; do
    files+=(
      "scripts/etc/redis/redis-${port}.conf"
      "scripts/etc/systemd/system/redis-${port}.service"
    )
  done
  files+=(
    scripts/root/.bashrc
    'scripts/~/.config/htop/htoprc'
  )

  for file in "${files[@]}"; do
    mkdir -p "${tmp_dir}/$(dirname "${file}")"
    curl -fsSL "${RAW_BASE_URL}/${file}" -o "${tmp_dir}/${file}" \
      || die "Failed to download ${RAW_BASE_URL}/${file}"
  done

  printf '%s\n' "${tmp_dir}/scripts"
}

install_redis_node_files() {
  local announce_ip="$1"
  local source_tree="$2"
  local work_dir port conf service

  log "Installing Redis node configs and systemd units."
  work_dir="$(mktemp -d)"
  cp -a "${source_tree}/etc/redis" "${work_dir}/redis"
  cp -a "${source_tree}/etc/systemd" "${work_dir}/systemd"

  install -d -m 0755 /etc/redis

  for port in "${PORTS[@]}"; do
    conf="${work_dir}/redis/redis-${port}.conf"
    service="${work_dir}/systemd/system/redis-${port}.service"

    [[ -f "${conf}" ]] || die "Missing ${conf}"
    [[ -f "${service}" ]] || die "Missing ${service}"

    grep -Eq '^cluster-announce-ip ' "${conf}" || die "${conf} does not define cluster-announce-ip"
    sed -i -E "s/^cluster-announce-ip .*/cluster-announce-ip ${announce_ip}/" "${conf}"
    sed -i -E "s|^dir .*|dir /var/lib/redis/${port}|" "${conf}"

    install -d -o redis -g redis -m 0750 "/var/lib/redis/${port}"
    install -m 0644 -o root -g root "${conf}" "/etc/redis/redis-${port}.conf"
    install -m 0644 -o root -g root "${service}" "/etc/systemd/system/redis-${port}.service"
  done
}

install_shell_and_htop_files() {
  local source_tree="$1"
  local target_user target_group target_home root_bashrc htoprc

  root_bashrc="${source_tree}/root/.bashrc"
  htoprc="${source_tree}/~/.config/htop/htoprc"

  [[ -f "${root_bashrc}" ]] || die "Missing ${root_bashrc}"
  [[ -f "${htoprc}" ]] || die "Missing ${htoprc}"

  target_user="${SUDO_USER:-${USER:-root}}"
  if ! getent passwd "${target_user}" >/dev/null; then
    target_user="root"
  fi
  target_group="$(id -gn "${target_user}")"
  target_home="$(getent passwd "${target_user}" | cut -d: -f6)"

  log "Installing root shell and htop configuration files."
  install -m 0644 -o root -g root "${root_bashrc}" /root/.bashrc
  install -d -m 0755 -o root -g root /root/.config
  install -d -m 0755 -o root -g root /root/.config/htop
  install -m 0644 -o root -g root "${htoprc}" /root/.config/htop/htoprc

  cmp -s "${root_bashrc}" /root/.bashrc || die "Failed to verify /root/.bashrc"
  cmp -s "${htoprc}" /root/.config/htop/htoprc || die "Failed to verify /root/.config/htop/htoprc"

  if [[ "${target_user}" != "root" ]]; then
    log "Installing htop config for sudo user ${target_user} at ${target_home}/.config/htop/htoprc."
    install -d -m 0755 -o "${target_user}" -g "${target_group}" "${target_home}/.config"
    install -d -m 0755 -o "${target_user}" -g "${target_group}" "${target_home}/.config/htop"
    install -m 0644 -o "${target_user}" -g "${target_group}" "${htoprc}" "${target_home}/.config/htop/htoprc"
    cmp -s "${htoprc}" "${target_home}/.config/htop/htoprc" \
      || die "Failed to verify ${target_home}/.config/htop/htoprc"
  fi

  log "Verified /root/.bashrc and /root/.config/htop/htoprc."
}

check_redis_modules() {
  local module

  for module in rejson redisbloom redistimeseries redisearch; do
    [[ -f "/usr/lib/redis/modules/${module}.so" ]] || die "Missing Redis module: /usr/lib/redis/modules/${module}.so"
  done
}

start_redis_nodes() {
  local port

  log "Enabling and starting Redis nodes: ${PORTS[*]}."
  systemctl daemon-reload

  for port in "${PORTS[@]}"; do
    systemctl enable --now "redis-${port}.service"
  done

  for port in "${PORTS[@]}"; do
    redis-cli -p "${port}" ping >/dev/null
  done
}

print_helpers() {
  local announce_ip="$1"
  local port node_lines="" service_units="" port_list="" create_endpoints=""
  local last_port="${PORTS[-1]}"

  for port in "${PORTS[@]}"; do
    node_lines+="  ${announce_ip}:${port}"$'\n'
    service_units+="redis-${port} "
    port_list+="${port} "
    create_endpoints+="${announce_ip}:${port} "
  done
  service_units="${service_units% }"
  port_list="${port_list% }"
  create_endpoints="${create_endpoints% }"

  cat <<EOF

Redis node services are installed and running on:
${node_lines}
Helper commands:

  # Check local node status
  systemctl status ${service_units} --no-pager
  redis-cli -p ${PORTS[0]} cluster nodes

  # Check what a security update left pending (nothing is restarted automatically)
  needrestart -b -r l
  cat /var/run/reboot-required 2>/dev/null || echo "no reboot pending"
EOF

  if ((${#PORTS[@]} >= 3)); then
    cat <<EOF

  # Create a new ${#PORTS[@]}-master cluster on this VM only
  redis-cli --cluster create ${create_endpoints} --cluster-replicas 0
EOF
  fi

  cat <<EOF

  # Add these ${#PORTS[@]} node(s) to an existing cluster
  EXISTING_CLUSTER_IP="<existing-cluster-ip>"
  ADD_NODE_DELAY_SECONDS=2
  for PORT in ${port_list}; do
    if ! redis-cli --cluster add-node ${announce_ip}:\${PORT} "\${EXISTING_CLUSTER_IP}:7000"; then
      echo "Failed to add ${announce_ip}:\${PORT}; stopping."
      break
    fi
    [[ "\${PORT}" == "${last_port}" ]] || sleep "\${ADD_NODE_DELAY_SECONDS}"
  done

  # Rebalance quickly after adding empty masters
  redis-cli --cluster rebalance <existing-cluster-ip>:7000 --cluster-use-empty-masters --cluster-threshold 1

  # Interactive reshard
  redis-cli --cluster reshard <existing-cluster-ip>:7000

  # Delete a node after checking its node ID
  redis-cli --cluster del-node <existing-cluster-ip>:7000 <node-id>

EOF
}

schedule_reboot() {
  if [[ "${SKIP_REBOOT:-0}" == "1" ]]; then
    log "SKIP_REBOOT=1 is set; not rebooting."
    return
  fi

  log "Setup complete. Rebooting in 30 seconds."
  systemctl reboot --when="+30s"
}

main() {
  local announce_ip private_cidr source_tree

  if [[ $# -gt 1 ]]; then
    usage
    exit 1
  fi

  require_root

  [[ "${NODE_COUNT}" =~ ^[1-4]$ ]] || die "NODE_COUNT must be an integer between 1 and 4 (got: ${NODE_COUNT})."
  local i
  for ((i = 0; i < NODE_COUNT; i++)); do
    PORTS+=("$((BASE_PORT + i))")
  done
  log "Installing ${NODE_COUNT} Redis node(s) on ports: ${PORTS[*]}"

  if [[ $# -eq 1 ]]; then
    announce_ip="$1"
    log "Using explicitly provided VM private IP: ${announce_ip}"
  else
    announce_ip="$(detect_private_ipv4)"
    log "Detected VM private IP: ${announce_ip}"
  fi
  validate_private_ipv4 "${announce_ip}" || die "Please provide a valid RFC1918 private IPv4 address."

  check_ip_bound_to_host "${announce_ip}"

  private_cidr="${PRIVATE_CIDR:-$(derive_cidr24 "${announce_ip}")}"

  install_prerequisites
  configure_redis_apt_repo
  install_redis
  configure_thp
  configure_firewall "${private_cidr}"
  configure_kernel
  configure_needrestart
  configure_auto_updates
  configure_timers
  configure_time_and_shell_helpers

  source_tree="$(prepare_source_tree)"
  install_shell_and_htop_files "${source_tree}"
  check_redis_modules
  install_redis_node_files "${announce_ip}" "${source_tree}"
  start_redis_nodes
  print_helpers "${announce_ip}"
  schedule_reboot
}

main "$@"
