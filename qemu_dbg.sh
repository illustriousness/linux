#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"

QEMU_BIN="${QEMU_BIN:-qemu-system-arm}"
MACHINE="${MACHINE:-mcimx6ul-evk}"
MEM="${MEM:-512M}"

KERNEL_IMAGE="$PWD/out/arch/arm/boot/Image"
DTB_IMAGE="${DTB_IMAGE:-$OUT_DIR/arch/arm/boot/dts/nxp/imx/imx6ul-14x14-evk.dtb}"

GDB_PORT="${GDB_PORT:-1234}"

CMDLINE="${CMDLINE:-console=ttymxc0,115200 earlycon loglevel=8 panic=-1}"
KERNEL_LOAD_ADDR="${KERNEL_LOAD_ADDR:-0x80008000}"
DTB_LOAD_ADDR="${DTB_LOAD_ADDR:-0x88000000}"

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "ERROR: $QEMU_BIN not found in PATH"
  exit 1
fi

if ! command -v fdtput >/dev/null 2>&1; then
  echo "ERROR: fdtput not found in PATH"
  echo "Hint: install device-tree-compiler package"
  exit 1
fi

if [[ ! -f "$KERNEL_IMAGE" ]]; then
  echo "ERROR: kernel image not found: $KERNEL_IMAGE"
  echo "Hint: run ./build.sh first"
  exit 1
fi

if [[ ! -f "$DTB_IMAGE" ]]; then
  echo "ERROR: dtb not found: $DTB_IMAGE"
  echo "Hint: run ./build.sh first, or set DTB_IMAGE"
  exit 1
fi

TMP_DTB_IMAGE="$(mktemp /tmp/imx6ul-qemu-dtb.XXXXXX)"
trap 'rm -f "$TMP_DTB_IMAGE"' EXIT
cp "$DTB_IMAGE" "$TMP_DTB_IMAGE"
fdtput -t s "$TMP_DTB_IMAGE" /chosen bootargs "$CMDLINE"

# QEMU's i.MX6UL board Linux loader jumps to 0x80010000, but ARM Image expects
# entry at PHYS_OFFSET + 0x8000. Use a tiny stub and raw loaders to start at
# 0x80008000 for reliable non-compressed Image debugging.
"$QEMU_BIN" \
  -M "$MACHINE" \
  -m "$MEM" \
  -nographic \
  -no-reboot \
  -S -gdb tcp::"$GDB_PORT" \
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
