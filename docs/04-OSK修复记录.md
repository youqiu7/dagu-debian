# 触摸屏虚拟键盘（OSK）修复记录 — 2026-10-20

设备：Xiaomi Pad 5 Pro 12.4（dagu），Debian 13 + GNOME 48.7 Wayland
问题：锁屏界面和搜索框都无法弹出虚拟键盘，平板没有物理键盘 → 无法输入密码/搜索

---

## 1. 根因

**GNOME Shell 只在启动时读一次 `screen-keyboard-enabled`。**

```
gnome-shell 启动时读到 false
  → ui/keyboard.js 创建 KeyContainer 后立即 dispose
  → 之后即使 gsettings 改成 true，对象已销毁，不会重建
  → 任何应用都无法触发 OSK
```

日志证据（错误状态下反复出现）：

```
Object .Gjs_ui_keyboard_KeyContainer (0x557dc1ca80), has been already disposed
   resource:///org/gnome/shell/ui/keyboard.js:1605
   resource:///org/gnome/shell/ui/keyboard.js:1689
   resource:///org/gnome/shell/ui/keyboard.js:1351
```

修复后同样的日志里 **`KeyContainer` 报错次数为 0**。

---

## 2. 修复步骤

### 2.1 用户会话

```bash
su - youqi -c "export XDG_RUNTIME_DIR=/run/user/1001; \
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus; \
  gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true"
```

### 2.2 GDM 登录界面（锁屏/登录也要能用）

```bash
mkdir -p /etc/dconf/db/gdm.d /etc/dconf/profile
printf '[org/gnome/desktop/a11y/applications]\nscreen-keyboard-enabled=true\n' \
    > /etc/dconf/db/gdm.d/00-osk
printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' \
    > /etc/dconf/profile/gdm
dconf update
```

**注意**：`/etc/dconf/profile/` 默认可能只有 `ibus`，**没有 `gdm`**。
只写 `greeter.dconf-defaults` 而不建 `gdm` profile，GDM 根本不会读那份配置。

### 2.3 关键一步：让 shell 重新初始化

设置改完后**必须重启 shell**，运行中改 gsettings 无效：

```bash
# 最干净：重启设备（GDM 自动登录会直接进桌面）
systemctl reboot
```

`loginctl terminate-session <id>` 会导致停在 GDM 登录界面 —— 自动登录只在**开机**时生效，logout 不会自动登入。

### 2.4 验证

```bash
# 无 KeyContainer disposed 报错即为正常
su - youqi -c "XDG_RUNTIME_DIR=/run/user/1001 journalctl --user --since '3 minutes ago' --no-pager" \
  | grep -c "KeyContainer"
# 应为 0
```

---

## 3. Electron 客户端永远弹不出 OSK

**Chromium/Electron 的 Wayland text-input 实现只支持输入法（IME），不实现 OSK 的 `enable` 请求。**

试过全部无效：

```
--ozone-platform=wayland
--enable-wayland-ime
--wayland-text-input-version=3
```

- YesPlayMusic 0.4.11：Electron 太老（Node v14.16），在 glibc 2.41 上直接 `futex facility returned an unexpected error code` / 段错误
- VutronMusic 3.2.0：Electron 37.10.3 / Chromium 138，能正常运行、能播放，**但搜索框敲不出键盘**

**结论**：
- 播放用 VutronMusic（界面好，触屏友好）
- 搜索用 **Firefox 网页版** `music.163.com`（GTK3，OSK 原生支持）

---

## 4. 顺带修的两个问题

### 4.1 系统时间（SSL 反复失败的真凶）

```
现象    apt 报 SSL certificate verify failed，反复出现
原因    设备无 RTC 电池，无 fake-hwclock，每次开机时间从内核编译日期起算
修复    apt install fake-hwclock systemd-timesyncd util-linux-extra
        date -s "<正确时间>" && fake-hwclock save
        /etc/systemd/timesyncd.conf.d/99-cn.conf 配国内 NTP
```

**坑**：`systemd-timesyncd` 对超过一定阈值的偏移会拒绝校正。手动 `date -s` 到接近正确值后，它才会接管微调。

### 4.2 ath11k WiFi 固件缺失

```
现象   网卡重新初始化后 wlp1s0 unavailable
原因   /lib/firmware/ath11k/ 不存在，固件只在 vendor_boot 的 initramfs 里
       （平时启动时 initramfs 加载一次，之后任何 reset/probe 都失败）
修复   从 boot-dagu.img 的 initramfs 提取：
       lib/firmware/ath11k/QCA6390/hw2.0/{amss.bin,m3.bin,board.bin}
       写入 rootfs 的 /lib/firmware/ath11k/
```

`ath11k` 是**内建驱动**（`/proc/kallsyms` 868 个符号，`/lib/modules/7.0.0-dirty` 只有 3 个 venus 模块），不能 `modprobe -r` 热重载，**下次重启才是验证点**。

---

## 5. 固件抽取方法（boot-dagu.img → initramfs → 固件）

```python
# boot v3 header
kernel_size  @8
ramdisk_size @12
header_size  @20

# ramdisk 偏移必须对 kernel 也对齐
ramdisk_start = align4096(align4096(header_size) + kernel_size)
```

ramdisk 是 **gzip 压缩的 cpio**（`1f 8b 08`），解压后按 newc 格式解析（magic `070701`）。

---

## 6. 安装包已同步

`dagu-debian-20261020/install/setup-system.sh`：

```
1.  UCM 定义入包（firmware/ucm/）
2.  apt 列表加 alsa-ucm-conf
3.  桌面用户加 audio 组
4.  OSK：youqi 的 gsettings + GDM 的 dconf profile/db
```

`bash -n` 通过。
