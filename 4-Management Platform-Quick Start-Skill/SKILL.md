---
name: espur-platform-ops
description: eSpur 管理端（neowatt.cn）的部署、更新、故障排查和设备接入；涵盖 nginx、PostgreSQL、Redis、FastAPI、Celery、Next.js、设备 bootstrap、离线巡检与告警。eSpur WireGuard 接入和国内中转分别参考 skill 2、skill 6；不要操作用户自有 WireGuard。
---

# eSpur 管理端（neowatt.cn 平台）部署与运维

本机是生产主站。本文的具体路径和状态以 2026-11-15 的只读核对为快照，后续先核验实际运行配置，不能把仓库版本或历史文档当作线上版本。

## 系统结构（先建立心智模型）

```
[浏览器/实机] —HTTPS 443—> [nginx]
                              ├─ /espur            → Next.js frontend  127.0.0.1:3000
                              └─ TLS: letsencrypt (neowatt.cn)
[frontend] —/api→ [FastAPI backend] 127.0.0.1:8000 → PostgreSQL 5432 / Redis 6379
[worker]  Celery（运行任务）          ← 同库同 Redis
[WG peer .254] → 中转 hub 8.134.215.146:51822（2026-11-14 起 mesh hub 迁至中转，本机不再是 hub）
[旧 /espur/api/mesh/] → 410；新加坡 mesh enroll 已退役（与设备 bootstrap 独立）
```

- 服务器：阿里云 ap-southeast-1 ECS `i-t4nizvwitrw9yg6yz0dl`，公网 47.237.111.211 = neowatt.cn。
- 运行用户 `zp`；开发工作区 `/home/zp/eSpur`；服务运行于 `/home/zp/releases/` 下的独立版本，运行路径以 systemd 为准。Python/Node 位于 `/home/zp/.local/envs/espur/bin`。
- 实机/组网侧不在本 skill：树莓派客户端见 skill 3（espur-v2.md），组网/hub 见 skill 2。

## 服务清单（启用状态以实际 systemd 为准）

| 单元 | 端口/作用 |
|---|---|
| espur-postgres / espur-redis | 5432 / 6379（仅 127.0.0.1） |
| espur-backend | uvicorn 127.0.0.1:8000，workers 2，EnvironmentFile=infra/.env |
| espur-worker | Celery（实时归档等任务） |
| espur-frontend | next start 127.0.0.1:3000 |
| espur-mesh-enroll | **已停用**；旧接口 `/espur/api/mesh/` 返回 410，不恢复旧组网注册流程 |
| wg-quick@wg0 | peer→中转 hub 8.134.215.146:51822（本机=.254，MTU 1380）；旧 hub/hub443 已于 2026-11-14 退役 |
| nginx | 80/443 TCP，配置 /etc/nginx/conf.d/espur.conf |

## 更新发布

先核对工作区变更、各服务实际工作目录及有效配置；不要以 `git pull`、在源码目录构建或重启服务推断独立 release 已更新。只读检查入口：

```bash
git -C /home/zp/eSpur status --short --branch
systemctl show espur-backend espur-frontend espur-worker -p Id -p WorkingDirectory -p ActiveState
systemctl cat espur-backend espur-frontend espur-worker
```

生产更新应准备独立候选 release，在隔离环境构建、测试并核对与实际运行版本的差异；明确数据库是否需要迁移、备份及恢复路径、服务切换和回滚，再按已授权的变更执行。**不自动执行 Alembic 迁移，不在运行版本目录原地重建前端，不仅凭源码目录构建成功宣称上线。** 后端、前端和 worker 可能使用不同 release；worker 还依赖其 release 内完整算法及验证目录，不能仅修改工作目录。

真实设备接入、PSU 指令、PDU 探测或开关需要与当前用户请求一致的明确授权；检查或更新管理端不自动授权这些操作。

## 从零复建（保证与本机一致）

复建参考 `references/server-setup.md`；复建前按目标环境核对版本和配置，不把历史快照当作当前可直接执行的脚本。要点：

1. 根据目标环境核对 systemd 单元和 EnvironmentFile；旧组网注册单元不属于现行服务；
2. 前端构建**必须**有 `management-v2/frontend/.env.production`（已随仓库提交）——
   缺失时的三连症状：页面能开但 API 全 404（nginx HTML）、logo 404、登录后 404；
3. 以候选版本的 Alembic head、数据库实际版本和备份/回滚方案为准；
4. 管理员由启动时 `ensure_admin_user` 从 env 的
   `MANAGEMENT_V2_ADMIN_USERNAME/PASSWORD` 引导；
5. SMTP（qq 邮箱）服务邀请函/验证码/**离线告警**；
6. 当前在线巡检每 60s 扫描，约 90s 无上报达到离线阈值，实际翻转受巡检时点影响。

## 排障速查

| 症状 | 处理 |
|---|---|
| 页面 200 但 API 404（nginx HTML） | 核对当前 release 的子路径构建参数和反向代理；需要重建时在独立候选 release 验证 |
| logo/静态资源 404 | 核对子路径与静态资源构建，不在运行目录原地重建 |
| 设备一直显示在线 | 当前以约 90s 无上报为阈值、每 60s 巡检；先核对实际配置及接收时间，再看 `online-sweep` 日志 |
| 离线邮件没收到 | SMTP 配置（infra/.env）、超管账号邮箱、`journalctl` 搜 offline-alert |
| mesh enroll 404/410 | 旧注册服务已退役，410 是预期；不要重启它或通过旧按钮签发组网 token，按 skill 2 的现行手工登记核实 |

平台操作（登记实机 / Token / 工牌 / 单口曲线）见 `references/platform-onboard.md`。

**UI 改动的强制前置**：前端设计标准在仓库
`management-v2/frontend/docs/DESIGN_SYSTEM.md`（token 表、标准组件清单、
新组件 checklist）。日期/下拉/弹窗/表单等同类交互**先复用标准组件**
（`RangeDatePicker` / `StyledSelect` / `.zc-dialog` 体系 / `.field`），
基准样例是 `components/RangeDatePicker.tsx`；禁止原生日历/下拉与新造风格。


## 2026-11-12 增补

- **平台拓扑新组件：国内中转节点** `8.134.215.146`（2026-11-14 从 8.148.245.206 换机；nginx stream 透明转发
  TCP 443/8443→新加坡主站:443、8444→新加坡:22；UDP 51821 死转发已删）。国际受限站点（校园网等）经它接入，
  平台零改动。维护/接入/坑点 → 新 skill `6-Domestic Relay-Quick Start-Skill`。
- **DB 会话时区已钉 UTC**（`app/database.py` connect options；提交 `b9f7762`）：
  库内时间戳列统一 naive UTC，排查时用 `(now() AT TIME ZONE 'UTC')` 口径，勿用本地 now()。
- **实例=一台服务器=自己的 PDU 口组**：共用 8 口 PDU 的两台服务器各建各的实例
  （A `pdu_ports=1-2-3-4`、B `5-6-7-8`），禁止混实例（≥2 保护语义，详见 skill 3 增补）。
- **bootstrap token 有效期 24h**（早期文档写 15 分钟，以 `TOKEN_TTL` 为准）。
