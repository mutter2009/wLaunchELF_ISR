#!/bin/bash
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版 v13)
#-----------------------------------------------------------------------------
# ISR 架构关键点：embed.make 从仓库内 iop/__precompiled/bdmfs_fatfs.irx 把文件
# 系统驱动嵌入 ELF（EXFAT=1 与否用的都是同一个文件）。因此必须把重编产物覆盖到
# iop/__precompiled/ 才生效，只装到 $PS2SDK/iop/irx 是没用的。
#
# 版本演进
#   v5 : 自动探测 IOP 编译器是否支持 C99；不支持时才给 ff.h 打补丁。
#   v6 : 换成 ps2homebrew:main 镜像，EE 阶段缺旧版 libjpg（jpgOpenRAW 等 API），回退。
#   v7 : 回 ps2dev/ps2dev:v1.0 镜像，重编时引用安装版 IOP linkfile。
#        但 v1.0 镜像里 $PS2SDK/iop/startup/src/linkfile 并不存在，
#        find 误取到 ee/startup/linkfile（EE 脚本含 _text_size），链接报
#        "undefined symbol _text_size"。
#   v8 : compile.yml 安装 build-base，修 host gcc 缺失（srxfixup 无法编译）。
#   v9 : 就地修补 master clone 的 IOP linkfile（去 SUBALIGN + _gp 移入 .data）。
#        但 master 是滚动分支，不同时刻结构不一致，补丁命中不全，仍偶发
#        "undefined symbol _gp"。
#   v11: 修正 v10 链接脚本本身的 _gp 写法（PROVIDE 在 binutils 2.14 下不定义 _gp，
#        改为 .gp 段内普通赋值 _gp = . + 0x7ff0，并在 SECTIONS 前定义
#        _text_size/_data_size/_bss_size 常量）。已用 ps2dev/ps2dev:v1.0 镜像实测可链接。
#   v12: 把 IOP 链接脚本直接内嵌进本脚本（heredoc），不再依赖仓库里单独的
#        iop_linkfile_a9vg 文件。原因：v11 交付后用户只更新了 .sh、漏换 .a9vg，
#        导致脚本与链接脚本版本错配、_text_size 校验失败。自包含后只需替换本脚本一个文件。
#   v13: 修 srxfixup "unallocated variable `fs_driver_mount_info'"。老工具链 GCC 3.2.3
#        默认 -fcommon，未初始化全局进 COMMON 段；binutils 2.14 在 -dc -r 下不把
#        COMMON 分配进 .bss，老 srxfixup --irx1 因此报未分配变量。给 bdmfs_fatfs 的
#        IOP 编译加 -fno-common（与现代 GCC 默认一致），未初始化全局直接进 .bss。
#
# 设置 ALLOW_UNPATCHED_FATFS=1 可跳过体积校验（不建议）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition v13)"
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

# MAKE_FLAGS 会逐步收集 linkfile 覆盖、工具链前缀等，最后传给 make
MAKE_FLAGS=""

