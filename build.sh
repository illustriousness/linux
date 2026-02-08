#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
ARCH="${ARCH:-arm}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
DEFCONFIG="${DEFCONFIG:-imx_v6_v7_defconfig}"
JOBS="${JOBS:-$(nproc)}"

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "ERROR: ${CROSS_COMPILE}gcc not found in PATH"
  echo "Hint: set CROSS_COMPILE to your ARM toolchain prefix, e.g."
  echo "  export CROSS_COMPILE=arm-linux-gnueabihf-"
  exit 1
fi

mkdir -p "$OUT_DIR"

make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image dtbs

VMLINUX_PATH="$OUT_DIR/vmlinux"
IMAGE_PATH="$OUT_DIR/arch/arm/boot/Image"
DTB_PATH="$OUT_DIR/arch/arm/boot/dts/nxp/imx/imx6ul-14x14-evk.dtb"

printf '\nBuild done:\n  vmlinux: %s\n  Image:   %s\n  dtb:     %s\n' \
  "$VMLINUX_PATH" "$IMAGE_PATH" "$DTB_PATH"
