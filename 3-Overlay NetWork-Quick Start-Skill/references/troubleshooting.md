# 组网排障手册

按现象对照。先跑一次体检命令拿到事实，再查表：

```bash
sudo wg show wg0                 # handshake / transfer / allowed ips
ping -c 3 47.237.111.211         # 公网层可达性
ping -c 3 10.66.66.1             # 隧道层可达性（hub）
ip route get 192.168.0.163       # 实验室网段路由
journalctl -u wg-quick@wg0 -n 30 # 服务日志
```

## 1. 无 handshake，但 ping 47.237.111.211 通

公网可达、隧道不通 = UDP 51820 被中间网络丢弃。校园网最常见。

处理顺序（每步在实机上验证 `sudo wg show wg0` 是否出现 handshake）：

### 1a. 确认 hub 侧没问题（管理员在 hub 上执行）

```bash
sudo wg show hub | grep -A3 "lab-01 的公钥前几位"   # peer 是否存在
sudo ss -ulnp | grep 51820                          # hub 在监听
```

阿里云控制台 → 安全组入方向必须有 `自定义 UDP 51820/51820, 源 0.0.0.0/0`。**这是最常见漏项**：服务器 firewalld 放行了 ≠ 云安全组放行了。

### 1b. 换 UDP 443

校园网通常放行出站 443（UDP 443 是 QUIC 端口，多数环境不拦）。

- hub 侧（管理员）：`/etc/wireguard/hub.conf` 的 `ListenPort` 改 443（若 hub 的 443/UDP 未被 nginx 占用；nginx 用的是 TCP，不冲突），`sudo bash -c 'wg syncconf hub <(wg-quick strip hub)'`。注意阿里云安全组同步放行 443/udp。
- 实机侧：`wg0.conf` 的 `Endpoint = 47.237.111.211:443`，`sudo systemctl restart wg-quick@wg0`。
- 所有客户端同步改 Endpoint。

### 1c. wstunnel（WireGuard 包进 TLS，463 端口形态即纯 HTTPS 流量）

UDP 443 也不通时（少数深度包检测环境）：

```bash
# hub（管理员）：
wstunnel server wss://0.0.0.0:443      # 需配证书，或用 ws:// 443 明文 websocket

# 实机：
wstunnel client -U wg://127.0.0.1:51821 wss://47.237.111.211:443
# 然后实机 wg0.conf 的 Peer 不再写 Endpoint，hub 侧 peer 保持
# 实机本地 wg0 把 Endpoint 换成 127.0.0.1:51821 的方式按 wstunnel 版本文档微调
```

## 2. handshake 正常但 ping 不通 10.66.66.1

1. `sudo wg show wg0` 的 `transfer` 是否双端有字节（只有 send 无 receive = hub 的回包进不来，检查 hub 侧 peer 的 AllowedIPs 是否含本机 mesh IP）。
2. 配置里 PublicKey 是否真的是 hub 公钥（`e2f1ELftAygMwTn/6sRR3Vp9eL9SHvVLmNTbQuFRxEg=`，找管理员核对）。
3. 本机若有第三方安全软件/SELinux enforcing，临时 `setenforce 0` 试一次，排除拦截。

## 3. 终端能 ping 实机(10.66.66.101)，ping 不到 192.168.0.163

实机的网关职责没配好。重跑 `join_mesh.sh`（幂等）或手动三步：

```bash
sysctl net.ipv4.ip_forward                              # 应为 1
ip route get 192.168.0.163                              # 应走实验室网卡（如 eth0）
sudo iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE 2>/dev/null \
  && echo "NAT ok" || sudo iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE
```

还不到 → 在实机上 ping 192.168.0.163 确认实机自己能通 PDU（实机本体不通就是 PDU/网线/ACL 问题，与组网无关，去查 deployment skill）。

## 4. 起隧道后实机整个失联

AllowedIPs 写入了 `192.168.0.0/24`（见 SKILL.md 生死攸关第 2 条）。恢复路径：

1. 让用户从实机本地控制台（显示器键盘）或同网段其他机器 SSH 进去。
2. `sudo sed -i 's/, 192.168.0.0\/24//' /etc/wireguard/wg0.conf`
3. `sudo systemctl restart wg-quick@wg0`

预防：只使用管理员下发的配置，不要手工改 AllowedIPs。

## 5. 大包丢 / SSH 能连但很卡 / scp 挂死

跨境 MTU。配置已设 1380；还不行：

```bash
# 找到不丢的最大包尺寸（1400 起试，逐步 -20）
ping -M do -s 1352 10.66.66.1    # 1352 + 28 = 1380
```

把 wg0.conf 的 MTU 改成「测得值 + 28」，restart。

## 6. 重装系统 / 换机器后重连

- 私钥还在（有备份）：直接重跑 `join_mesh.sh`，mesh IP 不变。
- 私钥丢了：让管理员在 hub 上删掉旧 peer（见 SKILL.md 管理员备忘），重新 `add-peer.sh` 生成新配置下发。

## 7. hub 侧自查清单（管理员用）

```bash
sudo wg show hub                    # peers 数量、各 peer handshake/transfer
sudo bash -c 'wg syncconf hub <(wg-quick strip hub)'   # 改配置后热加载
cat /home/zp/espur-mesh/peers.txt   # 注册表真源
firewall-cmd --list-ports | grep 51820                 # 本机防火墙
# 阿里云控制台安全组：51820/udp 入方向（没有 CLI，只能控制台点）
```