# ---------------------------------------------------------------------------
# 5) IOP linkfile：直接用仓库内置的静态兼容版，覆盖 master clone 的 linkfile
#
#   重编 bdmfs_fatfs 时，iop/Rules.make 默认用 $(PS2SDKSRC)/iop/startup/src/linkfile。
#   ps2sdk master 是滚动分支，其 linkfile 结构随时会变；之前用 sed/awk 实时补丁
#   它，先后踩过 SUBALIGN(parse error) 和 _gp(undefined symbol) 两个坑，且不同
#   时刻的 master 结构不一致导致补丁命中不全。
#
#   解决方案：仓库自带一份经过验证、兼容老工具链 (GCC 3.2.3 / binutils 2.14，
#   即 ps2dev/ps2dev:v1.0 镜像) 的完整 IOP linkfile（scripts/ci/iop_linkfile_a9vg）。
#   该脚本已在 v1.0 镜像里用真实 iop-ld 实测可链接，关键点：
#     - 无 SUBALIGN(...)（老 ld 会 parse error）
#     - _gp 用小数据段(.gp)内的普通赋值 "_gp = . + 0x7ff0" 定义（PROVIDE 写法
#       在 binutils 2.14 下不会真正定义 _gp）
#     - _text_size/_data_size/_bss_size 在 SECTIONS 之前用普通赋值定义成常量
#       （iop-ld mipsirx 仿真会无条件自动插入 .iopmod 段并 LONG() 引用这四个符号，
#       -dc -r 下前向引用必须提前定义；最终 iopmod 头由 srxfixup 重写）
#   直接把它复制到 master clone 的 linkfile 路径并覆盖，再让 IOP_LINKFILE 指向它。
#   这样完全不依赖 master 的实时结构，确定性最高。
# ---------------------------------------------------------------------------
# 5) IOP linkfile：脚本内置一份经过验证、兼容老工具链 (GCC 3.2.3 / binutils 2.14，
#    即 ps2dev/ps2dev:v1.0 镜像) 的完整 IOP linkfile，用 heredoc 直接写出并覆盖
#    master clone 的 linkfile。
#    —— 自包含，不再依赖仓库里单独的 iop_linkfile_a9vg 文件，彻底避免“漏换一个文件”
#       导致的链接脚本与 patch 脚本版本错配（v11 的 _gp / _text_size 校验失败即由此而来）。
#       该脚本已在 v1.0 镜像里用真实 iop-ld 实测可链接，关键点：
#         - 无 SUBALIGN(...)（老 ld 会 parse error）
#         - _gp 用小数据段(.gp)内的普通赋值 "_gp = . + 0x7ff0" 定义（PROVIDE 写法
#           在 binutils 2.14 下不会真正定义 _gp）
#         - _text_size/_data_size/_bss_size 在 SECTIONS 之前用普通赋值定义成常量
#           （iop-ld mipsirx 仿真会无条件自动插入 .iopmod 段并 LONG() 引用这四个符号，
#           -dc -r 下前向引用必须提前定义；最终 iopmod 头由 srxfixup 重写）
LINKFILE="$PS2SDKSRC/iop/startup/src/linkfile"
mkdir -p "$(dirname "$LINKFILE")"
emit_a9vg_linkfile() {
  cat > "$1" <<'A9VG_LINKFILE_EOF'
/*
# _____     ___ ____     ___ ____
#  ____|   |    ____|   |        | |____|
# |     ___|   |____ ___|    ____| |    \    PS2DEV Open Source Project.
#-----------------------------------------------------------------------
# Copyright ps2dev - http://www.ps2dev.org
# Licenced under Academic Free License version 2.0
# Review ps2sdk README & LICENSE files for further details.
#
# Linkfile script for iop-ld
#
# A9VG 定制版 IOP 链接脚本（兼容老工具链 GCC 3.2.3 / binutils 2.14，
# 即 CI 用的 ps2dev/ps2dev:v1.0 镜像）。基于官方 GNU ld 默认脚本，做了三处兼容：
#   1) 去掉所有 SUBALIGN 语法——binutils 2.14 的 iop-ld 不认识 SUBALIGN，
#      会直接 parse error。
#   2) _gp 用小数据段(.gp)内的普通赋值 "_gp = . + 0x7ff0" 定义。
#      binutils 2.14 不认 PROVIDE(_gp = ...)：那种写法会让 _gp 始终是
#      "undefined symbol"，链接报 "undefined symbol `_gp' referenced in expression"。
#   3) _text_size / _data_size / _bss_size 在 SECTIONS 之前用普通赋值定义成常量。
#      原因：iop-ld 的 mipsirx 仿真会无条件自动插入 .iopmod 段，里面以 LONG()
#      引用这四个符号；-dc -r 下若把它们定义在段之后会前向引用失败，所以必须
#      在 SECTIONS 之前先定义。最终 iopmod 头由 srxfixup 按真实段大小重写。
# 本文件由仓库自带，不再依赖 ps2sdk master 的实时 linkfile 结构。
*/

OUTPUT_FORMAT("elf32-littlemips", "elf32-bigmips",
        "elf32-littlemips")
OUTPUT_ARCH(mips)
ENTRY(_start)
 SEARCH_DIR("");
/* FORCE_COMMON_ALLOCATION */
/* Do we need any of these for elf?
   __DYNAMIC = 0;    */
/* 老 binutils 2.14 (iop-ld mipsirx) 会无条件自动插入 .iopmod 段，以 LONG() 引用
   _gp/_text_size/_data_size/_bss_size。-dc -r 下这些前向引用无法在段后解析，
   因此在此用普通赋值把它们先定义成常量（PROVIDE 不够，必须“已定义”）。
   _gp 之后会由 .gp 段重新赋为正确值；size 符号对 -G0 链接仅作占位，srxfixup 会重写 iopmod 头。 */
_gp = 0x7ff0;
_text_size = 0;
_data_size = 0;
_bss_size = 0;
SECTIONS
{
  /* Read-only sections, merged into text segment: */
  . = 0x0400000; /* Can conditionally be changed to . = 0x5ffe0000 + SIZEOF_HEADERS; */
  .interp     : { *(.interp)  } /* Can conditionally be removed */
  .reginfo ALIGN(16) : { *(.reginfo) }
  .hash          : { *(.hash)   }
  .dynsym        : { *(.dynsym)   }
  .dynstr        : { *(.dynstr)   }
  .gnu.version   : { *(.gnu.version)  }
  .gnu.version_d   : { *(.gnu.version_d)  }
  .gnu.version_r   : { *(.gnu.version_r)  }
  .rel.text      :
    { *(.rel.text) *(.rel.gnu.linkonce.t*) }
  .rela.text     :
    { *(.rela.text) *(.rela.gnu.linkonce.t*) }
  .rel.data      :
    { *(.rel.data) *(.rel.gnu.linkonce.d*) }
  .rela.data     :
    { *(.rela.data) *(.rel.gnu.linkonce.d*) }
  .rel.rodata    :
    { *(.rel.rodata) *(.rel.gnu.linkonce.r*) }
  .rela.rodata   :
    { *(.rela.rodata) *(.rela.gnu.linkonce.r*) }
  .rel.got       : { *(.rel.got)    }
  .rela.got      : { *(.rela.got)   }
  .rel.ctors     : { *(.rel.ctors)  }
  .rela.ctors    : { *(.rela.ctors) }
  .rel.dtors     : { *(.rel.dtors)  }
  .rela.dtors    : { *(.rela.dtors) }
  .rel.init      : { *(.rel.init) }
  .rela.init     : { *(.rela.init)  }
  .rel.fini      : { *(.rel.fini) }
  .rela.fini     : { *(.rela.fini)  }
  .rel.bss       : { *(.rel.bss)    }
  .rela.bss      : { *(.rela.bss)   }
  .rel.plt       : { *(.rel.plt)    }
  .rela.plt      : { *(.rela.plt)   }
  .init          : { *(.init) } =0
  .plt      : { *(.plt) }
  .text ALIGN(16) :
  {
    PROVIDE(_ftext = . );
    *(.text)
    *(.stub)
    /* .gnu.warning sections are handled specially by elf32.em.  */
    *(.gnu.warning)
    *(.gnu.linkonce.t*)
    *(.mips16.fn.*) *(.mips16.call.*)
  } =0
  PROVIDE(_etext = .);
  PROVIDE (etext = .);
  .fini      : { *(.fini)    } =0
  .rodata ALIGN(16) : { *(.rodata) *(.rodata.*) *(.gnu.linkonce.r*) }
  .rodata1   : { *(.rodata1) }
  /* Adjust the address for the data segment.  We want to adjust up to
     the same address within the page on the next page up.  */
  . = ALIGN(0x40000) + (. & (0x40000 - 1)); /* Can conditionally be changed to . = .; */
  .data ALIGN(16) :
  {
    PROVIDE(_fdata = .);
    *(.data)
    *(.gnu.linkonce.d*)
    CONSTRUCTORS
  }
  .data1   : { *(.data1) }
  .ctors         :
  {
    *(.ctors)
  }
  .dtors         :
  {
    *(.dtors)
  }
  .got           : { *(.got.plt) *(.got) }
  .dynamic       : { *(.dynamic) }
  /* We want the small data sections together, so single-instruction offsets
     can access them all, and initialized data all before uninitialized, so
     we can shorten the on-disk segment size.  */
  /* MIPS 小数据段：_gp 必须作为段内普通赋值定义（binutils 2.14 不认 PROVIDE(_gp=...)） */
  .gp ALIGN(16) :
  {
    _gp = . + 0x7ff0;
    *(.sdata)
    *(.sdata.*)
    *(.gnu.linkonce.s.*)
    *(.lit8)
    *(.lit4)
  } =0
  PROVIDE(_edata  =  .);
  PROVIDE (edata = .);
  __bss_start = .;
  PROVIDE(_fbss = .);
  .sbss      : { *(.sbss) *(.scommon) }
  .bss ALIGN(16) :
  {
   *(.dynbss)
   *(.bss)
   *(COMMON)
  }
  . = ALIGN(32 / 8);
  PROVIDE(_end = .);
  PROVIDE (end = .);
  /* .iopmod 段（iop-ld mipsirx 仿真自动插入）会引用以下四个 size 符号，
     老 binutils 2.14 必须在脚本里显式定义，否则报 undefined symbol。 */
  /* Stabs debugging sections.  */
  .stab 0 : { *(.stab) }
  .stabstr 0 : { *(.stabstr) }
  .stab.excl 0 : { *(.stab.excl) }
  .stab.exclstr 0 : { *(.stab.exclstr) }
  .stab.index 0 : { *(.stab.index) }
  .stab.indexstr 0 : { *(.stab.indexstr) }
  .comment 0 : { *(.comment) }
  /* DWARF debug sections.
     Symbols in the DWARF debugging sections are relative to the beginning
     of the section so we begin them at 0.  */
  /* DWARF 1 */
  .debug          0 : { *(.debug) }
  .line           0 : { *(.line) }
  /* GNU DWARF 1 extensions */
  .debug_srcinfo  0 : { *(.debug_srcinfo) }
  .debug_sfnames  0 : { *(.debug_sfnames) }
  /* DWARF 1.1 and DWARF 2 */
  .debug_aranges  0 : { *(.debug_aranges) }
  .debug_pubnames 0 : { *(.debug_pubnames) }
  /* DWARF 2 */
  .debug_info     0 : { *(.debug_info) }
  .debug_abbrev   0 : { *(.debug_abbrev) }
  .debug_line     0 : { *(.debug_line) }
  .debug_frame    0 : { *(.debug_frame) }
  .debug_str      0 : { *(.debug_str) }
  .debug_loc      0 : { *(.debug_loc) }
  .debug_macinfo  0 : { *(.debug_macinfo) }
  /* SGI/MIPS DWARF 2 extensions */
  .debug_weaknames 0 : { *(.debug_weaknames) }
  .debug_funcnames 0 : { *(.debug_funcnames) }
  .debug_typenames 0 : { *(.debug_typenames) }
  .debug_varnames  0 : { *(.debug_varnames) }
  /* These must appear regardless of  .  */
  .gptab.sdata : { *(.gptab.data) *(.gptab.sdata) }
  .gptab.sbss : { *(.gptab.bss) *(.gptab.sbss) }
  /*
   * These are the stuff that we don't want to be put in an IRX.
   */
  /DISCARD/ : {
    * ( .MIPS.abiflags )
  }
}
A9VG_LINKFILE_EOF
}
emit_a9vg_linkfile "$LINKFILE"
if [ ! -f "$LINKFILE" ]; then
  echo "ERROR: failed to install IOP linkfile to $LINKFILE" >&2
  exit 1
