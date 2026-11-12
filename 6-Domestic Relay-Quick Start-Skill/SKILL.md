---
name: espur-domestic-relay
description: 国内中转节点（8.148.245.206，广州轻量云）：校园网/受限线路站点的平台通道桥接。nginx stream 透明转发 TCP 443/8443→hub:443、UDP 51821→hub:51820。当用户提到 中转、国内服务器、桥接、国际不通、校园网连不上平台、遥测断、MQTT、8.148.245.206、relay 等相关话题时使用本 skill，包括新站点接入中转、中转故障排查、新增中转节点。
---

# 国内中转节点（受限线路站点的标准接入）

最后验证：2026-11-12（TCP 外测 0.67s 200 ✓ / UDP 回环 46ms 双向 ✓ / lab-01 切换后遥测恢复 ✓）。

## 场景判定（先确认该不该用）

症状：机器**国内方向完全正常**（ping 223.5.5.5 通、baidu 秒开），但到平台（新加坡
47.237.111.211 / neowatt.cn）的 **TCP 443 连不上、UDP 51820 不到达**——校园网国际限制、
CGNAT 出口路径劣化（含 MTU ~1250 黑洞，小包通大包丢）都是此类。此时遥测断、指令断、
平台如实显示离线——**任何机器侧代码都救不了，必须换路径：走国内中转**。

## 中转节点现状（唯一真源）

| 项 | 值 |
|---|---|
| 机器 | 阿里云广州轻量 2C2G，Ubuntu 24.04，root 登录 |
| 公网 | 8.148.245.206（裸 IP，无域名，**无备案需求**——纯 TCP/UDP 透传非网站服务） |
| 转发规则（nginx stream，/etc/nginx/modules-enabled/70-espur-relay.conf） | TCP 443→hub:443；TCP 8443→hub:443；UDP 51821→hub:51820 |
| 性质 | TLS 端到端透传（中转看不到明文）；hub IP 硬编码 `47.237.111.211`，hub 换机需同步 |

## 受限机器侧接入（两条命令）

```bash
# 1) 平台域名指向中转（机器全局生效，遥测/长轮询/bootstrap 全部自动走桥）
echo "8.148.245.206 neowatt.cn" | sudo tee -a /etc/hosts
# 2) WG 管理通道切中转（UDP 51821；主通道 UDP 被掐时的替代路径）
sudo sed -i 's/^Endpoint = .*/Endpoint = 8.148.245.206:51821/' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0 && ping -c 3 -W 2 10.66.66.1
```
- 生效时间：遥测 ≤60s（批量线程立即重试并补传缓存，最多 2 小时）；指令通道 ≤5s（长轮询线程立即重连）。
- 回滚：删 /etc/hosts 那行 + Endpoint 改回 `47.237.111.211:51820` + restart。
- ⚠️ /etc/hosts 是机器全局的：这台机器上访问 neowatt.cn 的**所有**流量都走桥；
  桥挂了它会退回 DNS 直连（hosts 删掉即彻底还原）。

## 验证命令

```bash
# 中转机上（自验转发链路）：
curl -s --resolve neowatt.cn:8443:127.0.0.1 -o /dev/null -w "%{http_code} %{time_total}s\n" \
  --max-time 8 https://neowatt.cn:8443/espur/api/health     # 预期 200
# hub 上（回环抓包，验证 UDP 转发）：
echo t > /dev/udp/8.148.245.206/51821
sudo tcpdump -i any -n "udp and host 8.148.245.206" -c 4   # 应看到 Out→In 一对
# 受限机器上：
curl -m 6 https://neowatt.cn/espur/api/health              # 200 = 桥通
```

## 坑点（全部实测）

1. **安全组两层**：轻量服务器的控制台防火墙（应用层）+ 阿里云安全组——TCP 8443/UDP 51821
   都要放行；本节点购买时默认已放行，新购节点需手动加。
2. **"自定义 UDP"vs TCP**：hub 自己的安全组 UDP 443 至今未通（2026-11-08 实测探测包零到达，
   用户称已加规则——疑协议类型选成 TCP）。复核安全组时先看协议类型。
3. **CGNAT 路径漂移**：受限线路的国际路径会漂——昨天 MTU 黑洞（1200 通/1300 丢）、
   今天国际 TCP/UDP 全断（仅 ICMP+国内）。**钳 MTU 只治前者，治不了漂移**——中转是唯一稳定解。
4. **中转透明无状态**：纯 TCP/UDP 透传，无会话表、无 TLS 终结，故障形态=nginx 进程挂
   （systemd 常驻自启）或安全组变更；nginx 重载即可。
5. **hub IP 硬编码**：nginx upstream 写死 47.237.111.211。hub 迁移时改
   70-espur-relay.conf + reload。
6. **WG 经中转后 MTU**：WG conf MTU=1200（lab-01 已设）；中转腿 1500 标准，无需再钳。
7. **遥测限流**：中转带宽 3-5Mbps 足够 10 台（遥测每台每秒几百字节）；长轮询挂连接不占带宽。

## 新增一台中转节点（从零模板）

```bash
apt update && apt install -y nginx libnginx-mod-stream
cat > /etc/nginx/modules-enabled/70-espur-relay.conf <<'EOF'
stream {
    upstream hub_https { server 47.237.111.211:443; }
    upstream hub_wg    { server 47.237.111.211:51820; }
    server { listen 443;  proxy_pass hub_https; proxy_connect_timeout 5s; proxy_timeout 300s; }
    server { listen 8443; proxy_pass hub_https; proxy_connect_timeout 5s; proxy_timeout 300s; }
    server { listen 51821 udp; proxy_pass hub_wg; proxy_timeout 60s; }
}
EOF
nginx -t && systemctl reload nginx
# 控制台防火墙放行 TCP 443/8443 + UDP 51821 入方向
```

## 管理通道备用（与中转互补）

受限机器的自愈反连隧道（TCP 出站，SSH 专用）：
```bash
# 密钥方式（hub relay 账号已装公钥则免密）：
nohup bash -c 'while true; do ssh -fN -R 22022:localhost:22 -i ~/.ssh/relay_key \
  -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no relay@47.237.111.211; sleep 10; done' >/dev/null 2>&1 &
# hub 进入：ssh -p 22022 <实机用户>@localhost
```
