#!/bin/bash
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版 v5)
#-----------------------------------------------------------------------------
# ISR 架构关键点：embed.make 从仓库内 iop/__precompiled/bdmfs_fatfs.irx 把文件
# 系统驱动嵌入 ELF（EXFAT=1 与否用的都是同一个文件）。因此必须把重编产物覆盖到
# iop/__precompiled/ 才生效，只装到 $PS2SDK/iop/irx 是没用的。
#
# 版本演进
#   v3 : 克隆 ps2sdk master + 假定新工具链前缀 -> v1.0 镜像里 Error 127
#   v4 : 运行时探测工具链前缀（iop- / mipsel-none-elf-），锁定 ps2sdk 2.0.0，
#        放宽 -Werror / -gz。Error 127 消失，但出现 Error 1：
#        FatFs r0.16 的 ff.h 在 FF_FS_EXFAT=1 时要求 C99，而 v1.0 镜像的
#        iop-gcc 是 GCC 3.2.3（不支持 C99）：
#            #error exFAT feature wants C99 or later
#            typedef QWORD FSIZE_t;   -> unknown type name 'QWORD'
#        接着 ff.h 里所有用到 FSIZE_t/FIL* 的声明全部 "syntax error before '*'"
#   v5 : 1) 自动探测 IOP 编译器是否支持 C99；不支持时才给 ff.h 打补丁
#           （去掉 #error + 补 typedef unsigned long long QWORD;）
#        2) 推荐配合 workflow 的 "fatfs" job 在新版镜像 ps2dev/ps2dev:latest
#           里跑本脚本（GCC 11+ 原生 C99，最稳）；老镜像里跑也能自愈
#        3) 体积校验阈值按实测收紧：CP869 原版 37724 字节，两张 GBK 码表各约
#           87KB，CP936 成品应 > 120000 字节
#
# 设置 ALLOW_UNPATCHED_FATFS=1 可跳过体积校验（不建议）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition v5)"
PS2SDK="${PS2SDK:-/usr/local/ps2dev/ps2sdk}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
ALLOW_UNPATCHED_FATFS="${ALLOW_UNPATCHED_FATFS:-0}"
# ps2dev/ps2sdk 仓库没有 2.0.0 这个 tag，直接用 master（即 r0.16 分支）。
# 脚本里会再对 master 的 linkfile 做 GCC 3.2.3 兼容补丁。
PS2SDKREF="${PS2SDKREF:-master}"
# FATFS_MODE:
#   936  -> FF_CODE_PAGE=936 + FF_LFN_UNICODE=0，驱动直接吐 GBK 字节（简体中文原生方案）
#           代价：ffunicode.c 会编进两张 GBK 码表（各约 87KB），IRX 从 37KB 涨到约 210KB，
#           占 IOP 内存较多。若实机黑屏/起不来，优先怀疑这里。
#   utf8 -> FF_CODE_PAGE=437 + FF_LFN_UNICODE=2，驱动直接吐 UTF-8 字节
#           437 码表只有 270 字节，IRX 基本维持原大小（约 40KB），对 IOP 最友好；
#           汉化版 draw_text.c 的 decode_any() 本来就优先按 UTF-8 解码。
FATFS_MODE="${FATFS_MODE:-936}"
case "$FATFS_MODE" in
  936)  CODE_PAGE=936; LFN_UNICODE=0; MIN_SIZE="${MIN_SIZE:-120000}" ;;
  utf8) CODE_PAGE=437; LFN_UNICODE=2; MIN_SIZE="${MIN_SIZE:-20000}" ;;
  *)    echo "ERROR: unknown FATFS_MODE=$FATFS_MODE (use 936 or utf8)" >&2; exit 1 ;;
esac
export PS2SDK
echo "Using PS2SDK=$PS2SDK"
echo "Using WORKSPACE=$WORKSPACE"
echo "Using PS2SDKREF=$PS2SDKREF"
echo "Using FATFS_MODE=$FATFS_MODE (FF_CODE_PAGE=$CODE_PAGE, FF_LFN_UNICODE=$LFN_UNICODE)"
echo "=========================================="

# ---------------------------------------------------------------------------
# 0) 探测工具链前缀（老镜像 = iop-，新镜像 = mipsel-none-elf-）
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

# --- 探测编译器是否支持 C99（GCC 3.2.3 的 gnu89 默认不定义 __STDC_VERSION__）---
C99=no
if "$IOPP"gcc -dM -E -x c /dev/null 2>/dev/null | grep -qE '#define[[:space:]]+__STDC_VERSION__'; then
  C99=yes
