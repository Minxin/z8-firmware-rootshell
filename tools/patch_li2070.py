#!/usr/bin/env python3
"""
patch_li2070.py — 修改 Z8 第二核镜像 li2070 的 initramfs，并保持模块字节数不变。

背景（硬约束）：
  repack_firmware.py 的 --replace-module 要求新模块与原 payload 长度**严格相同**
  （li2070 payload = 15,822,848 字节 = 模块长度 15,822,850 - 2 字节 CRC）。
  所以本脚本只做**原地替换**，绝不改变任何长度：

    li2070 布局（已实测）
      0x000000  NISI header（0x38 处 = initramfs gzip 长度 0x963dbb）
      0x5b1000  initramfs（gzip，压缩后 9,846,203 字节）
      0xf14dbb  其后 581 字节 0x00 padding，然后是 DTB（魔数 d00dfeed）
      0xf17002  模块结束

做法：
  1. 解压 gzip -> cpio(newc)
  2. 在 cpio 内**原地**覆盖一行（新内容比原行长就报错，绝不移动数据）
  3. 重新 gzip -9（实测比原文件小 ~3.3KB，有余量）
  4. 用 0x00 把 gzip 段补回原长度（标准 gzip 解压器在流结束处停止，忽略尾部）
  5. 拼回 li2070 —— DTB 与之后所有数据保持原偏移不变，总长度不变

用法：
  python3 patch_li2070.py                       # 默认：注入 telnetd 到 S11-LaMainApp
  python3 patch_li2070.py --dry-run             # 只验证可行性，不写文件
  python3 patch_li2070.py --show                # 打印将被替换的脚本内容
  python3 patch_li2070.py --out work/li_new.bin

注入后（相机刷入并开机、WiFi 起来后）：
  nc <相机IP> 2323     或    telnet <相机IP> 2323
  即可拿到第二核 root shell。随后可用 la_sh / osmem。
"""
import argparse
import os
import struct
import sys
import zlib

GZ_OFF = 0x5B1000      # initramfs gzip 在 li2070 内的偏移
GZ_LEN = 0x963DBB      # initramfs gzip 的压缩后长度（= header 0x38 处的值）

# 被覆盖的目标：S11-LaMainApp 里一行已被注释掉的 insmod（永远不会执行）
OLD_LINE = b"#\t\t/sbin/insmod /lib/modules/$MODULE.ko $* || exit 1"
# 注入的命令。telnetd 在 initramfs 里已存在（usr/sbin/telnetd）
NEW_CMD = b"\t\t/usr/sbin/telnetd -l /bin/sh -p 2323 &"


def die(msg, code=1):
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(code)


def extract_cpio(li):
    """从 li2070 解出 initramfs cpio。"""
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = dec.decompress(li[GZ_OFF:GZ_OFF + GZ_LEN])
    if len(out) == 0:
        die("gzip 解压失败，偏移 0x%x 处不是有效的 gzip 流" % GZ_OFF)
    return bytearray(out)


def patch_in_place(cpio, old, cmd):
    """原地覆盖一行。新内容必须能放进原行（含换行）的长度内。"""
    i = cpio.find(old)
    if i < 0:
        die("找不到目标行：%r" % old)
    # 原行含换行
    end = cpio.find(b"\n", i)
    if end < 0:
        die("目标行没有换行符，无法确定行边界")
    room = end - i + 1                      # 含换行的可用字节数
    if len(cmd) + 1 > room:
        die("放不下：命令 %d 字节，可用 %d 字节（含换行）。\n"
            "       请换更短的命令，或改用 cpio 重建方式（会改变长度，需另想办法）。"
            % (len(cmd), room))
    newline = cmd + b" " * (room - len(cmd) - 1) + b"\n"
    assert len(newline) == room
    cpio[i:end + 1] = newline
    return i, room


def rebuild_li(orig_li, new_cpio):
    """重新 gzip 并拼回 li2070；gzip 段用 0x00 补回原长度，保证总长不变。"""
    co = zlib.compressobj(9, zlib.DEFLATED, 16 + zlib.MAX_WBITS)
    gz = co.compress(bytes(new_cpio)) + co.flush()
    if len(gz) > GZ_LEN:
        die("重新压缩后 %d 字节 > 原 %d 字节，放不下了（差 %d）"
            % (len(gz), GZ_LEN, len(gz) - GZ_LEN))
    pad = GZ_LEN - len(gz)
    out = bytearray()
    out += orig_li[:GZ_OFF]
    out += gz
    out += b"\x00" * pad
    out += orig_li[GZ_OFF + GZ_LEN:]        # padding + DTB + 其余，原样保留
    return bytes(out), len(gz), pad


def verify(orig_li, new_li, expect_cmd):
    """自检：长度、gzip 可解压、注入内容确实存在。"""
    assert len(new_li) == len(orig_li), \
        "长度变了：%d -> %d" % (len(orig_li), len(new_li))
    # gzip 段之外必须逐字节相同（DTB 等绝不能被动过）
    assert new_li[:GZ_OFF] == orig_li[:GZ_OFF], "gzip 之前的字节被改动"
    assert new_li[GZ_OFF + GZ_LEN:] == orig_li[GZ_OFF + GZ_LEN:], \
        "gzip 之后的字节（padding/DTB）被改动"
    # 解压回来验证
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    cpio = dec.decompress(new_li[GZ_OFF:GZ_OFF + GZ_LEN])
    assert expect_cmd in cpio, "注入的命令在解压后的 cpio 里找不到"
    return len(cpio)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--li", default="z8dec/li2070_0311b0.bi", help="原始 li2070 模块")
    ap.add_argument("--out", default="work/li2070_patched.bin", help="输出")
    ap.add_argument("--cmd", default=NEW_CMD.decode(), help="要注入的命令（单行）")
    ap.add_argument("--dry-run", action="store_true", help="只验证，不写文件")
    ap.add_argument("--show", action="store_true", help="打印将被替换的脚本")
    args = ap.parse_args()

    li = open(args.li, "rb").read()
    print("input  %s  %d bytes" % (args.li, len(li)))

    if len(li) != 15822850:
        print("  警告：长度不是预期的 15,822,850，布局常量可能不适用")

    cpio = extract_cpio(li)
    print("cpio   %d bytes" % len(cpio))

    if args.show:
        i = cpio.find(OLD_LINE)
        if i < 0:
            die("找不到目标脚本行")
        print("\n--- S11-LaMainApp 片段（第 1 行将被替换）---")
        print(cpio[max(0, i - 400):i + 300].decode("utf-8", "replace"))
        return 0

    cmd = args.cmd.encode()
    off, room = patch_in_place(cpio, OLD_LINE, cmd)
    print("patch  cpio+0x%x  (%d 字节行，命令 %d 字节，补 %d 空格)"
          % (off, room, len(cmd), room - len(cmd) - 1))

    new_li, gzlen, pad = rebuild_li(li, cpio)
    print("gzip   %d bytes (原 %d，省 %d)，补 0x00 %d 字节" % (gzlen, GZ_LEN, GZ_LEN - gzlen, pad))

    cplen = verify(li, new_li, cmd)
    print("verify 长度一致 / 前后字节未动 / 解压后 cpio %d 字节 / 注入内容存在" % cplen)

    if args.dry_run:
        print("\n[dry-run] 未写文件。方案可行。")
        return 0

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(new_li)
    print("\nwrote  %s  (%d bytes, 与输入等长)" % (args.out, len(new_li)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
