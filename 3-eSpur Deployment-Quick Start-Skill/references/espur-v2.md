# eSpur_v2 与云平台运维（本机实例 lab-01）

## 部署形态

- 位置：`~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/`（run.py + src/ + scripts/ + config/）
- 2026-11-03 起第二台实机 **Studio**（user espur-studio，mesh 10.66.66.102）按同构布局部署，平台 external_id=**2**、账号 studio@espur.local，实时上报中（test 模式）
- 代码上游：私有仓 `Polar-Zhang/eSpur`（v2 全量）；skill 仓 `Polar-Zhang/eSpur-Quick-Start`（本 skill 的发布副本在 `3-eSpur Deployment-Quick Start-Skill/`）
- 进程：`espur-algorithm.service`（systemd，enabled + Restart=always + RestartSec=10），stdout 追加到 `algorithm_stdout.log`
- 防冻结：`espur-alg-watchdog.timer` 每 5 分钟检查日志 mtime，>900s 无输出自动重启服务
- 模式切换（闸门方案）：算法服务常驻，`SWITCH_DISABLED` 标记文件控制切换能力，
  **只有 live 开启端口切换**。切换操作与业务 IP 配置统一见 skill 5
  （5-eSpur Mode Switch）；闸门代码在 src/psu.py 的 set_psu 开头（上游同步该文件后需重打）

## 启动 / 重启（唯一正确方式）

```bash
sudo systemctl restart espur-algorithm
# 服务内部命令等价于：
# cd eSpur_v2 && python3 -u run.py --entry algorithm --mode real \
#   --pdu-ip 192.168.0.163 --community-public public --community-private private \
#   --psu-count 4 --psu-power 2000 --duration 0 --publish-db
```

参数铁律：`--publish-db`（漏了=不上报）、`--duration 0`（0=无限）、`python3 -u`（无缓冲日志）。

## systemd 单元全文（新机照抄，2026-11-03 Studio 验证）

`/etc/systemd/system/espur-algorithm.service`（User/WorkingDirectory 按机替换）：

    [Unit]
    Description=eSpur_v2 algorithm (real mode, PDU 192.168.0.163 + neowatt reporting)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    User=espur-studio
    WorkingDirectory=/home/espur-studio/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2
    ExecStartPre=-/usr/bin/python3 -I scripts/bootstrap_config.py --refresh --config config/config.ini
    ExecStart=/bin/sh -c 'exec /usr/bin/python3 -u run.py --entry algorithm --mode real --pdu-ip 192.168.0.163 --community-public public --community-private private --psu-count 4 --psu-power 2000 --duration 0 --publish-db >> algorithm_stdout.log 2>&1'
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target

防冻结看门狗三件套：`/usr/local/bin/espur-alg-watchdog.sh`（服务 active 且日志 mtime >900s
则 restart，`logger -t espur-alg-watchdog` 留痕）+ `espur-alg-watchdog.service`（Type=oneshot，
ExecStart=上述脚本）+ `espur-alg-watchdog.timer`（OnBootSec=10min，OnUnitActiveSec=5min）。
全部 `systemctl enable --now`。

## 代码同步（真源 = wattos 分支；codeload/scp 双通道）

**部署真源是 `Polar-Zhang/eSpur` 的 `wattos` 分支**（2026-10-28 实测：Pi 部署文件与 hub
wattos 工作树逐字节一致；`main` 分支停在旧版、缺模式闸门代码，**绝不能从 main 拉**）。
同步优先 hub 直推（SSH 走 mesh，最简单可靠）：

```bash
# hub → Pi 直接 scp（最常用）：
scp -i ~/.ssh/espur_hub_ed25519 <改动文件> \
  espur-5090@10.66.66.101:~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/src/同路径
# codeload tarball 通道（备用；分支必须是 wattos）：
curl -sL -H "Authorization: Bearer <token>" -o /tmp/eSpur.tgz \
  https://codeload.github.com/Polar-Zhang/eSpur/tar.gz/refs/heads/wattos
```

通道 C（2026-11-03 新增）：codeload 从实验室网络实测极慢（120s 超时），可走 Git Trees API +
raw 逐文件同步——`GET /repos/Polar-Zhang/eSpur/git/trees/wattos?recursive=1` 过滤 `eSpur_v2/`
前缀，再对每个 path 请求 `raw.githubusercontent.com/Polar-Zhang/eSpur/wattos/<path>`
（28 文件 284KB 实测秒级；下载后 `python3 -I -m compileall` 全量编译自检）。

