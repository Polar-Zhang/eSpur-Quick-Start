---
name: espur-full-stack
description: eSpur 项目全流程入口。先结合用户说明、主机身份及本机服务区分新加坡平台、北京中转、设备和终端，再路由到相应的 LCD、组网、客户端、管理端、模式或中转 skill；不得以云厂商或域名解析结果单独判定角色。
---

# eSpur 全流程总控

先识别平台主站、中转节点、设备或终端，再按任务选择分 skill。全网现状及两套互不混用的 WireGuard 见[拓扑台账](<../2-Overlay NetWork-Quick Start-Skill/references/topology.md>)；远端状态应单独核对。

## 分 skill 地图（均在本仓库，独立可用）

| 序号 | 目录 | 职责 | 适用于 |
|---|---|---|---|
| 1 | `1-LCD-Quick Start-Skill` | Waveshare 2.4 寸 SPI LCD + fbcp（**可选**） | 仅设备侧且实际接了屏 |
| 2 | `2-Overlay NetWork-Quick Start-Skill` | eSpur WireGuard 组网与排障 | 主站、设备侧 + 人的终端 |
| 3 | `3-eSpur Deployment-Quick Start-Skill` | eSpur_v2 客户端部署与运维 | 设备侧 |
| 4 | `4-Management Platform-Quick Start-Skill` | 管理端（neowatt.cn）部署/更新/运维 | 管理侧 |
| 5 | `5-eSpur Mode Switch-Quick Start-Skill` | 测试/生产模式边界和上联业务 IP | 设备侧 |
| 6 | `6-Domestic Relay-Quick Start-Skill` | 国内中转与双 WireGuard hub | 中转、受限线路设备 |

完整链路（新设备从零到平台出数）：
**1（有屏才做）→ 2 组网（远程优先）→ 3 部署 v2 客户端 → 4 平台接入（管理员生成 Token，实机一条命令）**

## 第一步：确认角色

用户已说明角色时，以用户说明为起点；操作前再核对目标主机、站点和当前服务。区分：

- 新加坡平台主站：运行管理平台服务；是 eSpur mesh 的普通 peer。
- 北京中转：运行透传及两套独立 hub；自有 `wg0` 与 eSpur `espur-wg0` 不可混用。
- 设备侧：采样/控制 PDU 并上报；同一站点可能有多个实例。
- 人的终端：仅按实际授权访问，不等同主站或设备。

只读核对可参考 `hostname`、`ip -br address`、`systemctl list-units --type=service`；
域名解析可能被 hosts 改写，云服务器也可能是中转，因此均不能单独证明角色。主机身份或站点
无法确认时不要猜，也不要写入配置或启动服务。不要用空 DNS 结果进行地址匹配。

## 第二步：按侧别路由

### 平台主站 → skill 4

直接进入 `4-Management Platform-Quick Start-Skill`：
- 从零复建/迁移 → 其 `references/server-setup.md`
- 日常更新发布 → 其 SKILL.md「更新发布」
- 平台功能操作（登记实机 / Token / 工牌 / 离线告警）→ 其 `references/platform-onboard.md`

### 国内中转 → skill 6

先核对当前中转与用户自有 WireGuard 的接口、端口和服务，严禁覆盖另一套网络。

### 设备侧 → 按实际任务选择分 skill

**① LCD（skill 1，可选，未接线直接跳过）**

先探测是否接了屏（三查，任一"是"才值得做 skill 1）：

```bash
ls /dev/spidev* 2>/dev/null                    # SPI 设备存在？
grep -qiE "ili9341|fbcp|spi=" /boot/firmware/config.txt 2>/dev/null && echo "config.txt 已有 LCD 配置"
systemctl is-active fbcp 2>/dev/null           # 已配置过？
```

- 三者全空 **且用户确认没接线** → 跳过 skill 1，直接进 ②。**不要**给未接线的机器
  装屏幕驱动（fbcp 需要真实 framebuffer，装了也是黑屏）。
- 接了屏或用户要做屏 → 按 skill 1 流程（注意它的实测环境表与免密 sudo 前提）。

**② 组网（skill 2）**

旧新加坡 hub 的 enroll 已退役，`join_mesh.sh` 及其旧看门狗不适用于现有北京 hub，
不要执行旧 `--enroll` 或脚本的配置模式。按 skill 2 的现行拓扑核对接口和节点台账；
北京自有 `wg0` 不属于 eSpur，禁止覆盖。

**③ 部署 eSpur_v2（skill 3）**

PDU 网段静态 IP（eth0 192.168.0.200/24）+ 代码同步（codeload 通道）+ systemd 启动。
运维细节、最低代码版本表、排障见其 `references/espur-v2.md` 与 `references/troubleshooting.md`。

**④ 平台接入（skill 4 的设备侧部分）**

管理员在平台设备详情页生成接入 Token（UI）→ 实机
`python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx` →
自动建号授权并开始上报。验收：平台设备卡片在线 + 四口小图出点。

**⑤ 模式与真实控制（仅在用户明确提出且确认现场条件后）**

先按实例、站点和物理端口核对当前实际版本。现有 `espur-switch.sh` 对 status/test/live
均有先启动服务的风险，暂不运行；测试闸门也不阻止所有手动/安全指令。见 skill 5。

## 快速排障路由

| 症状域 | 去处 |
|---|---|
| PDU 无响应 / 功率读数 0 / 实例进程 | skill 3 troubleshooting.md |
| 隧道不通 / handshake 失败 / mesh IP | skill 2 troubleshooting.md |
| 平台 404 / 登录 / 曲线 / 邮件告警 | skill 4 SKILL.md 排障速查 |
| 屏幕花了 / 方向不对 | skill 1 调参速查 |

## 铁律（跨 skill 通用）

1. 实机的 `config/config.ini` 含 api_key，绝不入库/外发；上游同步绝不整体覆盖它。
2. 平台仓库的私钥/Token 永不入库；设备身份（工牌）生命周期跟接入 Token 走。
3. 对 PDU 的一切探测串行、低速；绝不运行 test_pdu.py。
4. 给树莓派断电前先 `sudo shutdown`——直接拔电的 SD 损伤已经坑过一轮。
