# SPDX-License-Identifier: GPL-2.0

# 交叉编译前缀；可在命令行覆盖，例如：
# make -C learning CROSS_COMPILE=aarch64-linux-gnu-
CROSS_COMPILE ?= arm-linux-gnueabihf-

# strip 工具默认跟随交叉前缀。
STRIP ?= $(CROSS_COMPILE)strip

# C 编译参数：优化 + 常见告警。
CFLAGS ?= -O2 -Wall -Wextra

# 链接参数：默认静态链接，避免目标 rootfs 缺少动态加载器/运行库导致 not found。
# 如需动态链接，可在命令行覆盖：make -C learning LDFLAGS=
LDFLAGS ?= -static

# 安装命令，默认用系统 install。
INSTALL ?= install

# 产物二进制名称。
BIN := learn_char_test

# 安装前缀（目标 rootfs 内部路径）。
PREFIX ?= /usr/local

# 安装根目录（这里默认指向你的 NFS rootfs）。
DESTDIR ?= /home/lyc/srv/nfs/rootfs

# 最终安装目录 = DESTDIR + PREFIX + /bin。
BINDIR := $(DESTDIR)$(PREFIX)/bin

# 声明伪目标，避免与同名文件冲突。
.PHONY: all strip install clean

# make 内建会给 CC 一个默认值 cc。
# 仅当 CC 来源是 default 时，切到交叉编译器。
ifeq ($(origin CC), default)
CC := $(CROSS_COMPILE)gcc
endif

# 默认目标：构建可执行文件。
all: $(BIN)

# 从源文件构建目标程序。
$(BIN): learn_char_test.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# 可选目标：对二进制做 strip 减小体积。
strip: $(BIN)
	$(STRIP) $<

# 安装目标：创建目录并安装到 rootfs。
install: $(BIN)
	$(INSTALL) -d $(BINDIR)
	$(INSTALL) -m 0755 $(BIN) $(BINDIR)/$(BIN)

# 清理构建产物。
clean:
	rm -f $(BIN)