部署铁律：先备份（`cp -p` 带日期后缀）→ md5 双端比对 → Pi 上 `python3 -m py_compile` →
确认 `SWITCH_DISABLED` 等现场标记未动 → 才 `sudo systemctl restart espur-algorithm`；
hub 全程盯 `wg show hub` 确认握手/传输不受影响。

铁律：
1. `config/config.ini` 绝不覆盖（含 bootstrap 写入的 api_key；上游模板键集合与部署版一致，若上游加键需手工合并）。
2. `src/hal/snmp_pdu.py` 覆盖后重打实例级 total_power 语义：`total_power = sum(port_powers)`（文件内有注释标记；上游 0d932c0 的其余修复——OID/缩放/set 字符串化——与本地一致）。
3. 同步后跑一次直读验证：`cd eSpur_v2/src && python3 -c "import sys; sys.path.insert(0,'.'); from hal.snmp_pdu import SNMPPDU; print(SNMPPDU().get_power_data().total_power)"`（有负载应 >0）。
4. `src/psu.py` 覆盖后重打 `SWITCH_DISABLED` 闸门（set_psu 开头，模式切换语义；上游无此代码）。
   **自检必须包含 set 路径**：`grep -c "SWITCH_DISABLED" src/psu.py` ≥1——只查 run_algorithm 的
   `_SWITCH_GATE`（上报口径闸门）**不足以**证明切换被禁（2026-11-03 Studio 实锤：wattos 全新同步
   缺 set 路径闸门，test 模式下 coarse 决策把口 2/3/4 真实关掉、57W 负载断电；run_algorithm 自检
   全过掩盖了问题）。闸门补丁形态：set_psu 开头检查 `Path(__file__).resolve().parents[1]/
   SWITCH_DISABLED` 存在则 warning 后直接 return（本机 src/psu.py 已打，备份 .bak-20261103）。
   建议上游把闸门正式收编进 wattos。

## 平台接入（bootstrap，仅首次/凭证轮换时）

```bash
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx --config config/config.ini
# 预期输出：设备 lab-01 / 实例 1 / 账号 lab-01@espur.local；api_key 轮换写入、duckdb_ssl_path 置空
```

token 一次性（410 = 已消费/过期，找管理员重签）；脚本只写云平台字段，算法参数不碰；config.ini 含 api_key 不得提交/外传。

⚠ **上游 bug（wattos 待修，2026-11-03 Studio 实锤）**：bootstrap_config.py 的 CLOUD_KEYS 白名单漏了 `instance_id`，bootstrap/refresh 都**静默不写**实例号——每次 bootstrap 后必须核对 config.ini 的 instance_id 与平台返回一致（Studio=2 已手工修正）。另外模板的 `espur_deployment_abs_path` 是 macOS 路径（/Users/polar/...），它是数据/日志/matrix 目录的根（constant.py → ensure_deployment_directories），新机必须改成本机部署根。

**mine 接口状态语义**（排障利器）：HTTP 401 `Invalid credentials` = api_key 错；HTTP 404 `No instances granted` = key 有效但账号的实例授权被移除——对应平台 UI 的"未激活"。修复 = 管理员重签 token 重新 bootstrap（自动复用账号+重新授权）+ 重启算法；调试期间勿手动改账号授权，会和 bootstrap 打架。

## 验证清单

| 检查 | 命令 | 预期 |
|---|---|---|
| 凭证 | `curl "https://neowatt.cn/espur/api/device-bootstrap/mine?email=<email>&api_key=<key>"` | 200，lab-01 / [1] / ssl_path 空 |
| 上报通道 | `ss -tnp | grep <MainPID> | grep 47.237.111.211:443` | ESTAB，Send-Q 无堆积 |
| 采样 | `tail algorithm_stdout.log` | COARSE/Warmup 行，power 非 0（有负载时）；失败告警数 0 |
| 平台曲线 | 管理员看设备卡片 | 实时 + port1-4 小图（数据表 espur_instance_real_time_power_time / espur_port_power_time） |

注：日志 COARSE 行间隔可达数百秒（打印对齐），不代表卡住；判活看 CPU 增量（`awk '{print $14}' /proc/<pid>/stat`）。

## 上报语义（心智模型）

- 实时总功率 + 单口功率（port_powers=power[1]）逐条即发，失败仅中文告警（“发送实时数据失败/出错”“发送单口功率失败/出错”），不缓存不重试 → 进程死亡/断网期间的实时曲线**缺失不补**。
- 全量功率表 power_time_cache 每 1200s 批量 flush（≤1000 条/批），进程 close() 时再 flush —— 短暂断网后历史表可补，实时曲线不补。
- 节能率：第一次 PSU 切换决策前上报恒 0（`decision_count > 0` 判定）；日志 save_ratio 是内部估计值。
- total_power 是**实例级**（本实例 4 口之和），非设备级全 PDU 合计 —— 同步 snmp_pdu.py 后必须保留该语义。
- duckdb_ssl_path 必须为空：requests verify=falsy 跳过自签证书校验（平台证书链限制）。


