# eSpur_v2 实机客户端运维（lab-01 实测版）

v1 部署链（eSpur.zip + MySQL 云端）已被 v2 客户端 + neowatt 平台取代。本文件记录
v2 客户端在实机上的目录布局、启动方式、配置来源和最低版本要求。
2026-10-21 在 lab-01（Raspberry Pi 4B / trixie）上全链路实测。

## 本机目录布局

```
~/eSpur/eSpur-deployment/
├── 192.168.0.163_1-2-3-4/          # 实例目录 = PDU_IP_端口段
│   └── eSpur_v2/                   # v2 客户端（实际运行的一份）
│       ├── config/config.ini       # 算法参数 + 云平台字段
│       ├── scripts/bootstrap_config.py
│       ├── src/                    # 核心代码
│       └── run.py
└── config.ini / pdu_ip_ports-pid.json   # v1 遗留，v2 只参考布局约定
```

多实例沿用 v1 约定：config.ini 的 `instance_id = 1-2` 由 `update_config.py`
分发到各实例目录。

## 启动与配置

```bash
# 配置（首次用平台签发的 dboot token，之后每次启动前可刷新）
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxx --config eSpur_v2/config/config.ini
python3 eSpur_v2/scripts/bootstrap_config.py --refresh --config eSpur_v2/config/config.ini

# 启动算法（real 模式，直连 PDU + 上报 neowatt 平台）
cd eSpur_v2
python3 run.py --entry algorithm --mode real \
  --pdu-ip 192.168.0.163 --community-public public --community-private private \
  --psu-count 4 --psu-power 2000 --duration 0
```

config.ini 云平台字段（bootstrap 自动写，勿手改）：
`instance_id / email / api_key / duckdb_base_url(https://neowatt.cn/espur) /
duckdb_ssl_path(必须空) / duckdb_batch_* / duckdb_timeout`。
其余全是算法参数，v2 与 v1 语义相同。

## 最低代码版本（缺一则对应功能缺失）

| 功能 | 修复 commit | 本机自检 grep |
|---|---|---|
| SNMP 读数不全 0（OID 修复） | `0d932c0` | `grep -c "2.3.{port}.0" src/hal/snmp_pdu.py` ≥1 |
| set_psu 字符串 ON/OFF | 同上 | `grep -c 's {state_str}' src/hal/snmp_pdu.py` ≥1 |
| 单口功率上报 | `3b42ece` | `grep -c "port_powers" src/run_algorithm.py` ≥3 |
| 上报证书回落（无 ssl.crt 也能发） | `248a76d` | config.ini 的 `duckdb_ssl_path` 留空即可 |

## 数据链路（客户端视角）

每次采样（1s）：
1. `get_server_power()` → SNMP 读 PDU（总功率 + 各口电流×电压），
   OID 细节见 troubleshooting.md 的 PDU 段；
2. 总功率 → `espur_instance_real_time_power_time`（实时曲线）；
3. 单口功率 → `espur_port_power_time`（四口分曲线，平台卡片 2×2 小图）；
4. 统计/知识 → 批量缓存后上报（CSV 批量通道）。

全部走 HTTPS 直连 `neowatt.cn`（不走 WireGuard 隧道）；失败进本地缓存队列，
恢复后补传（cleanup-data）。

## 已知坑（本机实测）

- `duckdb_ssl_path` 非空且文件不存在 → 所有上报抛 OSError 且只打 warning，
  实机看起来在跑但一条数据都发不出去（v2 早期最隐蔽的坑，248a76d 修复）；
- PDU 读数恒 0 → 先查代码版本（原因 B，见 troubleshooting.md），不要急着信
  "插座无负载"；
- 平台侧节能率/功率口径都是 ×100 整数存储，前端负责还原——自己写脚本读
  平台 API 时记得除回来；
- 无负载时算法 coarse 模式的 `save_ratio` 会输出 >100% 的无意义初始值，
  平台已按口径还原显示，带载后自然正常。
