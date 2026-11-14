---
name: espur-deploy
description: 在树莓派 (Pi4 / Raspberry Pi OS trixie) 上部署、运行和排查 eSpur PSU 能耗优化测试床。覆盖：eSpur_v2 实机客户端（real 模式，直连 ATEN PDU 192.168.0.163，上报 neowatt 平台）、v1 部署链（eSpur-deployment 脚本）、PDU 的 SNMP 配置与验证、实例启停（run.py/run_eSpur）、平台数据验收。当用户提到 eSpur、eSpur_v2、PDU、SNMP 无响应/超时、功率读数为 0、run_eSpur、stat_eSpur、pdu_ip_ports-pid.json、PSU 功耗优化、部署 eSpur 实例、GT-eSpur 等任何相关话题时使用本 skill，包括全新部署、重装、故障排查和日常运维。
---

# eSpur 部署与排障

设备部署记录包含 2026-10 至 11 月的历史快照，并非实时实机状态。现网角色、实例与两套组网见[拓扑台账](<../2-Overlay NetWork-Quick Start-Skill/references/topology.md>)。实机代码、服务和闸门须逐台只读核对；不要因为文档声称已验证就假定当前一致。

## 系统结构（先建立心智模型）

```
[被测服务器 多PSU] ←电源← [ATEN PDU 192.168.0.163] ←网线直连→ [Pi eth0: 192.168.0.200/24]
                                                                [Pi wlan0: 测试局域网/校园网]
[neowatt 平台 https://neowatt.cn/espur（新加坡）] ←—— Pi(eSpur_v2) HTTPS 上报：总功率+单口功率
[WireGuard mesh hub 10.66.66.1] ←—— Pi wg0 出站隧道（人的远程运维，上报不走这里）
```

- 设备侧记录使用 **eSpur_v2 real 模式**：一个实例对应一台受供电服务器及其 PDU 口组和 external_id。lab 为 1，Studio A/B 为 2/3；两站 PDU 地址相同，不可仅凭 IP 判定站点。
- v1 链（eSpur 主程序 + MySQL 云端 120.76.119.71）已废弃不再上报，但部署脚本（update_config 的实例布局约定）仍在用。
- 组网与平台接入不属于本 skill：见 `2-Overlay NetWork-Quick Start-Skill`（完整链路：skill 2 组网 → 本 skill 部署 → skill 4 平台）。

## 生死攸关的事实（八条）

0. **测试闸门不是物理断电保护。** 当前仓库 `src/psu.py` 的 `SWITCH_DISABLED` 只阻止 `purpose=auto`，显式 `manual`/`safety` 不受该检查；实际安全补开调用是否传了正确 purpose 需按设备版本核对。手动指令仍可能产生真实 SET，不能声称测试模式禁止一切切换。现有 `espur-switch.sh` 连状态查询都会先启动服务、test 后落闸且只默认指向 1–4 口，**暂不要用于 status/test/live**；见 skill 5。不得把 live 或实际开关当作例行验收。

1. **PDU ACL 和路由按站点核对。** 某历史设备只响应 `192.168.0.x` 源地址；不能把历史 eth0/源地址直接套到其他机器。先确认站点、目标 PDU、实际路由及源地址，同地址的不同 PDU 不可混淆。
2. **PDU 网口怕并发扫描**：254 并发的 SNMP 探测曾把它打挂过（重启 PDU 才恢复）。对它的一切探测必须串行、低速、带间隔。
3. **绝不运行 `test_pdu.py`**：它会从 1 到 8 口依次通断电源，会切断插在 PDU 上的设备。现有 `scripts/check_pdu.sh` 使用整树 walk，不应自动运行；即使只读查询也可能拖慢 PDU。确认站点和设备后，只采用有界、串行、低频且经批准的精确读取。
4. **v2 启动命令必须带 `--publish-db`（默认 False 不上报！）和 `--duration 0`（0=无限）**，且用 `python3 -u`（无缓冲，否则 stdout 块缓冲导致日志不可见）。
5. 设备实例各有独立 systemd 单元；先只读核对其 `WorkingDirectory`、`ExecStart`、配置和状态，不要手工重复启动。是否重启须考虑实例、数据缓存和真实 PDU；看门狗及运行配置应按实机核实。
6. **多实例总功率须按本实例口组核对**。当前工作区读取实现已包含端口求和；实际设备版本未经本次核实。同步前对比精确版本，勿机械重打旧补丁或覆盖现场配置。
7. **bootstrap 后核对 instance_id、PDU 端口组及部署目录**。2026-11-03 旧版遗漏 instance_id 的问题是历史记录；当前工作区 `CLOUD_KEYS` 已包含该字段，不等于远端设备已更新。配置和旧模板可能包含凭据，勿打印或外传。

