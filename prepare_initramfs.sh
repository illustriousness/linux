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
BUSYBOX_BIN="${BUSYBOX_BIN:-}"
BUSYBOX_STATIC="${BUSYBOX_STATIC:-0}"
ROOTFS_DIR="${ROOTFS_DIR:-}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing command: $1"
    exit 1
  fi
}

for cmd in make cpio gzip sed find readelf; do
  need_cmd "$cmd"
done

if [[ -n "$CROSS_COMPILE" ]]; then
  need_cmd "${CROSS_COMPILE}gcc"
fi

if [[ "$SKIP_BUSYBOX" != "0" && "$SKIP_BUSYBOX" != "1" ]]; then
  echo "ERROR: invalid SKIP_BUSYBOX value: $SKIP_BUSYBOX (expected 0 or 1)"
  exit 1
fi

if [[ "$BUSYBOX_STATIC" != "0" && "$BUSYBOX_STATIC" != "1" ]]; then
  echo "ERROR: invalid BUSYBOX_STATIC value: $BUSYBOX_STATIC (expected 0 or 1)"
  exit 1
fi

if [[ -n "$ROOTFS_DIR" && ! -d "$ROOTFS_DIR" ]]; then
  echo "ERROR: ROOTFS_DIR is not a directory: $ROOTFS_DIR"
  exit 1
fi

check_static_toolchain_sanity() {
  local tmpd test_c test_bin
  local run_rc

  if [[ "$BUSYBOX_STATIC" != "1" ]]; then
    return
  fi

  tmpd="$(mktemp -d /tmp/bb-static-check.XXXXXX)"
  test_c="$tmpd/static_sanity.c"
  test_bin="$tmpd/static_sanity.arm"

  cat > "$test_c" <<'EOF'
#include <stdio.h>
int main(void)
{
  puts("static-sanity-ok");
  return 0;
}
EOF

  # 先验证交叉工具链能否产出最小静态程序。
  if ! "${CROSS_COMPILE}gcc" -static -O2 "$test_c" -o "$test_bin" >/dev/null 2>&1; then
    echo "ERROR: static toolchain sanity check failed at link stage"
    echo "Hint: current ${CROSS_COMPILE}gcc cannot produce runnable static binaries"
    rm -rf "$tmpd"
    exit 1
  fi

  # 若有 qemu-arm，则进一步验证静态程序可运行，提前拦截“编译成功但运行崩溃”。
  if command -v qemu-arm >/dev/null 2>&1; then
    set +e
    qemu-arm "$test_bin" >/dev/null 2>&1
    run_rc=$?
    set -e
    if [[ "$run_rc" -ne 0 ]]; then
      echo "ERROR: static toolchain sanity check failed at runtime (rc=$run_rc)"
      echo "Hint: static ARM userspace is broken with current toolchain/runtime; use BUSYBOX_STATIC=0"
      echo "Hint: or switch to another cross toolchain (e.g. older glibc toolchain / musl toolchain)"
      rm -rf "$tmpd"
      exit 1
    fi
  fi

  rm -rf "$tmpd"
}

copy_sysroot_lib() {
  local src="$1"
  local sysroot="$2"
  local rel dst real real_rel

  rel="${src#"$sysroot"/}"
  dst="$INITRAMFS_WORK/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"

  real="$(readlink -f "$src" || true)"
  if [[ -n "$real" && "$real" != "$src" && "$real" == "$sysroot/"* ]]; then
    real_rel="${real#"$sysroot"/}"
    mkdir -p "$(dirname "$INITRAMFS_WORK/$real_rel")"
    cp -a "$real" "$INITRAMFS_WORK/$real_rel"
  fi
}

