# eSpur 实机接入平台（配置中心模式，方案 B）

实机接入管理平台（https://neowatt.cn/espur）上报数据。前提：eSpur 已部署、设备可经 HTTPS 访问平台。WG 用于管理访问，不是遥测上报的必要条件；受限线路按现行中转拓扑核对。

**实机侧只有一条命令**（token 由平台生成）：

```bash
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxxx
```

配置（instance_id/email/api_key）写入 `config.ini` 后，核对实例和口组。真实设备启动须在明确授权及安全闸门核实后执行，并带 `--publish-db` 才上报；仅配置完成不等于已上报。

## 数据链路（心智模型）

```
[设备 eSpur_v2 算法] --HTTPS 443--> [nginx neowatt.cn/espur] --> [frontend:3000] --> [backend:8000]
        |                                     |                        |
     config.ini                          管理页(3000)            PostgreSQL(设备/实例/授权/数据)
  （bootstrap_config.py 从平台拉取写入）
```

- 上报是纯 push（HTTPS 出站），平台不会反向连实机。
- 组网隧道（10.66.66.x）只承载人的远程操作（SSH/PDU Web），上报流量不进隧道。
- 客户端 `constant.py` 在 import 时读取 `config.ini`，bootstrap/refresh 可在启动前写文件；控制路径另有设备主动长轮询，不能据此说算法运行期间完全不联网。失联后的行为应以设备版本及现场状态为准。

## 平台侧操作（管理员）

1. **登记设备**：实例页 → 「登记实机」→ 填设备名（lab-01）、版本、位置、IP（填 mesh IP `10.66.66.101`）。实例名自动按 `PDU IP_端口段` 约定生成。
2. **确认实例**：实例应与一台被供电服务器及其 PDU 口组对应，`external_id` 与实机配置一致；一台采集设备可能运行多个独立实例。
3. **签发 bootstrap token**（一次性、24 小时有效）——**UI（推荐）**：设备详情页 → 「实机接入」→ 可选填上报邮箱 → 「生成接入 Token」→ 复制页面给出的实机命令。API 备选：

   ```bash
   curl -s -X POST https://neowatt.cn/espur/api/device-bootstrap/tokens \
     -H "Authorization: Bearer <admin_token>" -H 'Content-Type: application/json' \
     -d '{"equipment_id": <设备id>, "email": "lab-01@espur.local"}'
   ```

   返回 `dboot-...`。兑换时，新建账号使用 `device` 角色；已有账号可能复用并轮换 API key，旧 key 立即失效，须先确认同账号设备影响。

**不要使用页面中的旧“组网 Token”按钮或旧 `--enroll` 命令。** 新加坡旧 mesh 注册服务已退役，现行组网节点按 skill 2 的新 hub 手工登记；`dboot-...` 设备上报配置 token 与组网 token 不是同一功能。

## 单口功率与曲线（2026-10-21 起）

客户端每次采样附带 PDU 单口功率，平台按口出曲线（设备卡片 2×2 小图 + 详情页分图）。

- **客户端最低版本**：`3b42ece`（实时循环带单口上报）+ `0d932c0`（SNMP OID 修复，
  之前读数恒 0）。自检：`grep -c port_powers src/run_algorithm.py` ≥3、
  `grep -c "2.3.{port}.0" src/hal/snmp_pdu.py` ≥1。
- 该 PDU（ATEN switched-pdu）使用口电流与电压计算单口功率；当前仓库 `snmp_pdu.py` 的实例总功率按配置口组求和。实际设备版本和 PDU 口径应先核对，不能把同一 PDU 的其他实例算入当前实例。API 的功率单位按相应接口定义核实。
- 验收：核对该实例实际口组、时间戳及持续采样，不能仅凭曲线存在认定整段无缺失。

## 实机侧操作（树莓派）

```bash
# 首次接入（唯一需要的一次）
python3 eSpur_v2/scripts/bootstrap_config.py --token dboot-xxxx

# 之后每次启动算法前（可配 systemd ExecStartPre；平台不可达时自动沿用本地配置）
python3 eSpur_v2/scripts/bootstrap_config.py --refresh
```

脚本只写 `config.ini` 的云管理平台字段（base_url/instance_id/email/api_key/ssl_path/batch 参数），算法参数一概不碰。多实例返回多个 external_id 时写 `1-2` 格式，配合既有 `update_config.py` 的分发布局。

