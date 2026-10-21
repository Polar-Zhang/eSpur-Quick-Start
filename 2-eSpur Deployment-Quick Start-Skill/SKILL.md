---
name: espur-deploy
description: 在树莓派 (Pi4 / Raspberry Pi OS trixie) 上部署、运行和排查 eSpur PSU 能耗优化测试床。覆盖：eSpur 代码部署（eSpur-deployment 脚本链）、ATEN PDU (192.168.0.163, 网线直连 eth0) 的 SNMP 配置与验证、实例启停（run_eSpur/stat_eSpur/shutdown_eSpur）、云数据库失联处理。当用户提到 eSpur、PDU、SNMP 无响应/超时、run_eSpur、stat_eSpur、pdu_ip_ports-pid.json、PSU 功耗优化、部署 eSpur 实例、GT-eSpur 等任何相关话题时使用本 skill，包括全新部署、重装、故障排查和日常运维。
---

# eSpur 部署与排障

## 系统结构（先建立心智模型）

```
[被测服务器 多PSU] ←电源← [ATEN PDU 192.168.0.163] ←网线直连→ [Pi eth0: 192.168.0.200/24]
                                                                  [Pi wlan0: 测试局域网]
[阿里云 120.76.119.71: MySQL + eSpur-management Web] ←—— Pi 上的实例上报数据
```

- 代码三部分：`eSpur`（主程序）、`eSpur-deployment`（部署编排脚本）、`eSpur-management`（云端 Web，**不装在 Pi 上**）。
- 一个「实例」= 一台被测服务器 = PDU 上一组端口。本机布局：`192.168.0.163_1-2-3-4`（instance_id=1）和 `192.168.0.163_5-6-7-8`（instance_id=2）。
- 蒲公英 VPN 不需要（Pi 在测试局域网内，wlan0 直连）。

## 生死攸关的三个事实

1. **PDU 有管理 ACL：SNMP 只响应源地址在 192.168.0.x 网段的请求。** 源地址不对时症状是「ARP 正常、SNMP/TCP/ICMP 全部无响应」，极易误判为 PDU 挂死。所以 eth0 必须静态配 192.168.0.200/24（netplan 持久化，见 references/deployment.md）。**任何「PDU 不响应」的排查第一步：`ip route get 192.168.0.163`，确认走 eth0 且 src 是 192.168.0.200。**
2. **PDU 网口怕并发扫描**：254 并发的 SNMP 探测曾把它打挂过（重启 PDU 才恢复）。对它的一切探测必须串行、低速、带间隔。
3. **绝不运行 `test_pdu.py`**：它会从 1 到 8 口依次通断电源，会切断插在 PDU 上的设备。验证 PDU 用只读的 `snmpget`/`snmpwalk` 或本 skill 的 `scripts/check_pdu.sh`。

## 代码来源（换新机器时）

skill 自带离线快照 **`assets/eSpur-code-snapshot.zip`**（2026-10-16 版本，含 eSpur.zip 主程序、eSpur-deployment 全部脚本与模板配置、eSpur-management 云端 Web）：

```bash
mkdir -p ~/eSpur && cd ~/eSpur
unzip ~/.zcode/skills/espur-deploy/assets/eSpur-code-snapshot.zip
# 得到 eSpur.zip、eSpur-deployment/、eSpur-management/，eSpur.zip 留作第 4 步部署用
```

上游 GitHub（在线时的备选；**本测试网络实测不可达**，SSH 形式还需先配公钥）：
- eSpur 主程序：`https://github.com/guomingtang/eSpur`（SSH: `git@github.com:guomingtang/eSpur.git`）
- eSpur-deployment：`https://github.com/beerjtu/eSpur-deployment`（SSH: `git@github.com:beerjtu/eSpur-deployment.git`）

## 部署流程（概要）

完整逐步命令（含依赖安装、netplan 文件全文）见 `references/deployment.md`。概要：

1. 装 `snmp`、`python3-pip python3-numpy python3-matplotlib`；pip 装 `colorlog pymysql colorama`（requirements 里钉的 numpy 1.19.5 在 Python 3.13 装不了，用新版实测兼容）。
2. eth0 静态 IP（netplan），验证 `snmpget -v1 -c public 192.168.0.163 .1.3.6.1.2.1.1.1.0` 返回 "switched-pdu"。
3. 改 `eSpur-deployment/config.ini`（`espur_deployment_abs_path`、`pdu_ip`）和 `pdu_ip_ports-pid.json`（实例布局，value 一律 "0"）。
4. 打 `eSpur.zip`（**顶层必须是 `eSpur/` 目录**，排除 .git/.idea/.DS_Store）→ `python3 deploy_eSpur_via_unzip.py` → `python3 update_config.py`。
5. `python3 run_eSpur.py 0` 启动全部；`python3 stat_eSpur.py` 验证。

## v2 客户端（当前实际在跑的形态）

v1 部署链之后，本机现运行 **eSpur_v2 real 模式**（直连 PDU + 上报 neowatt 云平台
`https://neowatt.cn/espur`，不再使用 MySQL 云端）。目录布局、启动命令、config.ini
云平台字段、**最低代码版本表**（SNMP OID 修复 0d932c0 / 单口上报 3b42ece）和已知坑
见 `references/v2-client.md`——排障前先读它，再看 troubleshooting.md。

平台接入（登记设备 / bootstrap token / 数据验收）属于组网 skill：
`3-Overlay NetWork-Quick Start-Skill/references/platform-onboard.md`。
完整链路顺序：本 skill（部署 v2 客户端）→ skill 3（组网 + 平台接入）。

## 日常运维

```bash
cd ~/eSpur/eSpur-deployment
python3 stat_eSpur.py                        # 状态/功率/节能统计
python3 print_log.py 192.168.0.163_1-2-3-4   # 实时日志
python3 shutdown_eSpur.py 0                  # 全部停止
python3 run_eSpur.py 0                       # 全部启动
bash ~/.zcode/skills/espur-deploy/scripts/check_pdu.sh   # PDU 连通性体检（只读）
```

日志在 `eSpur-deployment/log/<实例>/`，数据在 `eSpur-deployment/data/<实例>/`。实例重启后不会自启（原设计如此），需手动 `run_eSpur.py 0`。

## 排障

遇到问题时按 `references/troubleshooting.md` 的表逐条对照。高频问题：PDU 无响应（→ 查路由 src，九成是 ACL/路由问题）、数据库连接失败（云服务器 120.76.119.71 不可达属正常容错，数据暂存内存）、功率读数 0W（PDU 插座无负载，非故障）、sudo 缓存过期（网络配置需要 root 时让用户 `sudo -v`）。

## 本机既成事实（2026-10-16 部署）

- 部署根目录 `~/eSpur/`，手册在 `~/eSpur/eSpur部署完全手册.md`。
- 双实例已运行，端口继电器：1/2/3/5/6/7/8 ON、4 OFF；当前插座无负载（总电流 0A）。
- 云端 MySQL/管理系统在阿里云（root/GreenEdge666；DB 用户 espur/hiespur，库 eSpur_management），部署当天整机不可达。
