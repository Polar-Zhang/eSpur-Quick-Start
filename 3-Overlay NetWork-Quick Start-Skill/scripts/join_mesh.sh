#!/usr/bin/env bash
# eSpur overlay 组网一键接入（学校实机侧）
# 两种用法：
#   bash join_mesh.sh --enroll <token>              # 推荐：token 自动注册（密钥本机生成，私钥不出机）
#   bash join_mesh.sh /path/to/lab-XX-wg0.conf     # 备用：管理员下发的完整配置文件
# 幂等：可重复运行。动作：装 wireguard → 出站预检 → 注册/装配置 → 起隧道 → 开转发/NAT → 装看门狗 → 体检
set -u

HUB_PUB_IP="47.237.111.211"
HUB_MESH_IP="10.66.66.1"
MY_MESH_IP="10.66.66.101"
WG_CONF="/etc/wireguard/wg0.conf"
ENROLL_URL="https://neowatt.cn/espur/api/mesh/enroll"
MESH_WATCHDOG="espur-mesh-watchdog"
REPO_BASE="$(cd "$(dirname "$0")" && pwd)"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m: %s\n' "$*"; }
warn()  { printf '  \033[33m!!\033[0m: %s\n' "$*"; }
die()   { printf '  \033[31mFAIL\033[0m: %s\n' "$*" >&2; exit 1; }
step()  { bold "== $* =="; }

# root 下 SUDO 置空（直接执行），非 root 用 sudo；set -u 下必须先初始化
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

echo "=============================================="
echo " eSpur overlay 组网一键接入 (lab → hub $HUB_PUB_IP)"
echo "=============================================="

# ---------- 参数解析 ----------
MODE="$1"; shift || true
case "$MODE" in
  --enroll) ENROLL_TOKEN="${1:?用法: bash join_mesh.sh --enroll <token>（token 由管理员签发，15 分钟有效）}" ;;
  *) CONF_SRC="$MODE" ;;
esac

# ---------- 1. 安装 wireguard ----------
step "1. 安装 wireguard"
if command -v wg >/dev/null 2>&1 && $SUDO ip link add wgprobe type wireguard 2>/dev/null; then
    $SUDO ip link del wgprobe
    ok "wireguard 已可用 ($(wg --version))"
else
    if command -v dnf >/dev/null 2>&1; then
        dnf repolist 2>/dev/null | grep -q epel || $SUDO dnf install -y epel-release
        $SUDO sed -i -e 's|^metalink=|#metalink=|' -e 's|^#baseurl=|baseurl=|' \
            -e 's|download.example/pub/epel|mirrors.aliyun.com/epel|' /etc/yum.repos.d/epel*.repo 2>/dev/null
        $SUDO dnf install -y wireguard-tools >/dev/null || die "dnf 装 wireguard-tools 失败，手动排查 yum 源"
    elif command -v apt >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y wireguard >/dev/null || die "apt 装 wireguard 失败，手动排查 apt 源"
    else
        die "未识别的包管理器（需要 dnf 或 apt），手动安装 wireguard-tools 后重跑"
    fi
    ok "wireguard-tools 安装完成"
fi
if ! $SUDO ip link add wgprobe type wireguard 2>/dev/null; then
    die "内核不支持 wireguard（$(uname -r)）。需要 ≥5.6 或安装 DKMS 模块后重跑。"
fi
$SUDO ip link del wgprobe 2>/dev/null
ok "内核模块可用"

# ---------- 2. 出站连通性预检 ----------
step "2. 出站连通性预检（hub: $HUB_PUB_IP）"
if ping -c 3 -W 3 "$HUB_PUB_IP" >/dev/null 2>&1; then
    ok "ICMP 到 hub 通，基础路由正常"
else
    warn "ICMP 不通——可能被禁 ping，不必然失败，继续"
fi
if curl -s -m 8 -o /dev/null "$ENROLL_URL/../health" 2>/dev/null || true; then
    ok "HTTPS 443 出站可用（enroll 通道）"
fi

# ---------- 3. 生成/获取配置 ----------
if [ "$MODE" = "--enroll" ]; then
    step "3. enroll 注册（token → mesh IP + hub 公钥；密钥本机生成，私钥不出机）"
    command -v curl >/dev/null 2>&1 || die "需要 curl"
    # 本机生成密钥对
    PRIV=$(umask 077; wg genkey)
    PUB=$(printf '%s' "$PRIV" | wg pubkey)
    # POST 到 enroll 服务
    RESP=$(curl -s -m 15 -X POST "$ENROLL_URL" -H 'Content-Type: application/json' \
        -d "{\"token\":\"$ENROLL_TOKEN\",\"public_key\":\"$PUB\",\"agent\":\"join_mesh.sh\"}")
    echo "$RESP" | grep -q '"status": *"ok"' || die "enroll 失败: $RESP
