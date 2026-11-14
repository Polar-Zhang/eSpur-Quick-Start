---
name: espur-mesh-join
description: eSpur WireGuard 组网的拓扑核对、节点接入规划和排障。区分北京中转上的 eSpur hub 与用户自有 WG，保护现有接口和 PDU 路由；设备遥测独立走 HTTPS。
---

# eSpur WireGuard 组网

先阅读 [全网拓扑与台账](references/topology.md)。它是 2026-11-15 的记录；操作前仍需核对目标主机、当前接口、路由和运行配置，不能把记录当成远端实时状态。

## 网络和边界

| 网络 | 记录中的 hub | 节点或用途 |
|---|---|---|
| eSpur 管理网 | 北京 `espur-wg0`，`10.66.66.1/24`，UDP 51822 | 主站 `.254`、终端 `.2`、Studio `.102`、lab-01 `.101`；SSH 和按需访问 PDU 网段 |
| 用户自有网 | 同一北京机器的 `wg0`，`10.10.10.1/24`，UDP 51820 | 独立系统；不得覆盖其配置、重启其接口或改变其路由 |

设备遥测和指令通过 HTTPS/TCP：lab-01 按台账经北京 TCP 中转，Studio 侧直连新加坡。WG 与 HTTPS 是不同链路；仅有 WG 握手不能证明数据上报正常。新加坡主站是 eSpur peer，不是两个网络的 hub。

`192.168.0.163` 在 lab 和 Studio 是不同站点的 PDU，不能只凭 IP 断定设备。主站当前到该网段的路由指向 eSpur WG，按现行台账对应 lab 侧；访问或控制前必须确认站点和实际路由。

## 已退役组件：不得用于现网接入

- 旧新加坡 `hub`/`hub443`、51820/443 双端口切换、`espur-mesh-enroll` 和 `mesh-admin` 自动注册均已退役。旧的 `join_mesh.sh --enroll` 不可用。
- 本仓库的旧 [join_mesh.sh](scripts/join_mesh.sh) 曾覆盖 `wg0.conf`、改回旧 Endpoint 并安装自动重启看门狗，不能用于任何节点；本次已设置为退出提示。**这不会改变已安装在远端的旧脚本或看门狗。**
- 旧 51821 UDP 透传和 lab 反连 22022 不属于当前拓扑；不要凭历史记录启用或重建。

## 核对与接入规划

1. 先确定具体站点和主机角色：新加坡主站、北京中转、lab、Studio 或人的终端。北京中转已有两个不同接口，不能默认操作 `wg0`。
2. 只读检查本机接口、路由和目标服务；先确认哪个接口属于 eSpur，再决定是否需要操作。不要打印或传输私钥。
3. 新 peer 按实际台账分配地址，私钥在节点本机生成；确认 hub 公钥、Endpoint、MTU 和双方 AllowedIPs。节点上的本地 PDU 网段与 WG 路由不能冲突。
4. 涉及更改 peer、接口、路由、NAT、hosts 或防火墙时，先保留现有配置，核对对两套网络的影响并准备恢复通道。不要自动覆盖整个文件或自动重启接口。
5. 先核对节点与 hub 的近期握手，再分层核对节点路由、hub 路由、转发/NAT 和目标站点；设备上报另查 HTTPS。UDP 超时和 ICMP 结果不能单独证明安全组问题。

可用的只读检查（将接口替换为已确认的实际名称）：

```bash
ip -br address
ip -4 route show
ip route get 192.168.0.163
sudo wg show <已确认的接口> endpoints
sudo wg show <已确认的接口> latest-handshakes
sudo wg show <已确认的接口> transfer
systemctl status wg-quick@<已确认的接口> --no-pager
```

`wg show` 输出可能含节点公钥和公网端点；不要输出配置文件中的私钥。新加坡主站到北京 hub 的握手只证明这两个节点的近期通信，不证明其他节点或 PDU 可达。

更多排障边界见 [排障手册](references/troubleshooting.md)；受限线路的 TCP 中转见 [6 号 Skill](../6-Domestic%20Relay-Quick%20Start-Skill/SKILL.md)。
