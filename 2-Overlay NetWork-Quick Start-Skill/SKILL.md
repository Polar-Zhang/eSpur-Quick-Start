---
name: espur-mesh-join
description: eSpur overlay 组网（WireGuard 星型网，hub 在国内中转 8.134.215.146:51822，新加坡主站是普通 peer .254）。2026-11-14 起 enroll 自动注册已随旧 hub 退役，新节点手工注册（模板见文内）；打通后终端可 SSH 实机、直访 PDU 192.168.0.x 网段。当用户提到 实机组网、加入组网、overlay、WireGuard、wg、组网配置、隧道不通、handshake 失败、10.66.66.x、192.168.0.x 远程访问、实机接入管理端前的组网准备 等任何相关话题时使用本 skill，包括全新接入、重装系统后重连、换网络环境、排障。
---

# eSpur 实机 overlay 组网接入

一句话目标：实机手工写 wg0.conf（节点模板见下）接入国内中转 hub，终端即可 SSH 实机、直访其身后的 PDU 网段。

## 系统结构（先建立心智模型，2026-11-14 迁移后现行）

```
[广州终端 10.66.66.2]  ──out:udp──┐
[Studio   10.66.66.102] ─out:udp──┤   [hub/国内中转 8.134.215.146 = 10.66.66.1]
[lab-01   10.66.66.101] ─out:udp──┤     监听 51822/udp（单端口）
[新加坡   10.66.66.254] ─out:udp──┘
                                     lab-01 ── 实验室网段 192.168.0.0/24
                                     （ATEN PDU .163，由 lab-01 做网关路由进 mesh）
```

- 只有中转 hub 有公网 IP；四个节点（含新加坡主站）都只做出站 UDP 连接，各局域网不需要开任何入站端口。
- 实机上报管理端（`https://neowatt.cn/espur`，经中转 443 转发）走公网 HTTPS，**不进隧道**；隧道只承载 SSH/远程访问/跨网段直访。
- lab-01 是 PDU 网段的网关：隧道流量（10.66.66.x、192.168.0.x）经它转发，回程 masquerade（已固化进 lab-01 的 wg0.conf PostUp）。不配这一步，ping 得到实机但到不了 PDU。
- **单端口**：新 hub 只监听 51822/udp；旧 hub 的 51820/443 双端口与看门狗端口切换机制已随迁移退役。

## 生死攸关的四个事实

1. **私钥永远在节点本地生成，不出机、不入 Git。** 任何向你要私钥的流程都是错的。
2. **节点侧 peer 必须写 `AllowedIPs = 10.66.66.0/24`，绝不能漏。** 缺了它 **handshake 照常、keepalive 照发，但所有来自 hub 的数据包被节点静默丢弃**——表现为"双方握手正常却 ping 不通"（2026-11-14 迁移日实锤，三个节点同踩）。
3. **实机的 `AllowedIPs` 里绝不能写 `192.168.0.0/24`（lab-01 自己的本地网段）。** 写进去会让本地路由被隧道吞掉，实机当场失联（PDU 也全部不可达）。join_mesh.sh 会自动拒绝这种配置。
4. **隧道不通先判别丢包位置，别默认怀疑网络。** 症状：`wg show` 长时间无 handshake、`ping 10.66.66.1` 不通但 `ping 8.134.215.146` 通。候选原因：中转云安全组漏放行 51822/udp（最常见），或本地网络拦出站 UDP（机房校园网实测**不**拦）。

## 新节点接入（手工注册，2026-11-14 起唯一方式）

enroll 注册 API 随旧 hub 退役（它只活在新加坡机器上），**`join_mesh.sh --enroll` 已不可用**；`join_mesh.sh` 的本地部分（装依赖/预检/网关配置）仍可参考。新节点两步：

**① 节点本地生成密钥并写 `/etc/wireguard/wg0.conf`：**

```ini
[Interface]
Address = 10.66.66.<分配IP>/32        # 台账见文末 mesh IP 台账
PrivateKey = <本机 wg genkey 产物>
MTU = 1280                            # lab-01 校园网线用 1200（实测必要）

[Peer]
PublicKey = 5iJKGvXZridj4vY3lC86QvOGHoQINRWOANYFALGA9S0=   # 中转 hub 公钥
Endpoint = 8.134.215.146:51822
AllowedIPs = 10.66.66.0/24            # 事实②：绝不能漏
PersistentKeepalive = 25
```

