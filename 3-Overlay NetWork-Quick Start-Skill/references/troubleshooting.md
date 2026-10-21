# 组网排障手册

## 0. enroll 模式专属问题

| 症状 | 原因与处理 |
|---|---|
| enroll 返回 `token expired` / `token already used` | token 15 分钟有效、一次性。让管理员重新 `mesh-admin.py issue` |
| enroll 返回 `bad public key format` | 实机的 wg 版本过旧生成的密钥格式异常；升级 wireguard-tools 后重跑 |
| enroll 返回 `subnet conflict` | 两台 lab 机器声明了同一子网。管理员需确认哪台是真身，revoke 旧的后重新 issue |
| enroll 成功但脚本报 `/etc/wireguard/wg0.conf: Permission denied` | 旧版脚本 bug：只有配置文件模式分支会 `install -d /etc/wireguard`，token 模式分支漏了，**且此时 token 已被消耗**（hub 侧已注册）。处理：管理员重新 issue，用修复版脚本重跑（脚本 enroll 分支应含 `install -d -m 700 /etc/wireguard`，2026-10-21 已修） |
| 重装后想拿回原 IP | 管理员用**同名**再 issue 一个 token，--enroll 即复用原 mesh IP 并轮换密钥 |
| 看门狗行为检查 | `systemctl status espur-mesh-watchdog.timer`；`journalctl -t espur-mesh-watchdog --since -1h` 看自愈/切换记录 |
| 看门狗反复在双端口间跳 | 两个 UDP 端口都时通时断 = 校园网出站不稳。看 journal 里哪个端口成功率高，把 wg0.conf 固定到该端口，或按第 1c 条上 wstunnel |

按现象对照。先跑一次体检命令拿到事实，再查表：

```bash
sudo wg show wg0                 # handshake / transfer / allowed ips
ping -c 3 47.237.111.211         # 公网层可达性
ping -c 3 10.66.66.1             # 隧道层可达性（hub）
ip route get 192.168.0.163       # 实验室网段路由
journalctl -u wg-quick@wg0 -n 30 # 服务日志
```

### 0.5 快速判别：丢包发生在校园网还是 hub 安全组？（2026-10-21 实测案例）

`wg show` 只有 sent 没有 received、双端口都握不上手时，用两步定位丢包位置：

```bash
# ① 校园网是否放行"任意目的地"出站 UDP：STUN 请求公共服务器 3478/udp
python3 - <<'EOF'
import socket, os, struct
msg = struct.pack('>HHI', 0x0001, 0, 0x2112A442) + os.urandom(12)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(msg, ("stun.miwifi.com", 3478))   # 备选: stun.qq.com / ntp.aliyun.com:123
print("REPLY ok => 校园网放行出站 UDP" if s.recvfrom(256)[0] else "no reply")
EOF

# ② hub 侧 UDP 是否被云防火墙丢弃：对 hub 任意 UDP 端口发包
python3 - <<'EOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(b"probe", ("47.237.111.211", 9999))   # 未开服务的端口
try:
    s.recv(64); print("got reply")
except ConnectionRefusedError:
    print("ICMP port-unreachable => UDP 路径通，hub 安全组已放行（端口逻辑问题另查）")
except socket.timeout:
    print("timeout => 包在 hub 云防火墙被静默丢弃：阿里云安全组没放行 UDP")
EOF
```

判读（2026-10-21 实测：STUN 通 + hub 全端口 timeout → 阿里云安全组漏放行；放行 51820/udp + 443/udp 后看门狗自动建联，无需重新 enroll）：

| ① STUN/NTP | ② hub 探测 | 结论 | 处理 |
|---|---|---|---|
| 通 | ICMP unreachable | UDP 全链路通，是配置/密钥问题 | 按第 2 条查 PublicKey 与 hub peer |
| 通 | timeout | **hub 阿里云安全组没放行 UDP**（最常见） | 控制台加入方向 `51820/udp` + `443/udp`，源 0.0.0.0/0；放行后看门狗自动建联，无需新 token |
| 不通 | — | 校园网拦出站 UDP | 按第 1b 条走 443，仍不行按 1c 上 wstunnel |

注：NTP（`ntp.aliyun.com:123`）可替代 STUN 做测试①，但只能证明"特定端口对特定目的地"放行；STUN 证明的是任意目的地，两者结合判读更稳。

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

### 3.5 Debian/Ubuntu 实机注意：iptables 缺失时 NAT 静默失效

Debian 13 只预装 nftables（树莓派 Raspberry Pi OS Lite 同样）。join_mesh.sh 第 5 步在无 firewalld 时走 iptables，而 `iptables` 命令不存在时脚本**不报错、继续往下跑**，masquerade 根本没配上——症状是隧道通了之后，广州终端 ping 10.66.66.101 通、ping 192.168.0.163 不通。预防：跑脚本前 `command -v iptables || sudo apt-get install -y iptables`。

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
