#!/bin/bash
# eSpur 模式切换（闸门方案：算法服务常驻，遥测/决策/上报不断，仅切换能力开关）
#   test = 放置 SWITCH_DISABLED 标记，PSU 切换被禁止（测试模式）
#   live = 移除标记，算法恢复真实切换（正式模式）
# 用法: sudo /usr/local/bin/espur-switch.sh test
#       sudo /usr/local/bin/espur-switch.sh live [IP/前缀] [网关]
#   live 带 IP 参数时（业务 IP 由使用者提供），同时把上联 USB 网口配置为该 IP
set -u
MODE="${1:-}"
SVC=espur-algorithm
# 闸门路径按"真实登录用户"的家目录解析（sudo 下 $HOME=/root 会指错，曾致状态误报与 live 静默失效）
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
GATE="${ESPUR_GATE:-$REAL_HOME/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/SWITCH_DISABLED}"

systemctl enable "$SVC" >/dev/null 2>&1
systemctl start "$SVC"
case "$MODE" in
  test)
    touch "$GATE"
    echo "== 测试模式：切换已禁止（标记: $GATE），遥测/上报继续，服务 $(systemctl is-active $SVC)"
    ;;
  live)
    rm -f "$GATE"
    echo "== 正式模式：切换已开启（标记已移除），服务 $(systemctl is-active $SVC)"
    echo "   注意: 算法将按最小安全配置真实切换 PDU 端口（可能关闭冗余/空载口）"

    # 保底：可同时配置上联业务 IP（由使用者提供，本脚本不猜测）
    # 用法: live <IP/前缀> [网关]   —— 首次配置必须带网关；后续重配网关可省
    if [ "${2:-}" != "" ]; then
      ADDR="$2"; GW="${3:-}"
      UPLINK=$(ls /sys/class/net 2>/dev/null | grep -E "^enx" | head -1)
      [ -n "$UPLINK" ] || { echo "!! 未找到 USB 转接网口（enx*），跳过 IP 配置"; exit 1; }
      if nmcli -t -f NAME con show | grep -qx jifang; then
        nmcli con mod jifang connection.interface-name "$UPLINK" ipv4.addresses "$ADDR"
        [ -n "$GW" ] && nmcli con mod jifang ipv4.gateway "$GW"
      else
        [ -n "$GW" ] || { echo "!! 首次配置需要网关: live <IP/前缀> <网关>"; exit 1; }
        nmcli con add type ethernet ifname "$UPLINK" con-name jifang \
          ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" connection.autoconnect yes
      fi
      nmcli con up jifang >/dev/null 2>&1 \
        && echo "== 上联已配置: $UPLINK = $ADDR（网关 ${GW:-沿用原配置}）" \
        || echo "!! 上联配置激活失败（jifang），请检查网线/交换机"
    fi
    ;;
  *)
    if [ -f "$GATE" ]; then echo "当前: 测试模式（切换禁止）"; else echo "当前: 正式模式（切换允许）"; fi
    echo "用法: espur-switch.sh test | live [IP/前缀] [网关]"
    exit 1
    ;;
esac
