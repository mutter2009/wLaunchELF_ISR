#!/bin/sh
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
#-----------------------------------------------------------------------------
# 在 GitHub Actions 构建 wLaunchELF 之前运行，完成以下工作：
#   1. 定位 PS2SDK 源码树（$PS2SDKSRC），并确保 FatFs 外部依赖已下载。
#   2. 只 sed 修改 ffconf.h 的宏数值，不动其它行；不 `make clean`、不强制
#      重新 `download_dependencies`（如果源码已存在，避免把 patch 覆盖掉）。
#   3. 用 `make -C $PS2SDKSRC/<模块> all` 从源码重新编译 bdm / bdmfs_fatfs /
#      usbmass_bd，然后手动把生成的 IRX 复制到 $PS2SDK/iop/irx（这些模块
#      的 Makefile 没有 install 目标）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
PS2SDKSRC="${PS2SDKSRC:-$PS2SDK}"
echo "Using PS2SDK=$PS2SDK"
echo "Using PS2SDKSRC=$PS2SDKSRC"
echo "=========================================="

# ---------------------------------------------------------------------------
# 0) 确保 PS2SDKSRC 指向有效的 ps2sdk 源码树
# ---------------------------------------------------------------------------
if [ -z "$PS2SDKSRC" ] || [ ! -f "$PS2SDKSRC/Defs.make" ]; then
  echo "WARN: '$PS2SDKSRC' does not look like a PS2SDK source tree"
  for cand in /usr/local/ps2sdk "$PS2SDK" "$RUNNER_TEMP"/ps2sdk-src /tmp/ps2sdk-src; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/Defs.make" ]; then
      PS2SDKSRC="$cand"
      echo "Using fallback PS2SDKSRC=$PS2SDKSRC"
      break
    fi
  done
fi

if [ -z "$PS2SDKSRC" ] || [ ! -f "$PS2SDKSRC/Defs.make" ]; then
  echo "ERROR: cannot find a valid PS2SDK source tree (Defs.make missing)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) 确保 FatFs 源码已存在；如果不存在，安全地下载一次。
#    注意：只有在 fatfs 目录缺失时才调用 download_dependencies.sh，
#    防止它把已经 patch 过的 fatfs 强制 reset 回未 patch 版本。
# ---------------------------------------------------------------------------
FATSRC="$PS2SDKSRC/common/external_deps/fatfs"

if [ ! -f "$FATSRC/source/include/ffconf.h" ]; then
  echo "FatFs source not found at $FATSRC, downloading dependencies..."
  if [ ! -x "$PS2SDKSRC/download_dependencies.sh" ]; then
    echo "ERROR: $PS2SDKSRC/download_dependencies.sh not found or not executable"
    exit 1
  fi
  cd "$PS2SDKSRC" || exit 1
  bash ./download_dependencies.sh || {
    echo "ERROR: download_dependencies.sh failed"
    exit 1
  }
fi

FFCONF="$FATSRC/source/include/ffconf.h"
if [ ! -f "$FFCONF" ]; then
  echo "ERROR: ffconf.h still not found at $FFCONF"
  echo "Searched under PS2SDKSRC=$PS2SDKSRC"
  exit 1
fi
echo "Found ffconf.h: $FFCONF"

echo "--- Before patch ---"
grep -nE "FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE" "$FFCONF" || true

# ---------------------------------------------------------------------------
# 2) 只改宏的数值，不产生 #undef，也不动其它行
# ---------------------------------------------------------------------------
sed -i \
  -e 's/^#define[[:space:]][[:space:]]*FF_CODE_PAGE[[:space:]][[:space:]]*[0-9].*/#define FF_CODE_PAGE   936/' \
  -e 's/^#define[[:space:]][[:space:]]*FF_USE_LFN[[:space:]][[:space:]]*[0-9].*/#define FF_USE_LFN   2/' \
  -e 's/^#define[[:space:]][[:space:]]*FF_FS_EXFAT[[:space:]][[:space:]]*[0-9].*/#define FF_FS_EXFAT   1/' \
  -e 's/^#define[[:space:]][[:space:]]*FF_LFN_UNICODE[[:space:]][[:space:]]*[0-9].*/#define FF_LFN_UNICODE   0/' \
  "$FFCONF"

