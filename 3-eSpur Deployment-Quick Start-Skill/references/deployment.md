# eSpur 完整部署步骤（从零开始）【v1 遗留链】

> 本文档描述 v1 部署链（eSpur 主程序 + MySQL 云端），现已不再上报。
> 当前实际运行的是 eSpur_v2 客户端 + neowatt 平台，见 `v2-client.md`；
> 实例目录布局约定（192.168.0.163_1-2-3-4 / update_config.py 分发）仍沿用本文。

本机环境参照：Raspberry Pi 4B，Raspberry Pi OS Lite (Debian 13 trixie)，aarch64，Python 3.13，wlan0 在测试局域网（192.168.1.x），PDU 网线直连 eth0。

## 0. 获取代码

skill 自带离线快照（2026-10-16）：

```bash
mkdir -p ~/eSpur && cd ~/eSpur
unzip ~/.zcode/skills/espur-deploy/assets/eSpur-code-snapshot.zip
# → eSpur.zip（主程序，第 4 步直接可用）、eSpur-deployment/、eSpur-management/
```

快照内容：2026-10-16 上传版本的干净拷贝（无 .git/.idea/.DS_Store），eSpur-deployment 里的 config.ini 保留本机模板值（含云端 DB 账号），pdu_ip_ports-pid.json 已重置为全 "0"。

旧上游（beerjtu/eSpur-deployment、guomingtang/eSpur）已由 `Polar-Zhang/eSpur` 收编；v2 客户端从该仓库同步（本网络实测可达，codeload tarball 方式）。

## 1. 系统依赖

```bash
sudo apt-get install -y snmp python3-pip python3-numpy python3-matplotlib
python3 -m pip install --break-system-packages colorlog pymysql colorama
```

注意：
- `snmp` 包提供 snmpget/snmpwalk/snmpset（代码用 os.popen 调它们）。
- 项目 requirements.txt 钉的 `numpy==1.19.5`、`colorama~=0.4.4` 等是为老 Python 钉的，Python 3.13 上 numpy 1.19.5 无法编译。用系统 python3-numpy + pip 新版实测兼容（主代码只用 np.load/np.save/np.mean 等基础 API）。
- eSpur-management（云端 Web）额外需要 flask 系，不装 Pi 上，不用管。

## 2. 网络配置（关键，PDU 有 ACL）

PDU（ATEN switched-pdu）IP 固定 192.168.0.163，只认 192.168.0.x 源地址。Pi 的 eth0 静态配 192.168.0.200/24。

netplan + NetworkManager 的机器：编辑 eth0 对应的桩文件（文件名含 netplan-eth0 的 uuid，`ls /etc/netplan/` 找）：

```yaml
network:
  version: 2
  ethernets:
    eth0:
      renderer: NetworkManager
      match: {}
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses:
        - 192.168.0.200/24
      networkmanager:
        uuid: "<原文件里的 uuid>"
        name: "netplan-eth0"
        passthrough:
          proxy._: ""
```

```bash
sudo chmod 600 /etc/netplan/<该文件>.yaml
sudo netplan generate && sudo netplan apply
```

验证（**串行、低速**，不要并发扫描 PDU）：

```bash
ip route get 192.168.0.163        # 必须走 eth0 且 src 192.168.0.200
snmpget -v1 -c public 192.168.0.163 .1.3.6.1.2.1.1.1.0
# 期望: STRING: "switched-pdu"
```

若机器没有 netplan/NM，等价做法：eth0 静态 192.168.0.200/24（任何机制，只要重启后还在）。文档里的老办法「eth0 不配 IP + ip route add 192.168.0.163 dev eth0」**不要用**——那样源地址是 wlan0 的 IP，会被 PDU 的 ACL 丢弃。

## 3. 配置部署参数

```bash
cd ~/eSpur/eSpur-deployment
```

改 `config.ini`（[eSpur] 节）：
- `espur_deployment_abs_path` = eSpur-deployment 的绝对路径（如 /home/espur-5090/eSpur/eSpur-deployment）
- `pdu_ip` = 192.168.0.163
- `instance_id` = 1-2（多实例用 - 分隔，与云端 DB 的 espur_instance 表 id 对应）
- `single_psu_max_power` = 2000-2000（每实例单 PSU 额定功率）
- 其余参数（obr_win_size、cv_threshold 等）保持默认

改 `pdu_ip_ports-pid.json`：
```json
{"192.168.0.163_1-2-3-4": "0", "192.168.0.163_5-6-7-8": "0"}
```
key 格式 = `[pdu_ip]_[port1]-[port2]-...`；value 是运行时 PID，初始化一律 "0"。

## 4. 打包并部署实例

```bash
cd ~/eSpur
rm -f eSpur-deployment/eSpur.zip
zip -r -q eSpur-deployment/eSpur.zip eSpur -x 'eSpur/.git/*' 'eSpur/.idea/*' 'eSpur/.DS_Store'
cd eSpur-deployment
python3 deploy_eSpur_via_unzip.py    # 在当前目录创建 <实例名>/eSpur/ 并解压
python3 update_config.py             # 把 config.ini 按实例写入各实例的 Management_node/config/config.ini
```

zip 顶层必须是 `eSpur/`（不能是 eSpur-main/ 或散文件），否则 run_eSpur 找不到 Management_node。

验证各实例 `Management_node/config/config.ini`：pdu_ip、pdu_ports_used、psu_num、instance_id、single_psu_max_power 逐项正确。

## 5. 启动与验证