fi
if grep -qE 'SUBALIGN\([0-9]' "$LINKFILE"; then
  echo "ERROR: installed linkfile unexpectedly contains SUBALIGN syntax" >&2
  exit 1
fi
# 老 binutils 2.14 要求：_gp 必须用小数据段(.gp)内的普通赋值 "_gp = . + 0x7ff0" 定义
if ! grep -qE '_gp = \. \+ 0x7ff0' "$LINKFILE"; then
  echo "ERROR: installed linkfile missing '_gp = . + 0x7ff0' inside .gp section" >&2
  exit 1
fi
# iop-ld mipsirx 自动插入的 .iopmod 段会 LONG() 引用这三个 size 符号，必须提前定义
if ! grep -qE '_text_size = 0;' "$LINKFILE"; then
  echo "ERROR: installed linkfile missing top-level _text_size constant" >&2
  exit 1
fi
echo "OK: IOP linkfile installed (SUBALIGN-free, _gp in .gp section, size symbols defined)."
export IOP_LINKFILE="$LINKFILE"
IOP_LINKFILE="$LINKFILE"
echo "IOP_LINKFILE=$IOP_LINKFILE"

# ---------------------------------------------------------------------------
# 6) 重编 bdmfs_fatfs（这是唯一需要 CP936 的模块）
# ---------------------------------------------------------------------------
echo "Touching FatFs sources to force rebuild..."
find "$FATSRC" -maxdepth 4 -name '*.[ch]' -exec touch {} + 2>/dev/null || true

MAKE_FLAGS="IOP_TOOL_PREFIX=$IOPP CC=$HOSTCC $MAKE_FLAGS"
MAKE_FLAGS="$MAKE_FLAGS IOP_WARNFLAGS=-Wall IOP_DBGINFOFLAGS=-gdwarf-2"
# 老工具链 GCC 3.2.3 默认 -fcommon，未初始化的全局变量会进 COMMON 段；而 binutils 2.14
# 在 -dc -r（可重定位）链接下不会把 COMMON 分配进 .bss，老 srxfixup --irx1 因此报
# "unallocated variable"。加 -fno-common 让未初始化全局直接进 .bss（已分配段），
# 与现代 GCC 默认行为一致，srxfixup 不再报错。IOP_CFLAGS 末尾自带 $(IOP_CFLAGS) 追加，
# 故在 make 命令行传 IOP_CFLAGS=-fno-common 会拼到完整参数后、不会覆盖 -D_IOP/-G0 等。
MAKE_FLAGS="$MAKE_FLAGS IOP_CFLAGS=-fno-common"
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
