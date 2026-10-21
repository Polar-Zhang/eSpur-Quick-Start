---
name: espur-mesh-join
description: 让学校机房实机一句话加入 eSpur overlay 组网（WireGuard 星型网，hub 在新加坡 47.237.111.211），打通后广州终端可 SSH 实机、直访 PDU 192.168.0.x 网段。当用户提到 实机组网、加入组网、overlay、WireGuard、wg、组网配置、隧道不通、handshake 失败、10.66.66.x、192.168.0.x 远程访问、实机接入管理端前的组网准备 等任何相关话题时使用本 skill，包括全新接入、重装系统后重连、换网络环境、排障。
---

# eSpur 实机 overlay 组网接入

一句话目标：在学校实机上跑 `scripts/join_mesh.sh`，实机获得 mesh IP `10.66.66.101`，广州终端即可直达实机与其身后的 PDU 网段。

## 系统结构（先建立心智模型）

```
[广州终端 10.66.66.2] ──out:51820/udp──┐
                                       [hub/新加坡 47.237.111.211 = 10.66.66.1]
[学校实机 10.66.66.101] ─out:51820/udp─┘
    └── 实验室网段 192.168.0.0/24（ATEN PDU .163，由实机做网关路由进 mesh）
```

- 只有 hub 有公网 IP；实机与终端都只做出站 UDP 连接，校园网不需要开任何入站端口。
- 实机上报管理端（`https://neowatt.cn/espur`）走公网 HTTPS 直连，**不进隧道**；隧道只承载终端的 SSH/远程访问流量。
- 实机是 PDU 网段的网关：隧道流量（10.66.66.x）经它转发到 192.168.0.x，回程做 masquerade。不配这一步，终端 ping 得到实机但到不了 PDU。

## 生死攸关的三个事实

1. **配置文件含私钥，必须从组网管理员渠道获取，绝不入 Git。** 本 skill 的 `assets/wg0.conf.template` 只有占位符。实机的真实配置（mesh IP `10.66.66.101` + 对应私钥）由管理员在 hub 上用 `add-peer.sh` 生成后私下发给实机操作者。仓库是公开的，私钥进仓库 = 整个 mesh 沦陷。
2. **实机的 `AllowedIPs` 必须只有 `10.66.66.0/24`，绝不能写 `192.168.0.0/24`。** 那是实机自己的本地网段，写进去会让本地路由被隧道吞掉，实机当场失联（PDU 也全部不可达）。
3. **校园网经常限制 UDP。** 症状：`wg show` 长时间无 handshake、`ping 10.66.66.1` 不通但 `ping 47.237.111.211` 通。处理顺序见「排障速查」第 1 条，兜底方案在 `references/troubleshooting.md`（UDP 443 → wstunnel 包 TLS）。

## 一句话接入（标准流程）

把管理员下发的实机配置存为任意路径的 `lab-01-wg0.conf`，然后：

```bash
bash scripts/join_mesh.sh /path/to/lab-01-wg0.conf
```

脚本幂等，自动完成：装 wireguard-tools（dnf/apt 自适应）→ 出站连通性预检（ICMP + UDP 到 hub）→ 安装配置到 `/etc/wireguard/wg0.conf` → 启用 `wg-quick@wg0` → 开 IP 转发 + masquerade（PDU 网关职责）→ 最终体检。

成功判据（脚本最后会输出）：

```bash
wg show wg0        # 有 latest handshake
ping -c 3 10.66.66.1   # 通 = 到 hub
```

之后在任意已入网终端验证：`ping 10.66.66.101`（实机）、`ping 192.168.0.163`（PDU）。

## 执行流程（模型引导用户时的步骤）

1. **环境预检**（脚本会做，但若用户手动排查可先看）：

   ```bash
   uname -r                          # ≥5.6 内核自带 wireguard 模块；老内核脚本会提示装 DKMS
   systemctl is-active NetworkManager firewalld 2>/dev/null   # 影响配置方式，脚本自适应
   ping -c 3 47.237.111.211          # 基础出站路由
   ```

