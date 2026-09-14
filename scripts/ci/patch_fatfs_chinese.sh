#!/bin/bash
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版 v4)
#-----------------------------------------------------------------------------
# ISR 架构关键点：embed.make 从仓库内 iop/__precompiled/bdmfs_fatfs.irx 把文件
# 系统驱动嵌入 ELF（EXFAT=1 与否用的都是同一个文件）。因此必须把重编产物覆盖到
# iop/__precompiled/ 才生效，只装到 $PS2SDK/iop/irx 是没用的。
#
# v3 -> v4 的关键修正（v3 在 ps2dev/ps2dev:v1.0 镜像里必然失败的原因）：
#   1) v3 克隆的是 ps2sdk master，其 Defs.make 里
#      IOP_TOOL_PREFIX ?= mipsel-none-elf-
#      而 v1.0 镜像里的编译器叫 iop-gcc -> make 报 "Error 127: not found"。
#      v4 会先探测镜像里实际存在的前缀，再通过命令行变量强制指定。
#   2) ps2sdk master/2.0.0 链接 IRX 需要 host 工具 srxfixup（要用宿主机 cc 编译），
#      v1.0 镜像默认没有 gcc。workflow 已加 build-base，脚本里也会检测并传 CC。
#   3) 新版 ps2sdk 默认 -Werror 和 -gz（压缩调试段），老 GCC 会因此报错，
#      v4 用命令行变量放宽这两项。
#   4) ps2sdk 版本锁定到 tag 2.0.0（带 iop/fs/bdmfs_fatfs 的稳定发布版），
#      不再追 master，避免上游改动再次破坏 CI。
#   5) 只重编 bdmfs_fatfs；bdm/usbmass_bd/usbd 沿用仓库 iop/__precompiled 里的
#      原版（它们与 CP936 无关，没必要多失败两个环节）。
#
# 强制校验：CP869 原版约 37KB；CP936（带 GBK 码表）应明显大于 60000 字节，
# 体积没变大就 exit 1，防止再次静默编出无效版本。
# 设置 ALLOW_UNPATCHED_FATFS=1 可跳过该校验（不建议）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition v4)"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
ALLOW_UNPATCHED_FATFS="${ALLOW_UNPATCHED_FATFS:-0}"
PS2SDKREF="${PS2SDKREF:-2.0.0}"   # 锁定 ps2sdk 版本
export PS2SDK
echo "Using PS2SDK=$PS2SDK"
echo "Using WORKSPACE=$WORKSPACE"
echo "Using PS2SDKREF=$PS2SDKREF"
echo "=========================================="

# ---------------------------------------------------------------------------
# 0) 探测工具链前缀（v1.0 老镜像 = iop-，新镜像 = mipsel-none-elf-）
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

IOPP=""
for p in mipsel-none-elf- iop-; do
  if have "${p}gcc"; then IOPP="$p"; break; fi
done
if [ -z "$IOPP" ]; then
  echo "ERROR: neither mipsel-none-elf-gcc nor iop-gcc found in PATH" >&2
  echo "PATH=$PATH" >&2
  exit 1
fi

EEP=""
for p in mips64r5900el-ps2-elf- ee-; do
  if have "${p}gcc"; then EEP="$p"; break; fi
done

HOSTCC=cc
if ! have cc; then
  if have gcc; then HOSTCC=gcc; else
    echo "ERROR: no host compiler (cc/gcc) - srxfixup 无法编译" >&2
    exit 1
  fi
fi

echo "IOP tool prefix : $IOPP"
echo "EE  tool prefix : ${EEP:-<未检测到，交由 Defs.make 默认值>}"
echo "Host  compiler  : $HOSTCC"
"$IOPP"gcc --version | head -1 || true
echo "=========================================="

# ---------------------------------------------------------------------------
# 1) 取得含 iop/fs/bdmfs_fatfs 的 ps2sdk 源码树（锁定 tag，保证可复现）
# ---------------------------------------------------------------------------
PS2SDKSRC="${RUNNER_TEMP:-/tmp}/ps2sdk-src"
export PS2SDKSRC

tree_ok() {
  [ -f "$1/Defs.make" ] && [ -f "$1/iop/fs/bdmfs_fatfs/Makefile" ]
}

if tree_ok "$PS2SDKSRC"; then
  echo "Reusing existing ps2sdk source tree at $PS2SDKSRC"
else
  rm -rf "$PS2SDKSRC"
  echo "Cloning ps2dev/ps2sdk ($PS2SDKREF) ..."
  git clone --depth 1 -b "$PS2SDKREF" https://github.com/ps2dev/ps2sdk.git "$PS2SDKSRC" \
  || { echo "clone $PS2SDKREF failed, falling back to master"; \
       rm -rf "$PS2SDKSRC"; \
       git clone --depth 1 https://github.com/ps2dev/ps2sdk.git "$PS2SDKSRC" || {
         echo "ERROR: failed to clone ps2sdk"; exit 1; }; }