```bash
python3 run_eSpur.py 0          # 0 = 启动 json 里全部实例
sleep 5; ps -ef | grep '[m]ain.py'
cat pdu_ip_ports-pid.json       # value 应变成进程 pid
```

实例需要 root 的地方：无（main.py 里那句 ip route add 以普通用户跑会静默失败，但 eth0 的 /24 连接路由已覆盖，无影响）。

约 3 分钟初始采样窗口后：

```bash
python3 stat_eSpur.py
```

正常输出每实例的 Node_id、功率、累计电量。日志在 `log/<实例>/<时间戳>log`。

## 6. PDU 验证（只读，安全）

```bash
# 端口继电器状态（.23273.2.4.<N>.0，N=1..8）
snmpwalk -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273 | grep '23273.2.4'
# 全树（get_server_power 用它：result[1]=电压，result[10+N]=N口电流 0.01A）
time snmpwalk -v1 -c public 192.168.0.163 .1.3.6.1.4.1.23273
```

健康时全树 walk < 0.1s。PDU 地址不变时无需改动；若换 PDU，改 config.ini 的 pdu_ip 和 json 的 key 后重跑第 4 步（先 `python3 delete_eSpur.py 0` 清旧实例目录）。


## 机房部署变体（2026-10-22 确定，lab-01 机房形态）

与实验室 wlan0 上网不同，机房通过交换机上联，树莓派双网口分工：

```
[智能 PDU 192.168.0.163] ←网线直连→ [Pi eth0: 192.168.0.200/24]   控制面（不变）
[机房交换机] —网线—→ [Pi USB 转接网口: 10.123.4.246/22，网关 10.123.7.254]  上联面（上报+mesh+远程）
```

- USB 转接网口为原型机自带（无需额外硬件）。**jifang 连接已预配置**（2026-10-25 修正）：
  manual 10.123.4.246/22 + 网关 10.123.7.254 + autoconnect。**绑定必须用实际接口名 + MAC 双保险**
  （`ifname eth1` + `802-3-ethernet.mac-address 00:e0:4f:3b:a6:30`）：
  - ⚠ **接口名不一定是 `enx*`**——真实名取决于驱动（RTL8152 在本机是 `eth1`，非 predictable-name 的
    enx<MAC>）；`nmcli con mod` 改 glob 绑定会**静默失效**（读回仍是旧值），必须删除重建。
  - MAC 绑定与接口名无关，换 USB 口也不失效。
  - 现场判断：接口出现但 `NO-CARRIER` = 物理链路未建立（网线没插进转接器 RJ45 口 / 交换机端口
    不通），配置再对也没用——先解决物理层。
- 受限 sudo 免密已配置（/etc/sudoers.d/espur-ops，用户 espur-5090）：
  nmcli 全部 + `systemctl restart/status espur-algorithm` + `systemctl restart wg-quick@wg0`——
  远程运维（hub 经 mesh SSH）可完成网络配置与算法/隧道重启，其余仍需密码
- eth0 静态配置无网关，上联默认路由只有 USB 口一条，无冲突；配完 `ip route` 核对
- PDU 的 config.ini `pdu_ip = 192.168.0.163` 不变（直连控制面），实例命名约定不变
- **现场流程（终版，2026-10-25）**：① USB 转接网卡插树莓派，网线连转接网卡 ↔ 交换机；
  ② eth0 网线连 PDU（随整机搬运，本就连着）；③ 上电等 ~2 分钟（网络→服务→算法→上报全自动）
- 验收顺序（SSH 或管理员从服务端远程确认）：`ip -4 addr show enx*` 拿到 10.123.4.246 →
  `ping -c3 neowatt.cn` 出网 → `ip route get 192.168.0.163` 走 eth0 →
  `systemctl status espur-algorithm` → 平台翻在线 + 四口曲线恢复
- 保底（预配置失效时）：`sudo bash config-uplink.sh "enx*" 10.123.4.246/22 10.123.7.254`（通配同样适用）
- **出站策略两个坑（2026-10-28 机房实测）**：
  1. **DNS 解析**：数据中心常拦公网 DNS（223.5.5.5/119.29.29.29）与网关 DNS。
     症状：`ping 域名` 报 name resolution，而 IP 层通。**后果：平台上报全断**
     （上报走 HTTPS，需解析 neowatt.cn），设备看起来像掉线。
     排查：`nslookup neowatt.cn <网关>` / `<数据中心内网DNS>`；修复
     `nmcli con mod jifang ipv4.dns "<内网DNS> ..."`；
     兜底（所有 DNS 都不通时，hosts 写死平台 IP——上报只需解析这一个域名）：
     `echo "47.237.111.211 neowatt.cn" | sudo tee -a /etc/hosts` →
     `getent hosts neowatt.cn` 确认 → `sudo systemctl restart espur-algorithm`。
     （2026-10-28 实测：机房禁公网 DNS，hosts 兜底后上报立即恢复）
     兜底 `/etc/hosts` 写 `47.237.111.211 neowatt.cn`。
  2. **出站 UDP**：mesh（WireGuard）是 IP 直连不依赖 DNS，但需出站 UDP 51820/443；
     被拦则远程通道断（设备可能仍在正常上报）。应急：手机开同名热点让 wlan0 承载 mesh；
     长期：找数据中心放行 UDP 51820，或改走 wstunnel（TCP 443 伪装）。
     判定顺序：先看平台是否仍在上报 → 在则设备活着、只是远程通道断。
- 硬件看门狗已就位（挂死 1 分钟自愈），机房无人值守场景可依赖