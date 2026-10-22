#!/bin/bash
# switch-to-android — 从 Debian 切到 Android（a 槽）
#
# 槽位元数据在 ABL 私有区，Linux 侧写不了，所以本脚本只负责把设备送到 fastboot，
# 真正切槽必须在 PC 上执行：
#     switch-os.ps1 -To android
#
# 用法：
#   switch-to-android          # 进 fastboot 并打印后续步骤
#   switch-to-android --dry    # 只打印，不重启
set -u

DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

cat <<'EOF'
=====================================================
  切到 Android（a 槽）
=====================================================
槽位只能由 ABL 修改，Debian 无法直接写。步骤：
  1) 本脚本重启到 fastboot
  2) 在 PC 上运行：
        switch-os.ps1 -To android
     （或手动：fastboot set_active a && fastboot reboot）
  3) 想切回来时：switch-os.ps1 -To debian
-----------------------------------------------------
如果设备没有自动进 fastboot（本内核 PON 为模块，
reboot bootloader 可能只回显不动作），请手动：
  长按电源 10 秒关机 → 按住【音量下 + 电源】直到出现 fastboot
=====================================================
EOF

if [ "$DRY" = "1" ]; then
    echo "[dry-run] 不重启"
    exit 0
fi

echo "5 秒后重启到 bootloader（Ctrl+C 取消）..."
sleep 5
sync
systemctl reboot bootloader 2>/dev/null || reboot bootloader
