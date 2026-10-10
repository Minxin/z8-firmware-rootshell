#!/bin/sh
# z8_dsid.sh — 【必须在相机第二核的 root shell 里运行】
#
# ★ 不是在你电脑上跑！设备文件 /dev/mem、/dev/uio0 只存在于相机上。
#   流程：电脑连相机 WiFi → sh z8_connect.sh → 在相机 shell 里跑本脚本
#
# ★★ 重要：三个内存通道里，只有 /dev/mem 能用 dd 读！
#     /dev/uio0         : uio_fops.read 返回的是【中断计数 u32】，不是内存！
#                         只能用 mmap（需交叉编译的 osmem 工具）
#     /dev/oscom_memhelper : 只有 mmap + ioctl，同样不能用 dd 读
#     /dev/mem          : 标准 mem_fops，可以用 dd 读 ✓（CONFIG_DEVMEM=y，
#                         且 CONFIG_STRICT_DEVMEM 未开启）
#
# 用法（相机 shell 内）：
#   sh z8_dsid.sh probe                      # 探测哪个通道可用 ← 先跑这个
#   sh z8_dsid.sh <主核物理地址hex> [输出]     # dump
#   sh z8_dsid.sh scan [MB]                  # 扫内存找主核特征
#   sh z8_dsid.sh diff a b                   # 对比两次 dump
#
# 例：
#   sh z8_dsid.sh probe
#   sh z8_dsid.sh 0x16000000 /tmp/before.bin
#   # 相机上改设置（开预拍 / 改画质）
#   sh z8_dsid.sh 0x16000000 /tmp/after.bin
#   sh z8_dsid.sh diff /tmp/before.bin /tmp/after.bin
#
# 环境变量：
#   DEV=/dev/mem    指定通道（默认自动选）
#   LEN=0x10000     指定 dump 长度（默认 64KB）

DSID_BASE=${DSID_BASE:-0x16000000}
LEN=${LEN:-65536}

# ---------- 基础检查 ----------
if [ ! -r /proc/cpuinfo ] 2>/dev/null; then
    :
fi
# 判断是否在相机上：/dev/mem 或 /dev/uio* 至少有一个存在
if [ ! -e /dev/mem ] && [ ! -e /dev/uio0 ] && [ ! -e /dev/oscom_memhelper ]; then
    echo "[-] 没找到 /dev/mem、/dev/uio0、/dev/oscom_memhelper"
    echo "    你是不是在【电脑】上跑这个脚本了？"
    echo "    本脚本必须在【相机第二核的 root shell】里运行："
    echo "      1) 电脑连上相机 WiFi（AP 模式）"
    echo "      2) sh z8_connect.sh          # 在电脑上跑，telnet 进相机"
    echo "      3) 在相机 shell 里再跑本脚本"
    exit 1
fi

# ---------- probe：探测可用通道 ----------
if [ "$1" = "probe" ]; then
    echo "[*] 探测内存访问通道..."
    for d in /dev/mem /dev/uio0 /dev/uio1 /dev/oscom_memhelper; do
        if [ ! -e "$d" ]; then
            echo "  $d : 不存在"
            continue
        fi
        case "$d" in
          /dev/mem)
            # 试读 1 字节
            if dd if="$d" bs=1 count=1 >/dev/null 2>/tmp/.e; then
                echo "  $d : 存在，dd 可读 ✓  ← 推荐用这个"
            else
                echo "  $d : 存在，但读失败：$(cat /tmp/.e | head -1)"
            fi ;;
          /dev/uio*)
            echo "  $d : 存在，但【不能用 dd 读】（read 返回中断计数）"
            echo "        只能用 mmap → 需要交叉编译的 osmem 工具" ;;
          /dev/oscom_memhelper)
            echo "  $d : 存在，但【不能用 dd 读】（只有 mmap+ioctl）"
            echo "        只能用 mmap → 需要 osmem 工具" ;;
        esac
    done
    echo
    echo "[*] 内核模块状态："
    lsmod 2>/dev/null | grep -iE 'uio|oscom|sdhci' | sed 's/^/    /'
    echo
    echo "[*] 当前是 root 吗：$(id -u 2>/dev/null) （应为 0）"
    echo "[*] 可写目录建议用 /tmp：$(touch /tmp/.wtest 2>/dev/null && echo '可写 OK' && rm -f /tmp/.wtest || echo '不可写')"
    exit 0
fi

