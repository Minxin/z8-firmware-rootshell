#!/bin/sh
# z8_recon.sh — 相机端侦察脚本（在 Z8 第二核的 root shell 里运行）
#
# 怎么传上去（三选一）：
#   A) 主机起 HTTP：  python3 -m http.server 8000
#      相机上：       wget -O- http://<主机IP>:8000/z8_recon.sh | sh
#   B) 直接把内容粘贴进 telnet 会话
#   C) 用 printf 逐行敲
#
# 目标：搞清楚第二核能看到哪些内存窗口，以及能否够到主核(EXPEED)内存。
#
# ★ 关键认知：
#   DSID 表在 0x16000000 —— 那是**主核**的地址空间。
#   第二核的物理内存是 0x807800000（120MB），看不到 0x16000000。
#   所以「动态写 DSID」必须先把主核内存映射到第二核能看到的地方，
#   候选窗口：/dev/uio0（peri_pmc @0x840000000, ~2.9GB）或 /dev/mem。
#   本脚本先侦察，不假设地址。

echo "=========================================="
echo " Z8 第二核侦察"
echo "=========================================="

echo; echo "--- 1. 身份 ---"
id 2>&1
echo "uname: $(uname -a)"

echo; echo "--- 2. 关键设备节点 ---"
for d in /dev/mem /dev/kmem /dev/uio0 /dev/uio1 /dev/oscom_memhelper /dev/oscom_inthelper /dev/nikon_ipcu; do
    if [ -e "$d" ]; then echo "  [有] $d  $(ls -l $d 2>/dev/null | awk '{print $1,$3,$4}')"
    else echo "  [无] $d"; fi
done
echo "  --- /dev 下 uio/mem/oscom/nikon ---"
ls /dev 2>/dev/null | grep -iE 'uio|mem|oscom|nikon' | sed 's/^/     /'

echo; echo "--- 3. 已加载模块 ---"
lsmod 2>/dev/null | head -20

echo; echo "--- 4. 网络接口（找相机 IP）---"
ip addr 2>/dev/null | grep -E 'inet |^[0-9]' | sed 's/^/  /' || \
  ifconfig 2>/dev/null | grep -E 'inet |^[a-z]' | sed 's/^/  /'

echo; echo "--- 5. 进程（看 LaMainApp / telnetd 是否活着）---"
ps 2>/dev/null | grep -iE 'LaMain|telnet|avahi|wpa|hostap' | grep -v grep | sed 's/^/  /'

echo; echo "--- 6. 内核日志中的 UIO / mem 线索 ---"
dmesg 2>/dev/null | grep -iE 'uio|peri_pmc|memhelper|reserved' | head -10 | sed 's/^/  /'

echo; echo "--- 7. /sys/class/uio 内容 ---"
for f in /sys/class/uio/uio*/maps/map0/addr /sys/class/uio/uio*/maps/map0/size /sys/class/uio/uio*/name; do
    [ -r "$f" ] && echo "  $f = $(cat $f)"
done

echo; echo "--- 8. 试读 /dev/mem（第二核内存起点 0x807800000）---"
if [ -r /dev/mem ]; then
    dd if=/dev/mem bs=1 skip=$((0x807800000)) count=64 2>/dev/null | hexdump -C | sed 's/^/  /'
    echo "  (若全是 0 或报错，说明高地址不可读)"
else
    echo "  /dev/mem 不可读"
fi

echo; echo "--- 9. 试读 /dev/uio0（偏移 0 == 物理 0x840000000）---"
if [ -e /dev/uio0 ]; then
    dd if=/dev/uio0 bs=1 count=64 2>/dev/null | hexdump -C | sed 's/^/  /'
else
    echo "  /dev/uio0 不存在"
fi

echo; echo "--- 10. 试读 /dev/oscom_memhelper（共享内存）---"
if [ -e /dev/oscom_memhelper ]; then
    for off in $((0x80F000000)) $((0x80F002000)); do
        echo "  偏移 $off:"
        dd if=/dev/oscom_memhelper bs=1 skip=$off count=32 2>/dev/null | hexdump -C | sed 's/^/    /'
    done
else
    echo "  /dev/oscom_memhelper 不存在"
fi

echo; echo "=========================================="
echo " 侦察完成。请把以上输出发回来，据此决定下一步。"
echo "=========================================="
