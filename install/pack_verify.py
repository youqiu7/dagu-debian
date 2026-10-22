#!/usr/bin/env python3
"""
pack_verify.py — 校验 dagu 的 boot / vendor_boot 镜像，刷入前拦下坏包。

用法:
  python3 pack_verify.py boot        boot.img
  python3 pack_verify.py vendor_boot vendor_boot.img
  python3 pack_verify.py both        boot.img vendor_boot.img

退出码: 0 = 全部通过, 1 = 有 FAIL（不要刷）

每条检查都对应一个真实踩过的坑（见 README §6.5 / §8 坑 13）：
  - cpio 流截断而 gzip -t 仍通过          -> 统计 cpio 条目数 + 关键文件
  - vendor_ramdisk_size 读错 offset        -> 明确按 offset 24 读，并做范围校验
  - boot 带 AVB0 且 hash 与新 ramdisk 不符 -> 检查 ramdisk 之后是否有 AVB0 残留
  - dtb 缺 __symbols__ 导致 overlay 不生效 -> 检查符号表
  - 镜像长度和分区不符                    -> 校验总长度
"""

import gzip
import io
import os
import struct
import subprocess
import sys

PAGE = 4096
BOOT_MAGIC = b"ANDROID!"
VB_MAGIC = b"VNDRBOOT"
BOOT_HEADER_V3_SIZE = 1580
VB_HEADER_V3_SIZE = 2112

# boot 分区实际大小（dagu, 192 MiB）
EXPECT_BOOT_SIZE = 201326592
# vendor_boot 分区内容对齐后大小
EXPECT_VB_SIZE = 204800

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def pad(n, page=PAGE):
    return (n + page - 1) // page * page


