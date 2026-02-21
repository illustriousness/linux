#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="${BASE_SCRIPT:-$ROOT_DIR/prepare_initramfs.sh}"

KDIR="${KDIR:-$ROOT_DIR}"
OUT_DIR="${OUT_DIR:-$KDIR/out}"
ARCH="${ARCH:-arm}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
DEFCONFIG="${DEFCONFIG:-imx_v6_v7_defconfig}"
JOBS="${JOBS:-$(nproc)}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing command: $1"
    exit 1
  fi
}

for cmd in make sed; do
  need_cmd "$cmd"
done

if [[ -n "$CROSS_COMPILE" ]]; then
  need_cmd "${CROSS_COMPILE}gcc"
fi

if [[ ! -x "$BASE_SCRIPT" ]]; then
  if [[ -f "$BASE_SCRIPT" ]]; then
    chmod +x "$BASE_SCRIPT"
  else
    echo "ERROR: base script not found: $BASE_SCRIPT"
    exit 1
  fi
fi

if [[ ! -f "$OUT_DIR/.config" ]]; then
  echo "[debug 1/4] kernel .config missing, generate from $DEFCONFIG"
  make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
fi

echo "[debug 2/4] enforce debug-friendly kernel config"
"$KDIR/scripts/config" --file "$OUT_DIR/.config" \
  -e DEBUG_KERNEL \
  -e DEBUG_INFO \
  -e DEBUG_INFO_DWARF4 \
  -e GDB_SCRIPTS \
  -d DEBUG_INFO_NONE \
  -d DEBUG_INFO_REDUCED
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# GCC 15 + this kernel tree may fail to build with -Og.
# Use a safer debug-friendly baseline and allow override via KCFLAGS.
DEFAULT_KCFLAGS="-O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls"
# DEFAULT_KCFLAGS="-O0"
KCFLAGS="${KCFLAGS:-$DEFAULT_KCFLAGS}"
FORCE_REBUILD_BUSYBOX="${FORCE_REBUILD_BUSYBOX:-1}"

echo "[debug 3/4] build kernel+initramfs with KCFLAGS"
echo "KCFLAGS=$KCFLAGS"

if [[ "$FORCE_REBUILD_BUSYBOX" == "1" ]]; then
  # Debug 流程默认强制重编 BusyBox，避免误复用外部稳定二进制。
  BUSYBOX_BIN_OVERRIDE=""
  SKIP_BUSYBOX_OVERRIDE="0"
else
  BUSYBOX_BIN_OVERRIDE="${BUSYBOX_BIN:-}"
  SKIP_BUSYBOX_OVERRIDE="${SKIP_BUSYBOX:-0}"
fi

KCFLAGS="$KCFLAGS" \
KDIR="$KDIR" \
OUT_DIR="$OUT_DIR" \
ARCH="$ARCH" \
CROSS_COMPILE="$CROSS_COMPILE" \
DEFCONFIG="$DEFCONFIG" \
JOBS="$JOBS" \
BUSYBOX_BIN="$BUSYBOX_BIN_OVERRIDE" \
SKIP_BUSYBOX="$SKIP_BUSYBOX_OVERRIDE" \
"$BASE_SCRIPT"

echo "[debug 4/4] verify effective compile flags from .cmd"
if [[ -f "$OUT_DIR/fs/.readdir.o.cmd" ]]; then
  OPT_FLAG=""
  for flag in $KCFLAGS; do
    if [[ "$flag" == -O* ]]; then
      OPT_FLAG="$flag"
      break
    fi
  done

  if [[ -n "$OPT_FLAG" ]] && rg --quiet -- "$OPT_FLAG" "$OUT_DIR/fs/.readdir.o.cmd"; then
    echo "OK: $OPT_FLAG found in $OUT_DIR/fs/.readdir.o.cmd"
  else
    if [[ -n "$OPT_FLAG" ]]; then
      echo "WARN: $OPT_FLAG not found in $OUT_DIR/fs/.readdir.o.cmd"
    else
      echo "WARN: no -O* flag present in KCFLAGS (current: $KCFLAGS)"
    fi
  fi
  if rg --quiet -- "-fno-omit-frame-pointer" "$OUT_DIR/fs/.readdir.o.cmd"; then
    echo "OK: -fno-omit-frame-pointer found in $OUT_DIR/fs/.readdir.o.cmd"
  else
    echo "WARN: -fno-omit-frame-pointer not found in $OUT_DIR/fs/.readdir.o.cmd"
  fi
fi
