#!/usr/bin/env bash
# eSpur overlay 组网一键接入（学校实机侧）
# 用法: bash join_mesh.sh /path/to/lab-XX-wg0.conf
# 幂等：可重复运行。动作：装 wireguard → 出站预检 → 装配置 → 起隧道 → 开转发/NAT → 体检
set -u

CONF_SRC="${1:?用法: bash join_mesh.sh <wg0.conf 路径>（配置含私钥，向组网管理员获取）}"
HUB_PUB_IP="47.237.111.211"
HUB_MESH_IP="10.66.66.1"
MY_MESH_IP="10.66.66.101"
WG_CONF="/etc/wireguard/wg0.conf"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m: %s\n' "$*"; }
warn()  { printf '  \033[33m!!\033[0m: %s\n' "$*"; }
die()   { printf '  \033[31mFAIL\033[0m: %s\n' "$*" >&2; exit 1; }
step()  { bold "== $* =="; }

[ "$(id -u)" -eq 0 ] || SUDO="sudo"

echo "=============================================="
echo " eSpur overlay 组网一键接入 (lab → hub $HUB_PUB_IP)"
echo "=============================================="

# ---------- 0. 配置文件预检 ----------
step "0. 检查配置文件"
[ -f "$CONF_SRC" ] || die "配置文件不存在: $CONF_SRC。真实配置（含私钥）必须由组网管理员下发，仓库里的 template 只有占位符。"

grep -qE "^PrivateKey = [A-Za-z0-9+/]{43}=$" "$CONF_SRC" || die "配置缺 PrivateKey 或格式不对（应为 44 字符 base64）。是模板还是拿错文件了？向管理员要真实配置。"
PUBKEY_LINE=$(grep "^PublicKey" "$CONF_SRC" | head -1)
grep -qE "^PublicKey = [A-Za-z0-9+/]{43}=$" "$CONF_SRC" || die "配置缺 hub PublicKey 或格式不对，找管理员重新下发。"
ok "配置文件有效（$PUBKEY_LINE）"

grep -q "AllowedIPs.*192\.168\.0\.0/24" "$CONF_SRC" && die "配置的 AllowedIPs 含 192.168.0.0/24 —— 这是实机自己的本地网段，写进去会导致实机失联。找管理员重新下发。"

MESH_ADDR=$(grep "^Address" "$CONF_SRC" | head -1 | awk '{print $3}')
if [ -n "$MESH_ADDR" ] && [ "${MESH_ADDR%%/*}" != "$MY_MESH_IP" ]; then
    warn "配置的 mesh 地址是 $MESH_ADDR，本 skill 预期 lab 机器为 $MY_MESH_IP/24。继续执行，但请与管理员确认。"
fi

# ---------- 1. 安装 wireguard ----------
step "1. 安装 wireguard"
if command -v wg >/dev/null 2>&1 && ip link add wgprobe type wireguard 2>/dev/null; then
    ip link del wgprobe
    ok "wireguard 已可用 ($(wg --version))"
else
    if command -v dnf >/dev/null 2>&1; then
        # EPEL 需要时补装；fedora 镜像经常连不上，顺手切 aliyun 源
        dnf repolist 2>/dev/null | grep -q epel || $SUDO dnf install -y epel-release
        $SUDO sed -i -e 's|^metalink=|#metalink=|' -e 's|^#baseurl=|baseurl=|' \
            -e 's|download.example/pub/epel|mirrors.aliyun.com/epel|' /etc/yum.repos.d/epel*.repo 2>/dev/null
        $SUDO dnf install -y wireguard-tools || die "dnf 装 wireguard-tools 失败，手动排查 yum 源"
    elif command -v apt >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y wireguard || die "apt 装 wireguard 失败，手动排查 apt 源"
    else
        die "未识别的包管理器（需要 dnf 或 apt），手动安装 wireguard-tools 后重跑"
    fi
    ok "wireguard-tools 安装完成"
fi
# 内核模块：≥5.6 自带，老内核提示但不硬拦
KERNEL_MINOR="${KERNEL_MINOR:-$(uname -r | cut -d. -f1-2)}"
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
    warn "ICMP 不通——可能被禁 ping，不必然失败，继续（若最终无 handshake 回来查这里）"