（token 错/过期/已用，或网络不通。找管理员重新签发）"
    MESH_IP=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["mesh_ip"])')
    HUB_PUB=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["hub_public_key"])')
    [ "$MESH_IP" = "$MY_MESH_IP" ] || warn "分配到的 mesh IP 是 $MESH_IP（脚本常量按 lab 首机写死为 $MY_MESH_IP，后续步骤不受影响）"
    umask 077; cat > "$WG_CONF" <<EOF
[Interface]
Address = $MESH_IP/24
PrivateKey = $PRIV
MTU = 1380

[Peer]
PublicKey = $HUB_PUB
Endpoint = $HUB_PUB_IP:51820
AllowedIPs = 10.66.66.0/24
PersistentKeepalive = 25
EOF
    ok "已注册为 $MESH_IP，配置写入 $WG_CONF（含本机私钥，勿外传）"
else
    step "3. 检查配置文件"
    CONF_SRC="${CONF_SRC:-}"
    [ -n "$CONF_SRC" ] && [ -f "$CONF_SRC" ] || die "配置文件不存在。用法: bash join_mesh.sh <wg0.conf> 或 --enroll <token>"

    grep -qE "^PrivateKey = [A-Za-z0-9+/]{43}=$" "$CONF_SRC" || die "配置缺 PrivateKey 或格式不对（应为 44 字符 base64）。是模板还是拿错文件了？"
    PUBKEY_LINE=$(grep "^PublicKey" "$CONF_SRC" | head -1)
    grep -qE "^PublicKey = [A-Za-z0-9+/]{43}=$" "$CONF_SRC" || die "配置缺 hub PublicKey 或格式不对，找管理员重新下发。"
    ok "配置文件有效（$PUBKEY_LINE）"

    grep -q "AllowedIPs.*192\.168\.0\.0/24" "$CONF_SRC" && die "配置的 AllowedIPs 含 192.168.0.0/24 —— 这是实机自己的本地网段，写进去会导致实机失联。找管理员重新下发。"

    $SUDO install -d -m 700 /etc/wireguard
    $SUDO install -m 600 "$CONF_SRC" "$WG_CONF"
    ok "配置安装到 $WG_CONF"
fi

# ---------- 4. 起隧道 ----------
step "4. 启用 wg-quick"
$SUDO systemctl enable --now wg-quick@wg0 2>&1 | grep -v "^Created symlink" || true
sleep 2
$SUDO systemctl is-active --quiet wg-quick@wg0 || die "wg-quick@wg0 启动失败。journalctl -u wg-quick@wg0 -n 20 查看原因"

check_handshake() { $SUDO wg show wg0 2>/dev/null | grep -q "latest handshake"; }
if check_handshake; then
    ok "handshake 已建立"
else
    warn "暂无 handshake（等 30s 再查一次）"
    sleep 30
    if check_handshake; then
        ok "handshake 已建立（延迟到达）"
    else
        warn "UDP 51820 无响应，尝试备用端口 443 ..."
        $SUDO sed -i 's|Endpoint = .*:51820|Endpoint = '"$HUB_PUB_IP"':443|' "$WG_CONF"
        $SUDO systemctl restart wg-quick@wg0
        sleep 8
        if check_handshake; then
            ok "备用端口 443 握手成功 —— 校园网封了 UDP 51820，已自动切换（看门狗会维持）"
        else
            # 切回 51820，让看门狗持续轮询两个端口
            $SUDO sed -i 's|Endpoint = .*:443|Endpoint = '"$HUB_PUB_IP"':51820|' "$WG_CONF"
            $SUDO systemctl restart wg-quick@wg0
            warn "两个端口都暂未握手（可能阿里云安全组还没放行 443/udp + 51820/udp）。看门狗会持续自动重试，也可稍后 wg show 查看"
        fi
    fi
fi

# ---------- 5. 网关职责：转发 + NAT ----------
step "5. 配置网关职责（让终端能穿过实机访问 192.168.0.x 的 PDU）"
echo 'net.ipv4.ip_forward = 1' | $SUDO tee /etc/sysctl.d/99-wg-forward.conf >/dev/null
$SUDO sysctl --system >/dev/null 2>&1
sysctl -n net.ipv4.ip_forward | grep -q 1 && ok "IP 转发已开启（持久化）"

