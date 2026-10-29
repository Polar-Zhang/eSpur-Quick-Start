# 管理端从零复建清单（对齐当前生产机）

目标：在一台新的阿里云 ECS（同规格）上复建出与当前 neowatt.cn 完全一致的管理端。
当前生产：ap-southeast-1，ECS `i-t4nizvwitrw9yg6yz0dl`，47.237.111.211，Rocky Linux 9，用户 `zp`。

## 0. 前置

- 域名 neowatt.cn A 记录 → 本机公网 IP；阿里云安全组入方向：80/tcp、443/tcp、51820/udp、443/udp
- 系统包：`dnf install -y nginx git`；Python/Node 统一用 `/home/zp/.local/envs/espur/bin`
  （python 3.11 + uvicorn + alembic + node + npm 的专用 env）

## 1. 代码

```bash
cd /home/zp && git clone https://github.com/Polar-Zhang/eSpur.git eSpur
```

## 2. 数据层

```bash
# PostgreSQL 16 + Redis 7（systemd 单元 espur-postgres / espur-redis，仅 127.0.0.1）
# 库：management_v2，用户 espur/espur
```

## 3. 环境文件（密钥集中地，不入 git）

`management-v2/infra/.env`（backend/worker 的 EnvironmentFile）关键项：
`MANAGEMENT_V2_SECRET_KEY`、`MANAGEMENT_V2_ADMIN_USERNAME/PASSWORD`（启动时
ensure_admin_user 引导超管）、`MANAGEMENT_V2_DATABASE_URL=postgresql+psycopg://espur:espur@127.0.0.1:5432/management_v2`、
`MANAGEMENT_V2_REDIS_URL=redis://127.0.0.1:6379/0`、`MANAGEMENT_V2_PUBLIC_API_BASE_URL=https://neowatt.cn/espur/api`、
SMTP_*（qq 邮箱：邀请函/验证码/离线告警）。

## 4. 后端

```bash
cd /home/zp/eSpur/management-v2/backend
PYTHONPATH="/home/zp/eSpur/management-v2:/home/zp/eSpur/management-v2/shared/python:/home/zp/eSpur" \
  /home/zp/.local/envs/espur/bin/alembic upgrade head     # 以 `alembic heads` 实际输出为准（2026-10-30 时为 0027_user_expires_at，勿照抄）
sudo systemctl enable --now espur-backend                 # uvicorn 127.0.0.1:8000 --workers 2
```

内置能力（随代码自动生效，无额外配置）：
- 设备 bootstrap（/device-bootstrap/*，迁移 0021）
- 单口功率（表迁移 0022 + execute-sql 白名单分支 + /managed-instances/:id/port-power）
- 在线巡检：60s 扫描，30s 无上报判离线，翻转时给超管发提醒邮件（SMTP）
- 设备工牌角色（role=device）

## 5. 前端

```bash
cd /home/zp/eSpur/management-v2/frontend
npm install && npm run build          # 构建期环境由 .env.production 提供（必须存在！）
sudo systemctl enable --now espur-frontend   # next start 127.0.0.1:3000
```

`.env.production`（已随仓库提交，缺它 = 经典三连坑）：
`NEXT_BASE_PATH=/espur`、`NEXT_PUBLIC_BASE_PATH=/espur`、
`NEXT_SERVER_API_BASE=http://127.0.0.1:8000/api`、`NEXT_PUBLIC_API_BASE=/espur/api`。

## 6. nginx

`/etc/nginx/conf.d/espur.conf`（随仓库无，需按当前生产配置复制）：
- 80：ACME webroot（/var/www/certbot）+ 301 https
- 443：TLS 证书 /etc/letsencrypt/live/neowatt.cn/；`location /espur` → 127.0.0.1:3000；
  `location /espur/api/mesh/` → 127.0.0.1:8443/mesh/
- 本机防火墙 firewalld：放行 80/tcp、443/tcp、443/udp、51820/udp（后两者为 WG）
- espur.conf 内已启用 gzip（HTML/JSON/JS/CSS/SVG，跨境传输降 70-80%）与
  `/espur/_next/static/` 长缓存（immutable）——复建时必须带上，否则页面切换明显变卡
  （2026-10-29 实测：无压缩时跨境拉 JS chunk 是页面"卡一下"的主因）
- **数据库每日备份**（2026-10-30 起）：`/home/zp/backups/pg-backup.sh`（pg_dump -Fc，
  完整性自检，保留 14 份），crontab 每日 02:00 → /home/zp/backups/postgres/；
  复建时需重建该脚本与 cron
- `management-v2/var/traces/` 目录存 trace 场景 CSV（import-trace 端点写入），
  复建后需 mkdir；运行遥测保留策略：每实例最近 20 次运行的遥测，其余由每小时
  巡检自动清理（services/realtime_retention.prune_run_telemetry）
- 项目待办/已知问题台账：`management-v2/docs/known-issues.md`（含 P0/P1/P2 处理状态）

## 7. 组网 hub（与平台同机，见 skill 2）

- `wireguard-tools`；`/etc/wireguard/hub.conf`（51820/udp）与 `hub443.conf`（443/udp，
  Table=off 无 Address，peer 表从 hub.conf 同步）
- mesh enroll：`/home/zp/espur-mesh/`（enroll_service.py + mesh-admin.py + peers.txt + keys/），
  systemd 单元 espur-mesh-enroll（127.0.0.1:8443，root 运行）
- 工具链手册：hub 本机 `/home/zp/espur-mesh/README.md`

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
| legacy_power_time / legacy_port_power_time（1Hz 原始） | 保留 90 天 → 按小时聚合进 legacy_power_hourly / legacy_port_power_hourly 后删除原始行 |
| legacy_power_hourly / legacy_port_power_hourly | 永久（每天 24 行/口，体积可忽略） |
| legacy_ingest_records（上报审计） | 保留 14 天 |

常量：HISTORY_RAW_DAYS / INGEST_LOG_DAYS / ONLINE_OFFLINE_AFTER_SECONDS（30s 判离线），
均在 services/realtime_retention.py 与 main.py。聚合逻辑幂等（UNIQUE + ON CONFLICT）。

## 9. 验收

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://neowatt.cn/espur/instances      # 200
curl -s https://neowatt.cn/espur/api/overview -H "Authorization: Bearer <token>" # 200
sudo journalctl -u espur-backend --since -5min | grep -i error                   # 无
```

用超管登录后逐页：总览（实机面板）/ 设备卡片（四口小图）/ 详情页（铅笔改名）/ 用户管理（设备工牌）。