fi

if ! tree_ok "$PS2SDKSRC"; then
  echo "ERROR: $PS2SDKSRC does not contain iop/fs/bdmfs_fatfs"
  exit 1
fi
echo "PS2SDKSRC=$PS2SDKSRC"

# ---------------------------------------------------------------------------
# 2) 确保 FatFs 外部依赖存在（ps2sdk 2.0.0 官方脚本用的是 fjtrujy/FatFs iop-r0.16）
# ---------------------------------------------------------------------------
FATSRC="$PS2SDKSRC/common/external_deps/fatfs"

find_first() { find "$FATSRC" -maxdepth 5 -name "$1" 2>/dev/null | head -1; }

if [ -z "$(find_first ffconf.h)" ]; then
  echo "FatFs source not found at $FATSRC"
  if [ -f "$PS2SDKSRC/download_dependencies.sh" ]; then
    echo "Running ps2sdk's download_dependencies.sh ..."
    ( cd "$PS2SDKSRC" && bash ./download_dependencies.sh ) \
      || echo "WARN: download_dependencies.sh failed, will try direct clone"
  fi
fi

if [ -z "$(find_first ffconf.h)" ]; then
  echo "Cloning FatFs (fjtrujy/FatFs, branch iop-r0.16) directly ..."
  rm -rf "${FATSRC}_inprogress" "$FATSRC"
  git clone --depth 1 -b iop-r0.16 https://github.com/fjtrujy/FatFs.git "${FATSRC}_inprogress" \
    && mv "${FATSRC}_inprogress" "$FATSRC" || {
    echo "ERROR: failed to clone FatFs"; exit 1; }
fi

FFCONF_LIST="$(find "$FATSRC" -maxdepth 5 -name ffconf.h 2>/dev/null)"
if [ -z "$FFCONF_LIST" ]; then
  echo "ERROR: ffconf.h not found under $FATSRC"
  exit 1
fi
echo "Found ffconf.h:"
echo "$FFCONF_LIST"

# ---------------------------------------------------------------------------
# 3) 只改宏数值：CP936 / LFN=2 / exFAT=1 / LFN_UNICODE=0
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

if ! grep -hqE "^#define[[:space:]]+FF_CODE_PAGE[[:space:]]+936" $FFCONF_LIST; then
  echo "ERROR: FF_CODE_PAGE was NOT set to 936"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4) 重编 bdmfs_fatfs（这是唯一需要 CP936 的模块）
#    关键：用命令行变量覆盖工具前缀，绕开 Error 127
# ---------------------------------------------------------------------------
echo "Touching FatFs sources to force rebuild..."
find "$FATSRC" -maxdepth 4 -name '*.[ch]' -exec touch {} + 2>/dev/null || true

MAKE_FLAGS="IOP_TOOL_PREFIX=$IOPP CC=$HOSTCC"
MAKE_FLAGS="$MAKE_FLAGS IOP_WARNFLAGS=-Wall IOP_DBGINFOFLAGS=-gdwarf-2"
[ -n "$EEP" ] && MAKE_FLAGS="$MAKE_FLAGS EE_TOOL_PREFIX=$EEP"
echo "make flags: $MAKE_FLAGS"

MOD="$PS2SDKSRC/iop/fs/bdmfs_fatfs"
echo "Building $MOD ..."
if ! make -C "$MOD" all $MAKE_FLAGS; then
  echo "ERROR: build failed for iop/fs/bdmfs_fatfs"
  exit 1
fi

FATFS_IRX="$(find "$MOD" -maxdepth 2 -name bdmfs_fatfs.irx 2>/dev/null | head -1)"
if [ -z "$FATFS_IRX" ]; then
  echo "ERROR: bdmfs_fatfs.irx was not produced"
  exit 1
fi
echo "built: $FATFS_IRX ($(wc -c < "$FATFS_IRX") bytes)"

# ---------------------------------------------------------------------------
# 5) ISR 架构关键步骤：覆盖仓库内 iop/__precompiled/bdmfs_fatfs.irx
# ---------------------------------------------------------------------------
PRE="$WORKSPACE/iop/__precompiled"
mkdir -p "$PRE"
cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx" \
  && echo "OK: updated $PRE/bdmfs_fatfs.irx (this is the copy embed.make embeds)"

# ---------------------------------------------------------------------------
# 6) 强制校验 + 诊断输出
# ---------------------------------------------------------------------------
echo "=========================================="
ls -la "$PRE/bdmfs_fatfs.irx" 2>&1 || true
echo "Repo precompiled dir now contains:"
ls -la "$PRE" 2>/dev/null | head -20

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
