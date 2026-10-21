# eSpur_v2 与云平台运维（本机实例 lab-01）

## 部署形态

- 位置：`~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/`（run.py + src/ + scripts/ + config/）
- 代码上游：私有仓 `Polar-Zhang/eSpur`（v2 全量）；skill 仓 `Polar-Zhang/eSpur-Quick-Start`（本 skill 的发布副本在 `3-eSpur Deployment-Quick Start-Skill/`）
- 进程：`espur-algorithm.service`（systemd，enabled + Restart=always + RestartSec=10），stdout 追加到 `algorithm_stdout.log`
- 防冻结：`espur-alg-watchdog.timer` 每 5 分钟检查日志 mtime，>900s 无输出自动重启服务

## 启动 / 重启（唯一正确方式）

```bash
sudo systemctl restart espur-algorithm
# 服务内部命令等价于：
# cd eSpur_v2 && python3 -u run.py --entry algorithm --mode real \
#   --pdu-ip 192.168.0.163 --community-public public --community-private private \
#   --psu-count 4 --psu-power 2000 --duration 0 --publish-db
```

参数铁律：`--publish-db`（漏了=不上报）、`--duration 0`（0=无限）、`python3 -u`（无缓冲日志）。

## 代码同步（codeload tarball 通道）

github.com 主站常不可达；api.github.com + codeload.github.com 可用：

```bash
curl -sL -H "Authorization: Bearer <token>" -o /tmp/eSpur.tgz \
  https://codeload.github.com/Polar-Zhang/eSpur/tar.gz/refs/heads/main
tar xzf /tmp/eSpur.tgz eSpur-main/eSpur_v2/src/run_algorithm.py   # 按需提取
cp <提取文件> ~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/src/同路径
sudo systemctl restart espur-algorithm
```

铁律：
1. `config/config.ini` 绝不覆盖（含 bootstrap 写入的 api_key；上游模板键集合与部署版一致，若上游加键需手工合并）。
2. `src/hal/snmp_pdu.py` 覆盖后重打实例级 total_power 语义：`total_power = sum(port_powers)`（文件内有注释标记；上游 0d932c0 的其余修复——OID/缩放/set 字符串化——与本地一致）。
3. 同步后跑一次直读验证：`cd eSpur_v2/src && python3 -c "import sys; sys.path.insert(0,'.'); from hal.snmp_pdu import SNMPPDU; print(SNMPPDU().get_power_data().total_power)"`（有负载应 >0）。

## 平台接入（bootstrap，仅首次/凭证轮换时）

```bash
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx --config config/config.ini
# 预期输出：设备 lab-01 / 实例 1 / 账号 lab-01@espur.local；api_key 轮换写入、duckdb_ssl_path 置空
```

token 一次性（410 = 已消费/过期，找管理员重签）；脚本只写云平台字段，算法参数不碰；config.ini 含 api_key 不得提交/外传。

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
| 节能率未优化时报 0 | `dd1dcff` | `grep -c "decision_count > 0" src/run_algorithm.py` ≥1 |
| 上报证书回落 | `248a76d` | config.ini 的 `duckdb_ssl_path` 留空即可 |

## 已知坑与口径

- `duckdb_ssl_path` 非空且文件不存在 → 所有上报抛 OSError 且只打 warning（248a76d 修复的隐蔽坑）。
- 平台存储口径：power 与 cur_save_ratio 均 ×100 整数；平台前端负责还原——自写脚本读平台 API 记得除回来。
- 未优化时节能率上报 0（平台显示 --），见 dd1dcff；日志 save_ratio 是内部估计值，仅供算法内部使用。
