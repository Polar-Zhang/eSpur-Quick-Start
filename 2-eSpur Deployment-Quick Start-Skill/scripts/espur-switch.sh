#!/bin/bash
# eSpur 算法模式切换：test=测试模式(停算法+全部端口ON) / live=正式模式(算法接管节能优化)
# 用法: sudo /usr/local/bin/espur-switch.sh test|live
set -u
MODE="${1:-}"
SVC=espur-algorithm
PDU=192.168.0.163

case "$MODE" in
  test)
    systemctl stop "$SVC" 2>/dev/null
    systemctl disable "$SVC" >/dev/null 2>&1
    echo "-- 已停止算法并禁用自启，正在逐口恢复 ON(约8秒)..."
    for n in 1 2 3 4 5 6 7 8; do
      snmpset -v1 -c private -t 5 -r 1 "$PDU" ".1.3.6.1.4.1.23273.2.4.$n.0" s ON >/dev/null 2>&1
      sleep 1
    done
    echo "== 测试模式已生效，8 口继电器状态:"
    snmpwalk -v1 -c public -t 5 -r 1 "$PDU" .1.3.6.1.4.1.23273.2.4 2>/dev/null | sed 's/.*23273.2.4.//;s/ = STRING: /  /'
    ;;
  live)
    systemctl enable "$SVC" >/dev/null 2>&1
    systemctl restart "$SVC"
    sleep 3
    echo "== 正式模式已生效: 算法 $(systemctl is-active "$SVC")（enabled 自启）"
    echo "   注意: 算法将按最小安全配置自主管理端口，可能关闭冗余/空载端口"
    echo "   日志: tail -f ~/eSpur/eSpur-deployment/192.168.0.163_1-2-3-4/eSpur_v2/algorithm_stdout.log"
    ;;
  *)
    echo "用法: espur-switch.sh test|live"
    exit 1
    ;;
esac