install_busybox_runtime_deps() {
  local bb_bin="$1"
  local sysroot interp dep name src target_rel
  local -a deps libs
  declare -A seen=()

  if ! readelf -l "$bb_bin" | grep -q "Requesting program interpreter"; then
    echo "[3/6] BusyBox is static, runtime shared libs not required"
    return
  fi

  # 动态 BusyBox 需要把解释器和依赖库一并放进 initramfs，否则运行会失败或异常。
  sysroot="$(${CROSS_COMPILE}gcc -print-sysroot)"
  if [[ -z "$sysroot" || ! -d "$sysroot" ]]; then
    echo "ERROR: invalid sysroot from ${CROSS_COMPILE}gcc -print-sysroot: $sysroot"
    exit 1
  fi

  interp="$(readelf -l "$bb_bin" | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p' | head -n1)"
  mapfile -t deps < <(readelf -d "$bb_bin" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')

  libs=()
  if [[ -n "$interp" ]]; then
    libs+=("${interp##*/}")
  fi
  for dep in "${deps[@]}"; do
    libs+=("${dep##*/}")
  done

  for name in "${libs[@]}"; do
    [[ -n "$name" ]] || continue
    if [[ -n "${seen[$name]:-}" ]]; then
      continue
    fi
    seen["$name"]=1

    # 优先从 sysroot/lib 精确拷贝，避免误拿到宿主机 x86_64 的同名库。
    if [[ -e "$sysroot/lib/$name" ]]; then
      src="$sysroot/lib/$name"
    elif [[ -e "$sysroot/usr/lib/$name" ]]; then
      src="$sysroot/usr/lib/$name"
    else
      src="$(find "$sysroot/lib" "$sysroot/usr/lib" -name "$name" -print -quit)"
    fi
    if [[ -z "$src" ]]; then
      echo "ERROR: cannot find runtime lib in sysroot: $name"
      exit 1
    fi
    copy_sysroot_lib "$src" "$sysroot"
  done

  # 强校验：确保每个依赖都已经进入 initramfs，缺任意一个立即失败。
  for name in "${libs[@]}"; do
    [[ -n "$name" ]] || continue
    if [[ -e "$INITRAMFS_WORK/lib/$name" ]]; then
      continue
    fi
    if [[ -e "$INITRAMFS_WORK/usr/lib/$name" ]]; then
      continue
    fi
    echo "ERROR: missing runtime lib in initramfs after copy: $name"
    exit 1
  done

  echo "[3/6] copied BusyBox runtime shared libs from sysroot: $sysroot"
}

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

check_static_toolchain_sanity

if [[ ! -f "$OUT_DIR/.config" ]]; then
  echo "[1/6] kernel .config missing, generate from $DEFCONFIG"
  make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
fi

if [[ -n "$ROOTFS_DIR" ]]; then
  echo "[2/6] use existing rootfs directory"
  # 只从 ROOTFS_DIR 复制到临时目录再打包，确保源目录完全不被修改。
  rm -rf "$INITRAMFS_WORK"
  mkdir -p "$INITRAMFS_WORK"
  cp -a "$ROOTFS_DIR"/. "$INITRAMFS_WORK"/
  echo "[3/6] staged rootfs into: $INITRAMFS_WORK (source left untouched)"
elif [[ "$SKIP_BUSYBOX" == "1" ]]; then
  echo "[2/6] skip BusyBox rebuild/install (SKIP_BUSYBOX=1)"
  if [[ ! -x "$INITRAMFS_WORK/bin/busybox" ]]; then
    echo "ERROR: SKIP_BUSYBOX=1 but missing $INITRAMFS_WORK/bin/busybox"
    echo "Hint: run once without SKIP_BUSYBOX=1 to populate initramfs root"
    exit 1
  fi
  echo "[3/6] reuse existing initramfs root: $INITRAMFS_WORK"
elif [[ -n "$BUSYBOX_BIN" ]]; then
  echo "[2/6] use prebuilt BusyBox binary"
  if [[ ! -x "$BUSYBOX_BIN" ]]; then
    echo "ERROR: BUSYBOX_BIN is not executable: $BUSYBOX_BIN"
    exit 1
  fi
  if ! command -v qemu-arm >/dev/null 2>&1; then
    echo "ERROR: qemu-arm not found in PATH"
    echo "Hint: install qemu-user package, or unset BUSYBOX_BIN"
    exit 1
  fi
  # 复用外部 BusyBox 二进制，避免当前工具链重编后出现 applet 段错误。
  rm -rf "$INITRAMFS_WORK"
  mkdir -p "$INITRAMFS_WORK/bin"
  install -m 755 "$BUSYBOX_BIN" "$INITRAMFS_WORK/bin/busybox"
  # 通过 --list-full 生成 applet 软链接，统一指向目标系统内的 /bin/busybox。
  while IFS= read -r applet; do
    [[ -n "$applet" ]] || continue
    mkdir -p "$INITRAMFS_WORK/$(dirname "$applet")"
    ln -snf /bin/busybox "$INITRAMFS_WORK/$applet"
  done < <(qemu-arm "$INITRAMFS_WORK/bin/busybox" --list-full)
  # 部分场景会访问 linuxrc，这里补一个兼容链接。
  ln -snf /bin/busybox "$INITRAMFS_WORK/linuxrc"
  echo "[3/6] install prebuilt BusyBox into initramfs root: $INITRAMFS_WORK"
else
  echo "[2/6] build BusyBox"
  make -C "$BB_DIR" distclean >/dev/null
  make -C "$BB_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig >/dev/null
  if [[ "$BUSYBOX_STATIC" == "1" ]]; then
    if grep -q '^# CONFIG_STATIC is not set' "$BB_DIR/.config"; then
      sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BB_DIR/.config"
    elif grep -q '^CONFIG_STATIC=' "$BB_DIR/.config"; then
      sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' "$BB_DIR/.config"
    else
      echo 'CONFIG_STATIC=y' >> "$BB_DIR/.config"
    fi
  else
    if grep -q '^CONFIG_STATIC=' "$BB_DIR/.config"; then
      sed -i 's/^CONFIG_STATIC=.*/# CONFIG_STATIC is not set/' "$BB_DIR/.config"
    elif ! grep -q '^# CONFIG_STATIC is not set' "$BB_DIR/.config"; then
      echo '# CONFIG_STATIC is not set' >> "$BB_DIR/.config"
    fi
  fi

  # BusyBox 1.37 + newer kernel headers may fail in networking/tc.c (CBQ symbols).
  # Disable tc applet for a stable initramfs build.
  if grep -q '^CONFIG_TC=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_TC=.*/# CONFIG_TC is not set/' "$BB_DIR/.config"
  fi
  if grep -q '^CONFIG_FEATURE_TC_INGRESS=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_FEATURE_TC_INGRESS=.*/# CONFIG_FEATURE_TC_INGRESS is not set/' "$BB_DIR/.config"
  fi

  # 当前 GCC/BusyBox 组合下，ifconfig 状态展示路径（ifconfig -a）可能触发段错误。
  # 关闭该子功能，保留 ifconfig 基础配置能力；状态查看建议使用 ip a。
  if grep -q '^CONFIG_FEATURE_IFCONFIG_STATUS=' "$BB_DIR/.config"; then
    sed -i 's/^CONFIG_FEATURE_IFCONFIG_STATUS=.*/# CONFIG_FEATURE_IFCONFIG_STATUS is not set/' "$BB_DIR/.config"
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

if [[ -z "$ROOTFS_DIR" ]]; then
  install_busybox_runtime_deps "$INITRAMFS_WORK/bin/busybox"

  mkdir -p "$INITRAMFS_WORK"/{proc,sys,dev}
  # 先删除同名软链接（例如 BUSYBOX_BIN 分支中可能存在 /init -> /bin/busybox），
  # 避免重定向写文件时误覆盖 busybox 可执行文件。
  rm -f "$INITRAMFS_WORK/init"
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
else
  # ROOTFS_DIR 模式按源 rootfs 原样打包，不自动改写 /init 与目录布局。
  if [[ ! -e "$INITRAMFS_WORK/init" && ! -e "$INITRAMFS_WORK/sbin/init" ]]; then
    echo "WARN: staged rootfs has no /init and no /sbin/init"
    echo "Hint: set bootargs with rdinit=... or ensure init exists in rootfs"
  fi
fi

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

echo "[6/6] rebuild kernel Image + zImage + dtbs"
make -C "$KDIR" O="$OUT_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image zImage dtbs

echo
echo "Done."
echo "initramfs: $INITRAMFS_IMG"
echo "kernel:    $OUT_DIR/arch/arm/boot/Image"
echo "zImage:    $OUT_DIR/arch/arm/boot/zImage"
echo
echo "Start debug QEMU with initramfs:"
echo "  CMDLINE='console=ttymxc0,115200 earlycon loglevel=8 panic=-1 rdinit=/init drm_kms_helper.fbdev_emulation=0' ./qemu_dbg.sh"
