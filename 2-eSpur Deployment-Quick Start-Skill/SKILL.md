---
name: espur-deploy
description: 在树莓派 (Pi4 / Raspberry Pi OS trixie) 上部署、运行和排查 eSpur PSU 能耗优化测试床。覆盖：eSpur_v2 实机客户端（real 模式，直连 ATEN PDU 192.168.0.163，上报 neowatt 平台）、v1 部署链（eSpur-deployment 脚本）、PDU 的 SNMP 配置与验证、实例启停（run.py/run_eSpur）、平台数据验收。当用户提到 eSpur、eSpur_v2、PDU、SNMP 无响应/超时、功率读数为 0、run_eSpur、stat_eSpur、pdu_ip_ports-pid.json、PSU 功耗优化、部署 eSpur 实例、GT-eSpur 等任何相关话题时使用本 skill，包括全新部署、重装、故障排查和日常运维。
---

# eSpur 部署与排障

最后验证：2026-10-21（lab-01 全链路：部署 → 组网 → 平台 → 单口曲线）。

## 系统结构（先建立心智模型）

```
[被测服务器 多PSU] ←电源← [ATEN PDU 192.168.0.163] ←网线直连→ [Pi eth0: 192.168.0.200/24]
                                                                [Pi wlan0: 测试局域网/校园网]
[neowatt 平台 https://neowatt.cn/espur（新加坡）] ←—— Pi(eSpur_v2) HTTPS 上报：总功率+单口功率
[WireGuard mesh hub 10.66.66.1] ←—— Pi wg0 出站隧道（人的远程运维，上报不走这里）
```

- 当前运行形态是 **eSpur_v2 real 模式**：一个「实例」= PDU 上一组端口 = 平台一个 external_id。本机布局：`192.168.0.163_1-2-3-4`（平台 external_id=1）。
- v1 链（eSpur 主程序 + MySQL 云端 120.76.119.71）已废弃不再上报，但部署脚本（update_config 的实例布局约定）仍在用。
- 组网与平台接入不属于本 skill：见 `3-Overlay NetWork-Quick Start-Skill`（完整链路：本 skill 部署 → skill 3 组网 → 平台接入）。

## 生死攸关的三个事实

1. **PDU 有管理 ACL：SNMP 只响应源地址在 192.168.0.x 网段的请求。** 源地址不对时症状是「ARP 正常、SNMP/TCP/ICMP 全部无响应」，极易误判为 PDU 挂死。所以 eth0 必须静态配 192.168.0.200/24（netplan 持久化，见 references/deployment.md）。**任何「PDU 不响应」的排查第一步：`ip route get 192.168.0.163`，确认走 eth0 且 src 是 192.168.0.200。**
2. **PDU 网口怕并发扫描**：254 并发的 SNMP 探测曾把它打挂过（重启 PDU 才恢复）。对它的一切探测必须串行、低速、带间隔。
3. **绝不运行 `test_pdu.py`**：它会从 1 到 8 口依次通断电源，会切断插在 PDU 上的设备。验证 PDU 用只读的 `snmpget`/`snmpwalk` 或本 skill 的 `scripts/check_pdu.sh`。

## 代码来源

| 内容 | 来源 | 说明 |
|---|---|---|
| eSpur_v2 客户端（当前运行） | `github.com/Polar-Zhang/eSpur`（`eSpur_v2/` 子目录） | 本网络可达，codeload tarball 同步实测可用；**最低版本见 references/v2-client.md 的版本表** |
| v1 部署脚本（布局约定） | skill 自带 `assets/eSpur-code-snapshot.zip`（2026-10-16） | 含 eSpur-deployment 脚本与模板配置；update_config.py 的多实例分发仍在用 |

上游旧仓库（guomingtang/eSpur、beerjtu/eSpur-deployment）已由 Polar-Zhang/eSpur 收编，不要再用。

## 部署流程

### v2 客户端（主线，当前实际形态）

部署目录约定、启动命令、config.ini 云平台字段、**最低代码版本表**、已知坑
见 `references/v2-client.md`——那是 v2 的权威文档。概要：

1. 同步 `eSpur_v2/` 到实例目录（`~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2`）。
2. 平台 bootstrap token 写配置（`scripts/bootstrap_config.py --token`，见 skill 3 的 platform-onboard.md）。
3. `python3 run.py --entry algorithm --mode real --pdu-ip 192.168.0.163 ... --duration 0` 先零时长冒烟，再长跑。

### v1 链（遗留，仅布局约定仍被引用）

完整逐步命令见 `references/deployment.md`：装依赖 → eth0 静态 IP → 改 config.ini / pdu_ip_ports-pid.json → deploy_eSpur_via_unzip.py → update_config.py → run_eSpur.py。

## 日常运维（v2）

```bash
cd ~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2
python3 run.py --entry algorithm --mode real --pdu-ip 192.168.0.163 \
  --community-public public --community-private private \
  --psu-count 4 --psu-power 2000 --duration 0        # 启动（长跑去掉 duration 限制按需）
python3 scripts/bootstrap_config.py --refresh \
  --config config/config.ini                          # 启动前刷新平台配置（可选，离线安全）
tail -f log/*.log                                     # 实时日志（power= / psu= 每秒一行）
bash ~/.zcode/skills/espur-deploy/scripts/check_pdu.sh   # PDU 连通性体检（只读）
```

数据验收在平台（设备卡片四口小图 + 详情页），排障先读 `references/v2-client.md`，
再按 `references/troubleshooting.md` 对照。sudo 缓存过期（需要 root 时）让用户 `sudo -v`。

## 本机既成事实

- **2026-10-21（当前）**：v2 客户端运行中，平台 external_id=1 在线，单口曲线在线（口 3 实测 62W 屏幕负载）。SNMP OID 修复（`0d932c0`）与单口上报（`3b42ece`）均已在本机代码中。平台：lab-01 / lab-01@espur.local。
- **2026-10-16（v1 部署期，历史）**：双实例布局（1-2-3-4 / 5-6-7-8）；MySQL 云端（120.76.119.71）部署当天即不可达，现已彻底废弃。手册在 `~/eSpur/eSpur部署完全手册.md`。
