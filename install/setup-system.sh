#!/bin/bash
# dagu Debian 首次启动配置脚本
# 用法：在刚刷好 rootfs、首次登录（串口或 SSH）后以 root 运行
#   bash setup-system.sh
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行"
[ -d "$R/images" ] || die "找不到 $R/images，请在发布包的 install/ 目录里运行本脚本"

# ---------------------------------------------------------------- 0. 时间
# 这台设备没有 RTC 电池，每次开机时间都从内核编译日期起算。
# 时间不对会导致 apt 报 "SSL certificate verify failed"，后续所有安装全失败。
# 所以必须在第一次 apt 之前把时间拉正，并装上 fake-hwclock 保存。
say "0/8 时间同步（无 RTC 设备必做，否则 apt 全线 SSL 失败）"
CUR_YEAR=$(date +%Y)
if [ "$CUR_YEAR" -lt 2026 ]; then
    warn "当前系统时间是 $(date '+%Y-%m-%d %H:%M')，明显不正确"
    read -r -p "请输入当前正确时间 (YYYY-MM-DD HH:MM:SS)，直接回车跳过: " NOW
    if [ -n "${NOW:-}" ]; then
        date -s "$NOW" || warn "设置时间失败，apt 可能仍会 SSL 报错"
    else
        warn "跳过设置，如果 apt 报 SSL 错误请先用 date -s 手动设时间"
    fi
fi
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux-extra 2>/dev/null \
    || warn "util-linux-extra 安装失败（hwclock 不可用，不影响 fake-hwclock）"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fake-hwclock systemd-timesyncd 2>/dev/null \
    || warn "fake-hwclock/timesyncd 安装失败 —— 下次重启时间会再次漂移"
mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=ntp.aliyun.com ntp1.aliyun.com ntp.tencent.com\nFallbackNTP=ntp.aliyun.com\n' \
    > /etc/systemd/timesyncd.conf.d/99-cn.conf
systemctl enable --now systemd-timesyncd 2>/dev/null || true
fake-hwclock save 2>/dev/null && echo "    已保存时间快照: $(cat /etc/fake-hwclock.data 2>/dev/null)"
echo "    当前时间: $(date)"

# ---------------------------------------------------------------- 1. 基本参数
NEWUSER="${NEWUSER:-youqi}"
say "1/8 创建用户 $NEWUSER"
if ! id "$NEWUSER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$NEWUSER"
    echo "请设置 $NEWUSER 的密码："
    passwd "$NEWUSER"
else
    warn "用户 $NEWUSER 已存在，跳过"
fi

# ---------------------------------------------------------------- 2. 中文环境
say "2/8 中文语言环境"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq locales fonts-noto-cjk ibus-libpinyin
localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
cat > /etc/default/locale <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
EOF
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# ---------------------------------------------------------------- 3. 固件
say "3/8 安装固件（蓝牙 + ADSP/Venus）"
mkdir -p /lib/firmware/qca
if [ -f "$R/firmware/qca/htbtfw20.tlv" ]; then
    cp -f "$R/firmware/qca/htbtfw20.tlv" "$R/firmware/qca/htnv20.bin" /lib/firmware/qca/
    echo "    蓝牙固件: $(ls -la /lib/firmware/qca/htbtfw20.tlv | awk '{print $5}') 字节"
else
    warn "缺少 $R/firmware/qca/htbtfw20.tlv"
fi

if [ -f "$R/firmware/qcom-sm8250-xiaomi-dagu/fw-adsp-venus.tar.gz" ]; then
    mkdir -p /lib/firmware/qcom/sm8250/xiaomi/dagu
    tar -xzf "$R/firmware/qcom-sm8250-xiaomi-dagu/fw-adsp-venus.tar.gz" \
        -C /lib/firmware/qcom/sm8250/xiaomi/dagu
    SZ=$(du -sm /lib/firmware/qcom/sm8250/xiaomi/dagu | awk '{print $1}')
    [ "$SZ" -ge 10 ] || die "ADSP/Venus 固件解压后只有 ${SZ}MB，异常（应为 20MB）"
    echo "    ADSP/Venus 固件: ${SZ} MB"
