# 管理端从零复建参考

2026-11-15 快照：生产主站在新加坡，Rocky Linux 9，用户 `zp`。复建前以当前版本、环境配置、备份和实际服务为准；本文不能证明新机器与生产完全一致。本文不授权自动迁移、重启生产服务、连接实机或操作 PDU。

## 0. 前置

- 平台域名、证书及云安全组按目标部署核验；主站 HTTP/HTTPS 与北京中转的两套 WG 端口属于不同机器和用途，不按旧 hub 规则在新加坡开 UDP 51820/443。
- 系统包：`dnf install -y nginx git`；Python/Node 统一用 `/home/zp/.local/envs/espur/bin`
  （python 3.11 + uvicorn + alembic + node + npm 的专用 env）

## 1. 代码

仓库与实际 release 分别管理：先核对来源、分支、工作区及部署版本，准备独立候选目录。不要覆盖在用 release，也不要假设源码工作区就是正在运行的服务目录。

## 2. 数据层

```bash
# PostgreSQL 16 + Redis 7（systemd 单元 espur-postgres / espur-redis，仅 127.0.0.1）
# 数据库名及账号来自目标环境的受限配置；不要沿用文档或测试默认密码。
```

## 3. 环境文件（密钥集中地，不入 git）

`management-v2/infra/.env`（backend/worker 的 EnvironmentFile）关键项：
`MANAGEMENT_V2_SECRET_KEY`、`MANAGEMENT_V2_ADMIN_USERNAME/PASSWORD`（启动时
ensure_admin_user 引导超管）、`MANAGEMENT_V2_DATABASE_URL`、
`MANAGEMENT_V2_REDIS_URL=redis://127.0.0.1:6379/0`、`MANAGEMENT_V2_PUBLIC_API_BASE_URL=https://neowatt.cn/espur/api`、
SMTP_*（qq 邮箱：邀请函/验证码/离线告警）。

## 4. 后端

核对候选版本的迁移 head 与目标库实际版本，并准备经过核验的备份、迁移和回滚方案。只有任务明确授权部署且确认目标库后，才在隔离验证通过后执行相应迁移或服务切换；不自动执行 `alembic upgrade head`。服务绑定及工作目录以实际 systemd unit/drop-in 为准。

内置能力（随代码自动生效，无额外配置）：
- 设备 bootstrap（/device-bootstrap/*，迁移 0021）
- 单口功率（表迁移 0022 + execute-sql 白名单分支 + /managed-instances/:id/port-power）
- 当前在线巡检：60s 扫描，约 90s 无上报达到离线阈值，翻转时按配置通知；具体以部署版为准
- 设备工牌角色（role=device）

## 5. 前端

在独立候选 release 中构建前端，验证构建期子路径设置及结果，再按已授权的发布方案切换；不要在当前在线 release 原地重建 `.next`。

`.env.production`（已随仓库提交，缺它 = 经典三连坑）：
`NEXT_BASE_PATH=/espur`、`NEXT_PUBLIC_BASE_PATH=/espur`、
`NEXT_SERVER_API_BASE=http://127.0.0.1:8000/api`、`NEXT_PUBLIC_API_BASE=/espur/api`。

## 6. nginx

`/etc/nginx/conf.d/espur.conf`（随仓库无，需按当前生产配置复制）：
- 80：ACME webroot（/var/www/certbot）+ 301 https
- 443：TLS 证书 /etc/letsencrypt/live/neowatt.cn/；`location /espur` → 127.0.0.1:3000；
  旧 `location /espur/api/mesh/` 现返回 410，旧注册服务已退役。
- 核对目标机的实际防火墙及云安全组；不要把旧新加坡 hub 的 443/51820 UDP 放行规则当作当前要求。
- espur.conf 内已启用 gzip（HTML/JSON/JS/CSS/SVG，跨境传输降 70-80%）与
  `/espur/_next/static/` 长缓存（immutable）——复建时必须带上，否则页面切换明显变卡
  （2026-10-29 实测：无压缩时跨境拉 JS chunk 是页面"卡一下"的主因）
- **数据库每日备份**（2026-10-30 起）：`/home/zp/backups/pg-backup.sh`（pg_dump -Fc，
  完整性自检，保留 14 份），crontab 每日 02:00 → /home/zp/backups/postgres/；
  **恢复演练** `pg-restore-drill.sh` 每周日 03:30 自动执行（最新 dump → 临时库恢复 →
  关键表/账号核对 → 清理）——复建时两个脚本与 cron 都要重建
- `management-v2/var/traces/` 目录存 trace 场景 CSV（import-trace 端点写入），
  复建后需 mkdir；运行遥测保留策略：每实例最近 20 次运行的遥测，其余由每小时
  巡检自动清理（services/realtime_retention.prune_run_telemetry）
- 项目待办/已知问题台账：`management-v2/docs/known-issues.md`（含 P0/P1/P2 处理状态）

## 7. 组网（见 skill 2）

- 当前台账：北京中转 `espur-wg0` 为 eSpur hub（51822/udp），新加坡主站 `wg0` 为普通 peer `.254`。北京的 `wg0` 是用户自己的另一套 WG，不能覆盖或重启。
- 旧新加坡 hub、`espur-mesh-enroll` 和旧组网 token 流程已退役；`/home/zp/espur-mesh/README.md` 是历史内容。新节点登记以 skill 2 的当前拓扑为准。

## 8. 账号有效期（迁移 0027，2026-10-25 起）

- `users.expires_at`（NULL = 永不过期）；过期账号登录/刷新 token 均 401
  「Account expired（账号已过期，请联系管理员延期）」
- 管理端：用户管理弹窗每行显示到期日 + 剩余天数倒计时（过期红字）；
  超管点「✎ 设有效期」行内改日期（留空 = 永不过期）
- API：POST /users/{id}/expires-at（仅超级管理员；body {expires_at}，
  ISO 8601，null 清除）

## 8b. 数据保留策略（迁移 0023 起，每小时巡检自动执行）

| 数据 | 策略 |
|---|---|
| legacy_realtime_power_time | 7 天滚动 → 归档搬入 legacy_power_time |
| legacy_power_time / legacy_port_power_time（原始） | **当前自动删除暂停**；继续保留原始行，直到归档、查询与清理方案经验证 |
| legacy_power_hourly / legacy_port_power_hourly | 小时摘要，不可恢复秒级轨迹；旧桶和迟到数据完整性未全部核验 |
| legacy_ingest_records（上报审计） | 保留 14 天 |

以当前 release 的 `services/realtime_retention.py` 与 `main.py` 为准。归档样本工具及限制见主仓库 `management-v2/docs/raw-archive-tool.md`；不要因摘要或单次快照存在就删除原始数据。

## 9. 验收

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://neowatt.cn/espur/instances      # 200
curl -s https://neowatt.cn/espur/api/overview -H "Authorization: Bearer <token>" # 200
sudo journalctl -u espur-backend --since -5min | grep -i error                   # 无
```

用超管登录后逐页：总览（实机面板）/ 设备卡片（四口小图）/ 详情页（铅笔改名）/ 用户管理（设备工牌）。
