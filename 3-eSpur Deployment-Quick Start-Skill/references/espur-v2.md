# eSpur_v2 与云平台运维（历史记录与核对要点）

> 2026-11-15 审阅：本文包含历史主机、旧服务和示例，不能视为当前实机已验证配置。
> 当前网络角色、两套 WG 与实例口组以[全网拓扑](<../../2-Overlay NetWork-Quick Start-Skill/references/topology.md>)及实际只读核对为准。
> 旧 `espur-switch.sh` 的 status/test/live 都会先启动服务，不得执行；PDU 真实切换和重启需单独确认。

## 部署形态

- 位置：`~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/`（run.py + src/ + scripts/ + config/）
- 2026-11-03 起第二台实机 **Studio**（user espur-studio，mesh 10.66.66.102）按同构布局部署，平台 external_id=**2**、账号 studio@espur.local，实时上报中（test 模式）
- 代码上游：私有仓 `Polar-Zhang/eSpur`（v2 全量）；skill 仓 `Polar-Zhang/eSpur-Quick-Start`（本 skill 的发布副本在 `3-eSpur Deployment-Quick Start-Skill/`）
- 进程：`espur-algorithm.service`（systemd，enabled + Restart=always + RestartSec=10），stdout 追加到 `algorithm_stdout.log`
- 防冻结：`espur-alg-watchdog.timer` 每 5 分钟检查日志 mtime，>900s 无输出自动重启服务
- 当前工作区 `SWITCH_DISABLED` 只拦 auto；manual 和 safety 不受检查，部分安全调用却未显式传 safety。标记存在不等于禁止所有真实 SET。现有模式脚本暂不可用，见 skill 5；设备实际版本须单独核对。

## 启动 / 重启（历史示例，不是自动操作步骤）

> `--duration 0` 是无限运行，`--mode real` 可能控制 PDU。以下命令仅记录旧 unit；
> 不在运行服务旁手工启动第二实例，实际启停需明确目标实例和现场影响。

```bash
sudo systemctl restart espur-algorithm
# 服务内部命令等价于：
# cd eSpur_v2 && python3 -u run.py --entry algorithm --mode real \
#   --pdu-ip 192.168.0.163 --community-public public --community-private private \
#   --psu-count 4 --psu-power 2000 --duration 0 --publish-db
```

参数铁律：`--publish-db`（漏了=不上报）、`--duration 0`（0=无限）、`python3 -u`（无缓冲日志）。

## systemd 单元历史样例（2026-11-03 Studio；不可直接照抄）

> 路径、unit、代码及凭据机制须按设备核对；该示例不证明当前远端使用此版本。

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
上述看门狗属于历史记录；是否启用及其对现场的影响须按目标设备核对。

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

历史部署记录曾按备份、文件比对、编译和核对闸门的顺序更新。当前应先确认目标实例、精确版本、差异、可回滚方式和物理影响；不能把重启作为默认动作。旧新加坡 `hub` 已退役，北京自有 `wg0` 不得更改。

铁律：
1. `config/config.ini` 绝不覆盖（含 bootstrap 写入的 api_key；上游模板键集合与部署版一致，若上游加键需手工合并）。
2. 当前工作区已包含实例级 `total_power = sum(port_powers)`；实际设备版本需比较。不要机械重打旧补丁或覆盖现场配置。
3. 实机读取会产生 PDU 负载，先确认站点及所需 OID、串行并限制请求；不要把全树 walk 作为默认验证。
4. 当前工作区 `src/psu.py` 已含闸门，但仅拦 auto，manual/safety 不受其检查；实际安全调用和设备版本需核对。历史“上游无闸门、必须重打”的说明已过期。仅 grep 到标记也不能证明控制安全。


## 平台接入（bootstrap，仅首次/凭证轮换时）

```bash
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx --config config/config.ini
# 预期输出：设备 lab-01 / 实例 1 / 账号 lab-01@espur.local；api_key 轮换写入、duckdb_ssl_path 置空
```

token 一次性（410 = 已消费/过期，找管理员重签）；脚本只写云平台字段，算法参数不碰；config.ini 含 api_key 不得提交/外传。

2026-11-03 旧版 bootstrap 曾遗漏 `instance_id`；当前工作区 `CLOUD_KEYS` 已包含该字段，但远端设备版本未核验。核对每实例的 `instance_id`、端口组和部署目录；不要输出或覆盖真实凭据。

**mine 接口状态语义**（排障利器）：HTTP 401 `Invalid credentials` = api_key 错；HTTP 404 `No instances granted` = key 有效但账号的实例授权被移除——对应平台 UI 的"未激活"。修复 = 管理员重签 token 重新 bootstrap（自动复用账号+重新授权）+ 重启算法；调试期间勿手动改账号授权，会和 bootstrap 打架。

