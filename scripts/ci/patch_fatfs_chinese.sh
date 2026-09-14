#!/bin/sh
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版 v3 —— 带强制校验，失败即退出，避免静默编出无效版本)
#-----------------------------------------------------------------------------
# ISR 架构关键点：embed.make 从仓库内 iop/__precompiled/bdmfs_fatfs.irx 把
# 文件系统驱动嵌入 ELF（不读 $PS2SDK/iop/irx/）。因此本脚本除了重编安装到
# $PS2SDK/iop/irx 之外，【必须】把重编产物覆盖到 iop/__precompiled/ 才生效。
#
# v3 新增：
#   * 校验 ps2sdk 源码树里确实存在 iop/fs/bdmfs_fatfs，否则现场 clone
#   * 用 find 定位编译产物（不再写死 irx/ 子目录）
#   * 覆盖后强制检查体积：CP869 原版约 37KB，CP936(含码表) 远大于此，
#     体积没有明显增大就 exit 1，防止再次编出“看不出问题”的无效版本
#   * 设置 ALLOW_UNPATCHED_FATFS=1 可跳过强制校验（不建议）
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition v3)"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
PS2SDKSRC="${PS2SDKSRC:-$PS2SDK}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
ALLOW_UNPATCHED_FATFS="${ALLOW_UNPATCHED_FATFS:-0}"
export PS2SDK PS2SDKSRC          # 模块 Makefile 需要读取这两个变量
echo "Using PS2SDK=$PS2SDK"
echo "Using PS2SDKSRC=$PS2SDKSRC"
echo "Using WORKSPACE=$WORKSPACE"
echo "=========================================="

# ---------------------------------------------------------------------------
# 0) 确保 PS2SDKSRC 指向有效的 ps2sdk 源码树，且包含 bdmfs_fatfs 模块
# ---------------------------------------------------------------------------
need_clone=0
if [ ! -f "$PS2SDKSRC/Defs.make" ]; then
  echo "WARN: '$PS2SDKSRC' does not look like a PS2SDK source tree"
  need_clone=1
else
  if [ ! -f "$PS2SDKSRC/iop/fs/bdmfs_fatfs/Makefile" ]; then
    echo "WARN: '$PS2SDKSRC' has no iop/fs/bdmfs_fatfs (SDK-only install?)"
    need_clone=1
  fi
fi

if [ "$need_clone" -eq 1 ]; then
  for cand in /usr/local/ps2sdk "${RUNNER_TEMP:-/tmp}/ps2sdk-src" /tmp/ps2sdk-src; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/Defs.make" ] && [ -f "$cand/iop/fs/bdmfs_fatfs/Makefile" ]; then
      PS2SDKSRC="$cand"
      export PS2SDKSRC
      echo "Using fallback PS2SDKSRC=$PS2SDKSRC"
      need_clone=0
      break
    fi
  done
fi

if [ "$need_clone" -eq 1 ]; then
  echo "No usable PS2SDK source tree; cloning ps2dev/ps2sdk ..."
  PS2SDKSRC="${RUNNER_TEMP:-/tmp}/ps2sdk-src"
  export PS2SDKSRC
  rm -rf "$PS2SDKSRC"
  git clone --depth 1 https://github.com/ps2dev/ps2sdk.git "$PS2SDKSRC" || {
    echo "ERROR: failed to clone ps2sdk"
    exit 1
  }
fi
echo "PS2SDKSRC=$PS2SDKSRC"
if [ ! -f "$PS2SDKSRC/iop/fs/bdmfs_fatfs/Makefile" ]; then
  echo "ERROR: iop/fs/bdmfs_fatfs still missing after clone"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) 确保 FatFs 外部依赖存在
# ---------------------------------------------------------------------------
FATSRC="$PS2SDKSRC/common/external_deps/fatfs"

find_first() {  # $1=name  -> 打印第一个匹配文件路径（可为空）
  find "$FATSRC" -maxdepth 5 -name "$1" 2>/dev/null | head -1
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

FFCONF_LIST="$(find "$FATSRC" -maxdepth 5 -name ffconf.h 2>/dev/null)"
if [ -z "$FFCONF_LIST" ]; then
  echo "ERROR: ffconf.h not found under $FATSRC"
  exit 1
fi
echo "Found ffconf.h:"
echo "$FFCONF_LIST"

# ---------------------------------------------------------------------------
# 2) 只改宏数值：CP936 / LFN=2 / exFAT=1 / LFN_UNICODE=0
# ---------------------------------------------------------------------------
for FFCONF in $FFCONF_LIST; do
  echo "--- Before patch ($FFCONF) ---"
  grep -nE "^#define[[:space:]]+(FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE)" "$FFCONF" || true
  sed -i \
    -e 's/^#define[[:space:]][[:space:]]*FF_CODE_PAGE[[:space:]][[:space:]]*[0-9].*/#define FF_CODE_PAGE\t936/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_USE_LFN[[:space:]][[:space:]]*[0-9].*/#define FF_USE_LFN\t\t2/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_FS_EXFAT[[:space:]][[:space:]]*[0-9].*/#define FF_FS_EXFAT\t1/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_LFN_UNICODE[[:space:]][[:space:]]*[0-9].*/#define FF_LFN_UNICODE\t0/' \
    "$FFCONF"
  echo "--- After patch ---"
  grep -nE "^#define[[:space:]]+(FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE)" "$FFCONF" || true
done

# 确认关键宏真的被改掉了
if ! grep -hqE "^#define[[:space:]]+FF_CODE_PAGE[[:space:]]+936" $FFCONF_LIST; then
  echo "ERROR: FF_CODE_PAGE was NOT set to 936"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3) 触碰源文件，强制 make 重编（防止按时间戳跳过）
