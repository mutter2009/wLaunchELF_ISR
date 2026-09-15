#!/bin/bash
#=============================================================================
# Patch FatFs for Chinese (GBK / CP936) long file names on FAT32 + exFAT
# (wLaunchELF_ISR 专用版 v18)
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
#   v14: 修 v13 的回归。v13 在 make 命令行传 IOP_CFLAGS=-fno-common，但 GNU make 中
#        命令行赋值会整体覆盖 Rules.make 里的 "IOP_CFLAGS := ..." := 整行，把原定义
#        （含 -D_IOP/-G0 与所有 -I 头文件路径）一并冲掉，导致编译找不到 bdm.h/intrman.h
#        等头文件。改为就地 sed 改 iop/Rules.make，在原有 IOP_CFLAGS 定义里追加上
#        -fno-common，完整保留既有 flag 与 include 路径。已在 v1.0 镜像实测：头文件可
#        找到、fs_driver_mount_info 进 .bss（B）、链接阶段不再触发 srxfixup 报错。
#   v15: 重建整个 BDM/USB 驱动链而不仅是 bdmfs_fatfs。v14 只重编了 bdmfs_fatfs，而
#        仓库预装的 bdm.irx / usbmass_bd.irx 来自与 ps2sdk master 不同版本的工具链/API，
#        导致新版 bdmfs_fatfs 与旧版 bdm/usbmass_bd 不兼容，USB 设备能打开路径但列不出
#        文件（FAT32/exFAT 均空白）。现在依次重编 bdm、usbmass_bd、bdmfs_fatfs，并把三
#        个 .irx 同时装到 $PS2SDK/iop/irx/ 与仓库 iop/__precompiled/，确保 ELF 嵌入的
#        是一套同源同版本的驱动。R3Z 的成功经验也是同时替换这三个模块。
#   v17: v15 漏了 USB 链路最底层的 usbd.irx。embed.make 里 usbd 取自
#        $(PS2SDK)/iop/irx/usbd.irx（即 v1.0 镜像自带的旧版），而 usbmass_bd/bdm/
#        bdmfs_fatfs 取自仓库 iop/__precompiled/（我们从 master 重编的新版）。
#        于是形成"新 usbmass_bd + 旧 usbd"的版本错配：usbmass_bd 依赖新版 usbd 的
#        导出接口，加载后枚举不到设备，表现为 mass:/ 能进但列不出文件。
#        R3Z 能识别同一 U 盘，正因为它用 ps2homebrew:main 新工具链，usbd.irx 也是新版。
#        v17 把 usbd 也从同一份 master 源码重编并覆盖 $PS2SDK/iop/irx/usbd.irx
#        （embed.make 取 usbd 的唯一路径），保证整条链路同源同版本。
#        usbd 编译若失败则降级为警告（保留旧版继续出包），不阻断 CI。
#   v18: 已在 ps2dev/ps2dev:v1.0 真实工具链上把四个模块全跑通，修掉 v17 实测暴露的
#        三个硬伤（v17 在真机 CI 里其实一个模块都换不成）：
#        1) IOP linkfile 不能造 .gp 段。srxfixup 只认 .sdata/.lit8/.lit4 三个段名
#           （见 tools/srxfixup/src/iopfixconf.c）。usbd 用 IOP_PREFER_GPOPT=16384
#           （-mgpopt -G16384），几乎全部静态数据进 .sdata，合成 .gp 后直接
#             Error: section '.gp' needs allocation and has relocation data
#                    but not in program segment
#           -> 改回独立的 .sdata/.lit8/.lit4 段，_gp 用段外普通赋值定义。
#        2) ps2sdk master 有 C99 语法（如 bdm 的 for(int i=...)），GCC 3.2.3 默认
#           gnu89 直接 error -> 加"按需 -std=gnu99 重试"，编完还原 Rules.make。
#        3) ps2sdk master 还有 C11 写法（usbmass_bd 的 static_assert），GCC 3.2.3
#           报 syntax error -> 写 a9vg_compat.h 兼容垫片，用 -include 注入。
#           同时把 FatFs 的 C99 分支焊死（#elif 0），避免 gnu99 下 #include <stdint.h>
#           失败（IOP 老工具链没有 stdint.h）。
#        另：每个模块构建前先 make clean，避免上一次的旧产物被 make 当成最新。
#
# 设置 ALLOW_UNPATCHED_FATFS=1 可跳过体积校验（不建议）。
#=============================================================================
set -u

