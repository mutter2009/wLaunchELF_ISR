#!/bin/sh
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版)
#-----------------------------------------------------------------------------
# ISR 架构关键点：embed.make 从仓库内 iop/__precompiled/bdmfs_fatfs.irx 把
# 文件系统驱动嵌入 ELF（不读 $PS2SDK/iop/irx/）。因此本脚本除了重编安装到
# $PS2SDK/iop/irx 之外，【必须】把重编产物覆盖到 iop/__precompiled/ 才生效。
#
# ps2dev/ps2dev:v1.0 镜像里 $PS2SDK 即源码树（有 Defs.make），但缺少 FatFs
# 外部依赖，且镜像内没有 download_dependencies.sh，故本脚本兜底直接克隆
# fjtrujy/FatFs（与 ps2sdk 官方 download_dependencies.sh 完全同源同分支）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition)"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
PS2SDKSRC="${PS2SDKSRC:-$PS2SDK}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
export PS2SDK PS2SDKSRC          # 模块 Makefile 需要读取这两个变量
echo "Using PS2SDK=$PS2SDK"
echo "Using PS2SDKSRC=$PS2SDKSRC"
echo "Using WORKSPACE=$WORKSPACE"
echo "=========================================="

# ---------------------------------------------------------------------------
# 0) 确保 PS2SDKSRC 指向有效的 ps2sdk 源码树；找不到就现场 clone 一份
# ---------------------------------------------------------------------------
if [ ! -f "$PS2SDKSRC/Defs.make" ]; then
  echo "WARN: '$PS2SDKSRC' does not look like a PS2SDK source tree"
  for cand in /usr/local/ps2sdk "$PS2SDK" "${RUNNER_TEMP:-/tmp}/ps2sdk-src" /tmp/ps2sdk-src; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/Defs.make" ]; then
      PS2SDKSRC="$cand"
      export PS2SDKSRC
      echo "Using fallback PS2SDKSRC=$PS2SDKSRC"
      break
    fi
  done
fi

if [ ! -f "$PS2SDKSRC/Defs.make" ]; then
  echo "No valid PS2SDK source tree; cloning ps2dev/ps2sdk ..."
  PS2SDKSRC="${RUNNER_TEMP:-/tmp}/ps2sdk-src"
  export PS2SDKSRC
  rm -rf "$PS2SDKSRC"
  git clone --depth 1 https://github.com/ps2dev/ps2sdk.git "$PS2SDKSRC" || {
    echo "ERROR: failed to clone ps2sdk"
    exit 1
  }
fi
echo "PS2SDKSRC=$PS2SDKSRC"

# ---------------------------------------------------------------------------
# 1) 确保 FatFs 外部依赖存在
#    首选镜像内 download_dependencies.sh；没有则直接克隆官方同源仓库。
# ---------------------------------------------------------------------------
FATSRC="$PS2SDKSRC/common/external_deps/fatfs"

find_first() {  # $1=name  -> 打印第一个匹配文件路径（可为空）
  find "$FATSRC" -maxdepth 4 -name "$1" 2>/dev/null | head -1
}

if [ -z "$(find_first ffconf.h)" ]; then
  echo "FatFs source not found at $FATSRC"
  if [ -x "$PS2SDKSRC/download_dependencies.sh" ]; then
    echo "Running download_dependencies.sh ..."
    ( cd "$PS2SDKSRC" && bash ./download_dependencies.sh ) \
      || echo "WARN: download_dependencies.sh failed, will try direct clone"
  else
    echo "download_dependencies.sh not available, using direct clone"
  fi
fi

if [ -z "$(find_first ffconf.h)" ]; then
  echo "Cloning FatFs (fjtrujy/FatFs, branch iop-r0.16) ..."
  rm -rf "${FATSRC}_inprogress" "$FATSRC"
  git clone --depth 1 -b iop-r0.16 https://github.com/fjtrujy/FatFs.git "${FATSRC}_inprogress" \
    && mv "${FATSRC}_inprogress" "$FATSRC" || {
    echo "ERROR: failed to clone FatFs"
    exit 1
  }
fi

FFCONF_LIST="$(find "$FATSRC" -maxdepth 4 -name ffconf.h 2>/dev/null)"
if [ -z "$FFCONF_LIST" ]; then
  echo "ERROR: ffconf.h not found under $FATSRC"
  exit 1
fi
echo "Found ffconf.h:"
echo "$FFCONF_LIST"

