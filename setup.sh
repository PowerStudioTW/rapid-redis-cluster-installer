#!/usr/bin/env bash
set -Eeuo pipefail

REDIS_VERSION="${REDIS_VERSION:-6:8.8.0-1rl1~noble1}"
PORTS=(7000 7001 7002 7003)
DEFAULT_RAW_BASE_URL=""
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
  sudo bash setup.sh <vm-private-ip>

Remote GitHub raw install:
  RAW_BASE="https://raw.githubusercontent.com/<owner>/<repo>/<branch>"
  curl -fsSL "$RAW_BASE/setup.sh" | sudo env REDIS_CLUSTER_RAW_BASE="$RAW_BASE" bash -s -- <vm-private-ip>

Optional environment variables:
  PRIVATE_CIDR=<custom-private-cidr>
  REDIS_VERSION=6:8.8.0-1rl1~noble1
  SKIP_REBOOT=1
  REDIS_CLUSTER_SKIP_IP_BIND_CHECK=1
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root, for example: sudo bash setup.sh <vm-private-ip>"
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
  apt-get install -y ca-certificates curl gnupg lsb-release ufw chrony
}

configure_redis_apt_repo() {
  local codename

  codename="$(
    . /etc/os-release
    printf '%s' "${VERSION_CODENAME:-}"
  )"
  if [[ -z "${codename}" ]]; then
    codename="$(lsb_release -cs)"
  fi

  log "Configuring Redis APT repository for ${codename}."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor >/etc/apt/keyrings/redis-archive-keyring.gpg.tmp
  mv /etc/apt/keyrings/redis-archive-keyring.gpg.tmp /etc/apt/keyrings/redis-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/redis-archive-keyring.gpg

  cat >/etc/apt/sources.list.d/redis.list <<EOF
deb [signed-by=/etc/apt/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb ${codename} main
EOF

  apt-get update

  if ! apt-cache madison redis-server | awk '{print $3}' | grep -Fxq "${REDIS_VERSION}"; then
    apt-cache madison redis-server >&2 || true
    die "Redis package version ${REDIS_VERSION} is not available from APT on this OS codename (${codename})."
  fi
}

install_redis() {
  log "Installing Redis ${REDIS_VERSION} and locking package versions."
  export DEBIAN_FRONTEND=noninteractive

  apt-mark unhold redis redis-server redis-tools 2>/dev/null || true
  apt-get install -y \
    "redis=${REDIS_VERSION}" \
    "redis-server=${REDIS_VERSION}" \
    "redis-tools=${REDIS_VERSION}"
  apt-mark hold redis redis-server redis-tools

  systemctl disable --now redis-server 2>/dev/null || true
  systemctl mask redis-server 2>/dev/null || true
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

  log "Configuring UFW for SSH and Redis cluster traffic from ${private_cidr}."
  ufw allow ssh
  ufw allow from "${private_cidr}"
  ufw allow from "${private_cidr}" to any port 7000:7003 proto tcp
  ufw allow from "${private_cidr}" to any port 17000:17003 proto tcp
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

configure_needrestart_and_timers() {
  log "Configuring service restart and timer behavior."

  if [[ -f /etc/needrestart/needrestart.conf ]]; then
    sed -i "s/^#\?\$nrconf{restart}.*/\$nrconf{restart} = 'l';/" /etc/needrestart/needrestart.conf
  fi

  systemctl stop apt-daily.timer 2>/dev/null || true
  systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer 2>/dev/null || true
  systemctl disable apt-daily-upgrade.timer 2>/dev/null || true

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
  grep -Fqx '"\C-?": backward-kill-word' "${target_home}/.inputrc" || echo '"\C-?": backward-kill-word' >>"${target_home}/.inputrc"
  grep -Fqx '"\e[3;5~": backward-kill-word' "${target_home}/.inputrc" || echo '"\e[3;5~": backward-kill-word' >>"${target_home}/.inputrc"

  touch "${target_home}/.tmux.conf"
  grep -Fqx 'bind-key -n C-h send-keys C-w' "${target_home}/.tmux.conf" || echo 'bind-key -n C-h send-keys C-w' >>"${target_home}/.tmux.conf"

  chown "${target_user}:${target_user}" "${target_home}/.nanorc" "${target_home}/.inputrc" "${target_home}/.tmux.conf" 2>/dev/null || true
}

prepare_source_tree() {
  local script_dir tmp_dir file

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || true)"
  if [[ -n "${script_dir}" && -d "${script_dir}/scripts/etc/redis" && -d "${script_dir}/scripts/etc/systemd/system" ]]; then
    printf '%s\n' "${script_dir}/scripts/etc"
    return
  fi

  [[ -n "${RAW_BASE_URL}" ]] || die "Cannot find local scripts/. For remote install, set REDIS_CLUSTER_RAW_BASE to the GitHub raw base URL."

  tmp_dir="$(mktemp -d)"
  RAW_BASE_URL="${RAW_BASE_URL%/}"
  log "Downloading scripts/ from ${RAW_BASE_URL}."

  for file in \
    scripts/etc/redis/redis-7000.conf \
    scripts/etc/redis/redis-7001.conf \
    scripts/etc/redis/redis-7002.conf \
    scripts/etc/redis/redis-7003.conf \
    scripts/etc/systemd/system/redis-7000.service \
    scripts/etc/systemd/system/redis-7001.service \
    scripts/etc/systemd/system/redis-7002.service \
    scripts/etc/systemd/system/redis-7003.service; do
    mkdir -p "${tmp_dir}/$(dirname "${file}")"
    curl -fsSL "${RAW_BASE_URL}/${file}" -o "${tmp_dir}/${file}"
  done

  printf '%s\n' "${tmp_dir}/scripts/etc"
}

