> **2026-11-15 审阅说明：** 本文包含 v1 和旧设备历史记录，不等于现网状态。先核对[全网拓扑](<../../2-Overlay NetWork-Quick Start-Skill/references/topology.md>)、站点、实例及设备版本。禁止自动执行 PDU SET、断电重启、整树 SNMP walk 或网络变更；这些操作可能影响真实负载。

# eSpur 问题与解决方法

按症状查表。历史案例全部来自 2026-10-16 的真实部署。

## PDU 相关

### 症状：PDU 完全无响应（SNMP/TCP/ping 全超时）

**第一嫌疑永远是路由/源地址，不是设备坏了。** PDU 有管理 ACL，只响应源地址 192.168.0.x 的请求。

```bash
ip route get 192.168.0.163
```

- 显示走上联口仅说明当前路由与该历史站点预期不同；先核对目标站点、实际接口及源地址。`netplan apply` 会改变联网状态，不应作为自动修复。
- 显示 `dev eth0 src 192.168.1.17`（或其它非 192.168.0.x）→ 源地址不对，ACL 丢包。修：eth0 必须有 192.168.0.200/24。
- 显示 `dev eth0 src 192.168.0.200` 还不通 → 下一嫌疑才是设备真挂了。

**常见误报来源**：从测试局域网里**其它机器**（192.168.1.x）去 ping/snmpwalk 这台 PDU，必然全部超时（源地址被 ACL 丢弃）——这不是故障。只有在树莓派本机、源地址正确的前提下探测，结果才有意义。

判别 ACL 丢包 vs 设备挂死：ARP 层始终正常（`ip neigh | grep 163` 有 lladdr 00:14:97:xx）。两者表现相同；先修路由源地址（零成本），修完还不通再考虑断电重启 PDU。

### 症状：PDU 真的挂了（串行低速探测也全无响应）

历史上曾因并发 SNMP 扫描导致 PDU 无响应。PDU 断电重启会影响所有受供电设备，不能作为自动排障；必须先确定站点、负载和恢复条件。

预防：对 PDU 一律串行、带间隔探测；永远不要并发扫描它所在网段。绝不全网段扫描它的 /24。

### 症状：上电自检时某口没有继电器吸合声、灯不亮，只有蜂鸣器响

可能是上电默认状态，也可能是其他问题；不能仅凭指示灯判断。历史曾建议对该口 SET
及断电重启，此类操作会影响负载，不能自动执行，须先核实站点、接线和物理风险。

### 症状：功率读数 0.0 W

两个原因，先分清再动手（2026-10-21 曾因只想到第一个原因，排查绕了数小时）：

**原因 A：负载或读数为零。** 通讯失败、部分 OID 失败和真实无负载均可能表现为 0；不能单凭零值断定无负载。先核对站点与状态，再选择有界、低频的精确 OID 只读查询。

**原因 B：v2 客户端代码是旧版，OID 错误导致恒读 0（插了负载也是 0）。** 上游 commit `0d932c0`（2026-10-21）之前，`src/hal/snmp_pdu.py` 读的 `.23273.1.5 / .1.11.N` 分支在本机 PDU 上不存在（真实数据在 `.2.x`），且解析失败静默填 0——`get_power_data` 永远返回全 0，曾被误当"插座无负载"。判别：

```bash
grep -c "2.3.{port}.0" <运行目录>/eSpur_v2/src/hal/snmp_pdu.py   # ≥1 = 已修复；0 = 旧版
# 手动交叉验证（读到的总电流应与负载吻合）：
snmpget -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273.2.2.2.0 .1.3.6.1.4.1.23273.2.2.4.0
```

旧版必须升级（见 SKILL.md 的 v2 客户端最低版本表）。同时注意：同批修复还包括 `set_psu_state` 的值类型——控制 OID 只接受字符串 `s ON/OFF`，旧版发 Integer 会被静默拒绝（安全机制切 PSU 时才暴露）。

