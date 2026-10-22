#!/usr/bin/env bash
# build_flash.sh — dagu boot 链的打包+校验+刷写+验证 一条龙
#
# 设计原则：任何一步失败就停，绝不把未通过校验的镜像写到设备上。
#
# 用法（在 WSL 里跑）:
#   ./build_flash.sh pack   <boot-src> <vb-src> [--dtb file.dtb] [--cmdline-append "k=v"] [--rd-dir dir]
#   ./build_flash.sh verify <boot.img> <vendor_boot.img>
#   ./build_flash.sh flash  <boot.img> <vendor_boot.img> [slot]
#   ./build_flash.sh status
#
# 环境变量:
#   KSRC    内核树（默认 /root/k619/linux-6.19.14）
#   FASTBOOT Windows fastboot.exe（默认项目内 platform-tools）
#   TMPWIN  Windows 可访问的临时目录（默认 /mnt/c/Users/<you>/AppData/Local/Temp/dagu-boot）
set -euo pipefail

PROJ="/mnt/f/小米刷机/dagu移植debian/new-chat-1"
TOOLS="$PROJ/04-tools"
VERIFY="$TOOLS/pack_verify.py"
KSRC="${KSRC:-/root/k619/linux-6.19.14}"
FASTBOOT="${FASTBOOT:-$PROJ/platform-tools/platform-tools/fastboot.exe}"
FB_WIN="C:/Users/duoya/AppData/Local/Temp/dagu-boot"
TMP="${TMP:-/root/repack}"
PAGE=4096

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[STOP] %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------ 打包
# pack boot 壳 + kernel + (可选替换的) ramdisk，vendor_boot 壳 + (可选替换的) dtb
pack_one() {
    local shell="$1" kernel="$2" ramdisk="$3" out="$4"
    python3 - "$shell" "$kernel" "$ramdisk" "$out" <<'PY'
import struct, sys, os
PAGE = 4096
shell, kernel_path, ramdisk_path, out = sys.argv[1:5]

def pad(n): return (n + PAGE - 1) // PAGE * PAGE

data = bytearray(open(shell, "rb").read())
assert data[:8] == b"ANDROID!", "shell 不是 boot 镜像"
ks_old, rs_old = struct.unpack("<2I", data[8:16])
hdr = bytearray(data[:1580])
kernel = open(kernel_path, "rb").read()
ramdisk = open(ramdisk_path, "rb").read()
struct.pack_into("<I", hdr, 8, len(kernel))
struct.pack_into("<I", hdr, 12, len(ramdisk))
outbuf = bytes(hdr) + b"\x00" * (PAGE - 1580) + kernel + b"\x00" * (pad(len(kernel)) - len(kernel))
outbuf += ramdisk + b"\x00" * (pad(len(ramdisk)) - len(ramdisk))
# 关键：ramdisk 之后必须全零（清掉原壳里与新 ramdisk 失配的 AVB0）
outbuf += b"\x00" * max(0, len(data) - len(outbuf))
open(out, "wb").write(outbuf[:len(data)])
print(f"  packed {out}: kernel={len(kernel):,} ramdisk={len(ramdisk):,} total={len(data):,}")
PY
}

pack_vendor_boot() {
    local shell="$1" dtb="$2" out="$3" cmdline_append="${4:-}"
    python3 - "$shell" "$dtb" "$out" "$cmdline_append" <<'PY'
import struct, sys
PAGE = 4096
shell, dtb_path, out, append = sys.argv[1:5]

def pad(n): return (n + PAGE - 1) // PAGE * PAGE

d = bytearray(open(shell, "rb").read())
assert d[:8] == b"VNDRBOOT", "shell 不是 vendor_boot"
ver, pg, kaddr, raddr, vrsize = struct.unpack("<5I", d[8:28])   # vrsize 在 offset 24
hs, dtb_size_old = struct.unpack("<2I", d[2096:2104])
vr = d[PAGE:PAGE + vrsize]
dtb = open(dtb_path, "rb").read()

hdr = bytearray(d[:2112])
struct.pack_into("<I", hdr, 2100, len(dtb))
if append:
    cmd = bytes(hdr[28:28 + 2048]).split(b"\x00")[0].decode()
    if append not in cmd:
        cmd = (cmd + " " + append).strip()
        enc = cmd.encode()
        assert len(enc) < 2048, "cmdline 超长"
        hdr[28:28 + 2048] = enc + b"\x00" * (2048 - len(enc))
        print(f"  cmdline += {append}")

outbuf = bytes(hdr) + b"\x00" * (PAGE - 2112) + bytes(vr) + b"\x00" * (pad(vrsize) - vrsize)
outbuf += dtb + b"\x00" * (pad(len(dtb)) - len(dtb))
open(out, "wb").write(outbuf)
print(f"  packed {out}: vrsize={vrsize} dtb={len(dtb):,} total={len(outbuf):,}")
PY
}

# ------------------------------------------------------------------ 子命令
cmd="${1:-}"; shift || true

