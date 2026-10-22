# eSpur Quick Start Skills

eSpur 项目的全套部署/运维 skill：从一台全新的树莓派到云平台，按序号即按实施顺序。

## Skill 地图

| # | 目录 | 一句话 | 侧别 |
|---|---|---|---|
| 0 | `0-eSpur Full Stack-Quick Start-Skill` | **总控入口**：判定管理侧/设备侧，路由到下面各 skill | 双侧 |
| 1 | `1-LCD-Quick Start-Skill` | Waveshare 2.4 寸 SPI LCD + fbcp 镜像（可选） | 设备 |
| 2 | `2-Overlay NetWork-Quick Start-Skill` | WireGuard 组网：一键接入、看门狗自愈 | 设备 + 终端 |
| 3 | `3-eSpur Deployment-Quick Start-Skill` | eSpur_v2 客户端部署（PDU SNMP + 平台上报） | 设备 |
| 4 | `4-Management Platform-Quick Start-Skill` | 管理端全栈部署/更新/运维 + 设备接入管理 | 管理端 |
| 5 | `5-eSpur Mode Switch-Quick Start-Skill` | 测试/生产模式切换 + 上联业务 IP 配置 | 设备 |

新设备标准流程：**1（接了屏才做）→ 2 组网 → 3 部署 → 4 平台接入**。
不确定从哪开始：直接用 0 号总控，它会先判定你在管理侧还是设备侧。

## 拓扑

```
[树莓派 lab-01] —SNMP→ [ATEN PDU 192.168.0.163]
      │ wg mesh (10.66.66.101)                ← 远程运维
      │ HTTPS 上报（总功率 + 单口功率）
      ▼
[neowatt.cn 管理端]（阿里云新加坡 = WireGuard hub）
      ▲
[广州终端] —mesh 10.66.66.2— 远程操作实机与平台
```

## 相关仓库

- `Polar-Zhang/eSpur` — 主程序（v2 客户端 + 管理端前后端）
- 设备身份（工牌）、组网 Token 由管理端签发；**任何密钥/Token 不入库**

## 实机现状（2026-10-22）

lab-01（Raspberry Pi 4B / trixie）已完成全链路：LCD → 组网 → v2 部署 → 平台在线，
单口功率曲线实时上报中。