## 目录布局

```
~/eSpur/eSpur-deployment/
├── 192.168.0.163_1-2-3-4/          # 实例目录 = PDU_IP_端口段
│   └── eSpur_v2/                   # v2 客户端（实际运行的一份）
│       ├── config/config.ini       # 算法参数 + 云平台字段
│       ├── scripts/bootstrap_config.py
│       ├── src/
│       └── run.py
└── config.ini / pdu_ip_ports-pid.json   # v1 遗留，v2 只参考布局约定
```

多实例沿用 v1 约定：config.ini 的 `instance_id = 1-2` 由 update_config.py 分发到各实例目录。

## 最低代码版本（缺一则对应功能缺失）

| 功能 | 修复 commit | 本机自检 grep |
|---|---|---|
| SNMP 读数不全 0（OID 修复） | `0d932c0` | `grep -c "2.3.{port}.0" src/hal/snmp_pdu.py` ≥1 |
| set_psu 字符串 ON/OFF | 同上 | `grep -c 's {state_str}' src/hal/snmp_pdu.py` ≥1 |
| 单口功率上报 | `3b42ece` | `grep -c "port_powers" src/run_algorithm.py` ≥3 |
| psu 接口三方法（get_psu_info 等） | `9a27e65` | `grep -c "def get_metrics" src/hal/psu_snmp.py` ≥1 |
| 节能率未优化时报 0 | `dd1dcff` | `grep -c "decision_count > 0" src/run_algorithm.py` ≥1 |
| 实时观测缓冲封顶（树莓派内存） | `9bd948c` | `grep -c "realtime_power_cache_max" src/data/duckdb_client.py` ≥1 |
| 测试模式节能率报 0 | `7d80207` | `grep -c "_SWITCH_GATE" src/run_algorithm.py` ≥3 |
| 节能率 test 模式报 0（闸门联动） | `7d80207` | `grep -c "_SWITCH_GATE" src/run_algorithm.py` ≥3 |
| 上报证书回落 | `248a76d` | config.ini 的 `duckdb_ssl_path` 留空即可 |
| 手动指令长轮询（亚秒级到达） | `fa15aa7` | `grep -c "_manual_poll_loop" src/run_algorithm.py` ≥1 |
| 差量 SET + SET 锁 + 读回熔断 | `0eea17e` | `grep -c "_SET_LOCK" src/psu.py` ≥1 且 `grep -c "_readback_break" src/run_algorithm.py` ≥1 |
| 盲 PDU 防护（读数全 0 禁降载） | `14f844e` | `grep -c "power_trusted" src/psu.py` ≥1 |
| 手动指令防重放（继电器比对） | `14f844e` | `grep -c "防重放" src/run_algorithm.py` ≥1 |
| 缓存封顶 + batch_size 生效 | `14f844e` | `grep -c "power_time_cache_max" src/data/duckdb_client.py` ≥1 |
| bootstrap_config 写 instance_id | `73103da` | `grep -c '"instance_id"' scripts/bootstrap_config.py` ≥1 |
| runner 参数/StartLimit | `14f844e` | `grep -c "StartLimitIntervalSec" agent-v2/systemd/espur-runner@.service` ≥1 |
| 平台 /mine/wait 长轮询端点 | `fa15aa7` | `grep -rc "mine/wait" management-v2/backend/app/routers/device_bootstrap.py` ≥1 |

另有平台侧配套：账号有效期（expires_at，超管可设倒计时；test 模式下设备工牌
lab-01 已设 2026-12-31 到期）、回复邮件通知、社区回复时区/归属修复——均为
平台/管理端改动，与实机客户端同步无关。

## 已知坑与口径

