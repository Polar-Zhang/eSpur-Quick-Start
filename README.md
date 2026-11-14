# eSpur Quick Start Skills

eSpur 项目的部署与运维资料。先确认主机和站点，再按任务选择对应 Skill；实机和网络变更不能仅按编号自动执行。

## Skill 地图

| # | 目录 | 一句话 | 侧别 |
|---|---|---|---|
| 0 | `0-eSpur Full Stack-Quick Start-Skill` | **总控入口**：判定管理侧/设备侧，路由到下面各 skill | 双侧 |
| 1 | `1-LCD-Quick Start-Skill` | Waveshare 2.4 寸 SPI LCD + fbcp 镜像（可选） | 设备 |
| 2 | `2-Overlay NetWork-Quick Start-Skill` | eSpur WireGuard 组网、拓扑与排障 | 设备 + 终端 |
| 3 | `3-eSpur Deployment-Quick Start-Skill` | eSpur_v2 客户端部署（PDU SNMP + 平台上报） | 设备 |
| 4 | `4-Management Platform-Quick Start-Skill` | 管理端全栈部署/更新/运维 + 设备接入管理 | 管理端 |
| 5 | `5-eSpur Mode Switch-Quick Start-Skill` | 测试/生产模式切换 + 上联业务 IP 配置 | 设备 |
| 6 | `6-Domestic Relay-Quick Start-Skill` | 国内中转节点：受限线路站点桥接接入 | 设备 + 管理端 |

新设备标准流程：**1（接了屏才做）→ 2 组网 → 3 部署 → 4 平台接入**；
国际受限线路（校园网等）：在 2/3 之间插入 **6 中转接入**。
不确定从哪开始：先用 0 号总控核对平台、中转、设备或终端角色；不以云厂商或 DNS 单独判定。

## 拓扑

现网记录见 [全网拓扑](<2-Overlay NetWork-Quick Start-Skill/references/topology.md>)：北京同时承载 eSpur hub `espur-wg0:51822/udp` 和用户独立的 `wg0:51820/udp`；新加坡平台是 eSpur peer `.254`。lab 侧 HTTPS 经北京 TCP 中转，Studio 侧按台账直连新加坡，数据上报不走 WG。各节点实时状态须单独核对。

## 相关仓库

- `Polar-Zhang/eSpur` — 主程序（v2 客户端 + 管理端前后端）
- 平台设备 bootstrap 与旧组网注册是不同流程；旧新加坡 mesh enroll 和平台旧组网 Token 入口已退役，不能用于当前北京 hub。**任何密钥/Token 不入库**。

## 历史实机记录（非实时状态）

- **Studio**（Raspberry Pi 4B / trixie，user espur-studio）：全链路上线——LCD（背光物理12
  常亮方案）→ 组网 **10.66.66.102** → v2 部署（平台 external_id=**2**，studio@espur.local）
  → 实时上报中（test 模式，PDU 3 号口 ~57W）。systemd：espur-algorithm + 防冻结看门狗。
  2026-11-12：新增同 PDU 第二实例 **Studio-Backup（external_id=3，口组 5-8）**，
  部署目录 `192.168.0.163_5-6-7-8`，systemd `espur-algorithm-b`，平台在线。
- lab-01（Raspberry Pi 4B / trixie）：2026-10-22 曾全链路打通（LCD → 组网 .101 → v2 → 平台在线）。
  2026-11-07 起换新上行（eth1 CGNAT）+ 平台通道走**国内中转**；2026-11-14 起 WG mesh hub 亦迁至中转（8.134.215.146:51822），见 skill 2。

## 6-Domestic Relay-Quick Start-Skill

国内中转节点（8.134.215.146，2026-11-14 起）：校园网/受限线路站点的平台通道桥接 + **eSpur WG hub（51822/udp）**。
使用前分别核对两套 WG、TCP 透传和具体节点现状；旧的一键接入、自动切端口和配置覆盖模板不适用于当前拓扑。
