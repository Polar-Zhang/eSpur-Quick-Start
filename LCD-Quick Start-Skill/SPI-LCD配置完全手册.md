# 树莓派 SPI LCD（fbcp 镜像）配置完全手册

> **适用环境**（本手册全程在此环境实测通过，2026-10-16）：
> - 机型：**Raspberry Pi 4 Model B Rev 1.2**（4 核 ARMv8，arm_64bit=1）
> - 系统：**Raspberry Pi OS Lite**（Debian 13 **trixie**，内核 6.18.50+rpt-rpi-v8，约 500M 无桌面镜像）
> - 屏幕：**Waveshare 2.4inch LCD Module**（ILI9341 控制器，240×320，SPI 接口）
> - 参考链接：https://www.waveshare.net/wiki/2.4inch_LCD_Module （老教程基于 Bullseye，大量步骤已过时，本文全部更新）
>
> 配套文件：`~/LCD/waveshare-lcd-setup/` 是标准化 skill（含一键脚本 `scripts/setup.sh`，机器人和人都可以直接用它完成全流程）。本文是**手动**逐步配置的完整说明，含每一步的原因、细节和踩坑实录。

---

## 1. 硬件与接线

| LCD 引脚 | 树莓派 BCM GPIO | 物理引脚 | 说明 |
|---|---|---|---|
| VCC | 3.3V | 1 | **必须 3.3V**，接 5V 可能烧屏 |
| GND | GND | 6 | |
| DIN | GPIO10 (MOSI) | 19 | SPI 数据 |
| CLK | GPIO11 (SCLK) | 23 | SPI 时钟 |
| CS | GPIO8 (CE0) | 24 | SPI 片选 |
| DC | GPIO25 | 22 | 数据/命令选择 |
| RST | GPIO27 | 13 | 复位 |
| BL | GPIO24 | 18 | 背光 |

引脚定义来自驱动源码 `assets/Waveshare_fbcp/src/board/waveshare_2inch4_lcd.h`（`GPIO_TFT_DATA_CONTROL 25`、`GPIO_TFT_BACKLIGHT 24`、`GPIO_TFT_RESET_PIN 27`）。

## 2. 原理：fbcp 镜像架构

```
┌──────────────────────────── 树莓派 ────────────────────────────┐
│                                                                │
│  控制台 ──> HDMI framebuffer (/dev/fb0, 640×480)               │
│                │                                               │
│                │ bcm_host DISPMANX 快照 (GPU 侧抓屏)            │
│                ▼                                               │
│            fbcp 进程 (缩放 2:1 + 180° 翻转 + DMA)               │
│                │                                               │
│                ▼                                               │
│        /dev/spidev0.0 + GPIO25/24/27 ──杜邦线──> ILI9341 小屏    │
│                                          (320×240 横向显示)      │
└────────────────────────────────────────────────────────────────┘
```

关键认知：

1. **小屏不是独立的显示设备**，它是 HDMI 画面的"镜子"。两块屏共享同一个 framebuffer 和同一套控制台字体——这就是后文"字号取舍"问题的根源。
2. fbcp 抓屏用的是 **DISPMANX**（VideoCore 固件接口），属于"传统显示栈"。trixie 默认启用的 KMS 驱动（`vc4-kms-v3d`）与它不兼容，所以必须屏蔽 KMS，回落到传统固件 framebuffer。Pi 4 的 trixie 内核仍内建支持（`CONFIG_FB_BCM2708=y`，已验证）；**Pi 5 砍掉了传统栈，此路线不通**。
3. 屏幕以横向 320×240 使用（原生 240×320 竖屏转横），HDMI 640×480 与之同为 4:3，2:1 整数缩放最清晰。

## 3. 手动配置全流程

以下命令全部通过 SSH 执行，需要 root 的用 sudo。

### 步骤 0：环境确认

```bash
tr -d '\0' < /proc/device-tree/model   # Raspberry Pi 4 Model B Rev 1.2
grep VERSION_CODENAME /etc/os-release  # VERSION_CODENAME=trixie
```

不是这个组合时，本文的坑位会不一样（尤其 Pi 5 / 非 trixie），先停下来评估。

### 步骤 1：安装依赖

```bash
sudo apt update
sudo apt install -y cmake
```

就这些。**注意与老教程的差异**：

- 老教程装 BCM2835 库、WiringPi——fbcp 编译完全不需要它们（那是给官方 C 测试例程用的）。WiringPi 已停止维护，直接跳过。
- 老教程的 `sudo pip3 install RPi.GPIO spidev` 在 trixie 上被 **PEP 668** 禁止（报 `externally-managed-environment`）。若要跑 Python 例程，改用 apt：`sudo apt install -y python3-pil python3-numpy python3-spidev python3-rpi.gpio`。
- 若想跑官方 C 例程，trixie 上用 lgpio：`sudo apt install -y liblgpio-dev`，再把例程 Makefile 的 `USELIB` 改为 `USE_LGPIO`。

