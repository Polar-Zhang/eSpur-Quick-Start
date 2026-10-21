#!/bin/bash
# =====================================================================
# Waveshare 2.4inch SPI LCD (ILI9341, 240x320) + fbcp 镜像 - 一键配置
#
# 实测适用环境 (其他环境未验证, 强制运行可加 FORCE=1):
#   机型:   Raspberry Pi 4 Model B Rev 1.2
#   系统:   Raspberry Pi OS Lite (Debian 13 trixie, arm64, 内核 6.18)
#   屏幕:   Waveshare 2.4inch LCD Module, ILI9341, SPI 接线:
#           DIN->GPIO10(MOSI,物理19) CLK->GPIO11(SCLK,物理23) CS->GPIO8(CE0,物理24)
#           DC->GPIO25(物理22) RST->GPIO27(物理13) BL->GPIO24(物理18) VCC->3.3V GND->GND
#
# 用法:  sudo bash setup.sh          (在本 skill 的 scripts/ 目录下)
#        sudo FORCE=1 bash setup.sh  (机型/系统不完全匹配时强制)
#
# 本脚本完成: 清理半安装残留 -> 装依赖 -> 部署 bcm_host 到 /usr/local ->
#   开 SPI -> 配置 /boot/firmware/config.txt 与控制台字体 ->
#   编译安装 fbcp(含 180° 翻转) -> systemd 自启服务。全程幂等, 可重复运行。
# 完成后需重启生效。
#
# 关键背景 (为什么这么做, 详见 skill 上层的 SPI-LCD配置完全手册.md):
#   - trixie 移除了 libraspberrypi-*(bcm_host), 且 libdtovl0 声明 Breaks 它们,
#     无法用 dpkg 安装 -> 从 assets/ 的 bookworm 官方存档包提取文件部署到 /usr/local
#   - trixie 无 /etc/rc.local -> systemd 服务
#   - fbcp 依赖传统固件 framebuffer -> 必须屏蔽 vc4-kms-v3d (Pi4 内核仍内建支持)
#   - SPI 屏 180° 翻转用 fbcp 编译选项处理, display_rotate 保持 0 以免连 HDMI 一起转
# =====================================================================
set -e

FORCE=${FORCE:-0}
REAL_USER=${SUDO_USER:-$(id -un)}
REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$SCRIPT_DIR/../assets" && pwd)"
DEB_RT=$(ls "$ASSETS"/libraspberrypi0_*-1_arm64.deb 2>/dev/null | head -1)
DEB_DEV=$(ls "$ASSETS"/libraspberrypi-dev_*-1_arm64.deb 2>/dev/null | head -1)
FB_SRC="$ASSETS/Waveshare_fbcp"
CONF=/boot/firmware/config.txt

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行: sudo bash $0"
    exit 1
fi

echo '==> [0/6] 环境检查'
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)
echo "    机型: $MODEL / 用户: $REAL_USER"
if [ "$FORCE" != "1" ]; then
    echo "$MODEL" | grep -q 'Raspberry Pi 4' || { echo '!! 本脚本仅在 Pi 4 上验证过, 其他机型请确认后加 FORCE=1 运行'; exit 1; }
    grep -q 'trixie' /etc/os-release || { echo '!! 本脚本仅在 trixie 上验证过, 其他版本请确认后加 FORCE=1 运行'; exit 1; }
fi
[ -n "$DEB_RT" ] && [ -n "$DEB_DEV" ] && [ -d "$FB_SRC" ] || { echo "!! assets 不完整 (缺 deb 或 Waveshare_fbcp 源码): $ASSETS"; exit 1; }

echo '==> [1/6] 清理历史遗留的半安装包, 恢复 apt 健康'
# 若曾尝试用 dpkg 装 libraspberrypi-*, 会因 libdtovl0 的 Breaks 停在"已解包未配置",
# 且 apt 会因此拒绝一切安装; 先清掉 (没装过则无操作)
dpkg --purge libraspberrypi-dev libraspberrypi0 2>/dev/null || true
dpkg --configure -a || true

echo '==> [2/6] 安装依赖 (cmake / 编译工具)'
# DPkg::Lock::Timeout: 若后台 apt 任务占锁则最多等待 300 秒而不是立刻报错
apt-get -o DPkg::Lock::Timeout=300 update
# 早期失败尝试可能覆盖过 libdtovl.so.0, 重装确保系统包完整
apt-get -o DPkg::Lock::Timeout=300 install --reinstall -y libdtovl0
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y cmake