else
    warn "缺少 fw-adsp-venus.tar.gz，需手动从 modem 分区 (sde5) 的 image/ 复制 adsp.* venus.*"
fi

# CS35L41 扬声器固件：作者只把它放进了 initramfs，rootfs 的 /lib/firmware/cirrus 是空的。
# 不补的后果是四个功放全都 "Failed to request firmware ... .wmfw" → 完全无声。
if [ -f "$R/firmware/cirrus-full.tar.gz" ]; then
    tar -xzf "$R/firmware/cirrus-full.tar.gz" -C /lib/firmware/
    CNT=$(ls /lib/firmware/cirrus 2>/dev/null | wc -l)
    [ "$CNT" -ge 10 ] || die "cirrus 固件只解出 $CNT 个文件，异常"
    echo "    CS35L41 音频固件: $CNT 个文件"
else
    warn "缺少 cirrus-full.tar.gz —— 扬声器会完全无声"
fi

# ath11k WiFi 固件：作者只放进了 vendor_boot 的 initramfs，rootfs 里没有。
# 不补的后果：开机时 initramfs 加载能用，但网卡一旦 reset/suspend 恢复，
# 内核去 /lib/firmware 找固件 → -2 ENOENT → wlp1s0 unavailable → 彻底掉线。
if [ -f "$R/firmware/ath11k-firmware.tar.gz" ]; then
    mkdir -p /lib/firmware/ath11k/QCA6390/hw2.0
    tar -xzf "$R/firmware/ath11k-firmware.tar.gz" -C /
    AC=$(ls /lib/firmware/ath11k/QCA6390/hw2.0/ 2>/dev/null | wc -l)
    [ "$AC" -ge 3 ] || die "ath11k 固件只解出 $AC 个文件，异常（应为 3）"
    echo "    ath11k WiFi 固件: $AC 个文件"
else
    warn "缺少 ath11k-firmware.tar.gz —— 网卡 reset 后会掉线（开机仍能用）"
fi

# ALSA UCM 定义：没有它 ACP 解析不了 Syntax 7 的 HiFi.conf，
# 只会提供 off / pro-audio 两个空 profile，sink 永远停在 Dummy Output。
if [ -d "$R/firmware/ucm" ]; then
    mkdir -p /usr/share/alsa/ucm2/conf.d/sm8250
    cp -f "$R/firmware/ucm/Xiaomi-dagu/HiFi.conf" /usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf 2>/dev/null || {
        mkdir -p /usr/share/alsa/ucm2/Xiaomi-dagu
        cp -f "$R/firmware/ucm/Xiaomi-dagu/HiFi.conf" /usr/share/alsa/ucm2/Xiaomi-dagu/HiFi.conf
    }
    cp -f "$R/firmware/ucm/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf" \
          /usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf
    echo "    ALSA UCM 定义已安装"
else
    warn "缺少 firmware/ucm —— PipeWire 只会给 Dummy Output"
fi

# ---------------------------------------------------------------- 4. 网络
say "4/8 网络（NetworkManager 独占）"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq network-manager
systemctl disable --now wpa_supplicant@wlp1s0 2>/dev/null || true
systemctl mask wpa_supplicant@wlp1s0 2>/dev/null || true
systemctl disable --now systemd-networkd 2>/dev/null || true
systemctl enable --now NetworkManager

read -r -p "Wi-Fi SSID（留空跳过）: " SSID
if [ -n "${SSID:-}" ]; then
    read -r -s -p "Wi-Fi 密码: " PSK; echo
    nmcli dev wifi connect "$SSID" password "$PSK" || warn "连接失败，稍后可用 nmcli 重试"
fi