网关型机器（身后带子网）另加两行（lab-01 现行写法，2026-11-14 固化——此前 NAT 规则放 iptables 裸奔，机器重启即丢，导致 PDU 断路）：

```ini
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE
```

然后 `systemctl enable --now wg-quick@wg0`。

**② hub（中转）侧登记 peer：** 在中转的 `/etc/wireguard/espur-wg0.conf` 追加 peer 块（AllowedIPs 写分配的 /32；身后带子网的机器把子网也列上），`systemctl restart wg-quick@espur-wg0`（restart 会自动装内核路由；热改用 `wg syncconf` 时**路由不会自动加**，需手 `ip route add <子网> dev espur-wg0`，2026-11-14 实锤）。

成功判据：

```bash
wg show wg0            # 有 latest handshake
ping -c 3 10.66.66.1   # 通 = 到 hub
systemctl is-enabled wg-quick@wg0   # enabled
```

之后在任意已入网节点验证：`ping 10.66.66.101`（实机）、`ping 192.168.0.163`（PDU）。

## 管理员侧（中转 hub）速查

hub 配置就是中转上的一个文件：`/etc/wireguard/espur-wg0.conf`（peer 块带注释台账，含 PDU 子网声明）。

```bash
# 中转上
wg show espur-wg0 latest-handshakes    # 各 peer 握手时刻（0 = 从未连上）
cat /etc/wireguard/espur-wg0.conf      # peer 台账（本文件的唯一真源）
systemctl restart wg-quick@espur-wg0   # 改 conf 后应用（会重装内核路由）
sysctl net.ipv4.ip_forward             # 必须 =1（hub 转发 peer 间流量）
```

- 吊销 peer：删掉对应 peer 块 + restart。
- 重装系统后重连：**私钥在节点本地**。若节点密钥还在，conf 不用动；换了密钥则更新该 peer 的 PublicKey 后 restart。
- 云安全组必须放行 **51822/udp** 入方向（中转控制台）。

## 排障速查

| 症状 | 原因与处理 |
|---|---|
| 脚本一启动就报 `join_mesh.sh: line N: SUDO: unbound variable` | 旧版脚本 bug（2026-10-28 实锤）：`set -u` 下 `$SUDO` 未初始化。现行版已修（引用前 `SUDO=""`）。**执行前先 `grep -n 'SUDO=""' join_mesh.sh` 校验**——修复曾被并发提交覆盖过，别信"推过了" |
| enroll 报 token expired/already used | token 一次性（24 小时有效）。让管理员重新 `issue` |
| enroll 成功但报 `/etc/wireguard/wg0.conf: Permission denied` | 旧版脚本 bug（已修）：token 模式漏建 `/etc/wireguard` 目录，**且 token 已被消耗**。重新 issue 后用修复版脚本重跑 |
| 无 handshake，但 `ping 8.134.215.146` 通 | **中转云安全组没放行 51822/udp**（最常见根因；控制台补放行后 25s 内 keepalive 自动建立握手）；ping 公网也不通才是本地网络拦出站 UDP |
| handshake 正常但 ping 不通任何节点 | 三选一：① 节点侧 peer **漏写 `AllowedIPs`**（2026-11-14 迁移日三节点同踩，握手/keepalive 正常但数据包全被丢弃）② hub 侧该 peer AllowedIPs 不含目标网段 ③ hub 内核路由缺失（改 AllowedIPs 后用 restart 而非 syncconf，或手补 `ip route add <网段> dev espur-wg0`） |
| 终端能 ping 实机，ping 不到 192.168.0.163 | lab-01 网关职责缺件，按新增补：conf 内 PostUp masquerade（2026-11-14 起固化在 wg0.conf，裸 iptables 会在重启后丢）、ip_forward=1、hub 侧 lab-01 peer AllowedIPs 含 192.168.0.0/24、hub 内核路由。Debian 13/RPi OS 需先确认 iptables 已装（见 §3.5，缺失时 NAT 静默失效） |
| 实机起隧道后整个失联 | AllowedIPs 写入了 192.168.0.0/24（本地网段被隧道吞）。手工接入时最容易犯；已发生时按 troubleshooting.md 第 4 条恢复 |
| 大包丢、SSH 卡 | MTU 按线路：lab-01 校园网 1200（实测必要）、Studio/终端 1280、新加坡 .254 1380；仍卡再降 20 试 |
| 重装系统后重连 | 节点本地重新 genkey → 按本文模板写 conf（mesh IP 沿用台账）→ hub 侧更新该 peer PublicKey + restart |