fi
echo "Compiler C99    : $C99"
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
#    bdmfs_fatfs 的 Makefile 里 $(FATFS) 只要目录存在就不会去跑 external_deps，
#    所以这里直接克隆比跑 download_dependencies.sh 更省事也更可控。
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
# 3) 只改宏数值：码表 / LFN=2 / exFAT=1 / LFN_UNICODE
# ---------------------------------------------------------------------------
for FFCONF in $FFCONF_LIST; do
  echo "--- Before patch ($FFCONF) ---"
  grep -nE "^#define[[:space:]]+(FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE)" "$FFCONF" || true
  sed -i \
    -e "s/^#define[[:space:]][[:space:]]*FF_CODE_PAGE[[:space:]][[:space:]]*[0-9].*/#define FF_CODE_PAGE\t$CODE_PAGE/" \
    -e 's/^#define[[:space:]][[:space:]]*FF_USE_LFN[[:space:]][[:space:]]*[0-9].*/#define FF_USE_LFN\t\t2/' \
    -e 's/^#define[[:space:]][[:space:]]*FF_FS_EXFAT[[:space:]][[:space:]]*[0-9].*/#define FF_FS_EXFAT\t1/' \
    -e "s/^#define[[:space:]][[:space:]]*FF_LFN_UNICODE[[:space:]][[:space:]]*[0-9].*/#define FF_LFN_UNICODE\t$LFN_UNICODE/" \
    "$FFCONF"
  echo "--- After patch ---"
  grep -nE "^#define[[:space:]]+(FF_CODE_PAGE|FF_USE_LFN|FF_FS_EXFAT|FF_LFN_UNICODE)" "$FFCONF" || true
done

if ! grep -hqE "^#define[[:space:]]+FF_CODE_PAGE[[:space:]]+$CODE_PAGE" $FFCONF_LIST; then
  echo "ERROR: FF_CODE_PAGE was NOT set to $CODE_PAGE"
  exit 1
fi
if ! grep -hqE "^#define[[:space:]]+FF_FS_EXFAT[[:space:]]+1" $FFCONF_LIST; then
  echo "ERROR: FF_FS_EXFAT was NOT set to 1"
  exit 1
fi
if ! grep -hqE "^#define[[:space:]]+FF_LFN_UNICODE[[:space:]]+$LFN_UNICODE" $FFCONF_LIST; then
  echo "ERROR: FF_LFN_UNICODE was NOT set to $LFN_UNICODE"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4) pre-C99 兼容补丁（仅 GCC 3.2.x 等老编译器需要）
#    FatFs r0.16 打开 exFAT 后：
#        #if FF_FS_EXFAT
#        #if FF_INTDEF != 2
#        #error exFAT feature wants C99 or later
#        #endif
#        typedef QWORD FSIZE_t;
#    老 GCC 走 pre-C99 分支（FF_INTDEF=1），QWORD 未定义 -> 上面 #error 触发，
#    之后凡是 FIL* / FSIZE_t 的声明全部 syntax error before '*'。
#    解决办法：保留 FF_INTDEF=1，去掉 #error，并补一个 64 位类型。
# ---------------------------------------------------------------------------
FFH_LIST="$(find "$FATSRC" -maxdepth 5 -name ff.h 2>/dev/null)"
echo "Found ff.h:"
echo "$FFH_LIST"

if [ "$C99" = "no" ]; then
  echo ">>> Applying pre-C99 (QWORD) compatibility patch to ff.h ..."
  for FFH in $FFH_LIST; do
    # 4a) 去掉 exFAT 的 C99 硬报错
    awk '
      /^[[:space:]]*#error[[:space:]]+exFAT feature wants C99 or later/ {
        print "/* A9VG: pre-C99 编译器下允许 exFAT，QWORD 在下面补定义 */"
        next
      }
      { print }
    ' "$FFH" > "$FFH.a9vg" && mv "$FFH.a9vg" "$FFH"

    # 4b) 在 pre-C99 分支（#define FF_INTDEF 1）后补 QWORD
    #     注意：C99 分支里也有一行 "typedef WORD WCHAR;"，不能拿它当锚点，
    #     否则会插到错误的分支里。FF_INTDEF 1 是 pre-C99 分支独有的。
    awk '
      BEGIN { done = 0 }
      /^[[:space:]]*#define[[:space:]]+FF_INTDEF[[:space:]]+1/ && done == 0 {
        print
        print "typedef unsigned long long QWORD;\t/* A9VG: 64-bit unsigned for pre-C99 */"
        done = 1
        next
      }
      { print }
    ' "$FFH" > "$FFH.a9vg" && mv "$FFH.a9vg" "$FFH"

    echo "--- patched $FFH ---"
    grep -nE "QWORD|A9VG" "$FFH" | head -10
  done

  if ! grep -hq "typedef unsigned long long QWORD" $FFH_LIST; then
    echo "ERROR: failed to inject QWORD typedef into ff.h"
    exit 1
  fi
  if grep -hq "exFAT feature wants C99 or later" $FFH_LIST; then
    echo "ERROR: ff.h still contains the C99 #error guard"
    exit 1
  fi
  echo "OK: ff.h patched for pre-C99 compiler."