# ---------------------------------------------------------------------------
# 2) 只改宏数值：CP936 / LFN=2 / exFAT=1 / LFN_UNICODE=0
#    （对找到的所有 ffconf.h 副本逐个处理，规避目录布局差异）
# ---------------------------------------------------------------------------
for FFCONF in $FFCONF_LIST; do
  echo "--- Before patch ($FFCONF) ---"
  grep -nE "FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE" "$FFCONF" || true
  sed -i \
    -e 's/^#define[[:space:]][[:space:]]*FF_CODE_PAGE[[:space:]][[:space:]]*[0-9].*/#define FF_CODE_PAGE   936/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_USE_LFN[[:space:]][[:space:]]*[0-9].*/#define FF_USE_LFN   2/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_FS_EXFAT[[:space:]][[:space:]]*[0-9].*/#define FF_FS_EXFAT   1/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_LFN_UNICODE[[:space:]][[:space:]]*[0-9].*/#define FF_LFN_UNICODE   0/' \
    "$FFCONF"
  echo "--- After patch ---"
  grep -nE "FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE" "$FFCONF" || true
done

FFUNICODE="$(find_first ffunicode.c)"
if [ -n "$FFUNICODE" ] && grep -q "936" "$FFUNICODE"; then
  echo "OK: ffunicode.c appears to support CP936"
else
  echo "WARN: could not confirm CP936 in ffunicode.c (continuing anyway)"
fi

# ---------------------------------------------------------------------------
# 3) 触碰源文件，强制 make 重编（防止按时间戳跳过）
# ---------------------------------------------------------------------------
echo "Touching FatFs sources to force rebuild..."
find "$FATSRC" -maxdepth 3 -name '*.c' -exec touch {} + 2>/dev/null || true
touch "$PS2SDKSRC"/iop/fs/bdmfs_fatfs/src/*.c 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4) 从源码重编存储模块并安装到 $PS2SDK/iop/irx/（这些 Makefile 无 install 目标）
# ---------------------------------------------------------------------------
mkdir -p "$PS2SDK/iop/irx"

rebuild_module() {
  mod="$1"; name="$2"
  echo "Building $mod ..."
  if make -C "$PS2SDKSRC/$mod" all 2>&1; then
    echo "  OK: built $mod"
  else
    echo "  WARN: build failed for $mod"
    return 1
  fi
  src_irx="$PS2SDKSRC/$mod/irx/$name.irx"
  if [ -f "$src_irx" ]; then
    cp -f "$src_irx" "$PS2SDK/iop/irx/$name.irx" \
      && echo "  OK: installed $name.irx -> $PS2SDK/iop/irx/"
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
# 5) ISR 架构关键步骤：覆盖仓库内 iop/__precompiled/bdmfs_fatfs.irx
#    embed.make 从这里嵌入驱动，不覆盖则中文长名修复完全不生效！
#    （bdm / usbmass_bd / mx4sio_bd 保留仓库原版，维持 israpps 已验证的
#      驱动组合，只替换唯一需要 CP936 的 bdmfs_fatfs）
# ---------------------------------------------------------------------------
PRE="$WORKSPACE/iop/__precompiled"
FATFS_IRX="$PS2SDKSRC/iop/fs/bdmfs_fatfs/irx/bdmfs_fatfs.irx"
if [ -f "$FATFS_IRX" ]; then
  mkdir -p "$PRE"
  if cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx"; then
    echo "OK: updated $PRE/bdmfs_fatfs.irx (this is the copy embed.make embeds)"
  else
    echo "ERROR: failed to update $PRE/bdmfs_fatfs.irx"
    ok=0
  fi
else
  echo "ERROR: rebuilt bdmfs_fatfs.irx not found at $FATFS_IRX"
  ok=0
fi

# ---------------------------------------------------------------------------
# 6) 兜底：若单个模块失败，整体编译 iop 层后再覆盖一次
# ---------------------------------------------------------------------------
if [ "$ok" -eq 0 ]; then
  echo "Falling back to full 'make -C $PS2SDKSRC iop' ..."
  make -C "$PS2SDKSRC" iop 2>&1 || echo "WARN: 'make iop' failed; check toolchain env"
  if [ -f "$FATFS_IRX" ]; then
    cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx" && echo "OK: updated precompiled bdmfs_fatfs.irx (fallback)"
  fi
fi

# ---------------------------------------------------------------------------
# 7) 诊断输出
# ---------------------------------------------------------------------------
echo "=========================================="
echo "Final IRX files (timestamps should be NEW, sizes should be ~210KB for CP936):"
ls -la "$PS2SDK/iop/irx/bdm.irx" \
       "$PS2SDK/iop/irx/bdmfs_fatfs.irx" \
       "$PS2SDK/iop/irx/usbmass_bd.irx" 2>&1 || true
echo "Repo precompiled copy (embed.make source of truth):"
ls -la "$PRE/bdmfs_fatfs.irx" 2>&1 || true
echo "FatFs Chinese patch complete."
echo "=========================================="