## 代码来源

| 内容 | 来源 | 说明 |
|---|---|---|
| eSpur_v2 客户端（当前运行） | `github.com/Polar-Zhang/eSpur`（`eSpur_v2/` 子目录） | 本网络可达，codeload tarball 同步实测可用；**最低版本见 references/espur-v2.md 的版本表** |
| v1 部署脚本（布局约定） | skill 自带 `assets/eSpur-code-snapshot.zip`（2026-10-16） | 含 eSpur-deployment 脚本与模板配置；update_config.py 的多实例分发仍在用 |

上游旧仓库（guomingtang/eSpur、beerjtu/eSpur-deployment）已由 Polar-Zhang/eSpur 收编，不要再用。

## 部署流程

### v2 客户端（主线，当前实际形态）

部署目录约定、启动命令、config.ini 云平台字段、**最低代码版本表**、已知坑
见 `references/espur-v2.md`——那是 v2 的权威文档。概要：

1. 同步 `eSpur_v2/` 到实例目录（`~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2`）。
2. 平台 bootstrap token 写配置（`scripts/bootstrap_config.py --token`，见 skill 4 的 platform-onboard.md）。
3. `--duration 0` 是**无限运行**，不是零时长冒烟；`--mode real` 可能触发真实硬件操作。需要启动或验证时先明确目标实例、闸门和受供电负载，不在运行的服务旁手工启动第二进程。

### v1 链（遗留，仅布局约定仍被引用）

完整逐步命令见 `references/deployment.md`：装依赖 → eth0 静态 IP → 改 config.ini / pdu_ip_ports-pid.json → deploy_eSpur_via_unzip.py → update_config.py → run_eSpur.py。

## 日常运维（v2，systemd 托管）

先只读检查目标实例实际的 unit、工作目录、进程和日志。Studio A 与 B 的记录分别使用
`espur-algorithm`、`espur-algorithm-b`，具体设备部署位置以实机核对为准。重启会中断上报，
也可能影响物理供电，不能作为默认诊断步骤。旧 `check_pdu.sh` 会执行整树 SNMP walk，
不要自动运行；需验证时先确定站点、目标与负载，再选择受限读取方法。

**模式切换**见 skill 5：现有 `espur-switch.sh` 不能安全用于状态、test 或 live。

## 历史现场记录（不是当前状态证明）

- **2026-10-22（历史）**：算法改由 systemd 托管（`espur-algorithm.service` enabled + `espur-alg-watchdog.timer` 防冻结，冻结场景实锤过一次：平台偶发挂起时同步 POST 冻结主循环）。整机重启测试通过：网络/systemd 自启/上报全自动恢复，~1.5 分钟内可达。节能率上报在首次 PSU 切换前恒 0（`decision_count > 0` 判定）；Pi 关机期间数据不产生、实时曲线缺失不补。
- **2026-10-21**：v2 客户端运行中，平台 external_id=1 在线，单口曲线在线（口 3 实测 62W 屏幕负载）。SNMP OID 修复（`0d932c0`）与单口上报（`3b42ece`）均已在本机代码中。平台：lab-01 / lab-01@espur.local。
- **2026-10-16（v1 部署期，历史）**：双实例布局（1-2-3-4 / 5-6-7-8）；MySQL 云端（120.76.119.71）部署当天即不可达，现已彻底废弃。手册在 `~/eSpur/eSpur部署完全手册.md`。


## 2026-11-12 现状更新（先读这节再用旧文）

- 实例现状：external_id **1 = lab-01**（树莓派，实验站）、**2 = Studio A**（口组 1-4）、
  **3 = Studio-Backup**（口组 5-8，同 PDU 第二台服务器）。同 PDU 口组模型/部署铁律/
  手动指令新链路/中转接入 → 全部见 `references/espur-v2.md` 末节（2026-11-12 定案）。
- 最低代码版本表已扩充（长轮询/差量 SET/盲 PDU 防护/防重放/缓存封顶/bootstrap instance_id）。
- 本 skill 正文中的 external_id=1、单实例假设等描述按上表对齐后再执行。