### 步骤 2：部署 bcm_host 库到 /usr/local（本方案最关键的一步）

fbcp 的 `gpu.cpp` 第一行 `#include <bcm_host.h>`——DISPMANX 抓屏接口。**trixie 软件源把整个 `libraspberrypi-*`（userland）系列包删了**，apt 装不到；而用 dpkg 装 bookworm 存档包又有两重坑（文件冲突 + Breaks 声明，详见踩坑实录 5/6）。**唯一可行解：从存档包里把文件抠出来直接放到 /usr/local**（Linux 放发行版外软件的标准位置，不进 dpkg 数据库，永不和系统包冲突）：

```bash
# 两个包已在 ~/LCD/waveshare-lcd-setup/assets/，也可自行下载:
# http://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-userland/
#   libraspberrypi0_2+git20231018~131943+3c97f76-1_arm64.deb      (运行库)
#   libraspberrypi-dev_2+git20231018~131943+3c97f76-1_arm64.deb   (头文件)
A=~/LCD/waveshare-lcd-setup/assets
mkdir -p /tmp/bcmhost/rt /tmp/bcmhost/dev /usr/local/lib /usr/local/include
dpkg-deb -x $A/libraspberrypi0_*-1_arm64.deb /tmp/bcmhost/rt
dpkg-deb -x $A/libraspberrypi-dev_*-1_arm64.deb /tmp/bcmhost/dev
for f in libbcm_host libdebug_sym libvchiq_arm libvcos; do
    sudo cp -a "/tmp/bcmhost/rt/usr/lib/aarch64-linux-gnu/${f}.so.0" /usr/local/lib/
    sudo ln -sf "${f}.so.0" "/usr/local/lib/${f}.so"
done
sudo cp -a /tmp/bcmhost/dev/usr/include/. /usr/local/include/
sudo ldconfig && rm -rf /tmp/bcmhost
```

注意 **`libdtovl.so.0` 故意不部署**（循环里没有它）：系统包 `libdtovl0` 已提供它，重复放会引发冲突（踩坑实录 5）。fbcp 不使用 libdtovl。

验证：`ldconfig -p | grep bcm_host` 应看到 `/usr/local/lib/libbcm_host.so.0`。

### 步骤 3：开启 SPI

```bash
sudo raspi-config nonint do_spi 0    # 免交互；等价于菜单里 Interfacing Options -> SPI -> Yes
```

重启后 `/dev/spidev0.0` 出现才算生效。

### 步骤 4：修改 /boot/firmware/config.txt

> **路径坑**：trixie 上是 `/boot/firmware/config.txt`，老教程写的 `/boot/config.txt` 是软链接时代的旧路径。

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak.lcd   # 先备份！
sudo nano /boot/firmware/config.txt
```

注释掉这两行（屏蔽 KMS，回落传统 framebuffer）：

```text
#dtoverlay=vc4-kms-v3d
#max_framebuffers=2
```

确认 SPI 开启（步骤 3 已自动加）：`dtparam=spi=on`。

在文件**末尾**追加：

```text
# ==== Waveshare 2.4inch SPI LCD (fbcp) ====
hdmi_force_hotplug=1     # 无显示器也强制产生 HDMI framebuffer (fbcp 的画面来源)
max_usb_current=1
hdmi_group=2             # DMT (计算机显示器) 分组
hdmi_mode=1
hdmi_mode=87             # 87 = 使用自定义 CVT 分辨率
hdmi_cvt=640 480 60 6 0 0 0   # 640×480@60: 与小屏 4:3 同比例, 2:1 整数缩放最清晰
hdmi_drive=2
display_rotate=0         # 只影响 HDMI! 保持 0, 小屏翻转由 fbcp 编译选项处理(见步骤5)
```

### 步骤 5：编译 fbcp（含小屏 180° 翻转）

```bash
cd ~/LCD/waveshare-lcd-setup/assets/Waveshare_fbcp
rm -rf build && mkdir build && cd build
cmake -DSPI_BUS_CLOCK_DIVISOR=20 -DWAVESHARE_2INCH4_LCD=ON \
      -DBACKLIGHT_CONTROL=ON -DSTATISTICS=0 -DDISPLAY_ROTATE_180_DEGREES=ON \
      -DCMAKE_C_FLAGS=-I/usr/local/include \
      -DCMAKE_CXX_FLAGS=-I/usr/local/include \
      -DCMAKE_EXE_LINKER_FLAGS=-L/usr/local/lib ..
