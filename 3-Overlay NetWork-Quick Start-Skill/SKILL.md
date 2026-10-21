---
name: espur-mesh-join
description: 让学校机房实机一句话加入 eSpur overlay 组网（WireGuard 星型网，hub 在新加坡 47.237.111.211），支持 token 自动注册（--enroll，无需管理员手动做配置文件）、开机自启、常驻看门狗双端口自愈；打通后广州终端可 SSH 实机、直访 PDU 192.168.0.x 网段。当用户提到 实机组网、加入组网、overlay、WireGuard、wg、组网配置、token 注册、隧道不通、handshake 失败、10.66.66.x、192.168.0.x 远程访问、实机接入管理端前的组网准备 等任何相关话题时使用本 skill，包括全新接入、重装系统后重连、换网络环境、排障。
---

# eSpur 实机 overlay 组网接入

一句话目标：在学校实机上跑 `scripts/join_mesh.sh --enroll <token>`，实机自动完成密钥生成、注册、隧道建立、看门狗部署；广州终端即可直达实机与其身后的 PDU 网段。

## 系统结构（先建立心智模型）

```
[广州终端 10.66.66.2] ──out:udp──┐
                                 [hub/新加坡 47.237.111.211 = 10.66.66.1]
                                   监听 51820/udp（主）+ 443/udp（备）
[学校实机 10.66.66.101] ─out:udp─┘
    └── 实验室网段 192.168.0.0/24（ATEN PDU .163，由实机做网关路由进 mesh）
```

- 只有 hub 有公网 IP；实机与终端都只做出站 UDP 连接，校园网不需要开任何入站端口。
- 实机上报管理端（`https://neowatt.cn/espur`）走公网 HTTPS 直连，**不进隧道**；隧道只承载终端的 SSH/远程访问流量。
- 实机是 PDU 网段的网关：隧道流量（10.66.66.x）经它转发到 192.168.0.x，回程做 masquerade。不配这一步，终端 ping 得到实机但到不了 PDU。
- **双通道自愈**：hub 同时监听 51820/udp 和 443/udp（同一密钥、同一 peer 表）。看门狗检测到隧道死亡会自动在两个端口间切换。

## 生死攸关的三个事实

1. **私钥永远在实机本地生成，不出机、不入 Git。** token 模式下实机本地 `wg genkey`，只把公钥 POST 给 hub；hub 返回 mesh IP 和 hub 公钥。任何向你要私钥的流程都是错的。
2. **实机的 `AllowedIPs` 必须只有 `10.66.66.0/24`，绝不能写 `192.168.0.0/24`。** 那是实机自己的本地网段，写进去会让本地路由被隧道吞掉，实机当场失联（PDU 也全部不可达）。join_mesh.sh 会自动拒绝这种配置。
3. **隧道不通先判别丢包位置，别默认怀疑校园网。** 症状：`wg show` 长时间无 handshake、`ping 10.66.66.1` 不通但 `ping 47.237.111.211` 通。候选原因按 `references/troubleshooting.md` §0.5 两步法判别：hub 阿里云安全组漏放行 UDP（实测首日根因，更常见）或本地网络拦出站 UDP（本校园网实测**不**拦）。join_mesh.sh 首次运行会自动尝试 443 备用端口；运行后的断线由看门狗自动恢复。

## 一句话接入（token 模式，推荐）

向组网管理员要一个一次性 token（15 分钟有效），然后在实机上：

```bash
bash scripts/join_mesh.sh --enroll mesh-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

脚本自动完成（幂等，可重跑）：

1. 装 wireguard-tools（dnf/apt 自适应，EPEL 自动切阿里云源，内核模块检查）
2. 出站连通性预检
3. 本机生成密钥对 → token + 公钥 POST 到 `https://neowatt.cn/espur/api/mesh/enroll` → 获得 mesh IP 与 hub 公钥 → 写入 `/etc/wireguard/wg0.conf`
4. 启用 `wg-quick@wg0`（**开机自动组网**），首次握手失败自动试 443 备用端口
5. 开 IP 转发 + masquerade（PDU 网关职责，firewalld/iptables 自适应）
6. 部署看门狗 `espur-mesh-watchdog.timer`（每 2 分钟体检；无 handshake 超 3 分钟自动重拨并在 51820/443 间切换自愈）
7. 最终体检（`wg show` + ping hub）

成功判据（脚本最后会输出）：

```bash
wg show wg0            # 有 latest handshake
ping -c 3 10.66.66.1   # 通 = 到 hub
systemctl is-enabled wg-quick@wg0 espur-mesh-watchdog.timer   # 都是 enabled
```

之后在任意已入网终端验证：`ping 10.66.66.101`（实机）、`ping 192.168.0.163`（PDU）。

## 备用：配置文件模式（离线场景）

无法 HTTPS 访问注册接口时，让管理员用手工脚本生成完整配置文件（含私钥，通过安全渠道传），然后：

```bash
bash scripts/join_mesh.sh /path/to/lab-01-wg0.conf
```

