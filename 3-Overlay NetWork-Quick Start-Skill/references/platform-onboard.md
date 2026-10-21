# eSpur 实机接入平台（配置中心模式，方案 B）

实机接入管理平台（https://neowatt.cn/espur）上报数据。前提：组网已通（见 `3-Overlay NetWork-Quick Start-Skill`）、eSpur 已部署。

**实机侧只有一条命令**（token 由平台生成）：

```bash
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxxx
```

配置（instance_id/email/api_key）自动写入 `config.ini`，之后启动算法即可上报。

## 数据链路（心智模型）

```
[树莓派 eSpur_v2 算法] --HTTPS 443--> [nginx neowatt.cn/espur] --> [backend:8000]
        |                                     |                        |
     config.ini                          管理页(3000)            PostgreSQL(设备/实例/授权/数据)
  （bootstrap_config.py 从平台拉取写入）
```

- 上报是纯 push（HTTPS 出站），平台不会反向连实机。
- 组网隧道（10.66.66.x）只承载人的远程操作（SSH/PDU Web），上报流量不进隧道。
- 客户端 `constant.py` 在 import 时一次性读 `config.ini`——所以配置同步做在"启动前"（bootstrap/refresh 写文件），算法本体不联网取配置，平台失联不影响算法运行。

## 平台侧操作（管理员）

1. **登记设备**：实例页 → 「登记实机」→ 填设备名（lab-01）、版本、位置、IP（填 mesh IP `10.66.66.101`）。实例名自动按 `PDU IP_端口段` 约定生成。
2. **创建实例**：登记弹窗已自动创建（每台设备一个实例），`external_id` 即实机的 instance_id。
3. **签发 bootstrap token**（一次性、24 小时有效）——**UI（推荐）**：设备详情页 → 「实机接入」→ 可选填上报邮箱 → 「生成接入 Token」→ 复制页面给出的实机命令。API 备选：

   ```bash
   curl -s -X POST https://neowatt.cn/espur/api/device-bootstrap/tokens \
     -H "Authorization: Bearer <admin_token>" -H 'Content-Type: application/json' \
     -d '{"equipment_id": <设备id>, "email": "lab-01@espur.local"}'
   ```

   返回 `dboot-...`。email 对应的上报账号**自动创建**（member 角色，随机密码，只用 api_key）；已存在则复用并轮换 api_key（旧 key 立即失效）。

## 单口功率与曲线（2026-10-21 起）

客户端每次采样附带 PDU 单口功率，平台按口出曲线（设备卡片 2×2 小图 + 详情页分图）。

- **客户端最低版本**：`3b42ece`（实时循环带单口上报）+ `0d932c0`（SNMP OID 修复，
  之前读数恒 0）。自检：`grep -c port_powers src/run_algorithm.py` ≥3、
  `grep -c "2.3.{port}.0" src/hal/snmp_pdu.py` ≥1。
- 该 PDU（ATEN switched-pdu）没有单口瞬时功率 OID，单口功率 = 口电流 × 电压；
  总功率用设备级计量。口径：API 返回的 power 单位是 W（后端已还原）。
- 验收：平台设备卡片出现 4 条曲线即数据在进；四口之和 ≈ 总功率。

## 实机侧操作（树莓派）

```bash
# 首次接入（唯一需要的一次）
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxxx

# 之后每次启动算法前（可配 systemd ExecStartPre；平台不可达时自动沿用本地配置）
python3 eSpur_v2/scripts/bootstrap_config.py --refresh
```

脚本只写 `config.ini` 的云管理平台字段（base_url/instance_id/email/api_key/ssl_path/batch 参数），算法参数一概不碰。多实例返回多个 external_id 时写 `1-2` 格式，配合既有 `update_config.py` 的分发布局。

写完启动算法：

```bash
python3 run.py --entry algorithm --mode real \
  --pdu-ip 192.168.0.163 --community-public public --community-private private \
  --psu-count 4 --psu-power 2000 --duration 120
```

## 平台验收

| 检查项 | 位置 | 预期 |
|---|---|---|
| 设备在线 | 实例页 | 状态 online，last_seen 实时 |
| 实时曲线 | 实例详情 | 采样点持续进入 |
| 上报账号 | 用户管理 | lab-01@espur.local（member）已存在且已授权 |

## 排障

| 症状 | 处理 |
|---|---|
| bootstrap HTTP 410 | token 已用/过期。平台重新签发（账号已存在会复用并换 key，无副作用） |
| bootstrap HTTP 400 | 设备还没有实例，先建实例再签 token |
| refresh 失败但算法照常跑 | 预期行为（离线鲁棒）。查平台可达性与 api_key 是否被轮换（平台侧 regenerate 会使旧 key 失效，重新 bootstrap 即可） |
| 平台看到上报 401/403 | api_key 不对（被轮换）或账号未授权该实例。重新 bootstrap 会自动修正（复用账号+重新授权） |
| config.ini 改不进去 | 确认用的 `--config` 路径正确；脚本自动定位失败时显式传 `--config /path/to/config.ini` |

## API 速查（平台侧）

```bash
# 签发 token（admin JWT）
POST /espur/api/device-bootstrap/tokens   {"equipment_id": 5, "email": "lab-01@espur.local"}
# 实机换取配置（一次性）
POST /espur/api/device-bootstrap/redeem   {"token": "dboot-..."}
# 启动刷新（email+api_key 双因子）
GET  /espur/api/device-bootstrap/mine?email=...&api_key=...
```

## 既成事实（2026-10-21）

- lab-01 已登记（equipment_id=5, external_id=1），实例 `192.168.0.163_1-2-3-4`，上报账号 `lab-01@espur.local` 已由 bootstrap 自动创建并授权。
- 测试期间消费过一个 token（服务器本机验证用），台账在 `device_bootstrap_tokens` 表可审计。
- 客户端脚本位于 `eSpur_v2/scripts/bootstrap_config.py`（服务器仓库），实机部署时随 eSpur_v2 一起分发。