make -j$(nproc)
sudo install -m 755 fbcp /usr/local/bin/fbcp
```

cmake 参数说明：

| 参数 | 含义 |
|---|---|
| `SPI_BUS_CLOCK_DIVISOR=20` | SPI 时钟 = core_freq/20（约 20–25MHz）。花屏/不稳定就调大（40 更稳但更慢） |
| `WAVESHARE_2INCH4_LCD=ON` | 目标屏 2.4 寸（决定引脚、初始化序列、240×320） |
| `BACKLIGHT_CONTROL=ON` | fbcp 接管背光 |
| `STATISTICS=0` | 关闭统计输出 |
| `DISPLAY_ROTATE_180_DEGREES=ON` | **小屏画面转 180°**。为什么不用 display_rotate=2？因为它转的是 framebuffer，HDMI 显示器会跟着倒；这个编译选项只翻转 SPI 输出 |
| 三个路径参数 | 指向步骤 2 部署的 /usr/local 头文件和库 |

### 步骤 6：systemd 开机自启动

> **坑**：trixie 没有 `/etc/rc.local`（老教程"在 exit 0 前加 fbcp&"作废）。手工创建 rc.local 虽然可行，但标准做法是 systemd 服务：

```bash
sudo tee /etc/systemd/system/fbcp.service > /dev/null <<'EOF'
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
sudo systemctl daemon-reload && sudo systemctl enable fbcp.service
```

### 步骤 7：控制台字体（小屏可读的关键）

```bash
sudo nano /etc/default/console-setup
# 修改/添加:
FONTFACE="TerminusBold"
FONTSIZE="16x32"
```

**为什么**：默认 8×16 字体在 640×480 framebuffer 上，缩到小屏只剩约 4×8 物理像素，必然看不清。16×32 缩放后小屏字形约 16 物理像素（约 2.4mm 高），清晰可读。Terminus 字体系统自带（console-setup-linux 包），命名规则是"高x宽"，16×32 已是最大。

### 步骤 8：重启并验证

```bash
sudo reboot
# 重启后:
systemctl is-active fbcp          # active
ls /dev/fb0 /dev/spidev0.0        # 都存在
journalctl -u fbcp -b | tail      # 无报错
```

小屏应显示 40 列 × 15 行控制台，方向正、字清晰。

### （可选）官方显示测试例程

用于单独验证接线（不依赖 fbcp）。从 wiki 下载：`https://www.waveshare.net/w/upload/a/a8/LCD_Module_RPI_code.7z`（约 9.3M），`sudo apt install -y p7zip-full` 后解压。C 例程在 trixie 上需将 Makefile 的 `USELIB` 改为 `USE_LGPIO`；Python 例程直接 `sudo python3 python/example/2inch4_LCD_test.py`。

## 4. 参数调优速查

**分辨率 × 字体权衡表**（镜像方案两屏共享一套字体，不可兼得）：

| 方案 | 小屏字形(物理px) | HDMI 字号 | 备注 |
|---|---|---|---|
| 640×480 + 16×32（**当前，用户选定"小屏优先"**） | ~16，最清晰(2:1整数缩放) | 默认的约 2 倍 | |
| 800×600 + 16×32 | ~13 | 默认的约 1.6 倍 | |
| 800×600 + 12×24 | ~10 | ≈默认 | 小屏基本看不清 |
| 320×240 + 任意 | 1:1 原生 | — | **禁用**：HDMI 显示器会不可用（用户明确要求两分辨率不一致） |

改法：`sudo sed -i 's/^hdmi_cvt=.*/hdmi_cvt=640 480 60 6 0 0 0/' /boot/firmware/config.txt`；字体改 `/etc/default/console-setup` 的 `FONTSIZE`（12x24 = 53 列 × 20 行，小一档）。改完都要 `sudo reboot`。

**方向**：SPI 屏不对 → 重编译改 `DISPLAY_ROTATE_180_DEGREES`；HDMI 不对 → 改 `display_rotate`（0/1/2/3，只影响 HDMI）。

## 5. 踩坑实录与解法（按出场顺序）

**坑 1：`bcm_host.h: No such file or directory`（编译 fbcp 失败）**
现象：`gpu.cpp:1:10: fatal error: bcm_host.h`。
原因：trixie 源删除了 userland（libraspberrypi-*）系列包。
解法：见步骤 2，从 bookworm 官方存档包提取部署到 /usr/local。

**坑 2：dpkg 装 bookworm 存档包报文件冲突**
现象：`trying to overwrite '/usr/lib/aarch64-linux-gnu/libdtovl.so.0', which is also in package libdtovl0`，两个包停在"已解包未配置"。
原因：trixie 保留了 `libdtovl0` 系统包（dtoverlay 工具依赖），与存档包内同名文件撞车。
弯路：把 libdtovl.so.0 剔除后重打包（`dpkg-deb -R` + 删文件 + 清 md5sums + `dpkg-deb -b --root-owner-group`）→ 仍失败，见坑 3。
教训：先查 `dpkg -s`/`dpkg -S`，冲突背后可能还有元数据层面的封杀。