fi
if command -v nc >/dev/null 2>&1 || $SUDO sh -c 'command -v dnf >/dev/null && dnf install -y nmap-ncat || apt-get install -y netcat-openbsd' >/dev/null 2>&1; then
    if nc -u -z -w 3 "$HUB_PUB_IP" 51820 >/dev/null 2>&1; then
        ok "UDP 51820 出站可达"
    else
        warn "UDP 51820 探测无响应（校园网限 UDP 的典型信号）。先继续装，若最终无 handshake 按 troubleshooting.md 切 UDP 443 或 wstunnel"
    fi
fi

# ---------- 3. 安装配置并起隧道 ----------
step "3. 安装配置并启用 wg-quick"
$SUDO install -d -m 700 /etc/wireguard
$SUDO install -m 600 "$CONF_SRC" "$WG_CONF"
$SUDO systemctl enable --now wg-quick@wg0 2>&1 | grep -v "^Created symlink" || true
sleep 2
$SUDO systemctl is-active --quiet wg-quick@wg0 || die "wg-quick@wg0 启动失败。journalctl -u wg-quick@wg0 -n 20 查看原因"

if $SUDO wg show wg0 2>/dev/null | grep -q "latest handshake"; then
    ok "handshake 已建立"
else
    warn "暂无 handshake（等 30s 再查一次）"
    sleep 30
    $SUDO wg show wg0 2>/dev/null | grep -q "latest handshake" \
        && ok "handshake 已建立（延迟到达）" \
        || warn "仍无 handshake —— 8 成是 UDP 被拦或阿里云安全组未放行 51820/udp，按 references/troubleshooting.md 处理"
fi

# ---------- 4. 网关职责：转发 + NAT ----------
step "4. 配置网关职责（让终端能穿过实机访问 192.168.0.x 的 PDU）"
# 4a. IP 转发（持久化）
echo 'net.ipv4.ip_forward = 1' | $SUDO tee /etc/sysctl.d/99-wg-forward.conf >/dev/null
$SUDO sysctl --system 2>/dev/null | grep -q "ip_forward = 1" && ok "IP 转发已开启（持久化到 /etc/sysctl.d/99-wg-forward.conf）" \
    || { $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null; ok "IP 转发已开启（运行时）"; }

# 4b. 找到实验室网段的出口网卡（192.168.0.x 的路由设备）
LAB_IF=$(ip route get 192.168.0.163 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
[ -n "$LAB_IF" ] || die "找不到到 192.168.0.163 的路由——实机还没接入实验室网段？先完成 PDU 直连网卡的静态 IP 配置（见 2-eSpur Deployment skill）"
ok "实验室出口网卡: $LAB_IF"

# 4c. NAT：按防火墙类型自适应
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-masquerade >/dev/null 2>&1
    $SUDO firewall-cmd --permanent --add-interface=wg0 2>/dev/null
    $SUDO firewall-cmd --reload >/dev/null
    ok "firewalld: masquerade + wg0 已加入 zone"
else
    # 裸 iptables：只加 mesh 源的规则，幂等（-C 检查）
    if ! $SUDO iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "$LAB_IF" -j MASQUERADE 2>/dev/null; then
        $SUDO iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$LAB_IF" -j MASQUERADE
        # 持久化（有 netfilter-persistent 则存，没有则提示）
        if command -v netfilter-persistent >/dev/null 2>&1; then
            $SUDO netfilter-persistent save >/dev/null 2>&1
            ok "iptables masquerade 已加并持久化"
        else
            warn "iptables masquerade 已加（运行时）；安装 iptables-persistent 或写入 rc 脚本可持久化"
        fi
    else
        ok "iptables masquerade 规则已存在"
    fi
fi

# ---------- 5. 最终体检 ----------
step "5. 最终体检"
echo
$SUDO wg show wg0
echo
if ping -c 3 -W 3 "$HUB_MESH_IP" >/dev/null 2>&1; then
    ok "ping $HUB_MESH_IP 通 —— 实机 ↔ hub 打通"
else
    warn "ping $HUB_MESH_IP 不通，见上方 handshake 状态与 references/troubleshooting.md"
fi
echo
bold "完成。请广州终端（或任一已入网设备）验证："
echo "  ping 10.66.66.101        # → 实机"
echo "  ping 192.168.0.163       # → PDU（走实机转发）"
echo "  ssh <user>@10.66.66.101  # 直达实机"
echo "  浏览器 http://192.168.0.163  # PDU Web"