# ---------- diff ----------
if [ "$1" = "diff" ]; then
    b="$2"; a="$3"
    if [ -z "$b" ] || [ -z "$a" ] || [ ! -f "$b" ] || [ ! -f "$a" ]; then
        echo "用法: sh $0 diff <before.bin> <after.bin>"
        exit 1
    fi
    nb=$(wc -c < "$b"); na=$(wc -c < "$a")
    echo "[*] 对比 $b($nb) 与 $a($na)"
    [ "$na" -lt "$nb" ] && nb=$na
    i=0; hits=0
    while [ $((i+4)) -le "$nb" ]; do
        vb=$(dd if="$b" bs=1 skip=$i count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
        va=$(dd if="$a" bs=1 skip=$i count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
        if [ "$vb" != "$va" ]; then
            printf "  偏移 +%d (DSID %d): %s -> %s\n" "$i" $((i/4)) "${vb:-?}" "${va:-?}"
            hits=$((hits+1))
        fi
        i=$((i+4))
    done
    echo "[*] 共 $hits 项变化。上面这些就是你刚才改设置所影响的字段。"
    exit 0
fi

# ---------- scan ----------
if [ "$1" = "scan" ]; then
    DEV="${DEV:-/dev/mem}"
    MB="${2:-64}"
    if [ "$DEV" != "/dev/mem" ]; then
        echo "[-] scan 只能用 /dev/mem（其他通道不能用 dd 读）"
        exit 1
    fi
    echo "[*] 扫描 $DEV 前 $MB MB，寻找主核特征（PBPMAIN / HSFC / HSFCPROC）..."
    i=0
    while [ "$i" -lt "$MB" ]; do
        # 用文件暂存，避免命令替换里的 NUL 被吞掉
        dd if="$DEV" bs=1M skip=$i count=1 of=/tmp/.z8blk 2>/dev/null
        if [ -s /tmp/.z8blk ]; then
            for k in PBPMAIN HSFC HSFCPROC PBPSUB; do
                if grep -qa "$k" /tmp/.z8blk 2>/dev/null; then
                    echo "  [命中 $k] 1MB 块 $i  物理 0x$(printf '%x' $((i*1048576)))"
                fi
            done
        fi
        i=$((i+1))
    done
    rm -f /tmp/.z8blk
    echo "[*] 完成。若命中，说明主核内存可从 /dev/mem 直接读，"
    echo "    基址 = 命中块物理地址 - 该特征在 eg 模块内的偏移"
    exit 0
fi

# ---------- dump ----------
BASE="$1"
OUT="${2:-/tmp/dsid.bin}"

if [ -z "$BASE" ]; then
    echo "用法："
    echo "  sh $0 probe                          # 先探测通道 ← 建议先跑"
    echo "  sh $0 <主核物理地址hex> [输出文件]     # dump（默认 /tmp/dsid.bin）"
    echo "  sh $0 scan [MB]                      # 扫内存找主核特征"
    echo "  sh $0 diff <before> <after>          # 对比"
    exit 1
fi

DEV="${DEV:-/dev/mem}"
if [ "$DEV" != "/dev/mem" ]; then
    echo "[-] dump 模式目前只支持 /dev/mem。"
    echo "    /dev/uio0 与 /dev/oscom_memhelper 只能 mmap，dd 读出来的是错的。"
    echo "    若要用它们，请用交叉编译的 osmem 工具。"
    exit 1
fi
if [ ! -e "$DEV" ]; then
    echo "[-] $DEV 不存在"; exit 1
fi

ADDR=$(printf '%d' "$BASE" 2>/dev/null)
if [ -z "$ADDR" ]; then
    echo "[-] 地址格式不对：$BASE（应为 0x... 或十进制）"; exit 1
fi

echo "[*] 设备   : $DEV"
echo "[*] 物理地址: $BASE (=$ADDR)"
echo "[*] 长度   : $LEN 字节 -> $OUT"

# bs=1 + 大 skip 在 busybox dd 上很慢，改用 1M 对齐读取
BLK=$(( ADDR / 1048576 ))
OFF=$(( ADDR % 1048576 ))
NEED=$(( LEN + OFF ))
NBLK=$(( (NEED + 1048575) / 1048576 ))

dd if="$DEV" bs=1M skip=$BLK count=$NBLK of=/tmp/.z8raw 2>/tmp/.z8err
rc=$?
if [ $rc -ne 0 ] || [ ! -s /tmp/.z8raw ]; then
    echo "[-] 读取失败 (rc=$rc)。dd 报错："
    sed 's/^/    /' /tmp/.z8err
    echo "    可能原因：地址超出范围 / 未映射 / 权限不足"
    exit 1
fi
dd if=/tmp/.z8raw bs=1 skip=$OFF count=$LEN of="$OUT" 2>/dev/null
rm -f /tmp/.z8raw

if [ ! -f "$OUT" ]; then
    echo "[-] 输出文件 $OUT 未能创建（目录可写吗？建议放 /tmp）"
    exit 1
fi
SZ=$(wc -c < "$OUT")
echo "[*] 读出 $SZ 字节"
if [ "$SZ" -lt 16 ]; then
    echo "[-] 读得太少。可能地址不对或未映射。"
    echo "    试试先: sh $0 scan 64   确定主核内存在哪"
    exit 1
fi

echo "[*] 前 256 字节："
dd if="$OUT" bs=1 count=256 2>/dev/null | hexdump -C | sed 's/^/  /'
echo "[+] 已保存 $OUT"
echo "    下一步：在相机上改设置（开预拍 / 改画质），再 dump 一次，然后："
echo "      sh $0 diff $OUT /tmp/after.bin"
