# SPDX-License-Identifier: GPL-2.0

# 交叉编译前缀；可在命令行覆盖，例如：
# make -C learning CROSS_COMPILE=aarch64-linux-gnu-
CROSS_COMPILE ?= arm-linux-gnueabihf-

# strip 工具默认跟随交叉前缀。
STRIP ?= $(CROSS_COMPILE)strip

# C 编译参数：优化 + 常见告警。
CFLAGS ?= -O2 -Wall -Wextra

# 是否静态构建：1=静态链接，0=动态链接。
# 用法示例：
#   make -C learning STATIC=1
#   make -C learning STATIC=0
STATIC ?= 1

# 链接参数；可在命令行追加自定义参数。
LDFLAGS ?=

# 默认静态链接，避免目标 rootfs 缺少动态加载器/运行库导致 not found。
ifeq ($(STATIC),1)
LDFLAGS += -static
endif

# glibc 静态归档在部分版本会遗漏 stdio 依赖，导致 printf/puts 运行期崩溃。
# 默认开启规避：强制链接器拉入 _IO_file_doallocate。
STATIC_GLIBC_STDIO_FIX ?= 1
ifeq ($(STATIC),1)
ifeq ($(STATIC_GLIBC_STDIO_FIX),1)
LDFLAGS += -Wl,-u,_IO_file_doallocate
endif
endif

# 安装命令，默认用系统 install。
INSTALL ?= install

# bear 命令，支持命令行覆盖。
BEAR ?= bear

# bear 输出的编译数据库路径。
BEAR_OUTPUT ?= $(CURDIR)/compile_commands.json

# bear 采集时强制重编译，避免增量构建导致数据库为空。
BEAR_BUILD_FLAGS ?= -B

# 产物二进制名称。
BINS := learn_char_test hello

# 安装前缀（目标 rootfs 内部路径）。
PREFIX ?= /usr/local

# 安装根目录（这里默认指向你的 NFS rootfs）。
DESTDIR ?= /home/lyc/srv/nfs/rootfs

# 最终安装目录 = DESTDIR + PREFIX + /bin。
BINDIR := $(DESTDIR)$(PREFIX)/bin

# 声明伪目标，避免与同名文件冲突。
.PHONY: all strip install bear clean

# make 内建会给 CC 一个默认值 cc。
# 仅当 CC 来源是 default 时，切到交叉编译器。
ifeq ($(origin CC), default)
CC := $(CROSS_COMPILE)gcc
endif

# 默认目标：构建可执行文件。
all: $(BINS)

# 从源文件构建目标程序。
learn_char_test: learn_char_test.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

hello: hello.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# 可选目标：对二进制做 strip 减小体积。
strip: $(BINS)
	$(STRIP) $^

# 安装目标：创建目录并安装到 rootfs。
install: $(BINS)
	$(INSTALL) -d $(BINDIR)
	$(INSTALL) -m 0755 $(BINS) $(BINDIR)

# 生成 compile_commands.json，便于 clangd/vscode 使用。
bear:
	@if ! command -v $(BEAR) >/dev/null 2>&1; then \
		echo "ERROR: $(BEAR) not found in PATH"; \
		exit 1; \
	fi
	$(BEAR) --output $(BEAR_OUTPUT) -- $(MAKE) $(BEAR_BUILD_FLAGS) all

# 清理构建产物。
clean:
	rm -f $(BINS)
