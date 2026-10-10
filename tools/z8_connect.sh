#!/bin/sh
# z8_connect.sh — 主机端：连接 Z8 第二核的 root shell
#
# 前提：
#   1) 已刷入 Z_8_0311_telnet.bin
#   2) 相机 WiFi 已开启（相机菜单里手动开，默认关闭）
#   3) 你的电脑与相机在同一网络
#
# 用法：
#   ./z8_connect.sh                     # AP 模式：自动探测默认网关 = 相机 IP
#   ./z8_connect.sh 192.168.1.1         # 手动指定 IP
#   ./z8_connect.sh 192.168.1.1 2323    # 指定 IP + 端口
#   ./z8_connect.sh --scan              # STA 模式：扫描本网段找 2323 开放的主机
#   ./z8_connect.sh --scan 192.168.1    # 指定网段前缀扫描
#
# 两种 WiFi 模式的区别：
#   AP  模式（相机做热点）：相机 = DHCP 服务端 + 网关 => 看默认网关就是相机 IP
#   STA 模式（相机连路由器）：相机 = DHCP 客户端 => 默认网关是你的路由器，
#                             相机 IP 未知，必须用 --scan 或查路由器 DHCP 列表
#
# 说明：telnetd 是 busybox applet，连上直接就是 root shell（无密码），
#       因为第二核 /etc/passwd 的 root 密码字段为空、inittab 不给 getty。

PORT=2323
SCAN=0
NETPFX=""
IP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --scan) SCAN=1; shift; [ $# -gt 0 ] && case "$1" in --*) ;; *) NETPFX="$1"; shift;; esac ;;
        -*) echo "未知选项: $1"; exit 1;;
        *)  if [ -z "$IP" ]; then IP="$1"; else PORT="$1"; fi; shift;;
    esac
done

# ---------- 工具探测 ----------
NC=""
for c in nc ncat netcat; do
    if command -v $c >/dev/null 2>&1; then NC=$c; break; fi
done

# nc 是否支持 -z（BSD nc 支持，部分 nmap-ncat 也支持）
nc_probe() {
    [ -z "$NC" ] && return 2
    $NC -z -w 2 "$1" "$2" >/dev/null 2>&1 && return 0
    return 1
}

do_connect() {
    echo "[*] 连接 $1:$2 ..."
    if [ -n "$NC" ]; then
        exec $NC "$1" "$2"
    elif command -v telnet >/dev/null 2>&1; then
        exec telnet "$1" "$2"
    else
        echo "[-] 本机既无 nc 也无 telnet。macOS 自带 nc；Linux: apt install netcat-openbsd"
        exit 1
    fi
}

# ---------- STA 模式：网段扫描 ----------
if [ "$SCAN" = 1 ]; then
    if [ -z "$NETPFX" ]; then
        # 取本机 IP 的前三段
        MYIP=$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2; exit}')
        [ -z "$MYIP" ] && MYIP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
        if [ -z "$MYIP" ]; then
            echo "[-] 无法判断本机 IP，请指定网段前缀：$0 --scan 192.168.1"
            exit 1
        fi
        NETPFX=$(echo "$MYIP" | awk -F. '{print $1"."$2"."$3}')
    fi
    echo "[*] 扫描 $NETPFX.0/24 上开放 $PORT 的主机 ..."
    found=""
    i=1
    while [ $i -le 254 ]; do
        (
            t="$NETPFX.$i"
            if nc_probe "$t" "$PORT"; then echo "$t" >> /tmp/.z8scan.$$; fi
        ) &
        i=$((i+1))
        # 控制并发
        while [ "$(jobs -r 2>/dev/null | wc -l)" -ge 40 ]; do sleep 0.1; done
    done
    wait
    if [ -f /tmp/.z8scan.$$ ]; then
        found=$(sort -u /tmp/.z8scan.$$)
        rm -f /tmp/.z8scan.$$
    fi
    if [ -z "$found" ]; then
        echo "[-] 未找到开放 $PORT 的主机。排查："
        echo "    1) 相机 WiFi 是否真的开了？（相机菜单手动开启）"
        echo "    2) 刷的是不是 Z_8_0311_telnet.bin？"
        echo "    3) STA 模式下路由器是否开了 AP 隔离（客户端隔离）？开的话互相不通，改回 AP 模式"
        echo "    4) 网段前缀对不对？手动试：$0 --scan 192.168.1"
        exit 1
    fi
    echo "[+] 找到："
    echo "$found" | sed 's/^/      /'
    IP=$(echo "$found" | head -1)
    echo "[*] 连接第一个: $IP"
    do_connect "$IP" "$PORT"
fi

# ---------- 指定 IP ----------
if [ -n "$IP" ]; then
    echo "[*] 测试 $IP:$PORT ..."
    if nc_probe "$IP" "$PORT"; then
        echo "[+] 端口开放"
    else
        [ -z "$NC" ] && echo "[!] 无 nc，跳过端口探测，直接尝试连接"
        if [ -z "$NC" ] && ! command -v telnet >/dev/null 2>&1; then
            echo "[-] 无可用工具"; exit 1
        fi
        [ -n "$NC" ] && {
            echo "[-] 端口不通。可能原因："
            echo "    - 相机 WiFi 未开 / 刷的还是原版固件"
            echo "    - IP 不对（STA 模式下默认网关是路由器，不是相机）"
            echo "    - telnetd 未启动"
            echo "    试试扫描: $0 --scan"
            exit 1
        }
    fi
    do_connect "$IP" "$PORT"
    exit 0
fi

# ---------- AP 模式：探测默认网关 ----------
echo "[*] 未指定 IP，按 AP 模式探测默认网关..."
GW=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
[ -z "$GW" ] && GW=$(netstat -rn -f inet 2>/dev/null | awk '/^default/ {print $2; exit}')
[ -z "$GW" ] && GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')

if [ -z "$GW" ]; then
    echo "[-] 探测失败。请手动指定：$0 <相机IP>   或扫描：$0 --scan"
    exit 1
fi

echo "[+] 默认网关: $GW"
if nc_probe "$GW" "$PORT"; then
    echo "[+] 网关 $PORT 开放 —— 这就是相机（AP 模式）"
else
    echo "[!] 网关 $PORT 未开放。"
    echo "    AP 模式：网关就该是相机，不通说明 telnetd 没起来或固件没刷对"
    echo "    STA 模式：网关是你的路由器，不是相机！请用："
    echo "        $0 --scan"
    echo "    仍要尝试连接网关吗？[y/N] "
    read -r ans
    case "$ans" in y|Y) ;; *) exit 1;; esac
fi
do_connect "$GW" "$PORT"