echo "=========================================="
echo "FatFs Chinese LFN patch script (ISR edition v18)"
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
# 打印实际用到的 commit：master 是滚动分支，万一哪天又编不过，日志里有 commit 才好定位
PS2SDK_HEAD="$(git -C "$PS2SDKSRC" rev-parse HEAD 2>/dev/null || echo '<unknown: 源码树无 .git>')"
echo "ps2sdk HEAD = $PS2SDK_HEAD"
echo "（若需锁定版本，可把 workflow 里的 PS2SDKREF 设为某个 commit sha）"

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
    # 4a2) 关键：把 "C99 or later" 那个 #elif 直接关掉，强制走 pre-C99 分支。
    #      原因：本脚本后面有 -std=gnu99 兜底重试；一旦某个模块用 gnu99 编，
    #      __STDC_VERSION__ 就被定义，FatFs 会跳进 C99 分支去 #include <stdint.h>，
    #      而 IOP 的老 GCC 3.2.3 根本没有 stdint.h，立刻
    #         "stdint.h: No such file or directory" + 一连串 syntax error。
    #      把这一路焊死，FatFs 永远用我们补的 QWORD / BYTE / WORD / DWORD。
    if grep -qE '^#elif .*__STDC_VERSION__ >= 199901L' "$FFH"; then
      sed -i -E 's|^#elif[[:space:]].*__STDC_VERSION__ >= 199901L.*$|#elif 0\t/* A9VG: 老工具链无 stdint.h，强制走 pre-C99 分支 */|' "$FFH"
      echo "--- forced pre-C99 branch in $FFH ---"
    fi

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
    #     幂等：已经插过就不再插（否则重复 typedef 会 redefinition of `QWORD'）。
    if grep -q 'typedef unsigned long long QWORD' "$FFH"; then
      echo "--- QWORD typedef already present in $FFH, skipping ---"
    else
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
    fi

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
  /* MIPS 小数据段。
     重要：.sdata / .lit8 / .lit4 必须是各自独立的输出段，不能合成一个 .gp 段！
     srxfixup 的 IOP 配置（tools/srxfixup/src/iopfixconf.c）只认
         .sdata  { @segment {DATA GLOBALDATA} }
         .lit8   { @segment {DATA GLOBALDATA} }
         .lit4   { @segment {DATA GLOBALDATA} }
     这三个名字。若把它们塞进自定义段 .gp，srxfixup 会报
         "Error: section '.gp' needs allocation and has relocation data
                  but not in program segment"
     并让构建失败（ps2sdk 的 iop/usb/usbd 用了 IOP_PREFER_GPOPT=16384，
     即 -mgpopt -G16384，几乎全部静态数据都进 .sdata，必踩这个坑）。
     _gp 仍用「段外普通赋值」定义——binutils 2.14 不认 PROVIDE(_gp=...)。 */
  _gp = ALIGN(16) + 0x7ff0;
  .sdata     : { *(.sdata) *(.sdata.*) *(.gnu.linkonce.s.*) }
  .lit8      : { *(.lit8) }
  .lit4      : { *(.lit4) }
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
# 老 binutils 2.14 要求：_gp 必须是段外普通赋值 "_gp = ALIGN(16) + 0x7ff0"（PROVIDE 不生效）
if ! grep -qE '_gp = ALIGN\(16\) \+ 0x7ff0' "$LINKFILE"; then
  echo "ERROR: installed linkfile missing '_gp = ALIGN(16) + 0x7ff0'" >&2
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
# 6) 重编整个 BDM/USB 驱动链（确保同源同版本，避免模块间 API 不兼容）
# ---------------------------------------------------------------------------
MAKE_FLAGS="IOP_TOOL_PREFIX=$IOPP CC=$HOSTCC $MAKE_FLAGS"
MAKE_FLAGS="$MAKE_FLAGS IOP_WARNFLAGS=-Wall IOP_DBGINFOFLAGS=-gdwarf-2"
# 老工具链 GCC 3.2.3 默认 -fcommon，未初始化的全局变量（如 fs_driver_mount_info）会进
# COMMON 段；而 binutils 2.14 在 -dc -r（可重定位）链接下不会把 COMMON 分配进 .bss，
# 老 srxfixup --irx1 因此对不在“已分配段”的符号报 "unallocated variable"。加 -fno-common
# 让未初始化全局直接进 .bss（已分配段），与现代 GCC 默认行为一致，srxfixup 不再报错。
#
# 关键坑：iop/Rules.make 里 IOP_CFLAGS 是 “IOP_CFLAGS := -D_IOP -fno-builtin -G0 ... $(IOP_CFLAGS)”
# 的 := 立即赋值。GNU make 中「命令行赋值会整体覆盖 := 整行」——若在 make 命令行传
# “IOP_CFLAGS=-fno-common”，会把原定义（含 -D_IOP/-G0 以及所有 -I 头文件路径）整个冲掉，
# 导致编译时找不到 bdm.h/intrman.h 等头文件。所以不能走命令行覆盖，必须就地改 Rules.make：
# 在原有 IOP_CFLAGS 定义里追加上 -fno-common，从而完整保留既有 flag 与 include 路径。
RULES_MAKE="$PS2SDKSRC/iop/Rules.make"
if [ -f "$RULES_MAKE" ]; then
  if grep -qE 'IOP_CFLAGS := .*-fno-builtin -G0' "$RULES_MAKE"; then
    # 幂等：只在没加过时追加（脚本重跑会在同一棵源码树上累积重复 flag）
    if ! grep -qE 'IOP_CFLAGS := .*-fno-common' "$RULES_MAKE"; then
      sed -i -E 's|^(IOP_CFLAGS := -D_IOP -fno-builtin -G0)( .*)$|\1 -fno-common\2|' "$RULES_MAKE"
    fi
    echo "OK: appended -fno-common to IOP_CFLAGS in $RULES_MAKE"
  else
    echo "WARN: IOP_CFLAGS line not in expected form; falling back to command-line IOP_CFLAGS=-fno-common" >&2
    MAKE_FLAGS="$MAKE_FLAGS IOP_CFLAGS=-fno-common"
  fi