install_redis_node_files() {
  local announce_ip="$1"
  local source_etc="$2"
  local work_dir port conf service

  log "Installing Redis node configs and systemd units."
  work_dir="$(mktemp -d)"
  cp -a "${source_etc}/redis" "${work_dir}/redis"
  cp -a "${source_etc}/systemd" "${work_dir}/systemd"

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

  cat <<EOF

Redis node services are installed and running on:
  ${announce_ip}:7000
  ${announce_ip}:7001
  ${announce_ip}:7002
  ${announce_ip}:7003

Helper commands:

  # Check local node status
  systemctl status redis-7000 redis-7001 redis-7002 redis-7003 --no-pager
  redis-cli -p 7000 cluster nodes

  # Create a new 4-master cluster on this VM only
  redis-cli --cluster create ${announce_ip}:7000 ${announce_ip}:7001 ${announce_ip}:7002 ${announce_ip}:7003 --cluster-replicas 0

  # Add these 4 nodes to an existing cluster
  redis-cli --cluster add-node ${announce_ip}:7000 <existing-cluster-ip>:7000
  redis-cli --cluster add-node ${announce_ip}:7001 <existing-cluster-ip>:7000
  redis-cli --cluster add-node ${announce_ip}:7002 <existing-cluster-ip>:7000
  redis-cli --cluster add-node ${announce_ip}:7003 <existing-cluster-ip>:7000

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

  log "Setup complete. Rebooting in 1 minute."
  shutdown -r +1 "Redis cluster setup completed; rebooting to apply kernel/runtime settings."
}

main() {
  local announce_ip private_cidr source_etc

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  announce_ip="$1"
  validate_private_ipv4 "${announce_ip}" || die "Please provide a valid RFC1918 private IPv4 address."

  require_root
  check_ip_bound_to_host "${announce_ip}"

  private_cidr="${PRIVATE_CIDR:-$(derive_cidr24 "${announce_ip}")}"

  install_prerequisites
  configure_redis_apt_repo
  install_redis
  configure_thp
  configure_firewall "${private_cidr}"
  configure_kernel
  configure_needrestart_and_timers
  configure_time_and_shell_helpers

  source_etc="$(prepare_source_tree)"
  check_redis_modules
  install_redis_node_files "${announce_ip}" "${source_etc}"
  start_redis_nodes
  print_helpers "${announce_ip}"
  schedule_reboot
}

main "$@"
