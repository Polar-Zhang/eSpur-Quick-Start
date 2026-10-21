# eSpur 问题与解决方法

按症状查表。历史案例全部来自 2026-10-16 的真实部署。

## PDU 相关

### 症状：PDU 完全无响应（SNMP/TCP/ping 全超时）

**第一嫌疑永远是路由/源地址，不是设备坏了。** PDU 有管理 ACL，只响应源地址 192.168.0.x 的请求。

```bash
ip route get 192.168.0.163
```

- 显示 `via 192.168.1.1 dev wlan0` → 路由丢了（如 PDU 断电重启导致 eth0 链路抖动后被清掉）。修：确认 eth0 的 netplan 静态 IP 还在（`ip -4 addr show eth0`），不在则 `sudo netplan apply`。
- 显示 `dev eth0 src 192.168.1.17`（或其它非 192.168.0.x）→ 源地址不对，ACL 丢包。修：eth0 必须有 192.168.0.200/24。
- 显示 `dev eth0 src 192.168.0.200` 还不通 → 下一嫌疑才是设备真挂了。

**常见误报来源**：从测试局域网里**其它机器**（192.168.1.x）去 ping/snmpwalk 这台 PDU，必然全部超时（源地址被 ACL 丢弃）——这不是故障。只有在树莓派本机、源地址正确的前提下探测，结果才有意义。

判别 ACL 丢包 vs 设备挂死：ARP 层始终正常（`ip neigh | grep 163` 有 lladdr 00:14:97:xx）。两者表现相同；先修路由源地址（零成本），修完还不通再考虑断电重启 PDU。

### 症状：PDU 真的挂了（串行低速探测也全无响应）

曾因 254 并发 SNMP 扫描打挂（ARP 活着、其它全死，等待 15 分钟不自愈）。解决：**给 PDU 断电重启**（注意其插座上的设备会断电，需用户确认）。恢复后 SNMP 正常。

预防：对 PDU 一律串行、带间隔探测；永远不要并发扫描它所在网段。绝不全网段扫描它的 /24。

### 症状：上电自检时某口没有继电器吸合声、灯不亮，只有蜂鸣器响

大概率该口只是**上电默认 OFF**（自检时继电器只吸合要打开的口；蜂鸣器是正常自检音）。判别三步：
1. `snmpget ... .23273.2.4.<N>.0` 读状态，OFF 即符合此解释。
2. 用 snmpset 翻转 ON/OFF 验证继电器指令通路（零负载时安全）。
3. 看每口累计电能 `.23273.2.5.<N>.0`：非零说明该口历史上物理送过电（继电器没坏）；数值明显小于其它口 = 该口长期处于关闭状态（如 4 号口 3545 vs 其它口 30 万+）。

终极验证：把该口 snmpset ON 后给 PDU 断电重启 —— 若自检时它吸合了，说明 PDU 是「恢复断电前状态」模式；若仍不吸合，则是固定的上电默认 OFF 配置。

### 症状：功率读数 0.0 W

两个原因，先分清再动手（2026-10-21 曾因只想到第一个原因，排查绕了数小时）：

**原因 A：真没负载。** 判别：`snmpwalk -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273` 看 `23273.2.2.2.0`（总电流，0.01A）——为 0 就是真的没负载。电压 `23273.2.2.1.0` 应约 230。

**原因 B：v2 客户端代码是旧版，OID 错误导致恒读 0（插了负载也是 0）。** 上游 commit `0d932c0`（2026-10-21）之前，`src/hal/snmp_pdu.py` 读的 `.23273.1.5 / .1.11.N` 分支在本机 PDU 上不存在（真实数据在 `.2.x`），且解析失败静默填 0——`get_power_data` 永远返回全 0，曾被误当"插座无负载"。判别：

```bash
grep -c "2.3.{port}.0" <运行目录>/eSpur_v2/src/hal/snmp_pdu.py   # ≥1 = 已修复；0 = 旧版
# 手动交叉验证（读到的总电流应与负载吻合）：
snmpget -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273.2.2.2.0 .1.3.6.1.4.1.23273.2.2.4.0
```

旧版必须升级（见 SKILL.md 的 v2 客户端最低版本表）。同时注意：同批修复还包括 `set_psu_state` 的值类型——控制 OID 只接受字符串 `s ON/OFF`，旧版发 Integer 会被静默拒绝（安全机制切 PSU 时才暴露）。

**教训**：上机第一件事就做一次手动 snmpwalk 对数（总电流/总功率与负载 eyeball 对得上），再信客户端读数。

### 症状：想知道某端口继电器状态

`snmpget -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273.2.4.<N>.0` → "ON " / "OFF"。写入用 snmpset -c private 同 OID（**谨慎**：这是直接切电源，eSpur 的安全机制只在它自己的 set_psu 里）。

## 实例/进程相关

### 症状：run_eSpur.py 提示「实例已经在运行」

`pdu_ip_ports-pid.json` 里 value 非 0。先 `python3 stat_eSpur.py`（它会自动把已死进程的 pid 归零）或 `ps -ef | grep main.py` 确认；真没在跑就手动把 json 里对应 value 改 "0"。

### 症状：实例反复退出 / 收到 QQ 崩溃邮件

看 `log/<实例>/` 最新日志的 traceback。高频原因：
- PDU 不可达（见上，先修路由源地址）——get_server_power 对空结果做下标会抛 IndexError。
- 云 DB 问题不会导致退出（有容错），只会刷「数据库连接失败」ERROR。

### 症状：日志刷「数据库连接失败, 保存数据到需要发送的list:N」

阿里云 120.76.119.71 不可达（整机 SSH/ICMP 都不通=服务器没开）。**这是设计内容错，不处理**：数据排队暂存，服务器恢复后自动补传。N 持续增大属预期。若云服务器长期不开且介意内存，可停实例。

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