else
  echo "WARN: $RULES_MAKE not found; falling back to command-line IOP_CFLAGS=-fno-common" >&2
  MAKE_FLAGS="$MAKE_FLAGS IOP_CFLAGS=-fno-common"
fi
[ -n "$EEP" ] && MAKE_FLAGS="$MAKE_FLAGS EE_TOOL_PREFIX=$EEP"
echo "make flags: $MAKE_FLAGS"

# ---------------------------------------------------------------------------
# C99 兜底开关
#   ps2sdk master 早就改用 C99 写法（比如 iop/fs/bdm/src/part_driver.c 里的
#   "for (int i = 0; ...)"）。老工具链 GCC 3.2.3 默认 gnu89，遇到这种写法直接
#   报 error：'for' loop initial declaration used outside C99 mode。
#   解决办法是给 IOP_CFLAGS 追加 -std=gnu99（3.2.3 支持该选项）。
#
#   但 gnu99 会改变 inline 语义、也可能影响 FatFs 的编译，不能无脑全局开。
#   所以这里做成「按需、可逆」：每个模块先用默认 flag 编，失败就临时开 gnu99
#   重试，编完立刻把 Rules.make 还原，保证下一个模块又是默认状态。
# ---------------------------------------------------------------------------
RULES_BAK="${RULES_MAKE}.a9vg.bak"
[ -f "$RULES_MAKE" ] && cp -f "$RULES_MAKE" "$RULES_BAK"

