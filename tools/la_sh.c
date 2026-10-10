/*
 * la_sh.c — 连接 Z8 第二核 LaMainApp 调试接口（AF_UNIX）并收发文本命令
 *
 * 用法：
 *   la_sh /tmp/LaMainApp_unix_socket "help"
 *   la_sh /tmp/LaMainApp_unix_socket "memdump 0x407dc7ac 256"
 *   la_sh /tmp/LaMainApp_unix_socket "sh ls -la /"
 *   la_sh /tmp/LaMainApp_unix_socket        # 不带命令 -> 进入交互模式
 *
 * 交叉编译（aarch64，静态）：
 *   aarch64-linux-musl-gcc -Os -static -o la_sh la_sh.c
 *   # 或 aarch64-linux-gnu-gcc -Os -static -o la_sh la_sh.c
 *
 * 注意：LaMainApp 的命令按空格分词，第一个 token 是命令名。
 *       命令表：help / directuart / stackdump / memdump / sh
 *       其中 "sh <cmd>" 会以 root 执行 cmd（无字符过滤）。
 *       以 '&' 结尾则后台执行。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

#define BUFSZ 65536

static int send_all(int fd, const char *s, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, s + off, n - off);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "/tmp/LaMainApp_unix_socket";
    const char *cmd  = (argc > 2) ? argv[2] : NULL;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "path too long\n"); return 1;
    }
    strcpy(addr.sun_path, path);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        fprintf(stderr, "  目标: %s\n", path);
        return 1;
    }
    fprintf(stderr, "[+] connected to %s\n", path);

    if (cmd) {
        char line[BUFSZ];
        int n = snprintf(line, sizeof(line), "%s\n", cmd);
        if (send_all(fd, line, (size_t)n) < 0) { perror("write"); return 1; }
    } else {
        fprintf(stderr, "[+] 交互模式，输入命令（Ctrl-D 退出）\n");
    }

    /* 读回所有响应，直到对端关闭或空闲超时 */
    for (;;) {
        fd_set rfds;
        struct timeval tv;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = 2; tv.tv_usec = 0;

        int r = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) { if (errno == EINTR) continue; perror("select"); break; }
        if (r == 0) {
            if (cmd) break;                 /* 一次性命令：空闲即结束 */
            /* 交互模式：继续等 stdin */
            fd_set in;
            struct timeval tv2 = {0, 200000};
            FD_ZERO(&in); FD_SET(STDIN_FILENO, &in);
            if (select(STDIN_FILENO + 1, &in, NULL, NULL, &tv2) > 0) {
                char ibuf[BUFSZ];
                ssize_t got = read(STDIN_FILENO, ibuf, sizeof(ibuf));
                if (got <= 0) break;
                if (send_all(fd, ibuf, (size_t)got) < 0) { perror("write"); break; }
            }
            continue;
        }

        char buf[BUFSZ];
        ssize_t got = read(fd, buf, sizeof(buf) - 1);
        if (got < 0) { if (errno == EINTR) continue; perror("read"); break; }
        if (got == 0) { fprintf(stderr, "\n[+] peer closed\n"); break; }
        buf[got] = 0;
        fwrite(buf, 1, (size_t)got, stdout);
        fflush(stdout);
        (void)r;
    }

    close(fd);
    return 0;
}
