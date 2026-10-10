/*
 * osmem.c — 读取 Z8 第二核可见的物理内存（需 root）
 *
 * 依据（来自 Nikon 官方 GPL 源码 + 固件逆向，见 Z8_GPL源码分析.md）：
 *
 *   通道 1  /dev/mem
 *     内核配置 CONFIG_DEVMEM=y 且 CONFIG_STRICT_DEVMEM 未开启
 *     → 可 mmap 任意物理地址（最灵活）
 *
 *   通道 2  /dev/uio0    ← ★ 最值得试
 *     设备树 nikon-xxx.dts:
 *         peri_pmc@0x840000000 {
 *             compatible = "nikon,uio";
 *             reg = <0x8 0x40000000 0x0 0xb7fff000>;   // 0x840000000, ~2.9GB
 *         };
 *     内核 drivers/uio/uio_pdrv_genirq.c 在 CONFIG_ARCH_NIKON_XXX 下
 *     硬编码 { .compatible = "nikon,uio" }，且 CONFIG_UIO_PDRV_GENIRQ=y（内置）
 *     → 开机即自动匹配，/dev/uio0 的 mmap offset 0 == 物理 0x840000000
 *     → 这是一扇 ~2.9GB 的物理窗口，很可能覆盖主核(EXPEED)的内存/寄存器
 *
 *   通道 3  /dev/oscom_memhelper   （核间共享内存，较小）
 *     设备树 reserved-memory:
 *         OS_COM    @ 0x8_0F000000, 0x2000      (8 KB)
 *         share_mem @ 0x8_0F002000, 0x7FD000    (~8 MB)
 *     driver_mmap 用 remap_pfn_range，无边界检查
 *
 * 用法：
 *   osmem <phys_hex> <len> [out.bin]          # 默认 /dev/mem
 *   osmem 0x840000000 0x1000 -d /dev/uio0     # 用 UIO 通道
 *   osmem 0x80F002000 0x1000 -d /dev/oscom_memhelper
 *
 * 交叉编译：
 *   aarch64-linux-musl-gcc -Os -static -o osmem osmem.c
 *
 * 注意：
 *   - UIO 通道的 offset 是相对该设备基址的（0 = 0x840000000），
 *     所以读 0x840001000 时传 0x1000，程序会自动说明。
 *   - /dev/mem 与 oscom_memhelper 的 offset 就是物理地址本身。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>

/* UIO 设备基址（来自设备树 peri_pmc）；若用 -d /dev/uio0 则地址按此基址解释 */
static const unsigned long long UIO_BASE = 0x840000000ULL;

static const char *dev_default = "/dev/mem";

int main(int argc, char **argv) {
    const char *dev = dev_default;
    const char *addr_s = NULL, *len_s = NULL, *out = NULL;

    /* 简易参数解析：osmem ADDR LEN [out.bin] [-d DEV] */
    int pos = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) { dev = argv[++i]; continue; }
        if (!strcmp(argv[i], "-h")) {
            fprintf(stderr,
                "usage: %s <phys_hex> <len> [out.bin] [-d /dev/mem|/dev/uio0|/dev/oscom_memhelper]\n"
                "  /dev/mem, /dev/oscom_memhelper : offset == 物理地址\n"
                "  /dev/uio0                      : offset == 物理地址 - 0x%llx\n",
                argv[0], UIO_BASE);
            return 0;
        }
        if (pos == 0) addr_s = argv[i];
        else if (pos == 1) len_s = argv[i];
        else if (pos == 2 && argv[i][0] != '-') out = argv[i];
        pos++;
    }
    if (!addr_s || !len_s) {
        fprintf(stderr, "usage: %s <phys_hex> <len> [out.bin] [-d DEV]\n", argv[0]);
        return 1;
    }

    unsigned long long phys = strtoull(addr_s, NULL, 0);
    size_t len = (size_t)strtoull(len_s, NULL, 0);

    int is_uio = strstr(dev, "uio") != NULL;
    unsigned long long off = phys;
    if (is_uio) {
        if (phys < UIO_BASE) {
            fprintf(stderr, "UIO 通道：地址 %#llx 低于基址 %#llx\n", phys, UIO_BASE);
            return 1;
        }
        off = phys - UIO_BASE;
    }

    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        perror(dev);
        fprintf(stderr, "  需要 root；UIO 设备还需 uio_pdrv_genirq 已匹配\n");
        return 1;
    }
    fprintf(stderr, "[+] %s : phys %#llx, len %#zx (offset %#llx)\n", dev, phys, len, off);

    size_t pagesz = (size_t)sysconf(_SC_PAGESIZE);
    unsigned long long base = off & ~((unsigned long long)pagesz - 1);
    size_t offin = (size_t)(off - base);
    size_t maplen = ((offin + len + pagesz - 1) / pagesz) * pagesz;

    void *p = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);
    if (p == MAP_FAILED) {
        perror("mmap");
        fprintf(stderr, "  base=%#llx maplen=%#zx\n", base, maplen);
        close(fd);
        return 1;
    }
    const unsigned char *d = (const unsigned char *)p + offin;

    if (out) {
        FILE *f = fopen(out, "wb");
        if (!f) { perror("fopen"); return 1; }
        fwrite(d, 1, len, f);
        fclose(f);
        fprintf(stderr, "[+] wrote %s (%zu bytes)\n", out, len);
    }

    for (size_t i = 0; i < len; i += 16) {
        printf("%08llx  ", phys + i);
        size_t n = (len - i < 16) ? (len - i) : 16;
        for (size_t j = 0; j < 16; j++) {
            if (j < n) printf("%02x ", d[i + j]);
            else       printf("   ");
            if (j == 7) printf(" ");
        }
        printf(" |");
        for (size_t j = 0; j < n; j++) {
            unsigned char c = d[i + j];
            putchar((c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
    fflush(stdout);

    munmap(p, maplen);
    close(fd);
    return 0;
}