## 验证清单

| 检查 | 命令 | 预期 |
|---|---|---|
| 身份 | 核对当前设备与平台授权关系 | 勿将凭据放入命令行、URL 或日志；当前服务端已兼容请求头，设备须按版本迁移 |
| 上报通道 | 只读检查连接和目标地址 | lab 经国内中转，Studio 侧按台账直连；PID/连接与实际设备配置核对 |
| 采样 | `tail algorithm_stdout.log` | COARSE/Warmup 行，power 非 0（有负载时）；失败告警数 0 |
| 平台曲线 | 管理员看设备卡片 | 实时 + port1-4 小图（数据表 espur_instance_real_time_power_time / espur_port_power_time） |

注：日志 COARSE 行间隔可达数百秒（打印对齐），不代表卡住；判活看 CPU 增量（`awk '{print $14}' /proc/<pid>/stat`）。

## 上报语义（心智模型）

- 实时总功率 + 单口功率（port_powers=power[1]）逐条即发，失败仅中文告警（“发送实时数据失败/出错”“发送单口功率失败/出错”），不缓存不重试 → 进程死亡/断网期间的实时曲线**缺失不补**。
- 历史缓存有容量上限，实际 flush 间隔和批量阈值按设备配置与版本核对。ping 失败路径会进入未见重放消费的队列；重启、异常退出及长时间断连不保证补齐。
- 节能率：第一次 PSU 切换决策前上报恒 0（`decision_count > 0` 判定）；日志 save_ratio 是内部估计值。
- 当前工作区 total_power 为实例口组之和；部分 OID 失败会低估该值，不能把任一正读数当作全口完整证明。
- 当前工作区在 `duckdb_ssl_path` 为空或文件不存在时回退系统 CA 校验，不等于关闭 TLS 校验；按设备版本及证书链核对。


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

## 历史版本核对线索（不是当前验收标准）

以下 commit 和 grep 是当时排障线索，不保证当前行为、安全性或远端部署版本；须结合源码、实际进程与隔离测试核对。

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

- 旧版缺失证书路径可能导致上报异常；当前工作区回退系统 CA，设备版本需核验。
- 当前工作区客户端存储口径：power 以 W ×100 整数上报；`cur_save_ratio` 为比例值 ×10000（等于百分比 ×100）。具体设备和接口版本需核对。
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

上表是 2026-11-12 的进程部署记录。B 与 A 至少需区分口组、`pdu_ports_used`、服务及身份；不能据此假设其他配置、代码和闸门均一致。受供电服务器与运行采集控制程序的主机可能不是同一台。

### 2026-11-12 部署记录（历史线索，不能直接执行）

1. **`scripts/bootstrap_config.py` 必须与仓库最新版一致**（rsync 仓库 `eSpur_v2/scripts/`）。
   旧版缺 instance_id 写入（`73103da`），兑换后静默保持模板值 → **数据错报进别的实例**。
   自检：`grep -c '"instance_id"' scripts/bootstrap_config.py` ≥1。
2. 部署目录根**必须有 `run.py` 与 `SWITCH_DISABLED`**（只拷 src/scripts/config 会服务起不来/误开切换）。
3. bootstrap/refresh 重写后的 config 是**无空格 `=` 格式**（`pdu_ports_used=5-6-7-8`），
   sed 匹配不要带空格：`sed -i 's/^pdu_ports_used=.*/pdu_ports_used=5-6-7-8/'`。
4. systemd 单元**每实例一个**（espur-algorithm / espur-algorithm-b …），必带
   `StartLimitIntervalSec=0`，必带 `ExecStartPre=...bootstrap_config.py --refresh`。
5. 手动指令链路（2026-11-12 起默认）：设备独立线程长轮询 `/mine/wait`（亚秒级到达）；
   读回熔断（连续失败停试 10 分钟）；差量 SET。当前代码仅对逐口 SET 持锁，闸门/安全判断及权威态更新在锁外，不能声称全流程原子。
   `psu.py` 的权威态落盘 `.psu_authority.json`（重启不失忆）。
6. **历史 MTU 钳制**：lab-01 曾针对旧国际路径配置主机路由。当前上报使用国内中转；原 `47.237.111.211/32` 钳制是否仍有作用须按现有路由核对，不应自动套用。
7. **国际路径受限**（校园网/CGNAT：国内通、国际 TCP/UDP 断）→ 平台通道走国内中转，
   见新 skill `6-Domestic Relay-Quick Start-Skill`（机器侧仅 `/etc/hosts` 一行 + WG endpoint）。