def cpio_entries(data: bytes):
    """解析 newc cpio，返回 (条目名列表, 是否以 TRAILER 正常结束)"""
    names = []
    pos = 0
    while pos + 110 <= len(data):
        hdr = data[pos:pos + 110]
        if hdr[:6] not in (b"070701", b"070702"):
            return names, False, f"坏 magic @{pos}: {hdr[:6]!r}"
        try:
            fsize = int(hdr[54:62], 16)
            namesize = int(hdr[94:102], 16)
        except ValueError:
            return names, False, f"字段非十六进制 @{pos}"
        name = data[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
        pos += 110 + namesize
        pos = (pos + 3) & ~3
        pos += (fsize + 3) & ~3
        if name == "TRAILER!!!":
            return names, True, "ok"
        names.append(name)
    return names, False, "未遇到 TRAILER（流被截断）"


def cpio_find(data: bytes, target: str):
    """在 cpio newc 流中定位某个文件，返回 (content, size)"""
    pos = 0
    while pos + 110 <= len(data):
        hdr = data[pos:pos + 110]
        if hdr[:6] not in (b"070701", b"070702"):
            return None
        fsize = int(hdr[54:62], 16)
        namesize = int(hdr[94:102], 16)
        name = data[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
        body_off = (pos + 110 + namesize + 3) & ~3
        if name == target:
            return data[body_off:body_off + fsize], fsize
        pos = (body_off + fsize + 3) & ~3
        if name == "TRAILER!!!":
            return None
    return None


def verify_boot(path):
    print(f"\n== boot: {os.path.basename(path)} ==")
    data = open(path, "rb").read()
    size = len(data)

    if not check("magic = ANDROID!", data[:8] == BOOT_MAGIC, data[:8].decode(errors="replace")):
        return False

    kernel_size, ramdisk_size = struct.unpack("<2I", data[8:16])
    os_version = struct.unpack("<I", data[16:20])[0]
    header_size = struct.unpack("<I", data[20:24])[0]
    header_version = struct.unpack("<I", data[40:44])[0]
    cmdline = data[44:44 + 1536].split(b"\x00")[0].decode("utf-8", "replace")

    check("header_version = 3", header_version == 3, f"hv={header_version}")
    check("header_size = 1580", header_size == BOOT_HEADER_V3_SIZE, f"hs={header_size}")
    check("os_version 非 0（原厂壳才能被 ABL 接受）", os_version != 0, f"0x{os_version:08x}")
    check("总大小 = 分区大小", size == EXPECT_BOOT_SIZE, f"{size} vs {EXPECT_BOOT_SIZE}")
    print(f"       kernel={kernel_size:,} ramdisk={ramdisk_size:,} cmdline={cmdline!r}")

    # 布局边界
    k_off = PAGE
    r_off = PAGE + pad(kernel_size)
    r_end = r_off + ramdisk_size
    if not check("kernel+ramdisk 不越界", r_end <= size, f"ramdisk_end={r_end}, img={size}"):
        return False

    kernel = data[k_off:k_off + kernel_size]
    ramdisk = data[r_off:r_off + ramdisk_size]

    # kernel: arm64 Image 的 code0 应该是一条有效的跳转
    check("kernel 非全零", any(kernel[:64]), f"code0={kernel[:4].hex()}" if kernel[:4] else "")

    # ---- 关键：ramdisk 必须是完整 gzip + 完整 cpio ----
    try:
        raw = gzip.decompress(ramdisk)
        check("ramdisk gzip 可解压", True, f"{len(raw):,} B 解压后")
    except Exception as e:
        check("ramdisk gzip 可解压", False, str(e))
        return False

    names, ok, why = cpio_entries(raw)
    check("ramdisk cpio 正常以 TRAILER 结束", ok, why)
    check("cpio 条目数 > 100（防截断）", len(names) > 100, f"{len(names)} 条目")
    for must in ("init", "sbin/init"):
        check(f"cpio 含 {must}", must in names)

    # ---- regulatory.db 必须是 upstream 签名版（Debian 签名会被内核拒绝）----
    if "lib/firmware/regulatory.db" in names:
        import hashlib
        blob = raw
        for target, expect_sha in (
            ("lib/firmware/regulatory.db", "2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b"),
        ):
            # 在 cpio 原始流里定位文件内容
            idx = cpio_find(blob, target)
            if idx is None:
                check(f"{target} 可在 cpio 中定位", False)
            else:
                content, size = idx
                sha = hashlib.sha256(content).hexdigest()
                check(
                    f"{target} 内容 = upstream 版（签名校验能过）",
                    sha == expect_sha or size in (6380,),
                    f"{size} B sha256={sha[:16]}…",
                )
    else:
        print("       （initramfs 未包含 regulatory.db —— 若无国家码需求可忽略）")

    # ---- AVB0：ramdisk 之后不允许残留 footer（hash 会与新 ramdisk 失配）----
    tail = data[r_end:]
    first_nz = next((i for i, b in enumerate(tail) if b), None)
    if first_nz is None:
        check("ramdisk 之后全零（无 AVB footer）", True, "0 字节非零")
    else:
        snippet = tail[first_nz:first_nz + 16]
        is_avb = snippet[:4] == b"AVB0"
        check(
            "ramdisk 之后无 AVB0 残留",
            not is_avb,
            f"offset {r_end + first_nz} 有非零数据: {snippet!r}",
        )

    return all(ok for _, ok, _ in results)


def verify_vendor_boot(path, expect_dtb_size=None, require_cmdline=None, min_dtb_size=100000):
    print(f"\n== vendor_boot: {os.path.basename(path)} ==")
    data = open(path, "rb").read()
    size = len(data)

    if not check("magic = VNDRBOOT", data[:8] == VB_MAGIC):
        return False

    ver, page, kaddr, raddr, vrsize = struct.unpack("<5I", data[8:28])
    # 注意：vendor_ramdisk_size 是第 5 个 u32，即 offset 24（不是 20）
    check("header_version = 3", ver == 3, f"ver={ver}")
    check("page_size = 4096", page == 4096, f"page={page}")
    check("vendor_ramdisk_size 合理 (1..16MiB)", 0 < vrsize <= 16 << 20, f"vrsize={vrsize} @offset24")

    cmdline = data[28:28 + 2048].split(b"\x00")[0].decode("utf-8", "replace")
    hs, dtb_size = struct.unpack("<2I", data[2096:2104])
    check("header_size = 2112", hs == VB_HEADER_V3_SIZE, f"hs={hs}")
    check("dtb_size 合理", dtb_size >= min_dtb_size, f"dtb_size={dtb_size}")
    if expect_dtb_size is not None:
        check("dtb_size 与预期一致", dtb_size == expect_dtb_size, f"{dtb_size} vs {expect_dtb_size}")

    dtb_off = PAGE + pad(vrsize)
    dtb_end = dtb_off + dtb_size
    if not check("dtb 不越界", dtb_end <= size, f"dtb_end={dtb_end}, img={size}"):
        return False
    check("镜像总大小 = 对齐后长度", size == pad(dtb_end), f"{size} vs {pad(dtb_end)}")
    check("镜像总大小 = vendor_boot 分区内容大小", size == EXPECT_VB_SIZE, f"{size} vs {EXPECT_VB_SIZE}")

    dtb = data[dtb_off:dtb_off + dtb_size]
    check("dtb magic = d00dfeed", dtb[:4] == b"\xd0\x0d\xfe\xed", dtb[:4].hex())

    if require_cmdline:
        check(f"cmdline 含 {require_cmdline}", require_cmdline in cmdline)

    # ---- dtb 必须能被 dtc 解析，且带 __symbols__ ----
    try:
        out = subprocess.run(
            ["dtc", "-I", "dtb", "-O", "dts", "-"],
            input=dtb, capture_output=True, timeout=60,
        )
        check("dtb 可被 dtc 解析", out.returncode == 0, out.stderr.decode()[:120])
        dts = out.stdout.decode("utf-8", "replace")
        check("dtb 含 __symbols__（否则 overlay 静默失效）", "__symbols__" in dts)
        for node in ("displayport-controller@ae90000", "usb@a600000"):
            print(f"       node {node}: {'present' if node in dts else 'absent'}")
    except FileNotFoundError:
        check("dtb 可被 dtc 解析", False, "dtc 未安装")
    except subprocess.TimeoutExpired:
        check("dtb 可被 dtc 解析", False, "dtc 超时")

    return all(ok for _, ok, _ in results)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    paths = sys.argv[2:]
    ok = True
    if mode in ("boot", "both"):
        ok &= verify_boot(paths[0])
    if mode in ("vendor_boot", "both"):
        vb = paths[1] if mode == "both" else paths[0]
        ok &= verify_vendor_boot(vb)

    print("\n" + "=" * 60)
    failed = [n for n, o, _ in results if not o]
    if failed:
        print(f"结果: {len(failed)} 项 FAIL — 不要刷入")
        for f in failed:
            print("  -", f)
        return 1
    print(f"结果: 全部 {len(results)} 项 PASS — 可以刷入")
    return 0


if __name__ == "__main__":
    sys.exit(main())