echo "--- After patch ---"
grep -nE "FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE" "$FFCONF" || true

# ---------------------------------------------------------------------------
# 3) 确认 CP936 转换表存在
# ---------------------------------------------------------------------------
if grep -q "936" "$FATSRC/source/ffunicode.c" 2>/dev/null; then
  echo "OK: ffunicode.c appears to support CP936"
else
  echo "WARN: could not confirm CP936 in ffunicode.c (continuing anyway)"
fi

# ---------------------------------------------------------------------------
# 4) 强制 FatFs 源文件重新编译（头文件改动后，touch 源文件确保 make 重编）
# ---------------------------------------------------------------------------
echo "Touching FatFs sources to force rebuild..."
touch "$FATSRC"/source/*.c 2>/dev/null || true
touch "$PS2SDKSRC"/iop/fs/bdmfs_fatfs/src/*.c 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5) 从源码重新编译模块，并手动把生成的 IRX 复制到 $PS2SDK/iop/irx/
#    注意：这些 IOP 模块的 Makefile 只有 all 目标，没有 install 目标。
# ---------------------------------------------------------------------------
mkdir -p "$PS2SDK/iop/irx"

rebuild_module() {
  mod="$1"
  name="$2"
  echo "Building $mod ..."
  if make -C "$PS2SDKSRC/$mod" all 2>&1; then
    echo "  OK: built $mod"
  else
    echo "  WARN: 'make -C $PS2SDKSRC/$mod all' failed"
    return 1
  fi

  src_irx="$PS2SDKSRC/$mod/irx/$name.irx"
  dst_irx="$PS2SDK/iop/irx/$name.irx"
  if [ -f "$src_irx" ]; then
    cp -f "$src_irx" "$dst_irx" || {
      echo "  WARN: failed to copy $src_irx -> $dst_irx"
      return 1
    }
    echo "  OK: installed $name.irx -> $PS2SDK/iop/irx/"
  else
    echo "  WARN: expected IRX not found at $src_irx"
    return 1
  fi
}

ok=1
rebuild_module iop/fs/bdm          bdm          || ok=0
rebuild_module iop/fs/bdmfs_fatfs  bdmfs_fatfs  || ok=0
rebuild_module iop/usb/usbmass_bd  usbmass_bd   || ok=0

# ---------------------------------------------------------------------------
# 6) 兜底：若单个模块编译失败，整体编译 iop 层，然后复制关键 IRX
# ---------------------------------------------------------------------------
if [ "$ok" -eq 0 ]; then
  echo "Falling back to full 'make -C $PS2SDKSRC iop' ..."
  make -C "$PS2SDKSRC" iop 2>&1 || echo "WARN: 'make iop' also failed; check toolchain env"
  for mod in iop/fs/bdm iop/fs/bdmfs_fatfs iop/usb/usbmass_bd; do
    name="$(basename "$mod")"
    src_irx="$PS2SDKSRC/$mod/irx/$name.irx"
    dst_irx="$PS2SDK/iop/irx/$name.irx"
    [ -f "$src_irx" ] && cp -f "$src_irx" "$dst_irx" && echo "  OK: copied $name.irx (fallback)"
  done
fi

# ---------------------------------------------------------------------------
# 7) 诊断输出
# ---------------------------------------------------------------------------
echo "=========================================="
echo "Final IRX files (timestamps should be NEW, not from base image):"
ls -la "$PS2SDK"/iop/irx/bdm.irx \
       "$PS2SDK"/iop/irx/bdmfs_fatfs.irx \
       "$PS2SDK"/iop/irx/usbmass_bd.irx 2>&1 || true
echo "FatFs Chinese patch complete."
echo "=========================================="