LAB_IF=$(ip route get 192.168.0.163 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
[ -n "$LAB_IF" ] || die "找不到到 192.168.0.163 的路由——实机还没接入实验室网段？先完成 PDU 直连网卡配置（见 2-eSpur Deployment skill）"
ok "实验室出口网卡: $LAB_IF"

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-masquerade >/dev/null 2>&1
    $SUDO firewall-cmd --permanent --add-interface=wg0 2>/dev/null
    $SUDO firewall-cmd --reload >/dev/null
    ok "firewalld: masquerade + wg0 已加入 zone"
else
    if ! $SUDO iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "$LAB_IF" -j MASQUERADE 2>/dev/null; then
        $SUDO iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$LAB_IF" -j MASQUERADE
        if command -v netfilter-persistent >/dev/null 2>&1; then
            $SUDO netfilter-persistent save >/dev/null 2>&1
            ok "iptables masquerade 已加并持久化"
        else
            warn "iptables masquerade 已加（运行时）；建议安装 iptables-persistent 持久化"
        fi
    else
        ok "iptables masquerade 规则已存在"
    fi
fi

# ---------- 6. 看门狗（常驻自愈）----------
step "6. 安装看门狗（每 2 分钟体检隧道，断线自动重拨；51820 不通自动切 443）"
$SUDO tee /usr/local/bin/espur-mesh-watchdog.sh >/dev/null <<'WEOF'
#!/usr/bin/env bash
# eSpur mesh 隧道看门狗：无 handshake 超 3 分钟判定断线，先原地重拨，
# 再依次尝试 51820/443 双端口；恢复后停留在可用端口。
set -u
WG_CONF=/etc/wireguard/wg0.conf
HUB=47.237.111.211
STATE=/var/lib/espur-mesh-watchdog.state
LOGTAG=espur-mesh-watchdog

cur_port() { grep -oE 'Endpoint = [^ ]+' "$WG_CONF" | grep -oE '[0-9]+$'; }
set_port() {
    sed -i "s|Endpoint = [^ ]*|Endpoint = $HUB:$1|" "$WG_CONF"
    systemctl restart wg-quick@wg0 2>/dev/null
}
has_handshake() { wg show wg0 2>/dev/null | grep -q 'latest handshake'; }

# handshake 距今秒数（从未握过手则返回大数）
hs_age() {
    local ts
    ts=$(wg show wg0 latest-handshake 2>/dev/null)
    [ -n "$ts" ] && [ "$ts" != "0" ] && echo $(( $(date +%s) - ts )) || echo 999999
}

AGE=$(hs_age)
[ "$AGE" -lt 180 ] && exit 0     # 隧道健康，无事可做

logger -t "$LOGTAG" "no handshake for ${AGE}s, port=$(cur_port), recovering"
systemctl restart wg-quick@wg0 2>/dev/null
sleep 15
has_handshake && { logger -t "$LOGTAG" "recovered after restart"; exit 0; }

# 依次尝试另一个端口
for p in 51820 443; do
    [ "$p" = "$(cur_port)" ] && continue
    set_port "$p"
    sleep 15
    if has_handshake; then
        logger -t "$LOGTAG" "recovered on UDP $p (switched from $(cur_port 2>/dev/null))"
        echo "$p" > "$STATE"
        exit 0
    fi
done
logger -t "$LOGTAG" "still down on both ports; will retry next cycle"
WEOF
$SUDO chmod +x /usr/local/bin/espur-mesh-watchdog.sh
$SUDO tee /etc/systemd/system/${MESH_WATCHDOG}.service >/dev/null <<SVEOF
[Unit]
Description=eSpur mesh tunnel watchdog (auto-recover, dual-port failover)
After=wg-quick@wg0.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/espur-mesh-watchdog.sh
SVEOF
$SUDO tee /etc/systemd/system/${MESH_WATCHDOG}.timer >/dev/null <<TEOF
[Unit]
Description=Run eSpur mesh watchdog every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
TEOF
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now ${MESH_WATCHDOG}.timer >/dev/null 2>&1
$SUDO systemctl is-active --quiet ${MESH_WATCHDOG}.timer && ok "看门狗已启用（systemd timer，每 2 分钟）" || warn "看门狗 timer 未启动"

# ---------- 7. 最终体检 ----------
step "7. 最终体检"
echo
$SUDO wg show wg0
echo
if ping -c 3 -W 3 "$HUB_MESH_IP" >/dev/null 2>&1; then
    ok "ping $HUB_MESH_IP 通 —— 实机 ↔ hub 打通"
else
    warn "ping $HUB_MESH_IP 不通，看门狗会持续重试；若 10 分钟后仍不通按 troubleshooting.md 排查"
fi
echo
bold "完成。本机已配置：开机自动组网（wg-quick enable）+ 常驻看门狗（双端口自愈）。"
echo "  确认自启: systemctl is-enabled wg-quick@wg0 ${MESH_WATCHDOG}.timer"
echo "  查看状态: wg show wg0"
echo "  广州终端验证: ping $MY_MESH_IP / ping 192.168.0.163 / ssh <user>@$MY_MESH_IP"
