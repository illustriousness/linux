#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
ARCH="${ARCH:-arm}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
DEFCONFIG="${DEFCONFIG:-imx_v6_v7_defconfig}"
JOBS="${JOBS:-$(nproc)}"
ENABLE_FULL_DEBUG_INFO="${ENABLE_FULL_DEBUG_INFO:-1}"
ENABLE_BEAR="${ENABLE_BEAR:-1}"
BEAR_OUTPUT="${BEAR_OUTPUT:-$ROOT_DIR/compile_commands.json}"

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "ERROR: ${CROSS_COMPILE}gcc not found in PATH"
  echo "Hint: set CROSS_COMPILE to your ARM toolchain prefix, e.g."
  echo "  export CROSS_COMPILE=arm-linux-gnueabihf-"
  exit 1
fi

if [[ "$ENABLE_BEAR" == "1" ]] && ! command -v bear >/dev/null 2>&1; then
  echo "ERROR: bear not found in PATH"
  echo "Hint: install bear, or disable with:"
  echo "  ENABLE_BEAR=0 ./build.sh"
  exit 1
fi

mkdir -p "$OUT_DIR"

make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"

if [[ "$ENABLE_FULL_DEBUG_INFO" == "1" ]]; then
  scripts/config --file "$OUT_DIR/.config" \
    -e DEBUG_KERNEL \
    -d DEBUG_INFO_NONE \
    -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    -e DEBUG_INFO_DWARF4 \
    -d DEBUG_INFO_DWARF5 \
    -d DEBUG_INFO_REDUCED \
    -e DEBUG_INFO_COMPRESSED_NONE \
    -d DEBUG_INFO_COMPRESSED_ZLIB \
    -d DEBUG_INFO_COMPRESSED_ZSTD \
    -d DEBUG_INFO_SPLIT \
    -e GDB_SCRIPTS \
    -e KALLSYMS_ALL
  make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
fi

if [[ "$ENABLE_BEAR" == "1" ]]; then
  BEAR_TMP_OUTPUT="${BEAR_OUTPUT}.tmp"
  bear --output "$BEAR_TMP_OUTPUT" -- \
    make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image dtbs
  BEAR_ENTRY_COUNT="$( (rg -o '"file"[[:space:]]*:' "$BEAR_TMP_OUTPUT" || true) | wc -l | tr -d ' ' )"
  if [[ "$BEAR_ENTRY_COUNT" -gt 0 ]]; then
    mv -f "$BEAR_TMP_OUTPUT" "$BEAR_OUTPUT"
  else
    rm -f "$BEAR_TMP_OUTPUT"
    if [[ -f "$BEAR_OUTPUT" ]]; then
      EXISTING_ENTRY_COUNT="$( (rg -o '"file"[[:space:]]*:' "$BEAR_OUTPUT" || true) | wc -l | tr -d ' ' )"
      if [[ "$EXISTING_ENTRY_COUNT" -gt 0 ]]; then
        echo "WARN: bear captured no compile actions (incremental no-op); keeping existing $BEAR_OUTPUT"
      else
        echo "WARN: bear captured no compile actions and existing database is empty"
        echo "Hint: run a non-incremental build once (e.g. clean rebuild) to populate $BEAR_OUTPUT"
      fi
    else
      echo "WARN: bear captured no compile actions; writing empty compilation database"
      printf '[]\n' > "$BEAR_OUTPUT"
    fi
  fi
else
  make -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image dtbs
fi

VMLINUX_PATH="$OUT_DIR/vmlinux"
IMAGE_PATH="$OUT_DIR/arch/arm/boot/Image"
DTB_PATH="$OUT_DIR/arch/arm/boot/dts/nxp/imx/imx6ul-14x14-evk.dtb"

printf '\nBuild done:\n  vmlinux: %s\n  Image:   %s\n  dtb:     %s\n' \
  "$VMLINUX_PATH" "$IMAGE_PATH" "$DTB_PATH"
if [[ "$ENABLE_FULL_DEBUG_INFO" == "1" ]]; then
  printf '  debug:   DWARF4 + full symbols (GDB friendly)\n'
fi
if [[ "$ENABLE_BEAR" == "1" ]]; then
  printf '  cdb:     %s\n' "$BEAR_OUTPUT"
fi
