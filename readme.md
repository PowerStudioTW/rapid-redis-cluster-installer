# Redis Cluster 8.8.0 一行安裝

在新的 VM 上執行一行指令，即可安裝 Redis `8.8.0`、鎖定 APT 版本，並啟動 4 個 Redis Cluster node：

- `7000`
- `7001`
- `7002`
- `7003`

安裝完成後只會準備好 Redis node，不會自動建立 cluster，也不會自動加入既有 cluster；可以確認服務正常後再執行本文後面的 cluster 指令。

## VM 一行安裝

需求：Ubuntu 24.04、可使用 `sudo`、可連線至 GitHub 與 Redis APT repository。

直接執行：

```bash
curl -fsSL https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master/setup.sh | sudo bash
```

`setup.sh` 會優先取得預設路由使用的 RFC1918 內網 IP；若沒有預設路由來源，則在本機只有一個內網 IP 時使用該 IP。偵測成功後，會把安裝至 `/etc/redis/redis-7000.conf`～`redis-7003.conf` 的 `cluster-announce-ip` 全部改成該 IP。

如果 VM 有多個內網 IP 且無法安全判斷，安裝會停止。此時可在指令最後手動指定：

```bash
curl -fsSL https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master/setup.sh | sudo bash -s -- 10.0.0.10
```

預設會從 VM 內網 IP 自動推導出 `a.b.c.0/24`，並允許該網段連線 Redis cluster。安裝完成後會排程在 1 分鐘後重開機。

## 可選設定

如果內網不是 `/24`，可以在同一行指定允許的來源網段：

```bash
curl -fsSL https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master/setup.sh | sudo env PRIVATE_CIDR="10.0.0.0/16" bash
```

不希望安裝後自動重開機：

```bash
curl -fsSL https://raw.githubusercontent.com/PowerStudioTW/rapid-redis-cluster-installer/master/setup.sh | sudo env SKIP_REBOOT=1 bash
```

`REDIS_CLUSTER_RAW_BASE` 是進階覆寫參數。遠端執行時，`setup.sh` 還需要下載 repo 內的 Redis config 與 systemd unit；這個參數用來指定那些檔案的 GitHub Raw base URL。官方 repo URL 已經內建在腳本中，正常安裝不需要設定它。只有從 fork、其他 branch 或測試來源安裝時才需要覆寫：

```bash
RAW_BASE="https://raw.githubusercontent.com/<owner>/<repo>/<branch>"; curl -fsSL "$RAW_BASE/setup.sh" | sudo env REDIS_CLUSTER_RAW_BASE="$RAW_BASE" bash
```

額外允許可信任來源 IP 可以安裝後自行新增：

```bash
sudo ufw allow from <trusted-ip>
```

## 安裝內容

`setup.sh` 會執行：

- 安裝必要工具，包括 `curl`、`ufw`、`chrony`、`htop`
- 安裝 Redis `6:8.8.0-1rl1~noble1`，並 `apt-mark hold redis redis-server redis-tools`
- 停用並 mask 預設 `redis-server`
- 將 `scripts/etc/redis/redis-700*.conf` 安裝到 `/etc/redis/`
- 將 `scripts/etc/systemd/system/redis-700*.service` 安裝到 `/etc/systemd/system/`
- 將 `scripts/root/.bashrc` 安裝到 `/root/.bashrc`
- 將 `scripts/~/.config/htop/htoprc` 安裝到 `/root/.config/htop/htoprc`
- 若透過 `sudo` 執行，再將 `htoprc` 複製到原登入使用者的家目錄
- 複製完成後比對 `.bashrc` 與 `htoprc` 內容，驗證失敗會停止安裝
- 把 `cluster-announce-ip __REDIS_CLUSTER_ANNOUNCE_IP__` 替換成自動偵測或手動指定的 VM 內網 IP
- 啟動 `redis-7000` 到 `redis-7003`
- 設定 THP、UFW、sysctl、chrony、logrotate timer、apt daily timer、needrestart
- 完成後列出 helper 指令，並排程 1 分鐘後重開機

## Helper 指令

檢查本機 Redis node：

```bash
systemctl status redis-7000 redis-7001 redis-7002 redis-7003 --no-pager
redis-cli -p 7000 cluster nodes
```

安裝後若要在單台 VM 建立 4 master cluster：

```bash
VM_PRIVATE_IP="$(awk '$1 == "cluster-announce-ip" {print $2; exit}' /etc/redis/redis-7000.conf)"
redis-cli --cluster create "$VM_PRIVATE_IP":7000 "$VM_PRIVATE_IP":7001 "$VM_PRIVATE_IP":7002 "$VM_PRIVATE_IP":7003 --cluster-replicas 0
```

加入既有 Redis Cluster。`VM_PRIVATE_IP` 會從本機 Redis config 自動取得；只需要填寫既有 cluster 其中一台 node 的 IP：

```bash
VM_PRIVATE_IP="$(awk '$1 == "cluster-announce-ip" {print $2; exit}' /etc/redis/redis-7000.conf)"
EXISTING_CLUSTER_IP="<existing-cluster-ip>"
ADD_NODE_DELAY_SECONDS=3

for PORT in 7000 7001 7002 7003; do
  if ! redis-cli --cluster add-node "$VM_PRIVATE_IP:$PORT" "$EXISTING_CLUSTER_IP:7000"; then
    echo "Failed to add $VM_PRIVATE_IP:$PORT; stopping."
    break
  fi
  [[ "$PORT" == "7003" ]] || sleep "$ADD_NODE_DELAY_SECONDS"
done
```

每個 node 加入成功後會等待 5 秒再處理下一個。需要更長時間時可調高 `ADD_NODE_DELAY_SECONDS`。

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
