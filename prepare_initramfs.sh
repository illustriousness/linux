#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KDIR="${KDIR:-$ROOT_DIR}"
OUT_DIR="${OUT_DIR:-$KDIR/out}"
ARCH="${ARCH:-arm}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
DEFCONFIG="${DEFCONFIG:-imx_v6_v7_defconfig}"
JOBS="${JOBS:-$(nproc)}"

BB_DIR="${BB_DIR:-$KDIR/busybox/busybox-1.37.0}"
INITRAMFS_WORK="${INITRAMFS_WORK:-/tmp/initramfs-root}"
INITRAMFS_IMG="${INITRAMFS_IMG:-/tmp/initramfs.cpio.gz}"
SKIP_BUSYBOX="${SKIP_BUSYBOX:-0}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing command: $1"
    exit 1
  fi
}

for cmd in make cpio gzip sed find; do
  need_cmd "$cmd"
done

if [[ -n "$CROSS_COMPILE" ]]; then
  need_cmd "${CROSS_COMPILE}gcc"
fi

if [[ "$SKIP_BUSYBOX" != "0" && "$SKIP_BUSYBOX" != "1" ]]; then
  echo "ERROR: invalid SKIP_BUSYBOX value: $SKIP_BUSYBOX (expected 0 or 1)"
  exit 1
fi

if [[ "$SKIP_BUSYBOX" != "1" ]]; then
  if [[ ! -d "$BB_DIR" ]]; then
    echo "ERROR: BusyBox source dir not found: $BB_DIR"
    exit 1
  fi

  if [[ ! -f "$BB_DIR/Makefile" ]]; then
    echo "ERROR: invalid BusyBox source dir: $BB_DIR"
    exit 1
  fi
fi

if [[ ! -d "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
fi

if [[ ! -f "$OUT_DIR/.config" ]]; then
  echo "[1/6] kernel .config missing, generate from $DEFCONFIG"
  make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
fi

if [[ "$SKIP_BUSYBOX" == "1" ]]; then
  echo "[2/6] skip BusyBox rebuild/install (SKIP_BUSYBOX=1)"
  if [[ ! -x "$INITRAMFS_WORK/bin/busybox" ]]; then
    echo "ERROR: SKIP_BUSYBOX=1 but missing $INITRAMFS_WORK/bin/busybox"
    echo "Hint: run once without SKIP_BUSYBOX=1 to populate initramfs root"
    exit 1
  fi
  echo "[3/6] reuse existing initramfs root: $INITRAMFS_WORK"
else
  echo "[2/6] build BusyBox (static)"
  make -C "$BB_DIR" distclean >/dev/null
  make -C "$BB_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
  if grep -q '^# CONFIG_STATIC is not set' "$BB_DIR/.config"; then
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BB_DIR/.config"
  elif grep -q '^CONFIG_STATIC=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' "$BB_DIR/.config"
  else
    echo 'CONFIG_STATIC=y' >> "$BB_DIR/.config"
  fi

  # BusyBox 1.37 + newer kernel headers may fail in networking/tc.c (CBQ symbols).
  # Disable tc applet for a stable initramfs build.
  if grep -q '^CONFIG_TC=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_TC=.*/# CONFIG_TC is not set/' "$BB_DIR/.config"
  fi
  if grep -q '^CONFIG_FEATURE_TC_INGRESS=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_FEATURE_TC_INGRESS=.*/# CONFIG_FEATURE_TC_INGRESS is not set/' "$BB_DIR/.config"
  fi

  # Avoid x86-specific hash accel paths when cross-building BusyBox for ARM.
  if grep -q '^CONFIG_SHA1_HWACCEL=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_SHA1_HWACCEL=.*/# CONFIG_SHA1_HWACCEL is not set/' "$BB_DIR/.config"
  fi
  if grep -q '^CONFIG_SHA256_HWACCEL=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_SHA256_HWACCEL=.*/# CONFIG_SHA256_HWACCEL is not set/' "$BB_DIR/.config"
  fi

  make -C "$BB_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" oldconfig </dev/null >/dev/null
  make -C "$BB_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"

  echo "[3/6] install BusyBox into initramfs root"
  rm -rf "$INITRAMFS_WORK"
  mkdir -p "$INITRAMFS_WORK"
  make -C "$BB_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CONFIG_PREFIX="$INITRAMFS_WORK" install
fi

mkdir -p "$INITRAMFS_WORK"/{proc,sys,dev}
cat > "$INITRAMFS_WORK/init" <<'EOF'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
exec </dev/console >/dev/console 2>&1
echo "[initramfs] boot ok"
exec /bin/sh
EOF
chmod +x "$INITRAMFS_WORK/init"

echo "[4/6] pack initramfs: $INITRAMFS_IMG"
(
  cd "$INITRAMFS_WORK"
  find . -print0 | cpio --null -ov --format=newc --owner=0:0 2>/dev/null | gzip -9
) > "$INITRAMFS_IMG"

echo "[5/6] update kernel config: BLK_DEV_INITRD + INITRAMFS_SOURCE"
"$KDIR/scripts/config" --file "$OUT_DIR/.config" \
  -e BLK_DEV_INITRD \
  --set-str INITRAMFS_SOURCE "$INITRAMFS_IMG"
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

echo "[6/6] rebuild kernel Image + dtbs"
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image dtbs

echo
echo "Done."
echo "initramfs: $INITRAMFS_IMG"
echo "kernel:    $OUT_DIR/arch/arm/boot/Image"
echo
echo "Start debug QEMU with initramfs:"
echo "  CMDLINE='console=ttymxc0,115200 earlycon loglevel=8 panic=-1 rdinit=/init drm_kms_helper.fbdev_emulation=0' ./qemu_dbg.sh"