**教训**：功率结果须与站点和读数完整性核对；不要默认运行整树 `snmpwalk`。

### 症状：想知道某端口继电器状态

控制 OID 对某些 PDU 可能只写不可读；有界只读查询也需先确认站点和负载。`snmpset` 是直接切电源，不应作为常规检查，eSpur 的软件约束不会保护绕过软件的直接写入。

## 实例/进程相关

### 症状：run_eSpur.py 提示「实例已经在运行」

`pdu_ip_ports-pid.json` 里 value 非 0。先 `python3 stat_eSpur.py`（它会自动把已死进程的 pid 归零）或 `ps -ef | grep main.py` 确认；真没在跑就手动把 json 里对应 value 改 "0"。

### 症状：实例反复退出 / 收到 QQ 崩溃邮件

看 `log/<实例>/` 最新日志的 traceback。高频原因：
- PDU 不可达（见上，先修路由源地址）——get_server_power 对空结果做下标会抛 IndexError。
- 云 DB 问题不会导致退出（有容错），只会刷「数据库连接失败」ERROR。

### 症状：日志刷「数据库连接失败, 保存数据到需要发送的list:N」

这是历史 v1 提示，但当前工作区 v2 也包含同名待发队列：ping 失败时数据可能进入限长队列且未见重放消费路径，不能保证恢复后补齐。请按设备实际版本和上报失败路径调查。

### 症状：stat_eSpur.py 报错（找不到 energy.txt / get_latest_file）

实例刚启动还没过初始采样窗口（约 96 次采样 × 1.5~2s），等 3 分钟再跑。

### 症状：树莓派重启后 eSpur 没有运行

原设计不自启。手动：`cd ~/eSpur/eSpur-deployment && python3 run_eSpur.py 0`。重启后还应确认 eth0 静态 IP 回来了（netplan 已持久化，正常会自动）。

## 部署期相关

### 症状：pip 装 numpy==1.19.5 失败

Python 3.13 上老版本无法编译。用系统包 python3-numpy + pip 新版 colorlog/pymysql/colorama，实测兼容。

### 症状：deploy_eSpur_via_unzip.py 报「部署eSpur不成功」或 run 时找不到 Management_node

eSpur.zip 顶层不是 `eSpur/` 目录（比如解压出来是 eSpur-main/）。重新打包：`cd ~/eSpur && zip -r -q eSpur-deployment/eSpur.zip eSpur -x 'eSpur/.git/*' 'eSpur/.idea/*' 'eSpur/.DS_Store'`，删除实例目录后重跑。

### 症状：PDU Web 界面(http://192.168.0.163)打不开/超时

Web 和 SNMP 是两个独立进程，SNMP 正常而 Web 无响应 = Web 守护进程挂了（多抓几个页面就会触发），只有断电重启 PDU 才能恢复。登录：admin/admin（默认口令，GET 形式 `/login?a=admin&b=admin&` 返回 OK）。日常运维不需要 Web，全部走 SNMP 即可。

### 症状：sudo 需要密码 / 部署脚本改网络失败

网络配置（netplan/ip）需要 root。sudo 免密缓存约 15 分钟过期。让用户在自己终端跑一次 `sudo -v` 再继续，或请用户直接执行那条 sudo 命令。

### 症状：update_config.py 后实例配置不对

它按 json 的 key 顺序逐实例写 config，且 `instance_id`、`single_psu_max_power` 的 `-` 分隔列表**顺序必须与 json 的 key 顺序一致**。改完两边重跑 update_config.py。

---

# eSpur_v2 / 云平台运维相关（2026-10-22 增补）

### 症状：进程在跑但平台没有新数据

