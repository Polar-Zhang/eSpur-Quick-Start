#!/bin/bash
# eSpur 模式切换（闸门方案：算法服务常驻，遥测/决策/上报不断，仅切换能力开关）
#   test = 放置 SWITCH_DISABLED 标记，PSU 切换被禁止（测试模式）
#   live = 移除标记，算法恢复真实切换（正式模式）
# 用法: sudo /usr/local/bin/espur-switch.sh test|live
set -u
MODE="${1:-}"
SVC=espur-algorithm
GATE="${ESPUR_GATE:-$HOME/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/SWITCH_DISABLED}"

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
    ;;
  *)
    if [ -f "$GATE" ]; then echo "当前: 测试模式（切换禁止）"; else echo "当前: 正式模式（切换允许）"; fi
    echo "用法: espur-switch.sh test|live"
    exit 1
    ;;
esac