# --- C11 兼容垫片 -------------------------------------------------------------
# ps2sdk master 里已经有 C11 写法：iop/usb/usbmass_bd/src/scsi.c 用了 3 处
#   static_assert(sizeof(inquiry_data) == 36);
# 而 static_assert 是 C11 / GCC 4.6+ 才有的，GCC 3.2.3 遇到它直接
#   "syntax error before `sizeof'"（被当成隐式 int 的旧式声明）。
# 做法：写一个兼容头，把它降级成"数组大小断言"（失败时报 size of array is
# negative），再用 -include 注入到每个 IOP 编译单元最前面。
# 之所以用 -include 而不是 -D'static_assert(x)='：括号在 make 展开的 shell
# 命令行里要额外转义，容易踩坑；-include 无空格无括号，最稳。
A9VG_COMPAT_H="$PS2SDKSRC/common/include/a9vg_compat.h"
mkdir -p "$(dirname "$A9VG_COMPAT_H")"
cat > "$A9VG_COMPAT_H" <<'A9VG_COMPAT_EOF'
/* A9VG: 老工具链 (GCC 3.2.3 / binutils 2.14) 兼容垫片
   由 CI 脚本 patch_fatfs_chinese.sh 生成，通过 -include 注入每个 IOP 编译单元。 */
#ifndef A9VG_COMPAT_H
#define A9VG_COMPAT_H

/* C11 的 static_assert：GCC < 4.6 没有，降级为"数组大小编译期断言"。
   断言失败时编译器报 "size of array is negative"，效果等价。 */
#if defined(__GNUC__) && (__GNUC__ * 100 + __GNUC_MINOR__) < 406
#ifndef static_assert
#define A9VG_SA_CAT2(a, b) a##b
#define A9VG_SA_CAT(a, b)  A9VG_SA_CAT2(a, b)
#define static_assert(x)   typedef char A9VG_SA_CAT(a9vg_static_assert_, __LINE__)[(x) ? 1 : -1]
#endif
#endif

#endif /* A9VG_COMPAT_H */
A9VG_COMPAT_EOF
echo "OK: wrote C11 compat shim -> $A9VG_COMPAT_H"

if [ -f "$RULES_MAKE" ]; then
  if ! grep -qE 'IOP_CFLAGS := .*a9vg_compat\.h' "$RULES_MAKE"; then
    if grep -qE 'IOP_CFLAGS := .*-fno-builtin -G0' "$RULES_MAKE"; then
      sed -i -E "s|^(IOP_CFLAGS := -D_IOP -fno-builtin -G0)( .*)\$|\1 -include $A9VG_COMPAT_H\2|" "$RULES_MAKE"
      echo "OK: injected -include a9vg_compat.h into IOP_CFLAGS"
    else
      sed -i -E "s|^(IOP_CFLAGS := )(.*)\$|\1-include $A9VG_COMPAT_H \2|" "$RULES_MAKE"
      echo "OK: injected -include a9vg_compat.h into IOP_CFLAGS (fallback form)"
    fi
  else
    echo "OK: -include a9vg_compat.h already present in IOP_CFLAGS"
  fi
  cp -f "$RULES_MAKE" "$RULES_BAK"
fi

rules_have_gnu99() {
  [ -f "$RULES_MAKE" ] && grep -qE 'IOP_CFLAGS := .*-std=gnu99' "$RULES_MAKE"
}

enable_gnu99() {
  if [ ! -f "$RULES_MAKE" ]; then
    echo "WARN: $RULES_MAKE missing; cannot enable -std=gnu99" >&2
    return 0
  fi
  if grep -qE 'IOP_CFLAGS := .*-fno-builtin -G0' "$RULES_MAKE"; then
    sed -i -E 's|^(IOP_CFLAGS := -D_IOP -fno-builtin -G0)( .*)$|\1 -std=gnu99\2|' "$RULES_MAKE"
  else
    sed -i -E 's|^(IOP_CFLAGS := )(.*)$|\1-std=gnu99 \2|' "$RULES_MAKE"
  fi
  rules_have_gnu99 || echo "WARN: failed to enable -std=gnu99 in $RULES_MAKE" >&2
}

restore_rules() {
  [ -f "$RULES_BAK" ] && cp -f "$RULES_BAK" "$RULES_MAKE"
}

# 强制重新编译 FatFs 源（bdmfs_fatfs 会按需拉取 FatFs，这里 touch 保证它重编）
echo "Touching FatFs sources to force rebuild..."
find "$FATSRC" -maxdepth 4 -name '*.[ch]' -exec touch {} + 2>/dev/null || true