# ---------------------------------------------------------------- 5. 桌面
say "5/8 安装 GNOME 桌面（约 700 MB，视网络 10-30 分钟）"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gnome-core gdm3 firefox-esr alsa-utils alsa-ucm-conf easyeffects i2c-tools mesa-utils usbutils pciutils
echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager
systemctl enable gdm3
systemctl set-default graphical.target

# /dev/snd/* 是 root:audio 660，桌面用户不在 audio 组时 amixer 会报
# "Invalid card number"，dagu-audio-up 判 no mixer 后 PipeWire 只剩 Dummy Output。
for U in youqi debian; do
    id "$U" >/dev/null 2>&1 && usermod -aG audio "$U" && echo "    $U 已加入 audio 组"
done

# ---------------------------------------------------------------- 6. 服务和配置
say "6/8 安装服务与配置"
if [ -f "$R/config/anchor-cfg-20261020.tar.gz" ]; then
    TMP=$(mktemp -d)
    tar -xzf "$R/config/anchor-cfg-20261020.tar.gz" -C "$TMP"
    cp -f "$TMP/anchor-cfg/logind.conf" /etc/systemd/logind.conf
    mkdir -p /etc/NetworkManager/conf.d
    cp -f "$TMP"/anchor-cfg/nm/*.conf /etc/NetworkManager/conf.d/ 2>/dev/null || true
    cp -f "$TMP"/anchor-cfg/services/*.service /etc/systemd/system/ 2>/dev/null || true
    rm -rf "$TMP"
    systemctl daemon-reload
    systemctl enable wifi-powersave-off venus-load dagu-audio-up 2>/dev/null || true
    echo "    服务已安装（logind/NM/services）"
else
    warn "缺少 config/anchor-cfg-20261020.tar.gz，服务未安装"
fi

# 触摸屏虚拟键盘（OSK）
# 关键：gnome-shell 只在启动时读一次这个设置，运行中改 gsettings 无效
# （OSK 对象已 dispose，不会再重建）。所以必须在首次登录前写对，
# 并且给 GDM greeter 也配上，否则锁屏/登录界面无法输入密码。
if id youqi >/dev/null 2>&1; then
    UID_Y=$(id -u youqi)
    if [ -d "/run/user/$UID_Y" ]; then
        su - youqi -c "export XDG_RUNTIME_DIR=/run/user/$UID_Y; \
            export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_Y/bus; \
            gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true" 2>/dev/null \
            && echo "    触摸屏虚拟键盘已启用（youqi）" \
            || warn "youqi 的 OSK 设置失败，登录后手动执行：gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true"
    else
        warn "youqi 尚未登录，OSK 需在首次登录后设置（或重启一次让 GDM dconf 生效）"
    fi
fi

mkdir -p /etc/dconf/db/gdm.d /etc/dconf/profile
printf '[org/gnome/desktop/a11y/applications]\nscreen-keyboard-enabled=true\n' \
    > /etc/dconf/db/gdm.d/00-osk
printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' \
    > /etc/dconf/profile/gdm
dconf update 2>/dev/null
echo "    GDM 登录界面虚拟键盘已配置"

# Easy Effects（EQ 调音）
# 架构：默认输出保持硬件 sink（这样系统音量条才有效）；
# easyeffects 通过 filter-chain 处理，easyeffects_sink 是它的入口 capture 节点，
# 必须存在 —— 删掉它整条 EQ 链就断了（实测过）。
# 设备列表里会看到两个输出设备，这是 filter-chain 的固有结构，无法避免。
if [ -f "$R/config/systemd-user/easyeffects.service" ] && id youqi >/dev/null 2>&1; then
    UID_E=$(id -u youqi)
    install -d -o youqi -g youqi /home/youqi/.config/systemd/user
    install -o youqi -g youqi -m 644 "$R/config/systemd-user/easyeffects.service" \
        /home/youqi/.config/systemd/user/easyeffects.service
    if [ -d "/run/user/$UID_E" ]; then
        su - youqi -c "export XDG_RUNTIME_DIR=/run/user/$UID_E; \
            export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_E/bus; \
            systemctl --user daemon-reload; systemctl --user enable easyeffects" 2>/dev/null \
            && echo "    Easy Effects 已启用（默认输出保持硬件，音量条有效）" \
            || warn "Easy Effects service 启用失败，登录后手动执行 systemctl --user enable easyeffects"
    else
        warn "youqi 尚未登录，Easy Effects 需在首次登录后启用"
    fi
else
    warn "缺少 config/systemd-user/easyeffects.service，EQ 调音不可用"
fi

# 音频初始化脚本与服务（修好时序问题的那版：等 /run/user/1001 出现 + 麦克风重试仅 3 次）
if [ -f "$R/install/dagu-audio-up.sh" ]; then
    install -m 0755 "$R/install/dagu-audio-up.sh" /usr/local/bin/dagu-audio-up.sh
    echo "    dagu-audio-up.sh 已安装"
fi
if [ -f "$R/install/dagu-audio-up.service" ]; then
    install -m 0644 "$R/install/dagu-audio-up.service" /etc/systemd/system/dagu-audio-up.service
    systemctl daemon-reload
    systemctl enable dagu-audio-up 2>/dev/null || true
    echo "    dagu-audio-up.service 已安装并启用"
fi

# 电源键：锁屏而非 suspend（avoid ath11k -108 on resume）
su - "$NEWUSER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$NEWUSER") gsettings set org.gnome.settings-daemon.plugins.power power-button-action interactive" 2>/dev/null || true

# 关键：关闭自动挂起。ath11k 在 resume 时返回 -108，会把 Wi-Fi 打成"僵尸 6 Mbit/s"
for k in sleep-inactive-ac-type sleep-inactive-battery-type; do
    su - "$NEWUSER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$NEWUSER") gsettings set org.gnome.settings-daemon.plugins.power $k nothing" 2>/dev/null || true
done
su - "$NEWUSER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$NEWUSER") gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0" 2>/dev/null || true

# ---------------------------------------------------------------- 7. 可选软件
say "7/8 可选：WPS Office（ARM64，2.6 GB）"
if [ -f /root/wps365_arm64.deb ]; then
    dpkg -i /root/wps365_arm64.deb || apt-get -f install -y
elif [ -f "$R/../wps365_arm64.deb" ]; then
    dpkg -i "$R/../wps365_arm64.deb" || apt-get -f install -y
else
    echo "    未找到 wps365_arm64.deb，跳过（可从 WPS 365 官网 ARM64 渠道获取）"
fi

# ---------------------------------------------------------------- 8. 验证
say "8/8 验证"
echo "  内核      : $(uname -r)"
echo "  国家码    : $(iw reg get 2>/dev/null | sed -n 2p)"
echo "  屏幕      : $(cat /sys/class/drm/card0-DSI-1/status 2>/dev/null || echo N/A)"
echo "  触摸      : $(cat /sys/class/input/input7/name 2>/dev/null || echo N/A)"
echo "  蓝牙      : $(bluetoothctl show 2>/dev/null | grep Powered || echo N/A)"
echo "  Wi-Fi     : $(iw dev wlp1s0 link 2>/dev/null | grep -E 'SSID|bitrate' | tr '\n' ' ')"
echo "  USB       : max=$(cat /sys/class/udc/*/maximum_speed 2>/dev/null) cur=$(cat /sys/class/udc/*/current_speed 2>/dev/null)"
echo "  Venus     : $(ls /dev/video15 2>/dev/null || echo 未加载)"
echo "  根分区    : $(df -h / | tail -1)"

if ! iw reg get 2>/dev/null | grep -q "country CN"; then
    warn "国家码不是 CN —— 说明 boot 里的 regulatory.db 没生效，检查 dmesg | grep regulatory"
fi

cat <<'EOF'

配置完成，重启后进入 GNOME 桌面：
  reboot

若 Wi-Fi 速度掉到 6 Mbit/s，检查 /proc/cmdline 是否含 pcie_aspm=off（必须没有）。
EOF
