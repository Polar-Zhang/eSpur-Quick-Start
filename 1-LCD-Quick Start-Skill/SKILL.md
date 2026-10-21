---
name: waveshare-lcd-setup
description: 在树莓派 Raspberry Pi 4 + Raspberry Pi OS Lite (Debian 13 trixie) 上配置 Waveshare 2.4 寸 SPI LCD (ILI9341)，用 fbcp 把 HDMI 控制台镜像到 SPI 小屏并开机自启。当用户提到 SPI LCD、小屏幕、fbcp、2.4 寸屏、Waveshare LCD、树莓派接小屏/配屏、屏幕镜像、trixie 配置小屏、bcm_host、屏幕方向/字体调优 等任何相关话题时使用本 skill，包括初始化、重装、调参、排障。
---

# SPI LCD (fbcp) 配置

把 Waveshare 2.4 寸 SPI LCD 接到树莓派上，镜像 HDMI 控制台画面并开机自启。

## 实测适用环境（必须先核对）

| 项目 | 要求 | 说明 |
|---|---|---|
| 机型 | Raspberry Pi 4 Model B | 脚本强制检查；Pi 5 不可用（无传统 framebuffer，fbcp 路线不通） |
| 系统 | Raspberry Pi OS Lite, Debian 13 **trixie**, arm64 | 关键差异都针对 trixie；bullseye/bookworm 部分步骤不同 |
| 屏幕 | Waveshare 2.4inch LCD Module（ILI9341, 240×320） | 换屏要改 cmake 的 `-DWAVESHARE_*=ON` 目标 |
| 接线 | DIN→GPIO10, CLK→GPIO11, CS→GPIO8, DC→GPIO25, RST→GPIO27, BL→GPIO24, VCC→3.3V, GND→GND | 源码 `src/board/waveshare_2inch4_lcd.h` 定义 |
| 权限 | 免密 sudo（`/etc/sudoers.d/` 已配置） | setup.sh 必须以 root 运行 |

不满足时不要硬跑：先向用户说明差异，经确认后用 `sudo FORCE=1 bash setup.sh` 强制。

## 目录内容

```
waveshare-lcd-setup/
├── SKILL.md                 # 本文件
├── scripts/setup.sh         # 一键配置脚本（幂等，可重复运行）
└── assets/
    ├── libraspberrypi0_*.deb        # bcm_host 运行库（bookworm 官方存档包）
    ├── libraspberrypi-dev_*.deb     # bcm_host 头文件（同上）
    └── Waveshare_fbcp/              # fbcp-ili9341 驱动源码（已精简到编译所需）
```

完整原理、逐行解释、全部踩坑记录在同目录上层的 `~/LCD/SPI-LCD配置完全手册.md`，排障时先读它的"踩坑实录"一节。

## 执行流程

1. **环境自检**（不改动系统）：

   ```bash
   tr -d '\0' < /proc/device-tree/model      # 应为 Raspberry Pi 4 Model B...
   grep VERSION_CODENAME /etc/os-release     # 应为 trixie
   ls ~/LCD/waveshare-lcd-setup/assets/       # 应有 2 个 deb + Waveshare_fbcp/
   ```

2. **运行一键脚本**（约 2–3 分钟，含编译）：

   ```bash
   sudo bash ~/LCD/waveshare-lcd-setup/scripts/setup.sh
   ```

   脚本幂等：装依赖、把 bcm_host 部署到 /usr/local（**不要**用 dpkg 装，见坑 5/6）、开 SPI、改 `/boot/firmware/config.txt`（首次自动备份为 `.bak.lcd`）、设置控制台字体、以 180° 翻转编译 fbcp 装到 `/usr/local/bin/fbcp`、启用 systemd 服务 `fbcp.service`。

3. **重启**（SPI 和 config.txt 改动必须重启才生效）。重启会断开当前会话，执行前先告知用户。

4. **验证**：

   ```bash
   systemctl is-active fbcp        # 应为 active
   ls /dev/fb0 /dev/spidev0.0      # 两个设备节点都应存在
   journalctl -u fbcp -b --no-pager | tail   # 无报错
   ```

   SPI 屏应显示控制台（40 列 × 15 行，方向正、字清晰）。

## 调参速查（改完 `sudo reboot` 生效）

| 需求 | 操作 |
|---|---|
| 屏幕方向不对（SPI 屏） | 重编译：cmake 去掉/加上 `-DDISPLAY_ROTATE_180_DEGREES=ON`（改 setup.sh 后重跑） |
| HDMI 方向不对 | 改 config.txt 的 `display_rotate`（0/1/2/3）——注意它**只**影响 HDMI 侧 |
| 字太大/太小 | `sudo nano /etc/default/console-setup` 改 `FONTSIZE`（当前 16x32，改 12x24 更小更多行） |
| HDMI 分辨率 | 改 config.txt 的 `hdmi_cvt`——**不要**设为 320×240（与屏一致会让 HDMI 显示器不可用）；640×480 是小屏清晰度最优解（2:1 整数缩放） |
| 刷新率/花屏 | 调大 cmake 的 `-DSPI_BUS_CLOCK_DIVISOR`（如 40）重编译 |

镜像方案的固有约束：**两块屏共享同一个控制台字体**，小屏可读与 HDMI 字号正常不可兼得，当前参数是用户选定的"小屏优先"。

## 已知坑速查（详见手册"踩坑实录"）

1. config.txt 在 trixie 位于 `/boot/firmware/config.txt`，不是 `/boot/config.txt`
2. 没有 `/etc/rc.local`，自启必须用 systemd 服务
3. `sudo pip3 install` 被 PEP 668 禁止，Python 库一律 apt 安装
4. trixie 源里 userland（bcm_host）已删除，fbcp 编译会报 `bcm_host.h: No such file`
5. 从 bookworm 存档下 deb 用 dpkg 装 → `libdtovl.so.0` 文件冲突（撞系统包 libdtovl0）
6. 剔除冲突文件重打包再装 → 仍失败：libdtovl0 元数据声明 `Breaks: libraspberrypi0/dev`，dpkg 拒绝配置，且 apt 从此拒绝一切安装 → **唯一解：提取文件部署到 /usr/local**（setup.sh 已内置）
7. 半安装残留会让 apt 全挂 → `sudo dpkg --purge libraspberrypi-dev libraspberrypi0` 清掉
8. 官方 `shell/waveshare-2inch4` 脚本写死 `/home/pi`、旧路径、rc.local，在本环境必然失败，不要用
9. 必须注释 `dtoverlay=vc4-kms-v3d`（fbcp 靠传统固件 framebuffer；Pi4 内核 CONFIG_FB_BCM2708=y 已验证）
10. `display_rotate` 会连 HDMI 一起转，SPI 屏翻转只能用 fbcp 编译选项

## 卸载/回滚

```bash
sudo systemctl disable --now fbcp
sudo rm /etc/systemd/system/fbcp.service /usr/local/bin/fbcp
sudo rm -rf /usr/local/lib/libbcm_host* /usr/local/lib/libvchiq_arm* /usr/local/lib/libvcos* /usr/local/lib/libdebug_sym* /usr/local/include/bcm_host.h /usr/local/include/interface /usr/local/include/vc*
sudo cp /boot/firmware/config.txt.bak.lcd /boot/firmware/config.txt
sudo reboot
```
