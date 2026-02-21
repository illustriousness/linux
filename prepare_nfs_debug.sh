#!/usr/bin/env bash
# 开启严格模式：
# -e: 任一命令失败立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败即整体失败
set -euo pipefail

# 计算脚本所在目录的绝对路径。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 内核源码目录，允许外部通过环境变量 KDIR 覆盖。
KDIR="${KDIR:-$ROOT_DIR}"
# 内核输出目录（O=），默认放在源码目录下 out。
OUT_DIR="${OUT_DIR:-$KDIR/out}"
# 目标架构，默认 ARM。
ARCH="${ARCH:-arm}"
# 交叉编译工具链前缀，默认 arm-linux-gnueabihf-。
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
# 首次生成 .config 时使用的 defconfig。
DEFCONFIG="${DEFCONFIG:-imx_v6_v7_defconfig}"
# 并行编译线程数，默认使用主机 CPU 核心数。
JOBS="${JOBS:-$(nproc)}"

# 调试友好且相对稳定的编译优化参数。
# 说明：此内核树+较新 GCC 下，-Og 可能触发编译问题。
DEFAULT_KCFLAGS="-O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls"
# 允许外部通过 KCFLAGS 覆盖默认值。
KCFLAGS="${KCFLAGS:-$DEFAULT_KCFLAGS}"

# 检查命令是否存在；不存在就给出错误并退出。
need_cmd() {
  # command -v 成功表示命令可执行。
  if ! command -v "$1" >/dev/null 2>&1; then
    # 输出缺失命令名，便于快速安装依赖。
    echo "ERROR: missing command: $1"
    # 非 0 退出码终止脚本。
    exit 1
  fi
}

# 基础依赖检查：至少要有 make 和 sed。
for cmd in make sed; do
  # 逐个验证命令是否可用。
  need_cmd "$cmd"
done

# 如果设置了交叉前缀，则检查对应 gcc 是否存在。
if [[ -n "$CROSS_COMPILE" ]]; then
  # 例如 arm-linux-gnueabihf-gcc。
  need_cmd "${CROSS_COMPILE}gcc"
fi

# 若输出目录里还没有 .config，则先生成一次 defconfig。
if [[ ! -f "$OUT_DIR/.config" ]]; then
  # 打印阶段提示，便于观察进度。
  echo "[1/4] kernel .config missing, generate from $DEFCONFIG"
  # 使用 O= 进行 out-of-tree 配置生成。
  make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
fi

# 第二步：写入 NFS root + 调试所需配置。
echo "[2/4] enforce NFS root + debug-friendly kernel config"
# scripts/config 直接改 .config，避免手工 menuconfig。
"$KDIR/scripts/config" --file "$OUT_DIR/.config" \
  -e DEBUG_KERNEL \
  -e DEBUG_INFO \
  -e DEBUG_INFO_DWARF4 \
  -e GDB_SCRIPTS \
  -d DEBUG_INFO_NONE \
  -d DEBUG_INFO_REDUCED \
  -e DEVTMPFS \
  -e DEVTMPFS_MOUNT \
  -e NFS_FS \
  -e ROOT_NFS \
  -e LOCKD \
  -e SUNRPC \
  -e IP_PNP \
  -e IP_PNP_DHCP \
  -d INITRAMFS_FORCE \
  --set-str INITRAMFS_SOURCE ""
# olddefconfig 用默认值补齐新旧选项差异，保证配置闭合。
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# 第三步：按当前配置重新编译内核镜像与设备树。
echo "[3/4] rebuild kernel Image + zImage + dtbs for NFS root"
# 打印本次生效的 KCFLAGS，便于排错。
echo "KCFLAGS=$KCFLAGS"
# 编译 Image、zImage 与 dtbs；使用并行加速。
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  KCFLAGS="$KCFLAGS" -j"$JOBS" Image zImage dtbs

# 第四步：回显关键配置，确认脚本确实生效。
echo "[4/4] show effective rootfs-related config"
# 若 rg 未匹配到也不让脚本失败（|| true）。
rg -n "^CONFIG_(INITRAMFS_SOURCE|ROOT_NFS|NFS_FS|IP_PNP|IP_PNP_DHCP|DEVTMPFS_MOUNT)=" "$OUT_DIR/.config" || true

# 空行分隔，提升可读性。
echo
# 完成提示。
echo "Done."
# 输出内核镜像路径。
echo "kernel: $OUT_DIR/arch/arm/boot/Image"
# 输出压缩内核镜像路径。
echo "zImage: $OUT_DIR/arch/arm/boot/zImage"
# 空行分隔。
echo
# 给出下一步运行方式。
echo "Run QEMU (default now uses NFS mode in qemu_dbg.sh):"
# 启动调试脚本命令。
echo "  ./qemu_dbg.sh"