完整排查手册见 `references/troubleshooting.md`。

## 本机既成事实（2026-10-21 lab-01 入网 ✅，平台接入 ✅）

- hub（新加坡 47.237.111.211 = 10.66.66.1）三重开机自启：`wg-quick@hub`（51820/udp）、`wg-quick@hub443`（443/udp，同一密钥同一 peer 表）、`espur-mesh-enroll`（注册 API，经 nginx `https://neowatt.cn/espur/api/mesh/` 暴露）。阿里云安全组入方向已放行 51820/udp + 443/udp。
- lab-01 = 本机（eSpur-5090，Raspberry Pi 4B / Raspberry Pi OS Lite trixie，wlan0 上外网、eth0 = 192.168.0.200/24）：已 enroll 为 10.66.66.101，wg-quick + 看门狗 enabled，网关职责（ip_forward + eth0 masquerade）在位，`ping -I 10.66.66.101 192.168.0.163` 验证过终端→实机→PDU 全路径。重入 = 管理员同名 `issue` + 本机重新 `--enroll`（mesh IP 不变、密钥轮换）。
- **开机快速自愈已加（2026-10-22）**：`wg0-bounce-onboot.service`（enabled）——开机 30 秒后检查 wg0 握手记录（`/usr/local/bin/wg0-handshake-check.sh`），从未握手即 bounce 接口。背景实测：wg-quick 开机正常拉起但首次握手偶发失败且 wg 不自动重试，远程通路因此中断 5 分钟（等看门狗周期兜底）；此服务把恢复窗口压到 ~1 分钟。重启预期不可达窗口按 ~1.5 分钟算。
- `192.168.0.0/24` 已注册给 lab-01；新 lab 机器带**新**子网时在 issue 时声明，服务会做冲突检查。
- 首次接入踩过三个坑（细节见 troubleshooting.md）：① 旧版脚本 token 模式漏建 `/etc/wireguard` 目录，注册成功却写不了配置，白耗一个 token（已修）② Debian 13/RPi OS 无 iptables 时 NAT 静默失效（已修，脚本自动补装）③ 无 handshake 的真因是阿里云安全组漏放行 UDP，不是校园网——本校园网实测放行任意出站 UDP（判别法 §0.5）。④ 机房部署首跑（2026-10-28）又实锤两个：旧版脚本 `SUDO: unbound variable` 崩在第一步，且修复推送后被并发提交覆盖、现场拉到的仍是坏脚本——**现场执行前必须 grep 校验脚本含修复点**（§0.6）。
- **机房形态（2026-10-28 起为当前形态）**：lab-01 上联改走机房交换机（USB 转接网卡，业务 IP 10.123.4.246/22 网关 10.123.7.254，预配置见 skill 5），wlan0 不再承载外网。机房网络实测**不拦出站 UDP**：51820/443 双通道 handshake 正常；hub 侧该 peer 的 AllowedIPs 已含机房 PDU 网段 `192.168.0.0/24, 192.168.1.0/24`。机房**禁公网 DNS**——enroll/上报要解析 neowatt.cn 时用 hosts 兜底（`47.237.111.211 neowatt.cn`，详见 skill 3 deployment.md 机房部署变体）。上联未插好时症状同样是"双端口 tx-only 零收包"，先查 Carrier 再怀疑网络策略。
- 接入脚本需 root：授权**以 sudoers.d 文件落地为准（ls /etc/sudoers.d/）**，勿以 `sudo -n true` 通过为准——本镜像带 `010_global-tty` 全局时间戳，用户在终端输一次密码后 15 分钟内全机 `sudo -n` 都通，极像"授权成功"，过期即"失效"，已两次误诊为"重启清 sudoers.d"（2026-11-03 实锤）。授权用零引号两步走防粘贴翻车：先 `printf 'espur-studio ALL=(ALL) NOPASSWD: ALL' > /tmp/sudoers-xxx`，用户跑 `sudo install -m 440 /tmp/sudoers-xxx /etc/sudoers.d/espur-studio`（拿到时间戳窗口后运维可代为 install 固化）。
- **第二台实机 Studio 已入网（2026-11-03）**：enroll 分配 **10.66.66.102**（脚本提示"常量按 lab 首机写死 10.66.66.101"属预期告警，不影响功能）；远程运维走 `ssh espur-studio@10.66.66.102`。mesh IP 台账：lab-01=.101，Studio=.102。