### 现状速览（2026-11-12）

- lab-01：该条为 2026-11-12 的中转部署记录；网络恢复不能保证所有丢失采样自动补传，实际行为取决于失败路径与设备版本。
- Studio：A/B 两个算法单元 active，遥测满速；其 PDU（MAC 尾 :80）**控制 OID 只写不可读
  （GET 恒超时）且曾出现"ACK 但继电器不动作"间歇故障**——已上线差量 SET + 读回熔断缓解，
  这是历史记录；恢复出厂或更换 PDU 会影响受供电设备，不能作为自动排障。


## 信息大屏 /dashboard（2026-11-14 上线，测试版）

- 路由：`/espur/dashboard`（主站风格亮色，未替换 /overview）。`references/components/` 是历史参考副本，与主项目当前组件不一致，不能复制覆盖；以目标 release 的 `management-v2/frontend/components/` 和构建产物为准。
- 布局：KPI 六卡 → 三列（左=PUE/节能率仪表盘，中=3D 机房，右=当前状态行+设备动态）→
  30 天趋势全宽 → 运维链接。
- 数据：`GET /api/dashboard`（KPI/机房分组/趋势/PUE/节能率/事件一次带齐，10s 轮询）。
- PUE 口径：全 PDU 总功率 ÷ 服务器口功率合计（直连拓扑 ≈1.0；接入制冷/UPS 后升级为真实 PUE）。
- 机房分组：SITE_ALIAS 映射（equipment 名 → 机房显示名）；正式化为 site 字段后替换。


## 历史查询双路径 + 事故记录（2026-11-14 平台瘫痪事件）

- **历史卡查询双路径**（telemetry 端点 table=history）：
  ≤26h → legacy_power_time 原始表桶聚合（(instance,ts) 索引，秒级）；
  >26h → legacy_power_hourly 小时表（毫秒级）。
  **长区间禁止扫原始表**——2026-11-14 事故：详情页 10s 轮询 × 7d/30d 桶查询在 90 万行
  原始表上全并行扫描（无可用索引增益，范围覆盖 64-100%），73 个 postgres worker 卡死
  D 状态，负载 76，整机僵死（SSH/数据库全超时），用户被迫整机重启。
- **防复发三件套**（均已上线）：① 三表 (instance,timestamp) 索引确认存在 ② 历史查询
  statement_timeout 15s ③ 长区间强制走小时表。systemd 资源天花板（MemoryMax/CPUQuota）
  是部分防护；数据库、内存与磁盘 I/O 仍共享，不能保证整机永不受影响。
- 教训：**任何新数据端点必须先在真实数据量下 EXPLAIN 验证**，再上线轮询路径。

## 日志级别与轮转（2026-11-17 事故固化）

**事故**：`src/utils/utils.py` 根 logger 硬编码 DEBUG → urllib3 把每次 HTTPS 上报的
连接细节（`connectionpool.py _new_conn/_make_request`）全写进 stdout 重定向文件，
lab-01 `algorithm_stdout.log` 膨胀到 **381MB / 287 万行（尾部 99.8% 是 DEBUG）**，
~50MB/天。修复后 1KB/45s、DEBUG 绝迹；COARSE 是 print 不受影响，闸门/手动指令
告警是 WARNING 级照常保留（取证能力不损失）。

- **现行代码**（提交 `2f2468d`）：`logger.setLevel(os.environ.get("ESPUR_LOG_LEVEL", "INFO").upper())`
  ——默认 INFO，排障时可临时 `Environment=ESPUR_LOG_LEVEL=DEBUG` 后重启。
- **部署同步**：lab-01 已热修（`utils.py.bak-20261117` 备份在位）；**Studio / Studio-Backup
  下次部署拉新代码自动带上**，存量日志若大顺手 `: > algorithm_stdout.log`。
- **logrotate 保险**（root 一次安装）：
  ```
  sudo install -m 644 /tmp/espur-logrotate /etc/logrotate.d/espur-algorithm
  ```
  （模板在实机 /tmp/espur-logrotate：daily + size 20M + compress + rotate 7 +
  copytruncate + `su <user> <user>`——没有 `su` 会因日志目录属主报错。）
- **两个 sudo 坑（lab-01 实锤）**：① 全局时间戳 15 分钟——`sudo -n` 通过≠授权在，
  过期即密码门（skill 3 老坑再现）；② NOPASSWD 规则**必须完整路径**调用才匹配：
  `sudo -n /usr/bin/systemctl restart espur-algorithm` ✓，`sudo -n systemctl restart …` ✗，
  且带 `--no-pager` 之类附加参数同样不匹配（status 那条就是这样失效的）。