**坑 3：剔除文件后 dpkg 仍拒绝配置（真·元凶）**
现象：`libdtovl0 breaks libraspberrypi0 and is installed`，且 **apt 从此拒绝一切安装**（`E: Unmet dependencies`）。
原因：trixie 的 libdtovl0 在包元数据里显式声明 `Breaks: libraspberrypi0, libraspberrypi-dev`，官方主动封杀这两个包名，无论怎么重打包都无解；半安装状态又污染 dpkg 数据库。
解法：① 清理：`sudo dpkg --purge libraspberrypi-dev libraspberrypi0 && sudo dpkg --configure -a`（恢复 apt 健康，必做）；② 放弃 dpkg，改用 /usr/local 文件部署（步骤 2）。
教训：apt 整体罢工时，先怀疑 dpkg 里有半安装包（`dpkg -l | grep '^iU'`）。

**坑 4：官方一键脚本不可用**
现象：`shell/waveshare-2inch4` 跑不动。
原因：写死 `/home/pi`、`/boot/config.txt`、`/etc/rc.local`，还要求主机名为 raspberrypi——新系统四项全不满足。
解法：本手册的 setup.sh 已全部替换为 trixie 写法（动态路径/用户、systemd）。

**坑 5：rc.local 不存在**
原因：trixie 取消了该机制。
解法：systemd 服务（步骤 6）。

**坑 6：sudo pip3 被 PEP 668 拒绝**
现象：`error: externally-managed-environment`。
解法：Python 库一律 `apt install python3-xxx`。

**坑 7：KMS 与 fbcp 不兼容**
原因：fbcp 用 DISPMANX（传统固件栈）抓屏，`vc4-kms-v3d` 启用时无传统 framebuffer。
解法：注释 `dtoverlay=vc4-kms-v3d` 和 `max_framebuffers=2`。Pi 4 内核确认 `CONFIG_FB_BCM2708=y`（`zcat /proc/config.gz | grep BCM2708` 可查）。

**坑 8：display_rotate 转了 HDMI**
现象：想修小屏 180° 倒转，设了 `display_rotate=2`，结果 HDMI 显示器也倒了。
原因：display_rotate 作用于 framebuffer/HDMI 侧，镜像会把翻转带给两块屏。
解法：`display_rotate=0` 还原 HDMI；小屏翻转改用 fbcp 编译选项 `-DDISPLAY_ROTATE_180_DEGREES=ON`（步骤 5）。

**坑 9：字体两屏不可兼得**
现象：小屏字号调大，HDMI 跟着变大。
原因：镜像方案只有一个 framebuffer、一套控制台字体。
解法：见第 4 节权衡表，选定"小屏优先"（640×480 + 16×32）。若未来要两屏都舒服，可改为"两屏分工"：小屏不镜像，改跑 320×240 原生像素的专用状态程序。

**坑 10：SPI 开了但不生效**
原因：`dtparam=spi=on` 和屏蔽 KMS 都要重启才生效；重启前 `/dev/spidev0.0` 不存在，fbcp 起不来。
解法：所有配置改完一次性重启。

## 6. 卸载与回滚

```bash
sudo systemctl disable --now fbcp
sudo rm /etc/systemd/system/fbcp.service /usr/local/bin/fbcp
sudo rm -rf /usr/local/lib/libbcm_host* /usr/local/lib/libvchiq_arm* \
            /usr/local/lib/libvcos* /usr/local/lib/libdebug_sym* \
            /usr/local/include/bcm_host.h /usr/local/include/interface /usr/local/include/vc*
sudo cp /boot/firmware/config.txt.bak.lcd /boot/firmware/config.txt   # 还原显示配置
sudo reboot
```

## 7. 文件清单

```
~/LCD/
├── SPI-LCD配置完全手册.md                 # 本文件
└── waveshare-lcd-setup/                    # 标准 skill（已安装到 ~/.zcode/skills/ 软链）
    ├── SKILL.md                           # agent 用的流程定义
    ├── scripts/setup.sh                   # 一键配置脚本（幂等）
    └── assets/
        ├── libraspberrypi0_*-1_arm64.deb      # bcm_host 运行库（bookworm 官方存档）
        ├── libraspberrypi-dev_*-1_arm64.deb   # bcm_host 头文件（同上）
        └── Waveshare_fbcp/                    # fbcp-ili9341 源码（2025-03 Waveshare 版，已精简）
```
