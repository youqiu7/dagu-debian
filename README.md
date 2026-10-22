# dagu-debian

在 **Xiaomi Pad 5 Pro 12.4**（dagu / 22081281AC / SM8250-AC）上运行 **Debian 13**（Trixie）的移植记录与安装工具。

> 目标：把这块 Android 平板变成一台能日常使用的 Linux 平板。

---

## 当前状态

| 硬件 | 状态 | 说明 |
|---|---|---|
| 显示 | ✅ | 12.4" 2.5K，L81A 面板 + ktz8866 背光 |
| 触屏 | ✅ | Himax HX83121（10 点触控） |
| Wi-Fi | ✅ | ath11k QCA6390，CN 国家码，864+ Mbps |
| 蓝牙 | ✅ | QCA6390 |
| 扬声器 | ✅ | 四路 CS35L41，**ASP 直通绕过 DSP** |
| 麦克风 | ❌ | WCD9385 采集路径未打通 |
| USB | ✅ | USB-C OTG + g_serial 串口 |
| DP 输出 | ⚠️ | 内核就绪，需主动式 PD 扩展坞 |
| 传感器 | ❌ | ADSP 管理，AP 侧不可见 |

| 软件 | 状态 |
|---|---|
| GNOME 48.7 Wayland | ✅ 自动登录 |
| 触摸屏虚拟键盘（OSK） | ✅ 锁屏 + 应用内均可弹 |
| Easy Effects EQ 调音 | ✅ 常驻 |
| 时间同步 | ✅ 无 RTC 设备方案 |
| WPS Office ARM64 | ✅（需自备 deb） |

---

## 快速开始

### 前置

- 已解锁 BL 的 dagu 平板
- `platform-tools`（fastboot/adb）
- 镜像文件（**不在本仓库**，见下方「镜像」）

### 安装

```bash
# 1. 刷入（b 槽）
fastboot flash boot_b        images/boot-dagu.img
fastboot flash vendor_boot_b images/vendor_boot-dagu.img
fastboot flash userdata      images/rootfs-1.5g.img
fastboot set_active b
fastboot continue

# 2. 首次启动后，串口或 SSH 登录 root，运行配置脚本
bash install/setup-system.sh
```

脚本会依次处理：

```
0/8  时间同步（无 RTC 必做，否则 apt 全线 SSL 失败）
1/8  创建用户
2/8  中文环境
3/8  固件（ath11k / cirrus / qca 蓝牙 / adsp / UCM）
4/8  网络（NetworkManager 独占）
5/8  GNOME 桌面 + alsa-ucm-conf + easyeffects
6/8  服务（音频时序 / OSK / 自动挂起禁用）
7/8  可选：WPS Office
8/8  验证
```

---

## 镜像（不在本仓库）

| 文件 | md5 | 大小 |
|---|---|---|
| `boot-dagu.img` | `ee2d066be9c544b123ceefb4b682d87e` | 192 MB |
| `vendor_boot-dagu.img` | `1e6dfedc0cfa30fff6a69a4d03803523` | 200 KB |
| `rootfs-1.5g.img` | — | 1.5 GB |

**为什么不在仓库里**：GitHub 单文件 100 MB 限制，rootfs 1.5 GB。

镜像由上游作者构建，见致谢。

---

## 目录

```
docs/       移植记录（6 篇，含所有踩坑细节）
install/    安装与刷机脚本
config/     systemd / anchor 配置
firmware/   UCM 定义 + 小体积固件
```

### docs 索引

| 文档 | 内容 |
|---|---|
| `01-交付归档.md` | 最终状态、关键修复清单、遗留问题 |
| `02-覆盖对照表.md` | 15 项修复与安装包的逐条对应 |
| `03-音频修复-ASP绕过DSP.md` | 音质问题的根治方案 |
| `04-OSK修复记录.md` | 虚拟键盘为什么弹不出来 |
| `05-rootfs重建恢复记录.md` | rootfs 损坏后重建全过程 |
| `06-移植指南.md` | 完整移植手册 |

---

## 关键技术点

### 1. 音频：`PCM Source` 从 DSP 改 ASP

CS35L41 出厂只有 `Protection` 算法（动态压缩），音质糊、没细节。
把 `PCM Source` 切成 `ASP` 跳过 DSP，动态范围立刻回来。

```bash
for a in TL TR BL BR; do amixer -c0 cset name="$a PCM Source" 0; done
```

持久化要改 UCM 源文件 `/usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf`，运行时 cset 会被重置。

### 2. 音量：UCM 会重置，必须改源文件

`Digital PCM 817 / Analog PCM 18` 是原厂值，改成 `913 / 20`（上限）要直接改 UCM。

### 3. 虚拟键盘：必须让 gnome-shell 在 true 状态下启动

运行中改 `screen-keyboard-enabled` 无效 —— OSK 对象已经被 dispose。
必须改完重启（日志会看到 `KeyContainer has been already disposed`）。

GDM 登录界面还要额外配 `/etc/dconf/profile/gdm` + `/etc/dconf/db/gdm.d/`。

### 4. Wi-Fi 固件：initramfs 一份不够

作者只把 ath11k 固件放进 vendor_boot 的 initramfs，那是一次性的。
网卡任何 reset/suspend 恢复都去 rootfs 找，找不到就 `-2 ENOENT` 掉线。
必须把固件也写进 `/lib/firmware/ath11k/QCA6390/hw2.0/`。

### 5. 时间：没有 RTC 电池

每次开机时间都从内核编译日期起算，apt 直接报 `SSL certificate verify failed`。
需要 `fake-hwclock`（保存快照）+ `systemd-timesyncd`（NTP 校准）。

---

## 已知问题

| 问题 | 说明 |
|---|---|
| 麦克风不可用 | WCD9385 采集路径未打通，需要继续研究 UCM capture 配置 |
| DP 输出 | 内核（`CONFIG_TYPEC_DP_ALTMODE`）已就绪，但需要主动式 PD 扩展坞，被动线缆不会协商 |
| Electron 客户端无法弹出 OSK | Chromium 的 Wayland text-input 只做 IME，不实现 OSK 的 enable 请求。可用 Firefox 网页版替代 |
| a 槽 Android | userdata 被 Debian 占用，双系统需拆分区 |

---

## 致谢

- **[Huabin1010/dagu-mainline-linux](https://github.com/Huabin1010/dagu-mainline-linux)** — 主线上游移植，本项目的 boot/rootfs 基于其产物
- Linux mainline 社区 — SM8250 / CS35L41 / ath11k 驱动
- Debian 与 GNOME 项目

---

## 免责声明

刷机有风险，可能变砖。本仓库只提供记录与脚本，不提供镜像。
操作前请自行备份原厂分区（`boot_a` / `vendor_boot_a` / `vbmeta_a`）。
