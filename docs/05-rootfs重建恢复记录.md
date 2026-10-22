# rootfs 重建与系统恢复记录 — 2026-10-22

设备：Xiaomi Pad 5 Pro 12.4（dagu / 22081281AC / SM8250-AC / 16 GB）
起因：2026-10-21 解压自编内核模块到 `/lib/modules` 导致 rootfs 损坏（`exec /sbin/init failed`）
处置：放弃修复，用 `rootfs-1.5g.img` 重建，再重做此前所有配置

---

## 1. 重建结果

| 项目 | 状态 |
|---|---|
| rootfs | `rootfs-1.5g.img` → `/dev/sda34` 自动扩到 105 G，已用 616 M |
| 内核 | 作者正式版 `7.0.0-dirty #525`（`ee2d066b`） |
| vendor_boot | `1e6dfedc`（含 `regdom=CN` + `panic=10`） |
| 主机名 | `dagu` |
| 用户 | `youqi` / uid 1001 / sudo（镜像预置） |
| SSH | `dagu_key` 免密，`root@192.168.10.123` |

---

## 2. 重建路上踩的三个坑

### 坑 1：系统时间是 1970 年 → apt 全部 SSL 失败

```
SSL connection failed: error:0A000086:SSL routines::certificate verify failed
```

镜像没有预置硬件时钟，`apt-get update` 卡 25 分钟不是网慢，是证书有效期校验失败。

修复：
```bash
date -s "2026-10-22 04:30:00"
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
```

### 坑 2：WiFi 省电模式 → 下载只有 79 KB/s

```
signal      -40 dBm        链路极佳
rx / tx     1080 / 1200 Mbit/s
power_save  on             ← 元凶
实测        79 KB/s
```

关闭后立刻 3.2 MB/s（40 倍）：
```bash
iw dev wlp1s0 set power_save off
```

### 坑 3：NetworkManager 接管后原 wpa_supplicant 配置失效

setup 跑到一半 `wlp1s0` 变 DOWN，apt 断网，`set -e` 直接退出脚本。用 nmcli 重连：
```bash
nmcli device wifi connect "OPPO A5-5G" password "********"
```

---

## 3. 音频：两个真正的根因

重建后声卡（`card0 XiaomidaguCS35L`）、cirrus 固件（13 个 `.wmfw`）、ADSP 固件（20 个）全都在，但 PipeWire 只有 `Dummy Output`。

### 根因 A：`alsa-ucm-conf` 包未安装

```
dpkg -l alsa-ucm-conf  →  un（未安装）
```

UCM 配置框架本身缺失，ACP 无法解析 `Syntax 7` 的 `HiFi.conf`，只提供 `off` / `pro-audio` 两个空 profile，sink 永远是 Dummy。

```bash
apt-get install -y alsa-ucm-conf
```

装完立刻：
```
Devices    48. 内置音频 [alsa]
Sinks   *  51. 内置音频 Speakers  [vol: 0.85]
```

### 根因 B：桌面用户 `youqi` 不在 `audio` 组

```
/dev/snd/controlC0    root:audio 660
youqi 组              1001(youqi), 27(sudo)     ← 没有 audio
su - youqi amixer     Invalid card number '0'
```

`dagu-audio-up.sh` 的 `mixer_ready()` 读不到 mixer → 等 90 秒后报 `no mixer` → 退出，PipeWire 不发布 sink。

```bash
usermod -aG audio youqi
```

注意：加组后必须重建 user session（`loginctl terminate-user youqi`）才会对已在运行的 PipeWire 生效。

### 最终状态

```
dagu-audio-up.service   active
Sink                    57. 内置音频 Speakers  [vol: 0.85]
UCM 路径                alsa_output.platform-sound.HiFi__Speaker__sink
麦克风                  Microphone source missing（WCD9385 采集，未解决）
```

---

## 4. WPS Office

官网个人版只有 X64，ARM64 只存在于 WPS 365。

```bash
# 下载
wps-office_12.1.2.29183.AK.preread.sw.365_807310_arm64.deb   (752 MB)

# 安装（dpkg -i 会因缺 libglu1-mesa 失败，必须补依赖）
dpkg -i wps-office_*.deb
apt-get install -f -y        # 自动装 libglu1-mesa / libopengl0
```

结果：
```
ii  wps-office  12.1.2.29183.AK.preread.sw  arm64
/usr/bin/wps  /usr/bin/wpp  /usr/bin/et
```

`postinst` 报 `readelf: 未找到命令` 警告无害（缺 `binutils`，不影响启动）。

---

## 5. 重启验证（全部通过）

```
uptime                up 0 min
gdm3                  active
NetworkManager        active
ssh                   active
dagu-audio-up         active
sink                  内置音频 Speakers [vol: 0.85]   ← 自动恢复
图形会话              youqi seat0 tty2                  ← GDM 自动登录
```

---

## 6. 安装包已同步的修复

`dagu-debian-20261020/`：

| 变更 | 文件 |
|---|---|
| UCM 定义入包 | `firmware/ucm/Xiaomi-dagu/HiFi.conf`、`firmware/ucm/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf` |
| apt 列表补 `alsa-ucm-conf` | `install/setup-system.sh:102` |
| 桌面用户加 audio 组 | `install/setup-system.sh:107-111` |
| UCM 安装步骤 | `install/setup-system.sh:70-83` |

`bash -n` 通过。

---

## 7. 仍然缺失

- **麦克风**（WCD9385 capture）：`Microphone source missing`，与本次重建无关，重建前也不可用
- **DP**：需主动式 PD 扩展坞或 USB-C 显示器（内核侧已就绪，见 `17-dp/`）
- **传感器**：ADSP 管理，AP 侧不可见