其余步骤（隧道/网关/看门狗/自启）与 token 模式完全相同。

## 管理员侧（hub 上）速查

```bash
cd /home/zp/espur-mesh
sudo python3 mesh-admin.py issue lab-02 lab 192.168.0.0/24   # 签发 token（带子网）
sudo python3 mesh-admin.py issue phone-1 terminal            # 签发终端 token
sudo python3 mesh-admin.py list        # registry 总表
sudo python3 mesh-admin.py tokens      # token 状态
sudo python3 mesh-admin.py revoke lab-02   # 吊销（双端口同步生效）
```

- 同名再次 `issue` = 重入模式：复用原 mesh IP、换新密钥。**重装系统后直接重新 issue + --enroll，无需清理。**
- 完整服务器侧手册（hub443 同步、服务清单）在 hub 的 `/home/zp/espur-mesh/README.md`。
- 阿里云安全组必须放行 **51820/udp 和 443/udp** 两条入方向规则（控制台操作；firewalld 已放行）。

## 排障速查

| 症状 | 原因与处理 |
|---|---|
| enroll 报 token expired/already used | token 15 分钟有效且一次性。让管理员重新 `issue` |
| enroll 成功但报 `/etc/wireguard/wg0.conf: Permission denied` | 旧版脚本 bug（已修）：token 模式漏建 `/etc/wireguard` 目录，**且 token 已被消耗**。重新 issue 后用修复版脚本重跑 |
| 无 handshake，但 `ping 47.237.111.211` 通 | 先按 troubleshooting.md §0.5 判别丢包位置：STUN 通 + hub 全端口 timeout = **hub 阿里云安全组没放行 UDP**（实测最常见根因；控制台加 51820/udp + 443/udp，放行后等看门狗重试，不通则重新 enroll）；STUN 也不通才是本地网络拦 UDP，看门狗会自动切 443 |
| handshake 正常但 ping 不通 10.66.66.1 | 阿里云安全组未放行对应 UDP 端口，或客户端 PublicKey 与 hub 不匹配（重入模式换过钥），重新走一次 enroll |
| 终端能 ping 实机，ping 不到 192.168.0.163 | 实机网关配置缺失。重跑 `join_mesh.sh`（幂等），或按 references/troubleshooting.md 第 3 条手动配。Debian 13/RPi OS 需先确认 iptables 已装（见 §3.5，缺失时 NAT 静默失效） |
| 实机起隧道后整个失联 | AllowedIPs 写入了 192.168.0.0/24。token 模式不会发生（脚本强制）；文件模式脚本会拒绝。已发生时按 troubleshooting.md 第 4 条恢复 |
| 大包丢、SSH 卡 | 跨境 MTU，配置已设 1380；仍卡降到 1360 |
| 重装系统后重连 | 直接 `--enroll` 新 token（管理员同名 issue 即可），mesh IP 不变、密钥自动轮换 |
| 看门狗在工作吗 | `systemctl status espur-mesh-watchdog.timer`；`journalctl -t espur-mesh-watchdog` 看自愈记录 |

完整排查手册见 `references/troubleshooting.md`。

## 本机既成事实（2026-10-21 lab-01 入网 ✅）

- hub（新加坡 47.237.111.211 = 10.66.66.1）三重开机自启：`wg-quick@hub`（51820/udp）、`wg-quick@hub443`（443/udp，同一密钥同一 peer 表）、`espur-mesh-enroll`（注册 API，经 nginx `https://neowatt.cn/espur/api/mesh/` 暴露）。阿里云安全组入方向已放行 51820/udp + 443/udp。
- lab-01 = 本机（eSpur-5090，Raspberry Pi 4B / Raspberry Pi OS Lite trixie，wlan0 上外网、eth0 = 192.168.0.200/24）：已 enroll 为 10.66.66.101，wg-quick + 看门狗 enabled，网关职责（ip_forward + eth0 masquerade）在位，`ping -I 10.66.66.101 192.168.0.163` 验证过终端→实机→PDU 全路径。重入 = 管理员同名 `issue` + 本机重新 `--enroll`（mesh IP 不变、密钥轮换）。
- `192.168.0.0/24` 已注册给 lab-01；新 lab 机器带**新**子网时在 issue 时声明，服务会做冲突检查。
- 首次接入踩过三个坑（细节见 troubleshooting.md）：① 旧版脚本 token 模式漏建 `/etc/wireguard` 目录，注册成功却写不了配置，白耗一个 token（已修）② Debian 13/RPi OS 无 iptables 时 NAT 静默失效（已修，脚本自动补装）③ 无 handshake 的真因是阿里云安全组漏放行 UDP，不是校园网——本校园网实测放行任意出站 UDP（判别法 §0.5）。
- 接入脚本需 root：先 `sudo -n true` 验证，不行让用户终端 `sudo -v` 或补 `/etc/sudoers.d/` NOPASSWD（该机重装系统后免密配置丢过一次）。
