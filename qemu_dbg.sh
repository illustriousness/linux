#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"

QEMU_BIN="${QEMU_BIN:-qemu-system-arm}"
MACHINE="${MACHINE:-mcimx6ul-evk}"
MEM="${MEM:-512M}"

KERNEL_IMAGE="${KERNEL_IMAGE:-$OUT_DIR/arch/arm/boot/Image}"
DTB_IMAGE="${DTB_IMAGE:-$OUT_DIR/arch/arm/boot/dts/nxp/imx/imx6ul-14x14-evk.dtb}"

GDB_PORT="${GDB_PORT:-1234}"

CMDLINE="${CMDLINE:-console=ttymxc0,115200 earlycon loglevel=8 panic=-1}"

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "ERROR: $QEMU_BIN not found in PATH"
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

exec "$QEMU_BIN" \
  -M "$MACHINE" \
  -m "$MEM" \
  -kernel "$KERNEL_IMAGE" \
  -dtb "$DTB_IMAGE" \
  -append "$CMDLINE" \
  -nographic \
  -no-reboot \
  -S -gdb tcp::"$GDB_PORT"
