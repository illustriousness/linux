#!/usr/bin/env bash
# 启用严格模式：
# -e: 任一命令失败立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败即整体失败
set -euo pipefail

# 计算当前脚本所在目录的绝对路径。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 指定 out 构建目录，允许外部通过 OUT_DIR 覆盖。
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"

# QEMU 可执行文件名（默认 qemu-system-arm）。
QEMU_BIN="${QEMU_BIN:-qemu-system-arm}"
# 板级模型（当前调试目标为 i.MX6UL EVK）。
MACHINE="${MACHINE:-mcimx6ul-evk}"
# 虚拟机内存大小。
MEM="${MEM:-512M}"

# 内核镜像路径（默认取 out 目录编译产物）。
KERNEL_IMAGE="${KERNEL_IMAGE:-$OUT_DIR/arch/arm/boot/Image}"
# 设备树镜像路径（默认取 i.MX6UL EVK 对应 dtb）。
DTB_IMAGE="${DTB_IMAGE:-$OUT_DIR/arch/arm/boot/dts/nxp/imx/imx6ul-14x14-evk.dtb}"

# GDB 远程调试端口。
GDB_PORT="${GDB_PORT:-1234}"

# 手动开关：1=使用 NFS 根文件系统，0=使用 initramfs。
USE_NFS_ROOT=1
# QEMU user 网络网段（用于给 guest 发 DHCP 地址）。
NFS_NET_CIDR="${NFS_NET_CIDR:-192.168.10.0/24}"
# 在 guest 视角中宿主机地址（QEMU user 网络 host 地址）。
NFS_HOST_IP="${NFS_HOST_IP:-192.168.10.2}"
# NFS 服务器地址（默认等于上面的宿主机地址）。
NFS_SERVER="${NFS_SERVER:-$NFS_HOST_IP}"
# NFS 导出目录（guest 将其作为根文件系统挂载）。
NFS_EXPORT="${NFS_EXPORT:-/home/lyc/srv/nfs/rootfs}"
# NFS 根挂载参数（固定 v3/tcp 并显式指定端口，关闭 lockd 依赖）。
NFS_OPTS="${NFS_OPTS:-vers=3,proto=tcp,mountproto=tcp,port=2049,mountport=20048,nolock}"

# initramfs 模式默认内核启动参数。
DEFAULT_CMDLINE_INITRAMFS="console=ttymxc0,115200 earlycon loglevel=8 panic=-1 rdinit=/init drm_kms_helper.fbdev_emulation=0"
# NFS 模式默认内核启动参数（开启 nfsrootdebug 便于定位挂载问题）。
DEFAULT_CMDLINE_NFS="console=ttymxc0,115200 earlycon loglevel=8 panic=-1 root=/dev/nfs rw nfsroot=${NFS_SERVER}:${NFS_EXPORT},${NFS_OPTS} ip=dhcp nfsrootdebug drm_kms_helper.fbdev_emulation=0"
# 根据手动开关选择最终 bootargs。
if [[ "$USE_NFS_ROOT" == "1" ]]; then
  # NFS 根文件系统模式。
  CMDLINE="$DEFAULT_CMDLINE_NFS"
else
  # initramfs 模式。
  CMDLINE="$DEFAULT_CMDLINE_INITRAMFS"
fi
# 内核镜像加载地址（匹配 ARM Image 预期偏移）。
KERNEL_LOAD_ADDR="${KERNEL_LOAD_ADDR:-0x80008000}"
# 设备树加载地址。
DTB_LOAD_ADDR="${DTB_LOAD_ADDR:-0x88000000}"

# 检查 QEMU 是否在 PATH 中。
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  # 报错：找不到 QEMU。
  echo "ERROR: $QEMU_BIN not found in PATH"
  # 失败退出。
  exit 1
fi

