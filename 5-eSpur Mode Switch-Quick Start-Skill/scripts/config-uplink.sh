#!/usr/bin/env bash
# eSpur 上联业务口配置（待接入态）
# 业务 IP 由用户提供，本脚本只把给定值写入 USB 转接网口的 profile——绝不猜测/自动分配。
# 用法: sudo ./config-uplink.sh <接口名> <IP/前缀> <网关> [DNS]
#   例: sudo ./config-uplink.sh enx9c8e99abcd12 10.123.4.246/22 10.123.7.254
# 幂等：profile 已存在则更新（IP 变更时重跑即可）。配置后处于待接入态，
#       网线接入机房交换机自动启用。
set -euo pipefail

IFACE="${1:?用法: config-uplink.sh <接口名> <IP/前缀> <网关> [DNS]}"
ADDR="${2:?缺少业务 IP/前缀（由用户提供）}"
GW="${3:?缺少网关（由用户提供）}"
DNS="${4:-223.5.5.5 119.29.29.29}"
CON_NAME=jifang

[[ $UID -eq 0 ]] || { echo "请用 sudo 运行（nmcli 需要权限）"; exit 1; }

if nmcli -t -f NAME con show | grep -qx "$CON_NAME"; then
  nmcli con mod "$CON_NAME" \
    connection.interface-name "$IFACE" \
    ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ipv4.dns "$DNS"
else
  nmcli con add type ethernet ifname "$IFACE" con-name "$CON_NAME" \
    ipv4.method manual ipv4.addresses "$ADDR" ipv4.gateway "$GW" ipv4.dns "$DNS"
fi
nmcli con mod "$CON_NAME" connection.autoconnect yes

echo "== 已配置（待接入态）=="
echo "  接口: $IFACE = $ADDR, 网关 $GW, DNS $DNS"
echo "  网线接入交换机后自动启用；验收: ip -4 addr show $IFACE && ping -c3 neowatt.cn"
