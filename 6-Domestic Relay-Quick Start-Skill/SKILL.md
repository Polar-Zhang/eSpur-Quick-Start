---
name: espur-domestic-relay
description: 国内中转节点：校园网/受限线路站点的平台通道桥接。在任意一台国内云服务器上部署 nginx stream 透明转发（TCP→hub:443、UDP→hub:51820），让国际路径受限的机器经它访问平台。当用户提到 中转、国内服务器、桥接、国际不通、校园网连不上平台、遥测断、MQTT、relay 等相关话题时使用本 skill，包括新站点接入中转、部署新中转节点、中转故障排查与迁移。
---

# 国内中转节点（受限线路站点的标准接入）

> **本文所有 IP/端口均为"部署期参数"，不是常量。** 换中转机器、换 hub、换端口时，
> 以当期参数表为准替换所有占位符。文末附"当前生产实例参数表"（仅对照，勿照抄）。

最后验证：2026-11-14（切换至 8.134.215.146：TCP 外测 200 ✓ / UDP 回环 ✓ / lab-01 切换后遥测秒级恢复 ✓）。

## 场景判定（先确认该不该用）

症状：机器**国内方向完全正常**（ping 223.5.5.5 通、baidu 秒下大文件），但到平台的
**TCP 443 连不上、UDP 51820 不到达**（ICMP 却通）——校园网国际限制、CGNAT 出口路径
劣化/漂移（含 MTU 黑洞：小包通大包丢）都是此类。此时遥测断、指令断、平台如实显示
离线——**机器侧代码救不了，必须换路径：经一台国内中转**。

⚠️ 三种"修法"的适用边界：
| 手段 | 治什么 | 治不了什么 |
|---|---|---|
| 钳 MTU（路由 mtu 1200） | MTU 黑洞（小包通/大包丢阶段） | 国际 TCP/UDP 全断阶段 |
| 重启上游 CPE/光猫 | CGNAT 会话/线路死机（可能漂回好路径） | 线路硬件死亡 |
| **国内中转（本 skill）** | **以上全部**（绕开国际路径） | 机器连国内都不通（那不是本 skill 范畴） |

## 参数表（部署前先填）

| 占位符 | 含义 | 当前生产值（2026-11-12，仅对照） |
|---|---|---|
| `<RELAY_IP>` | 中转节点公网 IP | **8.134.215.146**（阿里云北京轻量 2C2G Ubuntu24；2026-11-14 由 8.148.245.206 切换而来——旧节点国际方向被 RST，新节点验证通过） |
| `<HUB_ADDR>` | 平台地址（域名或 IP） | neowatt.cn（= 47.237.111.211，新加坡） |
| `<TCP_PORT>` | 中转监听的 TCP 转发端口 | 443（主）与 8443（备用，避开平台占用时用） |
| `<UDP_PORT>` | 中转监听的 UDP 转发端口（WG） | 51821（hub 实听 51820） |

## 一、中转节点部署（在国内云服务器上，root）

```bash
apt update && apt install -y nginx libnginx-mod-stream
cat > /etc/nginx/modules-enabled/70-relay.conf <<'EOF'
stream {
    upstream hub_https { server <HUB_ADDR>:443; }
    upstream hub_wg    { server <HUB_ADDR>:51820; }
    server { listen <TCP_PORT>;  proxy_pass hub_https; proxy_connect_timeout 5s; proxy_timeout 300s; }
    server { listen <UDP_PORT> udp; proxy_pass hub_wg; proxy_timeout 60s; }
}
EOF
nginx -t && systemctl reload nginx
# 控制台防火墙/安全组放行：TCP <TCP_PORT> + UDP <UDP_PORT> 入方向（两层都要：控制台防火墙 + 安全组）
```

自验（在中转本机）：
```bash
curl -s --resolve <平台域名>:<TCP_PORT>:127.0.0.1 -o /dev/null \
  -w "%{http_code} %{time_total}s\n" --max-time 8 https://<平台域名>:<TCP_PORT>/<健康检查路径>
# 预期 200。UDP 验证：在 hub 侧 tcpdump 抓 <UDP_PORT>，中转发一个包看是否到达。
```

## 二、受限机器侧接入（两条命令）

```bash
# 1) 平台域名指向中转（机器全局生效；hosts 优先于 DNS）
echo "<RELAY_IP> <平台域名>" | sudo tee -a /etc/hosts
# 2) WG 管理通道切中转
sudo sed -i 's/^Endpoint = .*/Endpoint = <RELAY_IP>:<UDP_PORT>/' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0 && ping -c 3 -W 2 <WG hub 内网 IP，如 10.66.66.1>
```

生效时间：遥测 ≤60s（批量线程自动重试并**补传缓存，最多 2 小时**）；指令通道 ≤5s
（长轮询线程立即重连）。回滚：删 hosts 行 + Endpoint 改回直连 + restart。

## 三、维护与排查

- 转发服务：nginx（systemd 常驻自启）；`nginx -t && systemctl reload nginx` 改配置。
- 链路验证三步：中转本机自验（上）→ 任意外部机器 `curl --resolve` 外测 → 受限机器实测。
- hub 换机/IP 变更：改中转 `70-relay.conf` 的 upstream + reload（一处）。
- 换中转机器：改所有受限机器的 hosts 行 + WG endpoint（两处/台）。
- 带宽：3-5Mbps 足够 10 台（遥测每台每秒几百字节；长轮询挂连接不占带宽）。
- 安全：纯 TCP/UDP 透传（TLS 端到端，中转看不到明文）；裸 IP 非标端口无备案需求。

## 坑点（全部实测）

1. **防火墙两层**：云控制台防火墙 + 安全组都要放行；且规则协议必须对（"自定义 UDP"
   选成 TCP 是最高频错误——hub 自己的 UDP 443 至今未通就是这个坑，2026-11-08 实测探测包零到达）。
2. **CGNAT 路径漂移**：受限线的国际路径会漂——昨天 MTU 黑洞、今天国际全断、明天可能自愈。
   症状复现时先做三连测（国内大包/国内 1200 ping/国际 1200 ping）分清"网卡 vs 路径"，
   再决定是等漂移、重启上游 CPE，还是上中转。
3. **中转是透明无状态的**：无会话表、无 TLS 终结；故障形态只有 nginx 进程挂（自启）
   或安全组变更。nginx 重载即可。
4. **WG 经中转后 MTU 建议 ≤1200**：受限腿（CGNAT）MTU ~1250，隧道封装再吃一层。
5. **hosts 是机器全局的**：该机访问平台域名的所有流量都走桥；桥挂了删 hosts 行即
   回退 DNS 直连（平台域名解析恢复后自动直连）。

## 管理通道备用（与中转互补，SSH 专用）

自愈反连隧道（受限机器 → hub，TCP 出站）：
```bash
# 密钥就绪后（hub relay 账号）：
nohup bash -c 'while true; do ssh -fN -R 22022:localhost:22 -i ~/.ssh/relay_key \
  -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no relay@<HUB_ADDR>; sleep 10; done' >/dev/null 2>&1 &
# hub 进入：ssh -p 22022 <实机用户>@localhost