# 检查 fdtput（用于把 bootargs 写入 dtb）。
if ! command -v fdtput >/dev/null 2>&1; then
  # 报错：缺少 fdtput。
  echo "ERROR: fdtput not found in PATH"
  # 给出安装提示。
  echo "Hint: install device-tree-compiler package"
  # 失败退出。
  exit 1
fi

# 检查内核镜像文件是否存在。
if [[ ! -f "$KERNEL_IMAGE" ]]; then
  # 报错：找不到内核镜像。
  echo "ERROR: kernel image not found: $KERNEL_IMAGE"
  # 给出构建提示。
  echo "Hint: run ./build.sh first"
  # 失败退出。
  exit 1
fi

# 检查 dtb 文件是否存在。
if [[ ! -f "$DTB_IMAGE" ]]; then
  # 报错：找不到 dtb。
  echo "ERROR: dtb not found: $DTB_IMAGE"
  # 给出构建/覆盖变量提示。
  echo "Hint: run ./build.sh first, or set DTB_IMAGE"
  # 失败退出。
  exit 1
fi

# 校验 USE_NFS_ROOT 只能是 0 或 1。
if [[ "$USE_NFS_ROOT" != "0" && "$USE_NFS_ROOT" != "1" ]]; then
  # 报错：开关值非法。
  echo "ERROR: invalid USE_NFS_ROOT value: $USE_NFS_ROOT (expected 0 or 1)"
  # 失败退出。
  exit 1
fi

# 创建临时 dtb 文件，用于注入本次 bootargs。
TMP_DTB_IMAGE="$(mktemp /tmp/imx6ul-qemu-dtb.XXXXXX)"
# 退出时自动删除临时 dtb，避免污染 /tmp。
trap 'rm -f "$TMP_DTB_IMAGE"' EXIT
# 复制原始 dtb 到临时文件。
cp "$DTB_IMAGE" "$TMP_DTB_IMAGE"
# 把 /chosen/bootargs 更新为本次 CMDLINE。
fdtput -t s "$TMP_DTB_IMAGE" /chosen bootargs "$CMDLINE"
# 打印最终 bootargs，便于现场确认。
echo "bootargs: $CMDLINE"

# 初始化可选网络参数数组。
NET_ARGS=()
# 在 NFS 模式下，为 QEMU user 网络显式设置网段和 host IP。
if [[ "$USE_NFS_ROOT" == "1" ]]; then
  # guest 通过 DHCP 获取地址，并将 NFS_SERVER 访问到宿主机导出目录。
  NET_ARGS=(-nic "user,net=${NFS_NET_CIDR},host=${NFS_HOST_IP}")
fi

# 说明：
# QEMU 的 i.MX6UL 板默认 Linux loader 跳到 0x80010000，
# 但 ARM Image 期望入口是 PHYS_OFFSET + 0x8000（即 0x80008000）。
# 这里用 loader + 一段极小跳板 stub，确保非压缩 Image 调试稳定可复现。
"$QEMU_BIN" \
  -M "$MACHINE" \
  -m "$MEM" \
  -nographic \
  -no-reboot \
  -S -gdb tcp::"$GDB_PORT" \
  "${NET_ARGS[@]}" \
  -device loader,file="$KERNEL_IMAGE",addr="$KERNEL_LOAD_ADDR",force-raw=on \
  -device loader,file="$TMP_DTB_IMAGE",addr="$DTB_LOAD_ADDR",force-raw=on \
  -device loader,addr=0x80000000,data=0xe3a00000,data-len=4 \
  -device loader,addr=0x80000004,data=0xe59f1004,data-len=4 \
  -device loader,addr=0x80000008,data=0xe59f2004,data-len=4 \
  -device loader,addr=0x8000000c,data=0xe59ff004,data-len=4 \
  -device loader,addr=0x80000010,data=0xffffffff,data-len=4 \
  -device loader,addr=0x80000014,data="$DTB_LOAD_ADDR",data-len=4 \
  -device loader,addr=0x80000018,data="$KERNEL_LOAD_ADDR",data-len=4 \
  -device loader,addr=0x80000000,cpu-num=0