2. **拿配置**：没有配置文件时，联系组网管理员（hub 登录凭据持有者）在 hub 上执行 `./add-peer.sh lab-XX lab 192.168.0.0/24` 并把渲染出的 `wg0.conf` 私下传给实机操作者。**不要**自己照模板编造密钥——hub 侧没有对应公钥的 peer 会被直接丢弃。

3. **跑一键脚本**（约 1–2 分钟）：

   ```bash
   bash scripts/join_mesh.sh lab-01-wg0.conf
   ```

   脚本自适应 firewalld / ufw / 裸 iptables 三种防火墙；NAT 网关部分只处理 `10.66.66.0/24 → 实验室网卡` 方向，不动实机原有任何规则。

4. **验证**（本机 + 请广州终端配合）：

   ```bash
   sudo wg show wg0 | grep -E "handshake|transfer"   # handshake 出现且有收发字节
   ping -c 3 10.66.66.1                              # mesh 网关
   # 广州终端侧：ping 10.66.66.101 → ping 192.168.0.163 → 浏览器开 http://192.168.0.163
   ```

## 排障速查

| 症状 | 原因与处理 |
|---|---|
| `wg show` 无 handshake，但 `ping 47.237.111.211` 通 | 校园网拦 UDP 51820。先试换 UDP 443（hub 与客户端同步改 ListenPort/Endpoint），不行上 wstunnel，见 references/troubleshooting.md |
| handshake 正常但 ping 不通 10.66.66.1 | 多为阿里云安全组没放行 51820/udp（管理员侧确认），或客户端配置的 PublicKey 不是 hub 公钥 |
| 终端能 ping 实机，ping 不到 192.168.0.163 | 实机网关配置缺失。重跑 `join_mesh.sh`（幂等），或手动开 ip_forward + masquerade（见 references/troubleshooting.md 第 3 条） |
| 实机起隧道后整个失联 | 几乎一定是 AllowedIPs 写入了 192.168.0.0/24（见「生死攸关」第 2 条）。控制台进实机改回 `AllowedIPs = 10.66.66.0/24` |
| 大包丢、SSH 卡 | 跨境 MTU 问题，配置已设 1380；仍卡降到 1360 |
| 重装系统后重连 | 直接重跑本流程（私钥不变则 mesh IP 不变；私钥文件丢了找管理员吊销重发） |

完整排查手册（含 UDP 443 迁移步骤、wstunnel 配置、hub 侧自查清单）见 `references/troubleshooting.md`。

## 给管理员（hub 侧）的备忘

hub 与 add-peer 工具在新加坡服务器 `/home/zp/espur-mesh/`：`peers.txt` 是注册表真源，`add-peer.sh <name> <terminal|lab> [subnets]` 一条命令完成分配 IP/生成密钥/追加 hub 配置/渲染客户端配置。terminal 用 10.66.66.2-.99，lab 用 .101-.199。吊销 peer：删 hub 配置中对应 `[Peer]` 块后 `sudo bash -c 'wg syncconf hub <(wg-quick strip hub)'`。阿里云安全组必须放行 51820/udp（控制台操作，服务器上 firewalld 已放行）。

## 本 skill 的既成事实（2026-10-21 组网）

- hub 已在新加坡 ECS（i-t4nizvwitrw9yg6yz0dl，47.237.111.211）上线并开机自启，`wg show hub` 应有 2 个 peer（gz-terminal .2、lab-01 .101）。
- `192.168.0.0/24` 已注册给 lab-01；新 lab 机器带新子网时先在管理员处登记，避免子网冲突。
- lab-01 的私钥已生成待下发（在 hub 的 `/home/zp/espur-mesh/peers/lab-01/wg0.conf`）。
