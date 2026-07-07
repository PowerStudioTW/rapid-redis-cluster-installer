# Redis Cluster 8.8.0 安裝

這個 repo 會在一台 VM 上安裝 Redis `8.8.0`，鎖定 APT 版本，並啟動 4 個 Redis Cluster node：

- `7000`
- `7001`
- `7002`
- `7003`

`cluster-announce-ip` 必須使用該 VM 的內網 IP。安裝指令沒有帶 IP、IP 不是 RFC1918 內網 IP、或該 IP 不在本機網卡上，`setup.sh` 會直接停止。

## 本機安裝

```bash
VM_PRIVATE_IP="<vm-private-ip>"
sudo bash setup.sh "$VM_PRIVATE_IP"
```

## GitHub raw 遠端安裝

上傳到 GitHub 後，使用 raw URL 的 base path：

```bash
RAW_BASE="https://raw.githubusercontent.com/<owner>/<repo>/<branch>"
VM_PRIVATE_IP="<vm-private-ip>"
curl -fsSL "$RAW_BASE/setup.sh" | sudo env REDIS_CLUSTER_RAW_BASE="$RAW_BASE" bash -s -- "$VM_PRIVATE_IP"
```

預設會從 `VM_PRIVATE_IP` 自動推導出 `a.b.c.0/24`，並允許該網段連線 Redis cluster。
如果內網不是 `/24`，可以指定允許的來源網段：

```bash
RAW_BASE="https://raw.githubusercontent.com/<owner>/<repo>/<branch>"
VM_PRIVATE_IP="<vm-private-ip>"
PRIVATE_CIDR="<custom-private-cidr>"
curl -fsSL "$RAW_BASE/setup.sh" | sudo env PRIVATE_CIDR="$PRIVATE_CIDR" REDIS_CLUSTER_RAW_BASE="$RAW_BASE" bash -s -- "$VM_PRIVATE_IP"
```

測試安裝但不重開機：

```bash
VM_PRIVATE_IP="<vm-private-ip>"
sudo SKIP_REBOOT=1 bash setup.sh "$VM_PRIVATE_IP"
```

額外允許可信任來源 IP 可以安裝後自行新增：

```bash
sudo ufw allow from <trusted-admin-ip>
sudo ufw allow from <trusted-office-cidr>
```

## 安裝內容

`setup.sh` 會執行：

- 安裝 Redis `6:8.8.0-1rl1~noble1`，並 `apt-mark hold redis redis-server redis-tools`
- 停用並 mask 預設 `redis-server`
- 將 `scripts/etc/redis/redis-700*.conf` 安裝到 `/etc/redis/`
- 將 `scripts/etc/systemd/system/redis-700*.service` 安裝到 `/etc/systemd/system/`
- 把 `cluster-announce-ip __REDIS_CLUSTER_ANNOUNCE_IP__` 替換成指令輸入的 VM 內網 IP
- 啟動 `redis-7000` 到 `redis-7003`
- 設定 THP、UFW、sysctl、chrony、logrotate timer、apt daily timer、needrestart
- 完成後列出 helper 指令，並排程 1 分鐘後重開機

## Helper 指令

檢查本機 Redis node：

```bash
systemctl status redis-7000 redis-7001 redis-7002 redis-7003 --no-pager
redis-cli -p 7000 cluster nodes
```

在單台 VM 建立 4 master cluster：

```bash
VM_PRIVATE_IP="<vm-private-ip>"
redis-cli --cluster create "$VM_PRIVATE_IP":7000 "$VM_PRIVATE_IP":7001 "$VM_PRIVATE_IP":7002 "$VM_PRIVATE_IP":7003 --cluster-replicas 0
```

加入既有 Redis Cluster：

```bash
VM_PRIVATE_IP="<vm-private-ip>"
redis-cli --cluster add-node "$VM_PRIVATE_IP":7000 <existing-cluster-ip>:7000
redis-cli --cluster add-node "$VM_PRIVATE_IP":7001 <existing-cluster-ip>:7000
redis-cli --cluster add-node "$VM_PRIVATE_IP":7002 <existing-cluster-ip>:7000
redis-cli --cluster add-node "$VM_PRIVATE_IP":7003 <existing-cluster-ip>:7000
```

快速 rebalance 空 master：

```bash
redis-cli --cluster rebalance <existing-cluster-ip>:7000 --cluster-use-empty-masters --cluster-threshold 1
```

互動式 reshard：

```bash
redis-cli --cluster reshard <existing-cluster-ip>:7000
```

刪除 Redis node：

```bash
redis-cli -p 7000 cluster nodes
redis-cli --cluster del-node <existing-cluster-ip>:7000 <node-id>
```
