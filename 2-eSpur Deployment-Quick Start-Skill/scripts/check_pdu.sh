#!/usr/bin/env bash
# eSpur PDU 体检（只读，绝不改端口状态）
# 用法: bash check_pdu.sh [pdu_ip]
# 串行低速探测，避免打挂 PDU 网口
set -u
PDU="${1:-192.168.0.163}"
SRC_EXPECT="192.168.0."

fail=0

echo "== 1. 路由与源地址 =="
route_line=$(ip route get "$PDU" 2>/dev/null | head -1)
echo "$route_line"
if echo "$route_line" | grep -q "dev eth0"; then
    src=$(echo "$route_line" | grep -o 'src [0-9.]*' | awk '{print $2}')
    if [ -n "${src:-}" ] && [ "${src#"$SRC_EXPECT"}" != "$src" ]; then
        echo "   OK: 经 eth0 且源地址 $src 在 ${SRC_EXPECT}x 网段"
    else
        echo "   !! 源地址 $src 不在 ${SRC_EXPECT}x 网段，PDU 的 ACL 会丢弃所有请求"
        echo "      修: 确认 eth0 静态 192.168.0.200/24 (netplan) 后 sudo netplan apply"
        fail=1
    fi
else
    echo "   !! 未走 eth0（PDU 网线直连 eth0）"
    fail=1
fi

echo "== 2. ARP =="
if ip neigh | grep -q "$PDU.*lladdr"; then
    echo "   OK: $(ip neigh | grep "$PDU" | head -1)"
else
    echo "   !! 无 ARP 表项（链路或对端问题）"
    fail=1
fi

sleep 1
echo "== 3. SNMP sysDescr =="
out=$(snmpget -v1 -c public -t 5 -r 1 "$PDU" .1.3.6.1.2.1.1.1.0 2>&1)
if echo "$out" | grep -q 'switched-pdu'; then
    echo "   OK: $out"
else
    echo "   !! $out"
    fail=1
fi

sleep 1
echo "== 4. 全树 walk（eSpur 取数路径）=="
t0=$(date +%s.%N)
out=$(snmpwalk -v1 -c public -t 10 -r 1 "$PDU" .1.3.6.1.4.1.23273 2>&1)
t1=$(date +%s.%N)
if echo "$out" | grep -q '2.1.1.0'; then
    echo "   OK: walk 耗时 $(echo "$t1 $t0" | awk '{printf "%.2f", $1-$2}')s"
    echo "   电压: $(echo "$out" | grep '23273.2.2.1.0' | awk '{print $NF}') V"
    echo "   总电流: $(echo "$out" | grep '23273.2.2.2.0' | awk '{printf "%.2f", $NF/100}') A"
    echo "   端口继电器:"
    for n in 1 2 3 4 5 6 7 8; do
        st=$(echo "$out" | grep "23273.2.4.$n.0" | sed 's/.*: //')
        cur=$(echo "$out" | grep "23273.2.3.$n.0" | awk '{printf "%.2f", $NF/100}')
        echo "     口$n: $st  电流 ${cur}A"
    done
else
    echo "   !! $out"
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "== 结论: PDU 健康 =="
else
    echo "== 结论: 异常，按 references/troubleshooting.md 排查（先看第 1 步的路由源地址）=="
fi
exit $fail
