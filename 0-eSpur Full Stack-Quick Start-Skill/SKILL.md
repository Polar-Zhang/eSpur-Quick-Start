---
name: espur-full-stack
description: eSpur 项目全流程总控入口。先判定当前是管理侧（云服务器/公网 IP/neowatt.cn 平台）还是实机设备侧（树莓派/实验室机器），再路由到对应的分 skill：1-LCD（可选）、2-组网、3-eSpur 部署、4-管理端。当用户提到 eSpur 全流程、新机器初始化、不知道该用哪个 skill、管理侧还是设备侧、整体部署、从头搭建、LCD 要不要配 等任何整体性话题时使用本 skill。用户在调用时说明侧别的，直接按说明路由。
---

# eSpur 全流程总控

一句话：判定你在**管理侧**还是**实机设备侧**，然后把工作路由给对应编号的分 skill。

## 分 skill 地图（均在本仓库，独立可用）

| 序号 | 目录 | 职责 | 适用于 |
|---|---|---|---|
| 1 | `1-LCD-Quick Start-Skill` | Waveshare 2.4 寸 SPI LCD + fbcp（**可选**） | 仅设备侧且实际接了屏 |
| 2 | `2-Overlay NetWork-Quick Start-Skill` | WireGuard 组网接入 + 看门狗 | 设备侧 + 人的终端 |
| 3 | `3-eSpur Deployment-Quick Start-Skill` | eSpur_v2 客户端部署与运维 | 设备侧 |
| 4 | `4-Management Platform-Quick Start-Skill` | 管理端（neowatt.cn）部署/更新/运维 | 管理侧 |
| 5 | `5-eSpur Mode Switch-Quick Start-Skill` | 测试/生产模式切换 + 上联业务 IP 配置（IP 由使用者提供） | 设备侧 |

完整链路（新设备从零到平台出数）：
**1（有屏才做）→ 2 组网（远程优先）→ 3 部署 v2 客户端 → 4 平台接入（管理员生成 Token，实机一条命令）**

## 第一步：判定侧别

**用户已说明侧别时，直接采用，跳过探测。** 未说明时按顺序探测，任一命中即停：

```bash
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
echo "机型: ${MODEL:-未知}"

# 命中 1：树莓派 → 设备侧
echo "$MODEL" | grep -qi "raspberry pi" && SIDE=device

# 命中 2：阿里云元数据可达（本机是 ECS）→ 管理侧
curl -s -m 2 http://100.100.100.200/latest/meta-data/instance-id | grep -q "^i-" && SIDE=mgmt

# 命中 3：neowatt.cn 解析结果在本机网卡上 → 管理侧（平台所在机）
ip -4 addr show 2>/dev/null | grep -q "$(getent hosts neowatt.cn | awk '{print $1}')" && SIDE=mgmt

echo "SIDE=$SIDE"
```

两个特征都不命中且用户未说明时：**列出关键差异问用户**（这台机器有没有公网 IP？
是不是树莓派？要部署的是平台还是客户端？），不要猜。

## 第二步：按侧别路由

### 管理侧（SIDE=mgmt）→ skill 4

直接进入 `4-Management Platform-Quick Start-Skill`：
- 从零复建/迁移 → 其 `references/server-setup.md`
- 日常更新发布 → 其 SKILL.md「更新发布」
- 平台功能操作（登记实机 / Token / 工牌 / 离线告警）→ 其 `references/platform-onboard.md`

### 设备侧（SIDE=device）→ 按以下顺序走分 skill

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

`scripts/join_mesh.sh --enroll <token>`（token 找管理员签发）。完成后设备获得
mesh IP（lab 系列从 10.66.66.101 起），此后所有远程运维走 mesh，不再依赖局域网 IP。

**③ 部署 eSpur_v2（skill 3）**

PDU 网段静态 IP（eth0 192.168.0.200/24）+ 代码同步（codeload 通道）+ systemd 启动。
运维细节、最低代码版本表、排障见其 `references/espur-v2.md` 与 `references/troubleshooting.md`。

**④ 平台接入（skill 4 的设备侧部分）**

管理员在平台设备详情页生成接入 Token（UI）→ 实机
`python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx` →
自动建号授权并开始上报。验收：平台设备卡片在线 + 四口小图出点。

**⑤ 模式切换（进入正式运行前必做）**

PDU 接真实服务器 PSU 后，切生产模式：`espur-switch.sh live`（闸门开启，算法开始
真实优化）；接测试负载调试时保持 test。见 skill 5。

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
