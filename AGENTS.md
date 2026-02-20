# Repository Guidelines

## Project Structure & Module Organization
Core kernel code lives in `arch/`, `drivers/`, `fs/`, `kernel/`, `mm/`, `net/`, `security/`, and `lib/`. Shared headers are in `include/`, architecture-specific headers in `arch/*/include/`, and contributor docs in `Documentation/`. Use `MAINTAINERS` to find code owners and mailing lists.

This tree also contains local ARM bring-up tooling: `build.sh`, `prepare_initramfs.sh`, `prepare_initramfs_debug.sh`, and `qemu_dbg.sh`. BusyBox sources are in `busybox/`. Build artifacts are written to `out/` and `compile_commands.json`.

## Build, Test, and Development Commands
- `./build.sh`  
  Default ARM build (`imx_v6_v7_defconfig`), producing `Image`, `dtbs`, and `compile_commands.json`.
- `make O=out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) Image dtbs`  
  Fast incremental rebuild.
- `./prepare_initramfs.sh`  
  Rebuild BusyBox initramfs and update `INITRAMFS_SOURCE`.
- `./prepare_initramfs_debug.sh`  
  Debug-oriented rebuild (`DEBUG_INFO`, frame-pointer-friendly flags).
- `./qemu_dbg.sh`  
  Launch ARM QEMU debug session (GDB server on `:1234`).
- `make O=out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- W=1`  
  Build with extra compiler warnings.

## Coding Style & Naming Conventions
Follow `Documentation/process/coding-style.rst`: tabs for kernel C/Kconfig/Makefiles, 8-column tab width, and generally keep lines near 80 columns. `.editorconfig` is authoritative for per-language indentation (for example: Python/Rust use 4 spaces, YAML uses 2 spaces). Prefer clear, subsystem-aligned naming and avoid unrelated refactors in functional patches.

Run style checks before submission:
`scripts/checkpatch.pl --strict <patch-or-commit>`

## Testing Guidelines
At minimum, compile-test all touched paths and confirm `Image`/`dtbs` still build. For runtime checks, run targeted selftests under `tools/testing/selftests/` and include exact commands/results in your change notes. For debug flows, verify boot in `qemu_dbg.sh` when changes affect ARM startup, initramfs, or DT.

## Commit & Pull Request Guidelines
Recent local commits use short imperative subjects (for example, `start kernel`, `add debug build scripts`). Keep commits small and bisectable. For upstreamable patches, use kernel format: `subsystem: summary phrase` (about 70 chars), add a descriptive body, and include required trailers such as `Signed-off-by:` (and `Fixes:` when applicable).  

PRs should state scope, risk, build/test commands run, and target environment (board or QEMU machine).

现在优先使用prepare_nfs_debug.sh 进行构建 使用qemu_dbg.sh + vscode 进行调试
增加的注释均使用中文
不要乱加断点