case "$cmd" in
verify)
    [ $# -ge 2 ] || die "用法: verify <boot.img> <vendor_boot.img>"
    say "校验 $1 / $2"
    python3 "$VERIFY" both "$1" "$2" || die "校验未通过 —— 不要刷入"
    ok "校验通过"
    ;;

pack)
    BOOT_SHELL="${BOOT_SHELL:-$PROJ/dagu-port/10-upstream-dagu/boot-dagu.img}"
    VB_SHELL="${VB_SHELL:-$PROJ/dagu-port/10-upstream-dagu/vendor_boot-content.img}"
    KERNEL=""
    RAMDISK=""
    DTB=""
    APPEND=""
    RD_DIR=""
    OUT_BOOT="$TMP/boot-new.img"
    OUT_VB="$TMP/vendor_boot-new.img"
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel)   KERNEL="$2"; shift 2;;
            --ramdisk)  RAMDISK="$2"; shift 2;;
            --rd-dir)   RD_DIR="$2"; shift 2;;
            --dtb)      DTB="$2"; shift 2;;
            *boot*src*) : ;;
            *) shift;;
        esac
    done

    mkdir -p "$TMP"
    # 内核：没给就用壳里原有的
    if [ -z "$KERNEL" ]; then
        say "从 boot 壳提取 kernel"
        python3 - "$BOOT_SHELL" "$TMP/kernel.bin" <<'PY'
import struct, sys
PAGE=4096; s,o=sys.argv[1:3]
d=open(s,"rb").read(); ks=struct.unpack("<I", d[8:12])[0]
open(o,"wb").write(d[PAGE:PAGE+ks]); print(f"  kernel {ks:,} B")
PY
        KERNEL="$TMP/kernel.bin"
    fi

    # initramfs：--rd-dir 给目录则重新打包（这才是需要校验的那步）
    if [ -n "$RD_DIR" ]; then
        say "重打包 initramfs: $RD_DIR"
        ( cd "$RD_DIR" && find . -print0 | cpio --null -o -H newc -R root:root 2>/dev/null | gzip -9 > "$TMP/ramdisk-new.gz" )
        gzip -t "$TMP/ramdisk-new.gz" || die "新 ramdisk gzip 损坏"
        ok "ramdisk $(stat -c%s "$TMP/ramdisk-new.gz") B"
        RAMDISK="$TMP/ramdisk-new.gz"
    fi
    if [ -z "$RAMDISK" ]; then
        say "从 boot 壳提取 ramdisk"
        python3 - "$BOOT_SHELL" "$TMP/ramdisk-old.gz" <<'PY'
import struct, sys
PAGE=4096; s,o=sys.argv[1:3]
d=open(s,"rb").read(); ks,rs=struct.unpack("<2I", d[8:16])
off=PAGE+((ks+PAGE-1)//PAGE)*PAGE
open(o,"wb").write(d[off:off+rs]); print(f"  ramdisk {rs:,} B")
PY
        RAMDISK="$TMP/ramdisk-old.gz"
    fi

    say "打包 boot"
    pack_one "$BOOT_SHELL" "$KERNEL" "$RAMDISK" "$OUT_BOOT"

    say "打包 vendor_boot"
    if [ -z "$DTB" ]; then
        DTB="$TMP/dtb-current.dtb"
        python3 - "$VB_SHELL" "$DTB" <<'PY'
import struct, sys
PAGE=4096; s,o=sys.argv[1:3]
d=open(s,"rb").read()
vrsize=struct.unpack("<I", d[24:28])[0]; dtbsz=struct.unpack("<I", d[2100:2104])[0]
off=PAGE+((vrsize+PAGE-1)//PAGE)*PAGE
open(o,"wb").write(d[off:off+dtbsz]); print(f"  dtb {dtbsz:,} B")
PY
        [ -n "$APPEND" ] && die "--cmdline-append 需要配合 --dtb? 不，可直接用现有 dtb"
    fi
    pack_vendor_boot "$VB_SHELL" "$DTB" "$OUT_VB" "$APPEND"

    say "校验（未通过不刷）"
    python3 "$VERIFY" both "$OUT_BOOT" "$OUT_VB" || die "校验失败：镜像不可用，已停在打包阶段"
    ok "校验通过: $OUT_BOOT / $OUT_VB"
    ;;

flash)
    [ $# -ge 2 ] || die "用法: flash <boot.img> <vendor_boot.img> [slot]"
    SLOT="${3:-b}"
    say "刷前校验"
    python3 "$VERIFY" both "$1" "$2" || die "校验失败，拒绝刷写"

    say "确定槽位"
    CUR="$("$FASTBOOT" getvar current-slot 2>&1 | grep -oE '(a|b)$' | head -1 || true)"
    echo "  current-slot=${CUR:-unknown}  target=$SLOT"
    if [ -n "$CUR" ] && [ "$CUR" != "$SLOT" ]; then
        say "切到 $SLOT"
        "$FASTBOOT" set_active "$SLOT"
    fi

    cp "$1" "$FB_WIN/boot-flash.img"; cp "$2" "$FB_WIN/vb-flash.img"
    say "刷入"
    "$FASTBOOT" flash "boot_$SLOT" "$FB_WIN/boot-flash.img"
    "$FASTBOOT" flash "vendor_boot_$SLOT" "$FB_WIN/vb-flash.img"
    "$FASTBOOT" reboot
    ok "已刷入并重启，等待设备回来"
    ;;

status)
    say "设备状态"
    "$FASTBOOT" devices 2>&1 | tail -2
    for ip in 192.168.10.125 192.168.10.240 192.168.10.123; do
        if ping -c1 -W1 "$ip" >/dev/null 2>&1; then echo "  LAN $ip OK"; fi
    done
    ;;

*) sed -n '2,20p' "$0"; exit 2;;
esac
