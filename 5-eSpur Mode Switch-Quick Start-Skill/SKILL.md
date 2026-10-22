---
name: espur-mode-switch
description: eSpur 测试/生产双模式切换：PSU 切换闸门（test 闸门落下禁切换 / live 开启真实切换）与上联业务 IP 的配置管理。业务 IP 一律由用户提供，本 skill 只接收参数配置。当用户提到 测试模式、生产模式、模式切换、live、test、切换闸门、SWITCH_DISABLED、业务 IP、机房上联、待接入、现场部署 等任何相关话题时使用本 skill。
---

# eSpur 测试/生产模式切换

## 两种模式（先建立心智模型）

| | 测试模式（test） | 生产模式（live） |
|---|---|---|
| PSU 切换 | **禁止**（闸门落下，set_psu 只打日志） | **开启**（算法按知识库真实切换 PDU 端口） |
| 遥测/上报 | 照常 | 照常 |
| 算法服务 | 常驻运行 | 常驻运行 |
| 适用场景 | PDU 接屏幕/充电器等测试负载；开发调试 | PDU 接**真实服务器 PSU**，正式优化运行 |

实现：算法服务常驻，部署目录下 `SWITCH_DISABLED` 标记文件存在即禁止一切切换
（闸门代码在 src/psu.py 的 set_psu 开头——上游同步该文件后需重打，见 skill 3 同步铁律）。

**2026-10-22 实测事故**：coarse 模式按「PSU 冗余」逻辑会把总负载远小于单 PSU
额定时的多余端口关掉只留 1 个——两台测试负载因此被切断电。故规则 0：测试负载
在 PDU 上时必须保持 test 模式。

## 切换操作（一条命令，即时生效无需重启）

```bash
sudo /usr/local/bin/espur-switch.sh test                      # 测试模式（闸门落下，遥测照常）
sudo /usr/local/bin/espur-switch.sh live                      # 生产模式（仅闸门开启）
sudo /usr/local/bin/espur-switch.sh live 10.123.4.246/22 10.123.7.254
                                # 生产模式 + 一次性配好你提供的上联业务 IP（保底手动命令）
sudo /usr/local/bin/espur-switch.sh                           # 查看当前模式
```

- 脚本在本 skill `scripts/espur-switch.sh`，实机安装于 `/usr/local/bin/`（更新后重拷一次）
- `live` 带 IP 参数：闸门开启 + 上联 USB 口写入你提供的业务 IP 并立即激活
  （首次必须带网关；IP 变更时重跑即更新）
- 远程切换：`ssh -t <用户>@<实机IP> "sudo /usr/local/bin/espur-switch.sh live ..."`

## 机房部署前置加固（2026-10-23 已在实机应用）

- 上联走 USB 转接网口（enx*，交换机直连）：已装 udev 规则 `/etc/udev/rules.d/90-usb-net-nosuspend.rules` 禁用其 USB 自动省电（RTL8152/AX88179 类芯片的 autosuspend 会偶发断连），网卡插入即自动应用，无需手动。
- 无线唤醒类问题（AP 漫游管理/踢站）在机房有线接入下不存在；测试环境的对应缓解（wlan0 关省电）仅适用于测试环境。
- 挂死兜底（硬件看门狗 1min + journal 持久化）在机房同样生效。

## 上联业务 IP（重要：IP 一律由用户提供）

**本 skill 与所有脚本绝不猜测、不自动分配任何 IP。** 上联口（USB 转接网口）的
业务 IP、网关由使用者在部署前提供，脚本/命令只负责把给定值写入配置。

两种环境的上联形态：

| 环境 | 上联口 | 业务 IP 来源 |
|---|---|---|
| 测试（实验室） | wlan0（CMCC 等，DHCP） | 测试网络自动分配 |
| 生产（机房） | USB 转接网口（enx*） | **用户提供**（网络组分配的静态 IP） |

### 生产环境上联配置（预配置为待接入态）

**部署前**（拿到用户提供的业务 IP 后，远程或本地执行一次）：

```bash
sudo ./scripts/config-uplink.sh <接口名> <IP/22> <网关> [DNS]
# 例: sudo ./scripts/config-uplink.sh enx9c8e99abcd12 10.123.4.246/22 10.123.7.254
```

- 配置写入后处于**待接入态**：网线未插不会激活，插上交换机自动启用
- IP 后续变更：改用新值重跑本命令即可（幂等，同 profile 更新）
- **现场免调试**：插 PDU 线（eth0）→ 插上联线（USB 口）→ 上电，三步完成

### 现场验收（能看则看；不能到场靠平台在线状态判断）

```bash
ip -4 addr show <接口名>     # 拿到业务 IP
ip route get 192.168.0.163   # 控制面走 eth0、源 192.168.0.200
ping -c 3 neowatt.cn         # 出网
# 平台：设备翻回在线 + 四口曲线恢复
```

## 与其他 skill 的关系

- PSU 切换能力的本体语义与规则 0（测试负载必须 test 模式）见
  `3-eSpur Deployment-Quick Start-Skill/SKILL.md`；本 skill 是切换的执行入口
- 机房网络事实（网段/网关/ACL 未知项）见
  `3-eSpur Deployment-Quick Start-Skill/references/deployment.md` 的机房部署变体