写完先核对实例 ID、目标站点、口组、配置和测试闸门。只有用户明确授权实机启动后，按 skill 3 和现场部署配置操作；真实模式连接 PDU，不能把启动当作无副作用的冒烟。需要上报时须带 `--publish-db`；`--duration 0` 表示无限运行。

## 功耗数据导出（2026-10-29 起，仅管理员/超级管理员）

设备详情页 / 历史数据页 →「导出数据」按钮 → 弹窗选时间范围（快捷 1h/24h/7d + 自定义，
自动预估点数与体积）→ 下载 CSV。member/device 前端无按钮、接口 403。

```bash
# 预估（点数/端口/大小）
GET /espur/api/managed-instances/<id>/export?start=...&end=...&preview=1
# 导出（流式 CSV，UTF-8 BOM，Excel 直开）
GET /espur/api/managed-instances/<id>/export?start=...&end=...
```

- 列：`时间, 总功率(W), PSU状态, 在网口数, 口N功率(W)...`；端口列按范围内实际出现过的口生成
- **时间口径 = 设备本地墙钟（CST、naive）**；带时区入参按绝对时刻换算到 CST
- 总功率/PSU 流 = `legacy_power_time` ∪ `legacy_realtime_power_time`（有序归并、历史表优先去重）——
  尾部补实时表；单口流 = `legacy_port_power_time`。设备故障或断网期间可能有数据缺口，不承诺任意范围连续。
- 限制：单次最长 90 天；当前功率和单口原始数据自动删除已暂停，不能断言更早只剩小时聚合。大范围导出耗时和内存取决于部署版本、浏览器及数据量。
- 实现位置：后端 `routers/managed_instances.py` 的 export 端点；前端
  `components/TelemetryExportDialog.tsx`（api.ts 有 blob 下载封装）

## 平台验收

| 检查项 | 位置 | 预期 |
|---|---|---|
| 设备在线 | 实例页 | 状态 online，last_seen 实时 |
| 实时曲线 | 实例详情 | 采样点持续进入 |
| 上报账号 | 用户管理 | 设备账号已存在且获实例授权，角色以实际记录为准 |

## 排障

| 症状 | 处理 |
|---|---|
| 历史功率卡片节能率恒 ≈1.3%，实时却是 0/-- | 2026-10-28 有客户端能耗基线未门控的历史案例；先核对当前设备版本、运行模式及统计口径，不能凭相同症状断言相同根因或自动重推代码 |
| bootstrap HTTP 410 | token 已用/过期；重签并兑换可能轮换已有账号 key，先确认相关设备影响 |
| bootstrap HTTP 400 | 设备还没有实例，先建实例再签 token |
| refresh 失败但算法照常跑 | 查平台可达性和授权状态；重新 bootstrap 可能轮换已有 key，先核对影响并在获授权后操作 |
| 平台看到上报 401/403 | 区分凭据失效和账号授权缺失，先核对账号与实例；不要直接轮换 key 或重启设备 |
| config.ini 改不进去 | 确认用的 `--config` 路径正确；脚本自动定位失败时显式传 `--config /path/to/config.ini` |
| 设备卡片"未激活"，实机日志却无上报失败 | 授权链异常是可能原因之一；401/404 有助于区分凭据和授权。涉及重签 token、重新 bootstrap、修改授权或重启算法时，先核实影响并按用户授权操作 |

## API 速查（平台侧）

```bash
# 签发 token（admin JWT）
POST /espur/api/device-bootstrap/tokens   {"equipment_id": 5, "email": "lab-01@espur.local"}
# 实机换取配置（一次性）
POST /espur/api/device-bootstrap/redeem   {"token": "dboot-..."}
# 启动刷新（部署版可用请求头，旧设备仍可能使用查询参数）
GET  /espur/api/device-bootstrap/mine
# 使用 X-eSpur-Email 和 X-eSpur-Api-Key 请求头；不要将凭据写入示例 URL 或日志。
```

## 既成事实（2026-10-21）

- lab-01 已登记（equipment_id=5, external_id=1），实例 `192.168.0.163_1-2-3-4`，上报账号 `lab-01@espur.local` 已由 bootstrap 自动创建并授权。
- 测试期间消费过一个 token（服务器本机验证用），台账在 `device_bootstrap_tokens` 表可审计。
- 客户端脚本位于 `eSpur_v2/scripts/bootstrap_config.py`（服务器仓库），实机部署时随 eSpur_v2 一起分发。
