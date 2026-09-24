#!/usr/bin/env bash
# Managed by rapid-redis-cluster-installer.
# 非 HT VM 專用：網卡 combined queue 數固定為「CPU 數 - node 數」，並把每個 queue 的
# 中斷釘在不跑 Redis server 的 CPU 上，讓 Redis server 獨佔後面那幾顆核心。
set -uo pipefail

IFACE=__NIC_IFACE__
CPUS=(__NIC_CPUS__)

channel_value() {
  local section="$1"
  ethtool -l "${IFACE}" 2>/dev/null \
    | awk -v section="${section}" 'index($0, section) == 1 {found = 1} found && /^Combined:/ {print $2; exit}'
}

queues=${#CPUS[@]}
max_queues="$(channel_value 'Pre-set maximums')"
if [[ "${max_queues}" =~ ^[0-9]+$ ]] && ((max_queues > 0 && queues > max_queues)); then
  echo "${IFACE} supports at most ${max_queues} combined queues; using ${max_queues}."
  queues=${max_queues}
fi

if [[ "$(channel_value 'Current hardware settings')" == "${queues}" ]]; then
  echo "${IFACE} already uses ${queues} combined queues."
else
  ethtool -L "${IFACE}" combined "${queues}" || echo "Warning: ethtool -L ${IFACE} combined ${queues} failed." >&2
fi

# virtio-net 的中斷名稱是 virtioN-input.Q / virtioN-output.Q，其他驅動多半是 <iface>-...-Q。
vdev="$(basename "$(readlink -f "/sys/class/net/${IFACE}/device")")"
pinned=0
while read -r irq name; do
  q="${name##*[!0-9]}"
  cpu="${CPUS[$((10#${q} % ${#CPUS[@]}))]}"
  if echo "${cpu}" >"/proc/irq/${irq}/smp_affinity_list"; then
    echo "IRQ ${irq} (${name}) -> CPU ${cpu}"
    pinned=$((pinned + 1))
  fi
done < <(
  awk -v vdev="${vdev}" -v iface="${IFACE}" '
    $NF ~ ("^" vdev "-(input|output)\\.[0-9]+$") || $NF ~ ("^" iface "-.*[0-9]+$") {
      sub(/:$/, "", $1)
      print $1, $NF
    }' /proc/interrupts
)
((pinned > 0)) || echo "Warning: no per-queue IRQs found for ${IFACE} (${vdev}); IRQ affinity left unchanged." >&2

# 關掉 RPS，避免軟中斷又被分流到 Redis server 的 CPU。
for f in "/sys/class/net/${IFACE}"/queues/rx-*/rps_cpus; do
  [[ -e "${f}" ]] && echo 0 >"${f}"
done

exit 0