# 辅助函数：编译 IOP 模块并把 .irx 安装到系统路径与仓库预编译目录
#   默认 flag 编不过时，自动用 -std=gnu99 重试一次（ps2sdk master 含 C99 语法），
#   编完还原 Rules.make，避免影响后续模块。
install_iop_module() {
  local mod_path="$1"
  local irx_name="$2"
  local mod_label="$3"

  echo "Building $mod_label ($mod_path) ..."
  # 先清干净：残留的 obj/ 与 irx/*.elf 可能来自上一次（含旧链接脚本的）构建，
  # 会让 make 跳过重编、直接拿旧产物去跑 srxfixup，出现莫名其妙的报错。
  make -C "$mod_path" clean >/dev/null 2>&1 || true
  if ! make -C "$mod_path" all $MAKE_FLAGS; then
    echo ">>> $mod_label: default (gnu89) build failed, retrying with -std=gnu99 ..."
    enable_gnu99
    make -C "$mod_path" clean >/dev/null 2>&1 || true
    if ! make -C "$mod_path" all $MAKE_FLAGS; then
      restore_rules
      echo "ERROR: build failed for $mod_path (both gnu89 and gnu99)" >&2
      return 1
    fi
    restore_rules
    echo "OK: $mod_label built with -std=gnu99"
  fi

  local built_irx
  built_irx="$(find "$mod_path" -maxdepth 2 -name "$irx_name" 2>/dev/null | head -1)"
  if [ -z "$built_irx" ]; then
    echo "ERROR: $irx_name was not produced in $mod_path" >&2
    return 1
  fi
  echo "built: $built_irx ($(wc -c < "$built_irx") bytes)"

  # 安装到系统 PS2SDK（embed.make 可能优先从这里取）
  mkdir -p "$PS2SDK/iop/irx"
  cp -f "$built_irx" "$PS2SDK/iop/irx/$irx_name" \
    && echo "OK: installed $irx_name -> $PS2SDK/iop/irx/"

  # 同时覆盖仓库 iop/__precompiled/（ISR embed.make 明确从这里嵌入 bdmfs_fatfs）
  mkdir -p "$PRE"
  cp -f "$built_irx" "$PRE/$irx_name" \
    && echo "OK: installed $irx_name -> $PRE/"

  return 0
}

# 依次构建 USB 主机控制器、BDM 核心、USB 大容量存储块设备、FAT/exFAT 文件系统。
# bdm 的 Makefile 会在需要时自动先构建 libbdm.a，所以无需单独处理 libbdm。
#
# 关键：usbd.irx 必须一起重建！
#   embed.make 里 USB 链路取自两个不同来源：
#     $(EE_ASM_DIR)usbd_irx.s:        $(PS2SDK)/iop/irx/usbd.irx        <- v1.0 镜像自带(老)
#     $(EE_ASM_DIR)usbmass_bd_irx.s:  iop/__precompiled/usbmass_bd.irx  <- 我们从 master 重编(新)
#   只换下面三个、留着 v1.0 镜像里的老 usbd，会形成"新 usbmass_bd + 老 usbd"的
#   版本错配：usbmass_bd 依赖新版 usbd 的导出接口，加载后枚举不到设备，
#   表现为 mass:/ 能进但列不出文件（FAT32/exFAT 都空白）。
#   R3Z 版本能识别同一 U 盘，正因为它用 ps2homebrew:main 新工具链，usbd.irx 也是新版。
#   所以这里把 usbd 也从同一份 master 源码重编，并覆盖 $PS2SDK/iop/irx/usbd.irx
#   （embed.make 取 usbd 的唯一路径），保证整条链路同版本。
PRE="$WORKSPACE/iop/__precompiled"
rm -f "$PRE/.a9vg_fatfs_ok"     # 清掉上次可能残留的成功标记
rm -f "$PRE/.a9vg_usbd_ok"      # 同上（usbd 重建成功标记）

# 注：usbd 只在“成功”时覆盖。若它在老工具链下编译失败，不能让整个 CI 挂掉——
#     此时保留镜像自带的老 usbd 继续出包，但日志会打出醒目警告说明 USB 可能仍不可用。
if install_iop_module "$PS2SDKSRC/iop/usb/usbd" "usbd.irx" "USB host driver"; then
  touch "$PRE/.a9vg_usbd_ok"
