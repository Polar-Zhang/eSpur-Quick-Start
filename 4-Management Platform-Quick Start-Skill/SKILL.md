---
name: espur-platform-ops
description: eSpur 管理端（neowatt.cn 云平台）的部署、更新与运维：阿里云 ECS 上的 nginx + PostgreSQL + Redis + FastAPI backend + Celery worker + Next.js frontend 全栈、WireGuard hub 与 mesh enroll 服务、bootstrap 接入 Token、设备工牌、离线巡检与告警邮件。当用户提到 管理端、平台部署、neowatt、espur 后端/frontend/backend、espur-backend、数据库迁移 alembic、前端构建 404、设备工牌、离线告警邮件、平台更新发布、Token 签发 等任何相关话题时使用本 skill，包括从零复建、版本更新发布、故障排查。
---

# eSpur 管理端（neowatt.cn 平台）部署与运维

最后验证：2026-10-22（本机即生产机，以下所有路径/端口均为线上实况）。

## 系统结构（先建立心智模型）

```
[浏览器/实机] —HTTPS 443—> [nginx]
                              ├─ /espur            → Next.js frontend  127.0.0.1:3000
                              ├─ /espur/api/mesh/  → mesh enroll      127.0.0.1:8443
                              └─ TLS: letsencrypt (neowatt.cn)
[frontend] —/api→ [FastAPI backend] 127.0.0.1:8000 → PostgreSQL 5432 / Redis 6379
[worker]  Celery（运行任务）          ← 同库同 Redis
[WireGuard hub] 51820/udp + 443/udp（实机 mesh 隧道，与平台共存）
[espur-mesh-enroll] 8443：实机 token 换 mesh 配置（与后端 bootstrap 独立）
```

- 服务器：阿里云 ap-southeast-1 ECS `i-t4nizvwitrw9yg6yz0dl`，公网 47.237.111.211 = neowatt.cn。
- 运行用户 `zp`；代码 `/home/zp/eSpur`（main）；Python/Node 统一用 `/home/zp/.local/envs/espur/bin`。
- 实机/组网侧不在本 skill：树莓派客户端见 skill 3（espur-v2.md），组网/hub 见 skill 2。

## 服务清单（全部 systemd 开机自启）

| 单元 | 端口/作用 |
|---|---|
| espur-postgres / espur-redis | 5432 / 6379（仅 127.0.0.1） |
| espur-backend | uvicorn 127.0.0.1:8000，workers 2，EnvironmentFile=infra/.env |
| espur-worker | Celery（实时归档等任务） |
| espur-frontend | next start 127.0.0.1:3000 |
| espur-mesh-enroll | uvicorn 127.0.0.1:8443（组网 token 注册） |
| wg-quick@hub + @hub443 | 51820/udp + 443/udp，同一密钥同一 peer 表 |
| nginx | 80/443 TCP，配置 /etc/nginx/conf.d/espur.conf |

## 更新发布（日常唯一流程）

```bash
cd /home/zp/eSpur && git pull
# 后端有改动时：迁移 + 重启
cd management-v2/backend
PYTHONPATH="/home/zp/eSpur/management-v2:/home/zp/eSpur/management-v2/shared/python:/home/zp/eSpur" \
  /home/zp/.local/envs/espur/bin/alembic upgrade head
sudo systemctl restart espur-backend
# 前端有改动时：构建（构建期环境由 .env.production 提供）+ 重启
cd ../frontend && npm run build
sudo systemctl restart espur-frontend
# 冒烟：页面 200 + 登录 200
curl -s -o /dev/null -w "%{http_code}\n" https://neowatt.cn/espur/instances
```

## 从零复建（保证与本机一致）

完整清单（系统依赖、env 文件、nginx 全文、数据库、mesh hub、安全组）见
`references/server-setup.md`——按它装出来与当前生产机一致。要点：

1. systemd 单元 8 个（含 EnvironmentFile 指向 `management-v2/infra/.env`）；
2. 前端构建**必须**有 `management-v2/frontend/.env.production`（已随仓库提交）——
   缺失时的三连症状：页面能开但 API 全 404（nginx HTML）、logo 404、登录后 404；
3. alembic 迁移到最新（当前 head `0022_port_power_time`）；
4. 管理员由启动时 `ensure_admin_user` 从 env 的
   `MANAGEMENT_V2_ADMIN_USERNAME/PASSWORD` 引导；
5. SMTP（qq 邮箱）服务邀请函/验证码/**离线告警**；
6. 在线巡检：每 60s 扫描，30s 无上报判离线并给超管发提醒邮件。

## 排障速查

| 症状 | 处理 |
|---|---|
| 页面 200 但 API 404（nginx HTML） | 前端构建缺子路径 env：确认 `.env.production` 存在后 `npm run build` |
| logo/静态资源 404 | 同上（NEXT_PUBLIC_BASE_PATH 未内联） |
| 设备一直显示在线 | 是否真停了上报：30s 静默 + 60s 巡检才翻转；`journalctl -u espur-backend \| grep online-sweep` |
| 离线邮件没收到 | SMTP 配置（infra/.env）、超管账号邮箱、`journalctl` 搜 offline-alert |
| mesh enroll 404 | nginx 的 `/espur/api/mesh/` location 与 espur-mesh-enroll 服务状态 |

平台操作（登记实机 / Token / 工牌 / 单口曲线）见 `references/platform-onboard.md`。

**UI 改动的强制前置**：前端设计标准在仓库
`management-v2/frontend/docs/DESIGN_SYSTEM.md`（token 表、标准组件清单、
新组件 checklist）。日期/下拉/弹窗/表单等同类交互**先复用标准组件**
（`RangeDatePicker` / `StyledSelect` / `.zc-dialog` 体系 / `.field`），
基准样例是 `components/RangeDatePicker.tsx`；禁止原生日历/下拉与新造风格。