# ---------------------------------------------------------------------------
echo "Touching FatFs sources to force rebuild..."
find "$FATSRC" -maxdepth 4 -name '*.c' -exec touch {} + 2>/dev/null || true
find "$FATSRC" -maxdepth 4 -name '*.h' -exec touch {} + 2>/dev/null || true
touch "$PS2SDKSRC"/iop/fs/bdmfs_fatfs/src/*.c 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4) 从源码重编存储模块并安装到 $PS2SDK/iop/irx/
# ---------------------------------------------------------------------------
mkdir -p "$PS2SDK/iop/irx"

rebuild_module() {
  mod="$1"; name="$2"
  echo "Building $mod ..."
  if make -C "$PS2SDKSRC/$mod" all 2>&1; then
    echo "  OK: built $mod"
  else
    echo "  ERROR: build failed for $mod"
    return 1
  fi
  # 用 find 定位产物，兼容 irx/ 子目录或直接放在模块根目录的布局
  src_irx="$(find "$PS2SDKSRC/$mod" -maxdepth 2 -name "$name.irx" 2>/dev/null | head -1)"
  if [ -z "$src_irx" ]; then
    echo "  ERROR: $name.irx not found under $PS2SDKSRC/$mod"
    return 1
  fi
  echo "  built: $src_irx ($(wc -c < "$src_irx") bytes)"
  if cp -f "$src_irx" "$PS2SDK/iop/irx/$name.irx"; then
    echo "  OK: installed $name.irx -> $PS2SDK/iop/irx/"
  else
    echo "  ERROR: failed to install $name.irx"
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
# ---------------------------------------------------------------------------
PRE="$WORKSPACE/iop/__precompiled"
FATFS_IRX="$(find "$PS2SDKSRC/iop/fs/bdmfs_fatfs" -maxdepth 2 -name bdmfs_fatfs.irx 2>/dev/null | head -1)"
if [ -z "$FATFS_IRX" ]; then
  FATFS_IRX="$PS2SDK/iop/irx/bdmfs_fatfs.irx"
fi

if [ -f "$FATFS_IRX" ]; then
  mkdir -p "$PRE"
  cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx" \
    && echo "OK: updated $PRE/bdmfs_fatfs.irx (this is the copy embed.make embeds)"
else
  echo "ERROR: rebuilt bdmfs_fatfs.irx not found"
  ok=0
fi

# ---------------------------------------------------------------------------
# 6) 兜底：若单个模块失败，整体编译 iop 层后再覆盖一次
# ---------------------------------------------------------------------------
if [ "$ok" -eq 0 ]; then
  echo "Falling back to full 'make -C $PS2SDKSRC iop' ..."
  make -C "$PS2SDKSRC" iop 2>&1 || echo "WARN: 'make iop' failed; check toolchain env"
  FATFS_IRX="$(find "$PS2SDKSRC/iop/fs/bdmfs_fatfs" -maxdepth 2 -name bdmfs_fatfs.irx 2>/dev/null | head -1)"
  if [ -n "$FATFS_IRX" ] && [ -f "$FATFS_IRX" ]; then
    cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx" && echo "OK: updated precompiled bdmfs_fatfs.irx (fallback)"
  fi
fi

# ---------------------------------------------------------------------------
# 7) 强制校验 + 诊断输出
# ---------------------------------------------------------------------------
echo "=========================================="
echo "Final IRX files:"
ls -la "$PS2SDK/iop/irx/bdm.irx" \
       "$PS2SDK/iop/irx/bdmfs_fatfs.irx" \
       "$PS2SDK/iop/irx/usbmass_bd.irx" 2>&1 || true
echo "Repo precompiled copy (embed.make source of truth):"
ls -la "$PRE/bdmfs_fatfs.irx" 2>&1 || true

FATAL=0
if [ ! -f "$PRE/bdmfs_fatfs.irx" ]; then
  echo "ERROR: $PRE/bdmfs_fatfs.irx is missing!"
  FATAL=1
else
  SIZE=$(wc -c < "$PRE/bdmfs_fatfs.irx" | tr -d ' ')
  echo "bdmfs_fatfs.irx size = $SIZE bytes"
  echo "  (CP869 原版约 37724 字节；CP936 带码表应明显大于 60000 字节)"
  if [ "$SIZE" -lt 60000 ]; then
    echo "ERROR: bdmfs_fatfs.irx is still the old CP869 build -> 中文长文件名不会出现，只会显示 8.3 短名(~1)"
    FATAL=1
  else
    echo "OK: bdmfs_fatfs.irx looks like a CP936 build."
  fi
fi

if [ "$FATAL" -eq 1 ] && [ "$ALLOW_UNPATCHED_FATFS" != "1" ]; then
  echo "FatFs CP936 patch FAILED. 构建已中止。"
  echo "（如需无论如何都继续出包，可在 workflow 里给本步设置环境变量 ALLOW_UNPATCHED_FATFS=1）"
  exit 1
fi

echo "FatFs Chinese patch complete."
echo "=========================================="