else
  echo "WARNING: usbd.irx 未重建（保留镜像自带旧版），USB 设备可能仍然无法识别！" >&2
fi
install_iop_module "$PS2SDKSRC/iop/fs/bdm"         "bdm.irx"         "BDM core"          || exit 1
install_iop_module "$PS2SDKSRC/iop/usb/usbmass_bd" "usbmass_bd.irx"  "USB mass storage"  || exit 1
install_iop_module "$PS2SDKSRC/iop/fs/bdmfs_fatfs" "bdmfs_fatfs.irx" "FAT/exFAT fs"      || exit 1

touch "$PRE/.a9vg_fatfs_ok"     # 给 workflow 的 Verify 步骤当"确实换过驱动"的凭据

# ---------------------------------------------------------------------------
# 7) 强制校验 + 诊断输出
# ---------------------------------------------------------------------------
echo "=========================================="
echo "System PS2SDK IRX dir ($PS2SDK/iop/irx):"
ls -la "$PS2SDK/iop/irx"/usbd.irx "$PS2SDK/iop/irx"/bdm.irx "$PS2SDK/iop/irx"/usbmass_bd.irx "$PS2SDK/iop/irx"/bdmfs_fatfs.irx 2>&1 || true
echo "Repo precompiled dir ($PRE) now contains:"
ls -la "$PRE" 2>/dev/null | head -20

FATAL=0

# 校验四个核心 IRX 都已就位（usbd 是 USB 链路最底层，缺了就枚举不到设备）
for irx in usbd.irx bdm.irx usbmass_bd.irx bdmfs_fatfs.irx; do
  # usbd 允许降级：未重建时只警告，不判致命（老版仍在，至少能出包）
  if [ "$irx" = "usbd.irx" ] && [ ! -f "$PRE/.a9vg_usbd_ok" ]; then
    echo "WARNING: usbd.irx 未重建，ELF 里嵌入的仍是镜像自带的旧版 usbd ——" \
         "可能与新版 usbmass_bd 不兼容，USB 设备可能仍然读不到文件。"
    continue
  fi
  if [ ! -f "$PRE/$irx" ]; then
    echo "ERROR: $PRE/$irx is missing!"
    FATAL=1
  elif [ ! -f "$PS2SDK/iop/irx/$irx" ]; then
    echo "ERROR: $PS2SDK/iop/irx/$irx is missing!"
    FATAL=1
  else
    SIZE=$(wc -c < "$PRE/$irx" | tr -d ' ')
    echo "OK: $irx installed ($SIZE bytes)"
  fi
done

# bdmfs_fatfs 体积校验（判断是否真的带 LFN/CP936）
if [ -f "$PRE/bdmfs_fatfs.irx" ]; then
  SIZE=$(wc -c < "$PRE/bdmfs_fatfs.irx" | tr -d ' ')
  echo "bdmfs_fatfs.irx size = $SIZE bytes"
  echo "  (原版 CP869 为 37724 字节；FATFS_MODE=$FATFS_MODE 期望 >= $MIN_SIZE 字节)"
  if [ "$SIZE" -lt "$MIN_SIZE" ]; then
    echo "ERROR: bdmfs_fatfs.irx size is below expectation -> 认为构建不对"
    FATAL=1
  else
    echo "OK: bdmfs_fatfs.irx looks like a CP936 build."
    if [ "$SIZE" -gt 150000 ]; then
      echo "HINT: bdmfs_fatfs 超过 150KB（CP936 两张码表把 IOP 内存吃得很紧）。" \
           "若实机仍然读不到 U 盘文件、或进 mass:/ 黑屏/重启，"
      echo "      优先在 workflow 里加环境变量 FATFS_MODE=utf8 重编一次：" \
           "IRX 只有约 40KB，汉化版的 decode_any() 本来就优先按 UTF-8 解码。"
    fi
  fi
fi

if [ "$FATAL" -eq 1 ] && [ "$ALLOW_UNPATCHED_FATFS" != "1" ]; then
  echo "FatFs CP936 patch FAILED."
  echo "（如需无论如何都继续出包，可设置环境变量 ALLOW_UNPATCHED_FATFS=1）"
  exit 1
fi

echo "FatFs Chinese patch complete."
echo "=========================================="