- `duckdb_ssl_path` 非空且文件不存在 → 所有上报抛 OSError 且只打 warning（248a76d 修复的隐蔽坑）。
- 平台存储口径：power 与 cur_save_ratio 均 ×100 整数；平台前端负责还原——自写脚本读平台 API 记得除回来。
- 未优化时节能率上报 0（平台显示 --），见 dd1dcff；日志 save_ratio 是内部估计值，仅供算法内部使用。
- **历史/统计卡 1.3% 假节能率（2026-10-28 已修，wattos `7d170e9`）**：根因不是落表口径
  （实时与批量 flush 同源同门控，库里无非零脏值），而是**最差能耗基线累加**（run_algorithm.py
  两个循环的 `worst_psu_config_energy`）直接消费未门控的内部估计值（活跃 PSU 数 < 满配时被
  `x*1.5+0.01334` 垫到 ≈1.33%），统计卡 save_ratio=(worst−optimal)/worst 因此固化 ~1.3%，
  **重启算法才清零**（累计口径）。修复 = 两个循环的累加与上报口径一致（`decision_count>0 且
  live_mode` 才计入估计值）。自检：`grep -c "decision_count > 0 and live_mode" src/run_algorithm.py`
  ≥2；Pi 侧备份 `src/run_algorithm.py.bak-20261028`。


## 多实例同 PDU 口组模型 + 中转接入（2026-11-12 定案）

### 一台 8 口 PDU 服务两台服务器（口组语义）

**一个实例 = 一台服务器 = 自己的 PDU 口组**。禁止把两台服务器的口混进一个实例
（≥2 保护会被另一台服务器的口凑数，等于没有保护）：

| 部署目录 | 平台实例 | external_id | 口组 | 运行位置 |
|---|---|---|---|---|
| `192.168.0.163_1-2-3-4/eSpur_v2` | Studio_1-2-3-4（平台 id=8） | 2 | 1-4 | Studio 机器（espur-algorithm.service） |
| `192.168.0.163_5-6-7-8/eSpur_v2` | Studio-Backup_5-6-7-8（平台 id=9） | 3 | 5-8 | Studio 机器（espur-algorithm-b.service） |
| `192.168.0.163_1-2-3-4/eSpur_v2` | lab-01（平台 id=5） | 1 | 1-4 | lab 树莓派（espur-algorithm.service） |

新实例部署（B 型）与 A 型的差异只有四处：目录名口组、`pdu_ports_used`、systemd 单元名、
bootstrap token（平台实例须先建、token 24h 有效）。其余（run.py/SWITCH_DISABLED/闸门/护栏）完全一致。

### 部署铁律（2026-11-12 踩坑全集）

1. **`scripts/bootstrap_config.py` 必须与仓库最新版一致**（rsync 仓库 `eSpur_v2/scripts/`）。
   旧版缺 instance_id 写入（`73103da`），兑换后静默保持模板值 → **数据错报进别的实例**。
   自检：`grep -c '"instance_id"' scripts/bootstrap_config.py` ≥1。
2. 部署目录根**必须有 `run.py` 与 `SWITCH_DISABLED`**（只拷 src/scripts/config 会服务起不来/误开切换）。
3. bootstrap/refresh 重写后的 config 是**无空格 `=` 格式**（`pdu_ports_used=5-6-7-8`），
   sed 匹配不要带空格：`sed -i 's/^pdu_ports_used=.*/pdu_ports_used=5-6-7-8/'`。
4. systemd 单元**每实例一个**（espur-algorithm / espur-algorithm-b …），必带
   `StartLimitIntervalSec=0`，必带 `ExecStartPre=...bootstrap_config.py --refresh`。
5. 手动指令链路（2026-11-12 起默认）：设备独立线程长轮询 `/mine/wait`（亚秒级到达）；
   读回熔断（连续失败停试 10 分钟）；差量 SET（只 SET 状态变化的口）；SET 全程持锁。
   `psu.py` 的权威态落盘 `.psu_authority.json`（重启不失忆）。
6. **hub 路由 MTU 钳制**（CGNAT/受限线路上国际 MTU ~1250 时必须）：
   `sudo ip route replace 47.237.111.211/32 dev eth1 mtu 1200`
   （lab-01 已装持久化单元 `espur-mtu-clamp.service`）。
7. **国际路径受限**（校园网/CGNAT：国内通、国际 TCP/UDP 断）→ 平台通道走国内中转，
   见新 skill `6-Domestic Relay-Quick Start-Skill`（机器侧仅 `/etc/hosts` 一行 + WG endpoint）。

### 现状速览（2026-11-12）

- lab-01：新栈 + 中转 hosts 已配；其上行 CGNAT 线间歇断（恢复即自动补传，缓存 2h）。
- Studio：A/B 两个算法单元 active，遥测满速；其 PDU（MAC 尾 :80）**控制 OID 只写不可读
  （GET 恒超时）且曾出现"ACK 但继电器不动作"间歇故障**——已上线差量 SET + 读回熔断缓解，
  复发时用 PDU Web 页验证该口，必要时恢复出厂/换 PDU。