第一嫌疑：启动命令漏了 `--publish-db`（默认 False，数据只进本地缓冲，日志尾部有 "buffered ..." 统计）。第二嫌疑：config.ini 的 email/api_key 被平台轮换（管理员 regenerate 使旧 key 失效），重新 bootstrap 修正；不要在 URL、命令行或日志中暴露凭据；当前管理端支持请求头，设备端是否已迁移须单独核对。

### 症状：算法进程活着但日志长时间无输出、采样停止（冻结）

实锤场景：实时上报的同步 POST 在平台偶发挂起时冻结主循环，requests timeout 未兜底（`/proc/<pid>/task/*/syscall` 持续 73=ppoll、ESTAB Send-Q 有残留、CPU 不再增长）。兜底：`espur-alg-watchdog.timer` 每 5 分钟检查日志 mtime，>900s 无输出自动重启服务。手动恢复 `sudo systemctl restart espur-algorithm`。根治（上报改后台线程）待上游采纳。

### 症状：从上游同步代码后功率读数归零（或 total 口径不对）

读数全 0 可能来自 OID、网络或 PDU；不能直接归因旧代码。当前工作区已有实例口组求和，设备实际版本须核对；部分口读取失败仍可能低估功率。不要机械重打旧补丁或自动重启。

### 症状：节能率一直显示 -- / 0

设计行为：`cur_save_ratio if decision_count > 0 else 0.0` —— 第一次 PSU 配置切换决策前上报恒 0（run_algorithm.py coarse 主循环）。日志里的 `save_ratio=0.0133` 是内部估计值，与上报值无关，勿混淆。

### 症状：树莓派关机/重启后平台曲线有空洞

关机期间进程不产生数据；实时/单口失败不保证补传。历史缓存与刷写间隔依具体设备版本配置而定，ping 失败分支也不能保证重放；不要承诺断点无损恢复。

### 症状：平台 API 各种 401

区分凭证：上报用 email+api_key（仅数据通道）；`/managed-instances/<id>/port-power` 等管理端点要管理员 JWT（api_key 会报 "invalid token format"）；`execute-sql` 只写不读（SELECT 报 "Unsupported legacy SQL"）。实机侧无法代看平台数据，验收找管理员或用 /mine 验凭证。

### 症状：整机对所有通路同时下线（局域网 SSH + wg + 平台全断），现场强制重启才恢复

2026-10-22 17:00 实际发生（前次稳定运行 13.5 小时）。取证边界与结论：算法日志（落盘）无任何失败告警、17:11:31 批量 flush 后再无活动 —— **整机软挂死**（挂死来得太快，进程连"发现网络失败"的机会都没有），根因因 journal 未持久化而不可考；内存/OOM 已排除（3.7G + 2G zram，余量充足）。

**已加固（2026-10-22）：**
- journal 持久化：`/etc/systemd/journald.conf` → `Storage=persistent`，日志落 `/var/log/journal`，重启后可查上次死因（`journalctl -b -1 -n 200`）
- 硬件看门狗：`/etc/systemd/system.conf` → `RuntimeWatchdogSec=1min`（systemd 喂 `/dev/watchdog`/bcm2835_wdt，整机 hang 1 分钟自动重启，无需现场断电）；重装备后需重新设置
- 2026-10-28 13:24 机房部署日掉线（实测，与上条整机挂死无关）：**机房禁公网 DNS → 上报 HTTPS 解析 neowatt.cn 失败 → 平台判离线**。症状区分：设备端 `ping IP` 通而 `ping 域名` 报 name resolution = 纯 DNS 问题（不是掉线）；修复 = hosts 兜底（`47.237.111.211 neowatt.cn` 写入 /etc/hosts 后重启算法）或数据中心放行内网 DNS。完整机房出站策略见 deployment.md 机房部署变体

遇同类问题：恢复后先 `journalctl -b -1 -n 200` 与 `ls /sys/fs/pstore/` 找死因，再查 `systemctl show -p RuntimeWatchdogUSec`（应非 0）确认看门狗在岗。