else
  echo "Compiler supports C99 -> no ff.h patch needed."
fi

# ---------------------------------------------------------------------------
# 5) GCC 3.2.3 兼容补丁：ps2sdk master 的 IOP linkfile 用了 SUBALIGN(16)，
#    老 ld 不认识，链接时报 "parse error"。把它改回老格式即可。
# ---------------------------------------------------------------------------
LINKFILE="$PS2SDKSRC/iop/startup/src/linkfile"
if [ -f "$LINKFILE" ]; then
  echo ">>> Patching IOP linkfile for old binutils (remove SUBALIGN) ..."
  cp -f "$LINKFILE" "$LINKFILE.orig"
  sed -i -E 's/([[:space:]]*\.[a-zA-Z0-9_]+[[:space:]]+ALIGN\([0-9]+\)[[:space:]]*):[[:space:]]*SUBALIGN\([0-9]+\)/\1:/g' "$LINKFILE"
  sed -i -E 's/([[:space:]]*\.[a-zA-Z0-9_]+[[:space:]]*:[[:space:]]*\{[^}]*\}[[:space:]]*):[[:space:]]*SUBALIGN\([0-9]+\)/\1:/g' "$LINKFILE"
  # 兜底：再扫一遍，把单独出现的 SUBALIGN(...) 整段删掉
  sed -i -E 's/[[:space:]]*SUBALIGN\([0-9]+\)//g' "$LINKFILE"
  if grep -q "SUBALIGN" "$LINKFILE"; then
    echo "WARN: linkfile still contains SUBALIGN; restoring original"
    cp -f "$LINKFILE.orig" "$LINKFILE"
  else
    echo "OK: SUBALIGN removed from linkfile."
  fi

  # 老 ld 还无法解析 PROVIDE(_gp = ALIGN(16) + 0x7ff0) 里的 ALIGN 表达式，
  # 会报 "undefined symbol _gp referenced in expression"。改成用 _fdata 计算。
  if grep -qE 'PROVIDE\(_gp[[:space:]]*=[[:space:]]*ALIGN\(' "$LINKFILE"; then
    echo ">>> Patching IOP linkfile _gp for old binutils ..."
    sed -i -E 's/PROVIDE\(_gp[[:space:]]*=[[:space:]]*ALIGN\([0-9]+\)[[:space:]]*\+[[:space:]]*0x7ff0\)/PROVIDE(_gp = _fdata + 0x7ff0)/g' "$LINKFILE"
    if grep -qE 'PROVIDE\(_gp[[:space:]]*=[[:space:]]*_fdata[[:space:]]*\+[[:space:]]*0x7ff0\)' "$LINKFILE"; then
      echo "OK: _gp now uses _fdata + 0x7ff0."
    else
      echo "WARN: _gp patch may have failed, leaving as-is"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6) 重编 bdmfs_fatfs（这是唯一需要 CP936 的模块）
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
# 6) ISR 架构关键步骤：覆盖仓库内 iop/__precompiled/bdmfs_fatfs.irx
# ---------------------------------------------------------------------------
PRE="$WORKSPACE/iop/__precompiled"
mkdir -p "$PRE"
rm -f "$PRE/.a9vg_fatfs_ok"     # 清掉上次可能残留的成功标记
cp -f "$FATFS_IRX" "$PRE/bdmfs_fatfs.irx" \
  && echo "OK: updated $PRE/bdmfs_fatfs.irx (this is the copy embed.make embeds)"
touch "$PRE/.a9vg_fatfs_ok"     # 给 workflow 的 Verify 步骤当"确实换过驱动"的凭据

# ---------------------------------------------------------------------------
# 7) 强制校验 + 诊断输出
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
  echo "  (原版 CP869 为 37724 字节；FATFS_MODE=$FATFS_MODE 期望 >= $MIN_SIZE 字节)"
  if [ "$SIZE" -lt "$MIN_SIZE" ]; then
    echo "ERROR: bdmfs_fatfs.irx size is below expectation -> 认为构建不对"
    FATAL=1
  else
    echo "OK: bdmfs_fatfs.irx looks like a CP936 build."
  fi
fi

if [ "$FATAL" -eq 1 ] && [ "$ALLOW_UNPATCHED_FATFS" != "1" ]; then
  echo "FatFs CP936 patch FAILED."
  echo "（如需无论如何都继续出包，可设置环境变量 ALLOW_UNPATCHED_FATFS=1）"
  exit 1
fi

echo "FatFs Chinese patch complete."
echo "=========================================="