## 2026-11-12 现状增补（先读这节）

- **hub 的 UDP 443 备通道至今未通**：hub443 三个 peer 握手数全 0（2026-11-08 实测，
  从 Studio 发 UDP 443 探测包 hub 侧 tcpdump 零捕获）——阿里云安全组的规则需复核
  （须"自定义 UDP"443/443 入方向；用户称已加但实测未生效）。故看门狗的 443 自动切换
  目前实际不可用，51820 间歇黑洞的站点请改用下方反连隧道。
- **lab-01 管理通道已切三层**：① WG 直连（MTU 1200 已固化 wg0.conf）② **自愈反连隧道**
  （lab-01 → hub relay 账号 22022 端口，TCP 出站、与遥测同路、断 10s 自愈重连；
  hub 进入：`ssh -p 22022 espur-5090@localhost -i ~/.ssh/espur_hub_ed25519`）
  ③ 现场。hub 对 10.66.66.101/32 的 MTU 1300 主机路由重启后会失效，需重设。
- **同站点新增机器：不需要新 WG peer**——hub 管理 it 走同站已连机器 SSH 跳板
  （`ssh -J`），或新机器自建反连隧道。**平台遥测/指令从来不需要 WG**（出站 HTTPS）。
- 平台数据通道的国际路径问题 → 国内中转节点，见新 skill `6-Domestic Relay-Quick Start-Skill`。

## 2026-11-14 拓扑迁移（现行事实，覆盖上文一切 hub 相关描述）

**hub 从新加坡迁到国内中转**，动机：节点全在国内，出口绕新加坡再回来纯浪费 100ms+；新加坡主站不该是组网单点；且旧 hub 与平台同机、三接口同网段路由互相干扰。你的自有 WG hub（中转 51820/udp）全程未动。

- **新 hub**：中转 8.134.215.146，`espur-wg0`，监听 51822/udp，`10.66.66.1/24`，ip_forward=1、FORWARD ACCEPT（peer 间互访靠它）。peer 台账（conf 内有注释）：
  | 节点 | mesh IP | MTU | 说明 |
  |---|---|---|---|
  | 新加坡主站（平台） | .254 | 1380 | 原 hub 降级为普通 peer |
  | lab-01（eSpur-5090，校园网） | .101 | 1200 | 网关机：PostUp masquerade 已固化 conf |
  | Studio | .102 | 1280 | |
  | 广州终端 | .2 | 1280 | WireGuard 客户端（保留原 AllowedIPs） |
  全部节点私钥沿用原值（只换 hub 公钥与 Endpoint），`PersistentKeepalive = 25`。
- **新加坡旧 hub 退役**：`wg-quick@hub`（51820）+ `@hub443`（443）已 stop/disable，配置归档 `/etc/wireguard/retired-20261114/`；**enroll API 与 mesh-admin/registry 随之退役**——新增节点走本文手工流程。
- **PDU 网段路由四件套**（缺一不可，2026-11-14 全部实锤过）：① hub 侧 lab-01 peer AllowedIPs 含 `192.168.0.0/24, 192.168.1.0/24` ② hub 内核路由（restart 自动加）③ lab-01 PostUp masquerade（已固化）④ SG/终端侧 peer AllowedIPs 含目标网段。验证：`ping 192.168.0.163`（63ms，0% 丢包）。
- **中转 nginx 现状**：`443/8443→新加坡公网:443`（平台 API 公网路径，各站点上报用）、`8444→新加坡:22`（SSH 应急通道）；指向旧 hub 的 `51821→新加坡:51820` 死转发已删除。
- **旧产物同步失效**：看门狗 443 切换（hub443 已退役）、lab-01 反连隧道 22022（hub 侧已无 relay 账号，未重建；现在 WG 直连稳定，暂不需要）。lab-01 的 `wg0-bounce-onboot` 若还在，对新配置无害可保留。
- **管理 SSH**：`ssh -i ~/.ssh/espur_hub_ed25519 espur-5090@10.66.66.101`（lab-01 ✓ 实测）；Studio 管理公钥未装（装了即可直连）。
- **迁移日两个坑**（已写进上文事实②③与排障表）：节点侧漏 AllowedIPs（握手正常数据全丢）；syncconf 热改不装内核路由。

## 拓扑全景

全网物理/WG 双 hub/上报链路/机器台账/端口矩阵常驻文档：`references/topology.md`（2026-11-15 快照；**改网先改它**）。