echo '==> [3/6] 部署 bcm_host 开发库到 /usr/local'
# fbcp 编译需要 bcm_host.h / libbcm_host.so (DISPMANX 抓屏).
# trixie 删除了 libraspberrypi-* 包且 libdtovl0 声明 Breaks, 无法用 dpkg 安装,
# 改为从 assets 的 bookworm 官方存档包提取文件直接部署到 /usr/local:
#   - 运行库 -> /usr/local/lib (ldconfig 默认搜索路径)
#   - 头文件 -> /usr/local/include
# libdtovl.so.0 不部署 (系统 libdtovl0 已提供, fbcp 不使用)
rm -rf /tmp/bcmhost && mkdir -p /tmp/bcmhost/rt /tmp/bcmhost/dev
dpkg-deb -x "$DEB_RT" /tmp/bcmhost/rt
dpkg-deb -x "$DEB_DEV" /tmp/bcmhost/dev
mkdir -p /usr/local/lib /usr/local/include
for f in libbcm_host libdebug_sym libvchiq_arm libvcos; do
    cp -a "/tmp/bcmhost/rt/usr/lib/aarch64-linux-gnu/${f}.so.0" /usr/local/lib/
    ln -sf "${f}.so.0" "/usr/local/lib/${f}.so"
done
cp -a /tmp/bcmhost/dev/usr/include/. /usr/local/include/
rm -rf /tmp/bcmhost
ldconfig

echo '==> [4/6] 开启 SPI, 配置 /boot/firmware/config.txt 与控制台字体'
raspi-config nonint do_spi 0
# 首次运行时备份
[ -f "${CONF}.bak.lcd" ] || cp "${CONF}" "${CONF}.bak.lcd"
# 屏蔽 KMS 驱动, 让系统回落到传统固件 framebuffer (fbcp 依赖它; Pi4 内核 CONFIG_FB_BCM2708=y)
sed -i 's/^dtoverlay=vc4-kms-v3d$/#dtoverlay=vc4-kms-v3d/' "${CONF}"
sed -i 's/^max_framebuffers=2$/#max_framebuffers=2/' "${CONF}"
# 确保 SPI 开启 (raspi-config 已处理, 双重保险)
grep -q '^dtparam=spi=on' "${CONF}" || echo 'dtparam=spi=on' >> "${CONF}"
# HDMI 输出 640x480@60 + 16x32 字体 = "小屏优先"方案:
# fbcp 以 2:1 整数缩放到 SPI 屏, 小屏字形约 16 物理像素, 最清晰; HDMI 字号约为默认 2 倍
# 注意: display_rotate 保持 0 (它同时作用于 HDMI, 会把显示器也转倒),
# SPI 小屏的 180° 翻转由下一步 fbcp 编译选项 DISPLAY_ROTATE_180_DEGREES 处理
if grep -q '^hdmi_cvt' "${CONF}"; then
    # 已有配置则强制归一化, 保证重跑脚本即可更新参数
    sed -i 's/^hdmi_cvt=.*/hdmi_cvt=640 480 60 6 0 0 0/' "${CONF}"
    sed -i 's/^display_rotate=.*/display_rotate=0/' "${CONF}"
else
cat >> "${CONF}" <<'EOF'

# ==== Waveshare 2.4inch SPI LCD (fbcp) ====
hdmi_force_hotplug=1
max_usb_current=1
hdmi_group=2
hdmi_mode=1
hdmi_mode=87
hdmi_cvt=640 480 60 6 0 0 0
hdmi_drive=2
display_rotate=0
EOF
fi
# 控制台字体: TerminusBold 16x32, 640x480 下 40 列 x 15 行, SPI 小屏上有效字形约 16 物理像素
sed -i 's/^FONTFACE=.*/FONTFACE="TerminusBold"/; s/^FONTSIZE=.*/FONTSIZE="16x32"/' /etc/default/console-setup

echo '==> [5/6] 编译 fbcp 并配置 systemd 开机自启动 (替代已废弃的 /etc/rc.local)'
cd "$FB_SRC"
rm -rf build
mkdir build && cd build
# DISPLAY_ROTATE_180_DEGREES=ON: SPI 小屏画面转 180° (HDMI 不受影响)
cmake -DSPI_BUS_CLOCK_DIVISOR=20 -DWAVESHARE_2INCH4_LCD=ON \
      -DBACKLIGHT_CONTROL=ON -DSTATISTICS=0 -DDISPLAY_ROTATE_180_DEGREES=ON \
      -DCMAKE_C_FLAGS=-I/usr/local/include \
      -DCMAKE_CXX_FLAGS=-I/usr/local/include \
      -DCMAKE_EXE_LINKER_FLAGS=-L/usr/local/lib ..
make -j"$(nproc)"
install -m 755 fbcp /usr/local/bin/fbcp

cat > /etc/systemd/system/fbcp.service <<'EOF'
[Unit]
Description=Mirror framebuffer to Waveshare 2.4inch SPI LCD (fbcp)
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/fbcp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable fbcp.service

echo '==> [6/6] 收尾'
# 脚本以 root 运行, 归还文件属主
chown -R "$REAL_USER:$REAL_GROUP" "$SCRIPT_DIR/.."

echo
echo '===================================================='
echo ' 全部完成! 请重启: sudo reboot'
echo ' 重启后验证: systemctl status fbcp'
echo ' 恢复原配置: sudo cp /boot/firmware/config.txt.bak.lcd /boot/firmware/config.txt'
echo '===================================================='
